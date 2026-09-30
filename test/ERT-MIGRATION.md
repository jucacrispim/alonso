# Plano — migrar a suíte do alonso para ERT

Branch de trabalho: **`refactor-tests`**.
Suíte atual (baseline no início do refactor): **282 passed, 0 failed**
(commit-base `b885eac`).

## Status — CONCLUÍDO

Todas as fases foram aplicadas (commits `f765cdf` … fase 6), um commit por
fase. O runner é agora o ERT: `emacs -Q --batch -l test/alonso-tests.el`
→ **282 testes, 0 falhas**. A suíte antiga (asserts como efeito do load)
foi removida; `alonso-tests-lib.el` guarda só as declarações e helpers, e
`alonso-tests-ert.el` (scaffold da fase 0) foi apagado.

Rodar um subconjunto por tag (o runner auto-encerra ao rodar tudo):

    emacs -Q --batch -L test -l alonso-tests-lib.el -l alonso-ui-tests.el \
      --eval '(ert-run-tests-batch-and-exit (quote (tag ui)))'

Tags: `client`, `ui`, `tools`, `markdown`, `image`.

## Decisões confirmadas

1. **Granularidade: um `ert-deftest` por asserção.** Preserva o relatório
   linha-a-linha atual (o ERT aborta o teste no primeiro `should` que falha,
   então agrupar perderia asserções).
2. **Um commit por fase.**
3. Branch dedicado `refactor-tests`.

## 1. Inventário atual (medido)

| Arquivo | linhas | `alonso-tests--assert` | blocos top-level de teste |
|---|---|---|---|
| `test/alonso-tests.el` (runner) | 31 | 1 (só o summary) | — |
| `test/alonso-tests-lib.el` (harness) | 192 | — | — |
| `test/alonso-client-tests.el` | 406 | 41 | ~2 blocos grandes + helpers |
| `test/alonso-ui-tests.el` | 1197 | 113 | ~27 `let` + 14 `unwind-protect` |
| `test/alonso-tools-tests.el` | 640 | 59 | ~20 blocos |
| `test/alonso-markdown-tests.el` | 196 | 32 | ~22 `with-rendered` + 3 `let` |
| `test/alonso-image-tests.el` | 392 | 30 | ~18 blocos |

**Total: ~275 asserções.** Nenhum CI/Makefile hoje; roda só via
`emacs -Q --batch -l test/alonso-tests.el`.

Modelo atual: *asserts como efeito colateral do load* (cada `let` top-level
chama `alonso-tests--assert`). ERT precisa do oposto: cada teste é um
`ert-deftest` sem efeito no load.

## 2. Design-alvo

- `test/alonso-tests-lib.el` → só **setup compartilhado**:
  `declare-function`/`defvar`, macros de fixture (`alonso-tests--with-rendered`,
  `alonso-tests--with-pair`, …), e resets. **Some** o `alonso-tests--assert` e
  os contadores.
- Cada arquivo vira `ert-deftest`s com `(require 'ert)`.
- `alonso-tests.el` vira: `(require ...)` + `(ert-run-tests-batch-and-exit)`.
- Execução seletiva via **tags** (`ui`, `tools`, `client`, `markdown`, `image`,
  `slow`).

### Regra de conversão (um deftest por asserção)

- Um `ert-deftest` por asserção.
- Setup repetido vira **fixture** ou macro `with-*`, não `let` compartilhado.
- Só agrupar vários `should` num mesmo deftest quando o setup for caro **e** as
  asserções forem de fato uma coisa só.

## 3. Mecânica de conversão (por padrão)

| Hoje | Depois |
|---|---|
| `(alonso-tests--assert "lbl" cond)` | `(ert-deftest nome () (should cond))` |
| bloco `(let ((x ...)) (assert ...) (assert ...))` | `deftest`s com `:fixture` ou `(alonso-tests--with-x ...)` |
| `(dolist (case ...) (assert (format ...)))` | `dolist` de `should` num único deftest com `ert-info`, ou macro geradora |
| `(alonso-tests--with-rendered text ...)` | idem como **macro de fixture**, usada dentro do deftest |
| `unwind-protect` com `make-temp-file` | fixture `:before`/`:after`, ou `unwind-protect` dentro do deftest |

Nomes de teste: `alonso-<area>--<slug>` (ex.: `alonso-ui--format-tokens-1000`).

Erros viram **erro de teste** (com backtrace), não abortam o arquivo.

## 4. Fixtures necessárias

- `alonso-tests--reset-windows` (já existe) + reset de `alonso--pair-restore`,
  `window-atom`, `dedicated` → fixture `pair` para os `unwind-protect` de
  `ui-tests`.
- `alonso--reset-session` em `:before` dos testes de sessão/tokens.
- Limpeza dos buffers `alonso` / `alonso-chat` / `*alonso-img-*` entre testes.
- Temp dirs (`make-temp-file`) → helper `alonso-tests--with-temp-dir`.
- `cl-letf` de `alonso--prompt-json` / `gui-get-selection` / `transient` →
  permanecem dentro do corpo do deftest.

## 5. Risco por dependência de ordem/estado

O runner atual dá `require` em ordem fixa (client→ui→tools→markdown→image) e os
blocos compartilham estado global (buffers `alonso`/`alonso-chat`, janelas,
`alonso--pair-restore`, sessão). O ERT **ordena por nome** e não garante a
sequência atual → todo estado "herdado" precisa virar **fixture explícita**.
Esse é o grosso do trabalho, não a troca de `assert` por `should`.

Ordem de conversão (menor → maior risco):

1. **`markdown`** — quase puro (`with-rendered`), só 3 `let` de defcustoms.
2. **`image`** — buffers próprios, `cl-letf` local.
3. **`tools`** — buffers `alonso` + contexto de confirmação.
4. **`client`** — process filter + temp dirs.
5. **`ui`** — janelas/átomo/restore, 113 asserts. **Alto** — por último.

## 6. Fases (incrementais, suíte verde a cada passo)

- **Fase 0 — Shims (sem tocar nos testes).**
  - `(require 'ert)` no lib.
  - Runner ERT paralelo `test/alonso-tests-ert.el` (scaffold, não substitui o
    atual ainda).
  - *Verificação:* `emacs -Q --batch -l test/alonso-tests.el` continua 282/0.
- **Fase 1 — `markdown-tests` → ERT.**
- **Fase 2 — `image-tests` → ERT** (+ fixture de limpeza de buffers).
- **Fase 3 — `tools-tests` → ERT** (+ fixture do contexto de confirmação).
- **Fase 4 — `client-tests` → ERT** (+ helper de temp dir).
- **Fase 5 — `ui-tests` → ERT** (fixtures `pair`/`windows`/`session`).
- **Fase 6 — Trocar o runner.** `alonso-tests.el` passa a
  `(ert-run-tests-batch-and-exit)`; apagar `alonso-tests--assert` e contadores.
- **Fase 7 (opcional) — `Makefile`/CI** com alvos `test`, `test-ui`,
  `coverage`; ligar `undercover`.

## 7. Execução seletiva e relatórios (ganho)

```elisp
;; tudo
emacs -Q --batch -l test/alonso-tests.el
;; só uma área (via tag)
emacs -Q --batch -l test/alonso-tests-ert.el   ; scaffold da Fase 0
;; interativo
M-x ert RET ui RET
```

+ `M-x ert` interativo, jump-to-definition, `skip-unless`, tags, e cobertura
por linha via `undercover`.

## 8. Rollback

Fases 0–5 mantêm o runner antigo funcionando; a virada é só na Fase 6. Um
commit por fase → reverter só a Fase 6 volta ao harness antigo.

## 9. Esforço estimado

| Fase | Arquivos | Esforço |
|---|---|---|
| 0 shims | lib + runner novo | baixo |
| 1–2 markdown/image | 2 | baixo |
| 3–4 tools/client | 2 | médio |
| 5 ui | 1 (1197 linhas) | **alto** |
| 6 virada | 1 | baixo |

## Desenvolvimento e CI (Eldev)

O projeto usa **Eldev** para gerenciar dependências e rodar testes/cobertura.
Instale o script `eldev` uma vez (o instalador oficial o coloca em
`~/.local/bin/eldev`; aqui ele está em `~/local/bin/eldev`):

    curl -fsSL https://raw.githubusercontent.com/emacs-eldev/eldev/master/webinstall/eldev | sh

### Dependências

- **Runtime**: ficam no header `Package-Requires:` de `alonso.el`
  (`emacs`, `transient`). É esse header que o **Eldev lê** (e também o
  **MELPA**, na hora de buildar o pacote) — não há outra fonte.
- **Teste/cobertura**: `undercover` (com `dash` e `shut-up`) **não** é
  dependência de runtime e por isso **não** entra no `Package-Requires:`.
  Ele é declarado no `Eldev`:

      (eldev-add-extra-dependencies 'test 'undercover)

  Assim `eldev deps test`, `eldev test` e `eldev coverage` instalam tudo
  sozinhos no cache do Eldev (`~/.cache/eldev`), sem poluir o pacote.

### Comandos

    eldev test                 # suíte ERT (282 testes)
    eldev test-ert '(tag ui)'  # só os testes de UI
    eldev coverage             # roda sob o undercover e imprime a cobertura
    eldev deps                 # instala/atualiza as dependências

Ou, via `Makefile`: `make test`, `make test-ui`, `make coverage`, `make deps`,
`make clean`.

> Obs.: o runner standalone `emacs -Q --batch -l test/alonso-tests.el`
> **não** é usado pelo Eldev — ele chama `ert-run-tests-batch-and-exit` e
> encerraria o processo do Eldev. Por isso `eldev-test-fileset` lista os cinco
> arquivos de teste, sem o runner nem o `alonso-tests-lib.el`.

### Cobertura

O comando `coverage` (definido no `Eldev`) liga o `undercover`, instrumenta
`alonso*.el` (excluindo `test/`), roda a suíte e emite o relatório. Variáveis:

| Variável | Efeito |
|---|---|
| `COVERAGE_FORMAT` | `text` (default), `lcov`, `coveralls`, `codecov`, `simplecov` |
| `COVERAGE_FILE` | onde gravar (default `coverage.txt`) |
| `COVERAGE_MIN` | se setado, **falha** (exit 1) abaixo desse percentual |

Exemplos:

    make coverage                                   # texto
    make coverage-lcov                              # coverage/lcov.info
    COVERAGE_MIN=75 make coverage                   # gate de cobertura

### CI

Um pipeline mínimo:

    eldev deps test    # instala runtime + test deps
    eldev test         # 282 testes, código de saída 0/1
    eldev coverage     # (opcional) relatório; use COVERAGE_MIN para o gate


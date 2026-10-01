#!/bin/bash

cd docs/build
mv html alonso
tar -czf docs.tar.gz alonso

curl -F 'file=@docs.tar.gz' https://docs.poraodojuca.dev/e/ -H "Authorization: Key $TUPI_AUTH_KEY"

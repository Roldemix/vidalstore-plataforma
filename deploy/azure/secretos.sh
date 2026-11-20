#!/usr/bin/env bash
# Copia los .env locales (fuera del repo) a /opt/vidalstore/secretos/ de cada VM.
# Uso: bash deploy/azure/secretos.sh ~/secretos-vidalstore/bff.env ~/secretos-vidalstore/gw-azure.env
set -euo pipefail
RG="${RG:-rg-vidalstore-e3}"
poner() { # vm archivo nombre
  local b64; b64="$(base64 -w0 "$2")"
  az vm run-command invoke -g "$RG" -n "$1" --command-id RunShellScript --output none --scripts \
    "install -d -o azureuser -g azureuser -m 700 /opt/vidalstore/secretos; echo $b64 | base64 -d > /opt/vidalstore/secretos/$3; chown azureuser:azureuser /opt/vidalstore/secretos/$3; chmod 600 /opt/vidalstore/secretos/$3"
  echo "OK $1:/opt/vidalstore/secretos/$3"
}
poner bff "${1:?bff.env}" bff.env
poner gw-azure "${2:?gw-azure.env}" gw-azure.env

#!/usr/bin/env bash
# Enciende las dos maquinas Azure. La IP publica es estatica, no cambia.
set -euo pipefail

RG="${RG:-rg-vidalstore-e3}"

for nombre in gw-azure bff; do
  az vm start --resource-group "$RG" --name "$nombre" --output none
  echo "$nombre encendida"
done

az vm list --resource-group "$RG" --show-details \
  --query "[].[name, powerState, publicIps]" --output table

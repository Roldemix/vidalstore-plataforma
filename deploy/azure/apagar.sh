#!/usr/bin/env bash
# Apaga y libera las maquinas Azure para no gastar credito del learner.
set -euo pipefail

RG="${RG:-rg-vidalstore-e3}"

for nombre in gw-azure bff; do
  az vm deallocate --resource-group "$RG" --name "$nombre" --output none
  echo "$nombre apagada"
done

az vm list --resource-group "$RG" --show-details \
  --query "[].[name, powerState]" --output table

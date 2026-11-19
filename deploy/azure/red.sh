#!/usr/bin/env bash
# Red de Azure para la EP3: una VNet con el borde publico y el BFF privado.
# No crea maquinas; de eso se encarga maquinas.sh.
set -euo pipefail

RG="${RG:-rg-vidalstore-e3}"
LOCATION="${LOCATION:-eastus}"
VNET="${VNET:-vnet-vidalstore}"
CIDR="${CIDR:-10.1.0.0/16}"

az group create --name "$RG" --location "$LOCATION" --output none

az network vnet create --resource-group "$RG" --name "$VNET" \
  --address-prefixes "$CIDR" --output none

for subred in "snet-gw 10.1.1.0/24" "snet-bff 10.1.2.0/24"; do
  set -- $subred
  az network vnet subnet create --resource-group "$RG" --vnet-name "$VNET" \
    --name "$1" --address-prefixes "$2" --output none 2>/dev/null || true
done

# gw-azure: unico punto publico. 80 para el desafio HTTP-01 de Let's Encrypt
# y 443 para el sitio. El 22 no se abre: se administra con az vm run-command.
az network nsg create --resource-group "$RG" --name nsg-gw --output none
az network nsg rule create --resource-group "$RG" --nsg-name nsg-gw \
  --name http --priority 100 --access Allow --protocol Tcp \
  --direction Inbound --destination-port-ranges 80 --output none
az network nsg rule create --resource-group "$RG" --nsg-name nsg-gw \
  --name https --priority 110 --access Allow --protocol Tcp \
  --direction Inbound --destination-port-ranges 443 --output none

# bff: sin IP publica. Recibe 8081 desde gw-azure y desde el gateway de AWS
# (10.0.0.0/16) por la ruta privada entre nubes.
az network nsg create --resource-group "$RG" --name nsg-bff --output none
az network nsg rule create --resource-group "$RG" --nsg-name nsg-bff \
  --name bff-desde-borde --priority 100 --access Allow --protocol Tcp \
  --direction Inbound --source-address-prefixes 10.1.1.0/24 \
  --destination-port-ranges 8081 --output none
az network nsg rule create --resource-group "$RG" --nsg-name nsg-bff \
  --name bff-desde-aws --priority 110 --access Allow --protocol Tcp \
  --direction Inbound --source-address-prefixes 10.0.0.0/16 \
  --destination-port-ranges 8081 --output none

# El BFF sale hacia la VPC de AWS por gw-azure, que hace de router (EP2).
az network route-table create --resource-group "$RG" --name rt-bff-gw --output none
az network route-table route create --resource-group "$RG" --route-table-name rt-bff-gw \
  --name aws --address-prefix 10.0.0.0/16 --next-hop-type VirtualAppliance \
  --next-hop-ip-address 10.1.1.10 --output none
az network vnet subnet update --resource-group "$RG" --vnet-name "$VNET" \
  --name snet-bff --route-table rt-bff-gw --output none

echo "Red lista en $RG/$VNET (snet-gw 10.1.1.0/24, snet-bff 10.1.2.0/24)."

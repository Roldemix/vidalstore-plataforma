#!/usr/bin/env bash
# Red de Azure para la EP3. No crea maquinas (maquinas.sh).
set -euo pipefail

RG="${RG:-rg-vidalstore-e3}"
LOCATION="${LOCATION:-northcentralus}"   # ver deploy/azure/region.txt
VNET="${VNET:-vnet-vidalstore}"
CIDR="${CIDR:-10.1.0.0/16}"

az group create --name "$RG" --location "$LOCATION" --output none
az network vnet create --resource-group "$RG" --name "$VNET" --address-prefixes "$CIDR" --output none

for subred in "snet-gw 10.1.1.0/24" "snet-bff 10.1.2.0/24"; do
  set -- $subred
  az network vnet subnet create --resource-group "$RG" --vnet-name "$VNET" \
    --name "$1" --address-prefixes "$2" --output none 2>/dev/null || true
done

# gw-azure: unico punto publico (80 ACME, 443 sitio). 22 solo desde la subred de bff.
az network nsg create --resource-group "$RG" --name nsg-gw --output none
az network nsg rule create --resource-group "$RG" --nsg-name nsg-gw --name http --priority 100 \
  --access Allow --protocol Tcp --direction Inbound --destination-port-ranges 80 --output none
az network nsg rule create --resource-group "$RG" --nsg-name nsg-gw --name https --priority 110 \
  --access Allow --protocol Tcp --direction Inbound --destination-port-ranges 443 --output none
az network nsg rule create --resource-group "$RG" --nsg-name nsg-gw --name ssh-desde-bff --priority 120 \
  --access Allow --protocol Tcp --direction Inbound --source-address-prefixes 10.1.2.0/24 \
  --destination-port-ranges 22 --output none

# bff: sin IP publica.
az network nsg create --resource-group "$RG" --name nsg-bff --output none
az network nsg rule create --resource-group "$RG" --nsg-name nsg-bff --name bff-desde-borde --priority 100 \
  --access Allow --protocol Tcp --direction Inbound --source-address-prefixes 10.1.1.0/24 \
  --destination-port-ranges 8081 --output none
az network nsg rule create --resource-group "$RG" --nsg-name nsg-bff --name bff-desde-aws --priority 110 \
  --access Allow --protocol Tcp --direction Inbound --source-address-prefixes 10.0.0.0/16 \
  --destination-port-ranges 8081 --output none

# bff sale a Internet y a AWS por gw-azure (reenvio + MASQUERADE). Sin IP publica,
# bff no tiene otra salida (descargas de Docker, runner de GitHub, imagenes).
az network route-table create --resource-group "$RG" --name rt-bff-gw --output none
az network route-table route create --resource-group "$RG" --route-table-name rt-bff-gw \
  --name aws --address-prefix 10.0.0.0/16 --next-hop-type VirtualAppliance \
  --next-hop-ip-address 10.1.1.10 --output none
az network route-table route create --resource-group "$RG" --route-table-name rt-bff-gw \
  --name internet --address-prefix 0.0.0.0/0 --next-hop-type VirtualAppliance \
  --next-hop-ip-address 10.1.1.10 --output none
az network vnet subnet update --resource-group "$RG" --vnet-name "$VNET" \
  --name snet-bff --route-table rt-bff-gw --output none

echo "Red lista en $RG/$VNET ($LOCATION)."

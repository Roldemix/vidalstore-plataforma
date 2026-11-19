#!/usr/bin/env bash
# Crea gw-azure (IP publica, 10.1.1.10) y bff (privada, 10.1.2.10).
# Ejecutar despues de red.sh. Es idempotente.
set -euo pipefail

RG="${RG:-rg-vidalstore-e3}"
LOCATION="${LOCATION:-eastus}"
VNET="${VNET:-vnet-vidalstore}"
ADMIN_USER="${ADMIN_USER:-azureuser}"
TAMANO="${TAMANO:-Standard_B2s}"

CLOUD_INIT="$(mktemp)"
trap 'rm -f "$CLOUD_INIT"' EXIT

cat >"$CLOUD_INIT" <<'EOF'
#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io docker-compose-v2
systemctl enable --now docker
usermod -aG docker azureuser
# gw-azure reenvia el trafico del BFF hacia AWS.
sysctl -w net.ipv4.ip_forward=1
echo 'net.ipv4.ip_forward=1' >/etc/sysctl.d/99-vidalstore.conf
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
apt-get install -y iptables-persistent
netfilter-persistent save
mkdir -p /opt/vidalstore/certs
EOF

IP_PUBLICA="$(az network public-ip show --resource-group "$RG" --name pip-gw-azure \
  --query ipAddress --output tsv 2>/dev/null || true)"
if [[ -z "$IP_PUBLICA" ]]; then
  az network public-ip create --resource-group "$RG" --name pip-gw-azure \
    --sku Standard --allocation-method Static --output none
fi

az network nic create --resource-group "$RG" --name nic-gw-azure \
  --vnet-name "$VNET" --subnet snet-gw \
  --private-ip-address 10.1.1.10 \
  --public-ip-address pip-gw-azure \
  --network-security-group nsg-gw \
  --ip-forwarding true --output none 2>/dev/null || true

az network nic create --resource-group "$RG" --name nic-bff \
  --vnet-name "$VNET" --subnet snet-bff \
  --private-ip-address 10.1.2.10 \
  --network-security-group nsg-bff --output none 2>/dev/null || true

crear_vm() {
  local nombre="$1" nic="$2"
  if az vm show --resource-group "$RG" --name "$nombre" >/dev/null 2>&1; then
    echo "$nombre ya existe"
    return
  fi
  az vm create --resource-group "$RG" --name "$nombre" --location "$LOCATION" \
    --nics "$nic" --image Ubuntu2204 --size "$TAMANO" \
    --admin-username "$ADMIN_USER" --generate-ssh-keys \
    --custom-data "$CLOUD_INIT" --output none
}

crear_vm gw-azure nic-gw-azure
crear_vm bff nic-bff

az vm list --resource-group "$RG" --show-details \
  --query "[].[name, powerState, privateIps, publicIps]" --output table

cat <<'FIN'

Siguiente paso manual (una sola vez): generar la llave en gw-azure y autorizarla
en bff, para que el runner pueda desplegar el BFF sin guardar secretos.

  az vm run-command invoke -g RG -n gw-azure --command-id RunShellScript \
    --scripts "mkdir -p /opt/vidalstore/llaves && ssh-keygen -t ed25519 -N '' -f /opt/vidalstore/llaves/bff_ed25519"

  az vm run-command invoke -g RG -n gw-azure --command-id RunShellScript \
    --scripts "cat /opt/vidalstore/llaves/bff_ed25519.pub"   # copiar la salida

  az vm run-command invoke -g RG -n bff --command-id RunShellScript \
    --scripts "echo 'CLAVE_PUBLICA' >> /home/azureuser/.ssh/authorized_keys"
FIN

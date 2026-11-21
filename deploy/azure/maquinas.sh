#!/usr/bin/env bash
# Crea gw-azure (IP publica con DNS, 10.1.1.10) y bff (privada, 10.1.2.10) y deja
# la llave SSH bff -> gw-azure. Ejecutar despues de red.sh. Idempotente.
set -euo pipefail

RG="${RG:-rg-vidalstore-e3}"
LOCATION="${LOCATION:-northcentralus}"
VNET="${VNET:-vnet-vidalstore}"
ADMIN_USER="${ADMIN_USER:-azureuser}"
TAMANO="${TAMANO:-Standard_B2als_v2}"     # 2 vCPU; cuota regional: 6
AZ_LABEL="${AZ_LABEL:-vidalstore-ep3}"

COMUN="$(mktemp)"; CI_GW="$(mktemp)"; CI_BFF="$(mktemp)"
trap 'rm -f "$COMUN" "$CI_GW" "$CI_BFF"' EXIT

cat >"$COMUN" <<'EOF2'
#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
# bff sale por gw-azure: puede tardar en haber ruta de salida.
for i in $(seq 1 60); do apt-get update && break || sleep 10; done
apt-get install -y docker.io docker-compose-v2
systemctl enable --now docker
usermod -aG docker azureuser
install -d -o azureuser -g azureuser /opt/vidalstore /opt/vidalstore/bff /opt/vidalstore/gw-azure
install -d -o azureuser -g azureuser -m 700 /opt/vidalstore/secretos
EOF2

cat "$COMUN" >"$CI_BFF"
cat "$COMUN" >"$CI_GW"
cat >>"$CI_GW" <<'EOF2'
# gw-azure reenvia (y enmascara) el trafico de bff hacia Internet y AWS.
sysctl -w net.ipv4.ip_forward=1
echo 'net.ipv4.ip_forward=1' >/etc/sysctl.d/99-vidalstore.conf
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
apt-get install -y iptables-persistent
netfilter-persistent save
EOF2

# IP publica con etiqueta DNS: <etiqueta>.<region>.cloudapp.azure.com
az network public-ip create --resource-group "$RG" --name pip-gw-azure \
  --sku Standard --allocation-method Static --dns-name "$AZ_LABEL" --output none

az network nic create --resource-group "$RG" --name nic-gw-azure --vnet-name "$VNET" --subnet snet-gw \
  --private-ip-address 10.1.1.10 --public-ip-address pip-gw-azure \
  --network-security-group nsg-gw --ip-forwarding true --output none 2>/dev/null || true
az network nic update --resource-group "$RG" --name nic-gw-azure --ip-forwarding true --output none

az network nic create --resource-group "$RG" --name nic-bff --vnet-name "$VNET" --subnet snet-bff \
  --private-ip-address 10.1.2.10 --network-security-group nsg-bff --output none 2>/dev/null || true

crear_vm() {
  local nombre="$1" nic="$2" init="$3"
  if az vm show --resource-group "$RG" --name "$nombre" >/dev/null 2>&1; then echo "$nombre ya existe"; return; fi
  az vm create --resource-group "$RG" --name "$nombre" --location "$LOCATION" --nics "$nic" \
    --image Ubuntu2204 --size "$TAMANO" --admin-username "$ADMIN_USER" --generate-ssh-keys \
    --custom-data "$init" --output none
}
crear_vm gw-azure nic-gw-azure "$CI_GW"      # primero: bff sale por el
crear_vm bff nic-bff "$CI_BFF"

az vm list --resource-group "$RG" --show-details --query "[].[name,powerState,privateIps,publicIps]" --output table
IP="$(az network public-ip show -g "$RG" -n pip-gw-azure --query ipAddress -o tsv)"
FQDN="$(az network public-ip show -g "$RG" -n pip-gw-azure --query dnsSettings.fqdn -o tsv)"
echo "IP publica de gw-azure: $IP"
echo "FQDN: $FQDN"

# --- Llave SSH generada en bff; la publica se agrega una vez a gw-azure --------
run() { az vm run-command invoke -g "$RG" -n "$1" --command-id RunShellScript --scripts "$2" --query 'value[0].message' -o tsv; }
echo "Esperando cloud-init en bff (puede tardar unos minutos)..."
for _ in $(seq 1 40); do
  run bff "cloud-init status | grep -q 'status: done' && echo LISTO" | grep -q LISTO && break; sleep 15
done
# Carpetas de trabajo (idempotente; las VM de la entrega anterior no las tienen).
PREP="install -d -o $ADMIN_USER -g $ADMIN_USER /opt/vidalstore /opt/vidalstore/bff /opt/vidalstore/gw-azure && install -d -o $ADMIN_USER -g $ADMIN_USER -m 700 /opt/vidalstore/secretos"
run gw-azure "$PREP" >/dev/null
run bff "$PREP" >/dev/null
run bff "[ -f /home/$ADMIN_USER/.ssh/gw_azure_ed25519 ] || runuser -u $ADMIN_USER -- ssh-keygen -q -t ed25519 -N '' -C bff-deploy -f /home/$ADMIN_USER/.ssh/gw_azure_ed25519" >/dev/null
PUB="$(run bff "cat /home/$ADMIN_USER/.ssh/gw_azure_ed25519.pub" | grep -o 'ssh-ed25519 [A-Za-z0-9+/=]* bff-deploy' | head -1)"
[[ -n "$PUB" ]] || { echo "No se pudo leer la llave publica" >&2; exit 1; }
run gw-azure "grep -qxF '$PUB' /home/$ADMIN_USER/.ssh/authorized_keys || echo '$PUB' >> /home/$ADMIN_USER/.ssh/authorized_keys" >/dev/null
echo "Llave bff -> gw-azure lista."
echo "Siguiente: GW_AZURE_IP=$IP bash deploy/aws/permisos-e3.sh"

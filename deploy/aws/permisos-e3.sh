#!/usr/bin/env bash
# Ajusta el Security Group de AWS al esquema de la EP3:
#   - 443 (gw-aws) y 3001/3002/3010 (servicios) solo desde la VNet de Azure
#   - 8080 del gateway solo dentro del propio SG (ya lo abre crear-infraestructura.sh)
#   - nada abierto a Internet y 22 cerrado: todo se administra con Session Manager
#
# El trafico de Azure llega NATeado por gw-azure, por eso se permite el /16
# completo: cubre a gw-azure (10.1.1.10) y a bff (10.1.2.10).
#
# Uso: bash deploy/aws/permisos-e3.sh
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
VPC_ID="${VPC_ID:?Definir VPC_ID (lo imprime crear-infraestructura.sh)}"
ORIGEN="${ORIGEN_AZURE:-10.1.0.0/16}"

SG="$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=vidalstore-internal" \
  --query 'SecurityGroups[0].GroupId' --output text)"

if [[ "$SG" == "None" || -z "$SG" ]]; then
  echo "No se encontro el Security Group vidalstore-internal. Ejecutar crear-infraestructura.sh." >&2
  exit 1
fi

quitar() {
  local puerto="$1" cidr="$2"
  aws ec2 revoke-security-group-ingress --region "$REGION" --group-id "$SG" \
    --ip-permissions "IpProtocol=tcp,FromPort=$puerto,ToPort=$puerto,IpRanges=[{CidrIp=$cidr}]" \
    >/dev/null 2>&1 || true
}

permitir() {
  local puerto="$1" cidr="$2" descripcion="$3"
  aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG" \
    --ip-permissions "IpProtocol=tcp,FromPort=$puerto,ToPort=$puerto,IpRanges=[{CidrIp=$cidr,Description=\"$descripcion\"}]" \
    >/dev/null 2>&1 || true
}

# Reglas de la EP2 que ya no corresponden: el unico borde publico es Azure.
for puerto in 80 443 22; do
  quitar "$puerto" 0.0.0.0/0
done

permitir 443 "$ORIGEN" "gw-azure a gw-aws (HTTPS interno)"
permitir 3001 "$ORIGEN" "bff a catalogo"
permitir 3002 "$ORIGEN" "bff a licencias"
permitir 3010 "$ORIGEN" "bff a eventos"

echo "Reglas del SG $SG:"
aws ec2 describe-security-groups --region "$REGION" --group-id "$SG" \
  --query 'SecurityGroups[0].IpPermissions[].{protocolo:IpProtocol,desde:FromPort,hasta:ToPort,rangos:IpRanges[].CidrIp}' \
  --output table

# La ruta de vuelta a Azure la deja la EP2 (VPN o peering). Sin ella, gw-aws no
# responde a gw-azure y el sitio devuelve 502.
RUTA="$(aws ec2 describe-route-tables --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "RouteTables[].Routes[?DestinationCidrBlock=='$ORIGEN'] | []" --output json)"

if [[ "$RUTA" == "[]" ]]; then
  echo
  echo "AVISO: la VPC no tiene ruta hacia $ORIGEN. Hay que crear el peering o la"
  echo "VPN de la EP2 antes de que gw-azure alcance gw-aws."
else
  echo "Ruta hacia $ORIGEN presente."
fi

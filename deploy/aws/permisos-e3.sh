#!/usr/bin/env bash
# Reglas de red de AWS para la EP3.
#   gw-aws:  80 abierto (reto ACME); 443 SOLO desde la IP publica de gw-azure.
#   interno: 3001/3002/3010 desde la VNet de Azure; nada abierto a Internet; 22 cerrado.
# Uso: GW_AZURE_IP=<ip publica de gw-azure> VPC_ID=vpc-... bash deploy/aws/permisos-e3.sh
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
VPC_ID="${VPC_ID:?Definir VPC_ID}"
GW_AZURE_IP="${GW_AZURE_IP:?Definir GW_AZURE_IP (IP publica de gw-azure)}"
ORIGEN="${ORIGEN_AZURE:-10.1.0.0/16}"

sg_id() {
  aws --region "$REGION" ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$1" \
    --query 'SecurityGroups[0].GroupId' --output text
}
SG_INT="$(sg_id vidalstore-internal)"
SG_GW="$(sg_id vidalstore-gw-aws)"
for v in "$SG_INT" "$SG_GW"; do
  [[ "$v" != "None" && -n "$v" ]] || { echo "Falta un SG; ejecutar crear-infraestructura.sh y desplegar-ec2.sh" >&2; exit 1; }
done

quitar()   { aws --region "$REGION" ec2 revoke-security-group-ingress --group-id "$1" --ip-permissions "IpProtocol=tcp,FromPort=$2,ToPort=$2,IpRanges=[{CidrIp=$3}]" >/dev/null 2>&1 || true; }
permitir() { aws --region "$REGION" ec2 authorize-security-group-ingress --group-id "$1" --ip-permissions "IpProtocol=tcp,FromPort=$2,ToPort=$2,IpRanges=[{CidrIp=$3,Description=\"$4\"}]" >/dev/null 2>&1 || true; }

# SG interno: nada publico; el 443 ya no viene por la ruta privada
for p in 80 443 22; do quitar "$SG_INT" "$p" 0.0.0.0/0; done
quitar "$SG_INT" 443 "$ORIGEN"
permitir "$SG_INT" 3001 "$ORIGEN" "bff a catalogo"
permitir "$SG_INT" 3002 "$ORIGEN" "bff a licencias"
permitir "$SG_INT" 3010 "$ORIGEN" "bff a eventos"

# SG de gw-aws
permitir "$SG_GW" 80 0.0.0.0/0 "reto ACME"
quitar   "$SG_GW" 443 0.0.0.0/0
permitir "$SG_GW" 443 "$GW_AZURE_IP/32" "solo gw-azure"

for sg in "$SG_INT" "$SG_GW"; do
  echo "== $sg"
  aws --region "$REGION" ec2 describe-security-groups --group-ids "$sg" \
    --query 'SecurityGroups[0].IpPermissions[].{proto:IpProtocol,desde:FromPort,rangos:IpRanges[].CidrIp}' --output table
done

RUTA="$(aws --region "$REGION" ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "RouteTables[].Routes[?DestinationCidrBlock=='$ORIGEN'] | []" --output json)"
if [[ "$RUTA" == "[]" ]]; then
  echo "AVISO: no hay ruta hacia $ORIGEN (peering/VPN). Sin ella servicios no alcanza a bff (BFF_URL) ni bff a servicios."
fi

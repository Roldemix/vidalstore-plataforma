#!/usr/bin/env bash
# EP3: lanza las 8 instancias EC2 del Learner Lab (limite 8 en ejecucion):
#   nat, mq-1, mq-2, mq-3, datos, servicios, gestion, gw-aws
# `nat` es una instancia (no un NAT Gateway). Todas usan LabInstanceProfile y
# se administran con Session Manager (sin SSH). Idempotente por nombre.
#
# Uso (Git Bash):
#   export MSYS_NO_PATHCONV=1 VPC_ID=... PUBLIC_SUBNET=... APP_SUBNET=... \
#          DATA_SUBNET_A=... DATA_SUBNET_B=... SECURITY_GROUP=sg-interno
#   bash deploy/aws/desplegar-ec2.sh
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
VPC_ID="${VPC_ID:?Definir VPC_ID}"
PUBLIC_SUBNET="${PUBLIC_SUBNET:?Definir PUBLIC_SUBNET}"
APP_SUBNET="${APP_SUBNET:?Definir APP_SUBNET}"
DATA_SUBNET_A="${DATA_SUBNET_A:?Definir DATA_SUBNET_A}"
DATA_SUBNET_B="${DATA_SUBNET_B:?Definir DATA_SUBNET_B}"
SECURITY_GROUP="${SECURITY_GROUP:?Definir SECURITY_GROUP (sg interno)}"
AMI_ID="${AMI_ID:-ami-0820d0c589175bc01}"
PROFILE="${INSTANCE_PROFILE:-LabInstanceProfile}"
TIPO_BORDE="${TIPO_BORDE:-t3.micro}"   # nat y gw-aws
TIPO_APP="${TIPO_APP:-t3.small}"       # mq, datos, servicios, gestion

aws_() { aws --region "$REGION" "$@"; }

tag_spec() {
  printf 'ResourceType=%s,Tags=[{Key=Name,Value=%s},{Key=Project,Value=vidalstore},{Key=ManagedBy,Value=aws-cli}]' "$1" "$2"
}

user_data_nat() {
  cat <<'UD'
#!/bin/bash
set -euxo pipefail
dnf install -y iptables-services
echo 'net.ipv4.ip_forward=1' >/etc/sysctl.d/99-nat.conf
sysctl -p /etc/sysctl.d/99-nat.conf
IFACE="$(ip -o -4 route show to default | awk '{print $5}' | head -1)"
iptables -t nat -A POSTROUTING -o "$IFACE" -s 10.0.0.0/16 -j MASQUERADE
iptables-save >/etc/sysconfig/iptables
systemctl enable --now iptables
UD
}

user_data_rol() {
  local rol="$1"
  cat <<UD
#!/bin/bash
set -euxo pipefail
dnf update -y
dnf install -y docker git unzip tar
dnf install -y libicu || true
systemctl enable --now docker
usermod -aG docker ec2-user

if ! command -v aws >/dev/null 2>&1; then
  curl -fsSL -o /tmp/awscliv2.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip
  unzip -q /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
fi

if ! docker compose version >/dev/null 2>&1; then
  mkdir -p /usr/local/lib/docker/cli-plugins
  curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-compose \
    https://github.com/docker/compose/releases/download/v2.32.4/docker-compose-linux-x86_64
  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
fi

mkdir -p /opt/vidalstore
echo "$rol" >/opt/vidalstore/ROLE
UD
}

# lanzar nombre subred ip rol tipo "sg1 sg2" [publica]
lanzar() {
  local nombre="vidalstore-$1" subred="$2" ip="$3" rol="$4" tipo="$5" sgs="$6" publica="${7:-}"
  local existente
  existente="$(aws_ ec2 describe-instances \
    --filters "Name=tag:Name,Values=$nombre" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)"
  if [[ "$existente" != "None" ]]; then
    echo "$nombre ya existe: $existente" >&2
    echo "$existente"; return
  fi
  local datos
  if [[ "$rol" == "nat" ]]; then datos="$(user_data_nat)"; else datos="$(user_data_rol "$rol")"; fi
  local ip_publica=(--no-associate-public-ip-address)
  [[ -n "$publica" ]] && ip_publica=(--associate-public-ip-address)
  # shellcheck disable=SC2086
  aws_ ec2 run-instances --image-id "$AMI_ID" --instance-type "$tipo" \
    --iam-instance-profile Name="$PROFILE" --subnet-id "$subred" \
    --private-ip-address "$ip" --security-group-ids $sgs "${ip_publica[@]}" \
    --metadata-options HttpTokens=required,HttpEndpoint=enabled \
    --user-data "$datos" --tag-specifications "$(tag_spec instance "$nombre")" \
    --query 'Instances[0].InstanceId' --output text
}

# --- 1. nat (instancia) y rutas de las subredes privadas ---------------------
NAT_ID="$(lanzar nat "$PUBLIC_SUBNET" 10.0.1.5 nat "$TIPO_BORDE" "$SECURITY_GROUP" publica)"
aws_ ec2 wait instance-running --instance-ids "$NAT_ID"
aws_ ec2 modify-instance-attribute --instance-id "$NAT_ID" --no-source-dest-check
for rt in vidalstore-app-rt vidalstore-data-rt; do
  RT_ID="$(aws_ ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$rt" \
    --query 'RouteTables[0].RouteTableId' --output text)"
  aws_ ec2 replace-route --route-table-id "$RT_ID" --destination-cidr-block 0.0.0.0/0 --instance-id "$NAT_ID" >/dev/null 2>&1 \
    || aws_ ec2 create-route --route-table-id "$RT_ID" --destination-cidr-block 0.0.0.0/0 --instance-id "$NAT_ID" >/dev/null
done
echo "Esperando a que nat pase los chequeos (el resto necesita salida a Internet)..." >&2
aws_ ec2 wait instance-status-ok --instance-ids "$NAT_ID"

# --- 2. SG propio de gw-aws: 80 abierto (reto ACME); el 443 lo abre permisos-e3.sh
GW_SG="$(aws_ ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=vidalstore-gw-aws" \
  --query 'SecurityGroups[0].GroupId' --output text)"
if [[ "$GW_SG" == "None" ]]; then
  GW_SG="$(aws_ ec2 create-security-group --vpc-id "$VPC_ID" --group-name vidalstore-gw-aws \
    --description "gw-aws: 80 ACME, 443 solo gw-azure" \
    --tag-specifications "$(tag_spec security-group vidalstore-gw-aws-sg)" \
    --query GroupId --output text)"
  aws_ ec2 authorize-security-group-ingress --group-id "$GW_SG" --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
fi

# --- 3. las 7 restantes ------------------------------------------------------
GW_ID="$(lanzar gw-aws "$PUBLIC_SUBNET" 10.0.1.10 gateway "$TIPO_BORDE" "$SECURITY_GROUP $GW_SG" publica)"
lanzar servicios "$APP_SUBNET"    10.0.11.10 servicios "$TIPO_APP" "$SECURITY_GROUP" >/dev/null
lanzar gestion   "$APP_SUBNET"    10.0.11.20 gestion   "$TIPO_APP" "$SECURITY_GROUP" >/dev/null
lanzar mq-1      "$DATA_SUBNET_A" 10.0.21.10 kafka-rabbitmq-1 "$TIPO_APP" "$SECURITY_GROUP" >/dev/null
lanzar mq-2      "$DATA_SUBNET_B" 10.0.22.10 kafka-rabbitmq-2 "$TIPO_APP" "$SECURITY_GROUP" >/dev/null
lanzar mq-3      "$DATA_SUBNET_A" 10.0.21.11 kafka-rabbitmq-3 "$TIPO_APP" "$SECURITY_GROUP" >/dev/null
lanzar datos     "$DATA_SUBNET_A" 10.0.21.20 postgres "$TIPO_APP" "$SECURITY_GROUP" >/dev/null

# --- 4. Elastic IP de gw-aws -------------------------------------------------
aws_ ec2 wait instance-running --instance-ids "$GW_ID"
ALLOC="$(aws_ ec2 describe-addresses --filters "Name=tag:Name,Values=vidalstore-gw-aws-eip" \
  --query 'Addresses[0].AllocationId' --output text)"
if [[ "$ALLOC" == "None" ]]; then
  ALLOC="$(aws_ ec2 allocate-address --domain vpc \
    --tag-specifications "$(tag_spec elastic-ip vidalstore-gw-aws-eip)" \
    --query AllocationId --output text)"
fi
aws_ ec2 associate-address --instance-id "$GW_ID" --allocation-id "$ALLOC" --allow-reassociation >/dev/null
EIP="$(aws_ ec2 describe-addresses --allocation-ids "$ALLOC" --query 'Addresses[0].PublicIp' --output text)"
DOMINIO="${EIP//./-}.sslip.io"

N="$(aws_ ec2 describe-instances --filters "Name=instance-state-name,Values=pending,running" \
  --query 'length(Reservations[].Instances[])' --output text)"
echo
echo "Instancias pending/running en la cuenta: $N (maximo 8)"
[[ "$N" -le 8 ]] || echo "AVISO: hay mas de 8; apaga o termina las sobrantes."
echo "GW_SG=$GW_SG"
echo "EIP=$EIP"
echo "AWS_URL=https://$DOMINIO"
echo
echo "Siguiente: gh variable set AWS_URL --repo roldemix/vidalstore-plataforma --body \"https://$DOMINIO\""

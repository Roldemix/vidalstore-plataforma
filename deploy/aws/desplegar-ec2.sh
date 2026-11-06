#!/usr/bin/env bash
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
VPC_ID="${VPC_ID:?Definir VPC_ID}"
PUBLIC_SUBNET="${PUBLIC_SUBNET:?Definir PUBLIC_SUBNET}"
APP_SUBNET="${APP_SUBNET:?Definir APP_SUBNET}"
DATA_SUBNET_A="${DATA_SUBNET_A:?Definir DATA_SUBNET_A}"
DATA_SUBNET_B="${DATA_SUBNET_B:?Definir DATA_SUBNET_B}"
SECURITY_GROUP="${SECURITY_GROUP:?Definir SECURITY_GROUP}"
AMI_ID="${AMI_ID:-ami-0820d0c589175bc01}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
PROFILE="${INSTANCE_PROFILE:-LabInstanceProfile}"

tag_spec() {
  local type="$1"
  local name="$2"
  printf 'ResourceType=%s,Tags=[{Key=Name,Value=%s},{Key=Project,Value=vidalstore},{Key=ManagedBy,Value=aws-cli}]' "$type" "$name"
}

find_nat() {
  aws ec2 describe-nat-gateways --region "$REGION" \
    --filter "Name=vpc-id,Values=$VPC_ID" "Name=tag:Project,Values=vidalstore" \
    --query 'NatGateways[0].NatGatewayId' --output text
}

NAT_ID="$(find_nat)"
if [[ "$NAT_ID" == "None" ]]; then
  ALLOCATION_ID="$(aws ec2 describe-addresses --region "$REGION" \
    --filters "Name=tag:Project,Values=vidalstore" \
    --query 'Addresses[0].AllocationId' --output text)"
  if [[ "$ALLOCATION_ID" == "None" ]]; then
    ALLOCATION_ID="$(aws ec2 allocate-address --region "$REGION" --domain vpc \
      --tag-specifications "$(tag_spec elastic-ip vidalstore-nat-eip)" \
      --query 'AllocationId' --output text)"
  fi
  NAT_ID="$(aws ec2 create-nat-gateway --region "$REGION" \
    --subnet-id "$PUBLIC_SUBNET" --allocation-id "$ALLOCATION_ID" \
    --tag-specifications "$(tag_spec natgateway vidalstore-nat)" \
    --query 'NatGateway.NatGatewayId' --output text)"
fi

aws ec2 wait nat-gateway-available --region "$REGION" --nat-gateway-ids "$NAT_ID"

for route_table_name in vidalstore-app-rt vidalstore-data-rt; do
  ROUTE_TABLE_ID="$(aws ec2 describe-route-tables --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$route_table_name" \
    --query 'RouteTables[0].RouteTableId' --output text)"
  aws ec2 replace-route --region "$REGION" --route-table-id "$ROUTE_TABLE_ID" \
    --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_ID" >/dev/null 2>&1 || \
    aws ec2 create-route --region "$REGION" --route-table-id "$ROUTE_TABLE_ID" \
      --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_ID" >/dev/null
done

aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SECURITY_GROUP" \
  --ip-permissions 'IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description="Public HTTP"}]' \
  'IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0,Description="Public HTTPS"}]' \
  >/dev/null 2>&1 || true

USER_DATA="$(cat <<'EOF'
#!/bin/bash
set -euxo pipefail
dnf update -y
dnf install -y docker git
systemctl enable --now docker
usermod -aG docker ec2-user
mkdir -p /opt/vidalstore
cat >/opt/vidalstore/ROLE <<ROLE
${ROLE}
ROLE
EOF
)"

launch_instance() {
  local name="$1"
  local subnet="$2"
  local private_ip="$3"
  local role="$4"
  local existing
  existing="$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=$name" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)"
  if [[ "$existing" != "None" ]]; then
    echo "$name already exists: $existing"
    return
  fi
  local data="${USER_DATA//\$\{ROLE\}/$role}"
  aws ec2 run-instances --region "$REGION" --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" --iam-instance-profile Name="$PROFILE" \
    --subnet-id "$subnet" --private-ip-address "$private_ip" \
    --security-group-ids "$SECURITY_GROUP" \
    --user-data "$data" --tag-specifications "$(tag_spec instance "$name")" \
    --query 'Instances[0].InstanceId' --output text
}

launch_instance vidalstore-gw-aws "$PUBLIC_SUBNET" 10.0.1.10 gateway
launch_instance vidalstore-servicios "$APP_SUBNET" 10.0.11.10 servicios
launch_instance vidalstore-gestion "$APP_SUBNET" 10.0.11.20 gestion
launch_instance vidalstore-mq-1 "$DATA_SUBNET_A" 10.0.21.10 kafka-rabbitmq-1
launch_instance vidalstore-mq-2 "$DATA_SUBNET_B" 10.0.22.10 kafka-rabbitmq-2
launch_instance vidalstore-mq-3 "$DATA_SUBNET_A" 10.0.21.11 kafka-rabbitmq-3
launch_instance vidalstore-postgres "$DATA_SUBNET_A" 10.0.21.20 postgres

echo "Despliegue solicitado. Verificar estados y SSM con describe-instances y ssm describe-instance-information."

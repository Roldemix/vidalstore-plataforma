#!/usr/bin/env bash
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
NAME="${VIDALSTORE_NAME:-vidalstore}"
AMI_ID="${AMI_ID:-ami-0820d0c589175bc01}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
PROFILE="${INSTANCE_PROFILE:-LabInstanceProfile}"

tag_spec() {
  local type="$1"
  local name="$2"
  printf 'ResourceType=%s,Tags=[{Key=Name,Value=%s},{Key=Project,Value=vidalstore},{Key=ManagedBy,Value=aws-cli}]' "$type" "$name"
}

find_vpc() {
  aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=tag:Project,Values=vidalstore" "Name=tag:ManagedBy,Values=aws-cli" \
    --query 'Vpcs[0].VpcId' --output text
}

VPC_ID="$(find_vpc)"
if [[ "$VPC_ID" == "None" ]]; then
  VPC_ID="$(aws ec2 create-vpc --region "$REGION" --cidr-block 10.0.0.0/16 \
    --tag-specifications "$(tag_spec vpc "$NAME-vpc")" \
    --query 'Vpc.VpcId' --output text)"
  aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
  aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'
fi

IGW_ID="$(aws ec2 describe-internet-gateways --region "$REGION" \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --query 'InternetGateways[0].InternetGatewayId' --output text)"
if [[ "$IGW_ID" == "None" ]]; then
  IGW_ID="$(aws ec2 create-internet-gateway --region "$REGION" \
    --tag-specifications "$(tag_spec internet-gateway "$NAME-igw")" \
    --query 'InternetGateway.InternetGatewayId' --output text)"
  aws ec2 attach-internet-gateway --region "$REGION" --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID"
fi

create_subnet() {
  local name="$1"
  local cidr="$2"
  local az="$3"
  local id
  id="$(aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$name" \
    --query 'Subnets[0].SubnetId' --output text)"
  if [[ "$id" == "None" ]]; then
    id="$(aws ec2 create-subnet --region "$REGION" --vpc-id "$VPC_ID" \
      --cidr-block "$cidr" --availability-zone "$az" \
      --tag-specifications "$(tag_spec subnet "$name")" \
      --query 'Subnet.SubnetId' --output text)"
  fi
  printf '%s' "$id"
}

PUBLIC_SUBNET="$(create_subnet "$NAME-public-a" 10.0.1.0/24 us-east-1a)"
APP_SUBNET="$(create_subnet "$NAME-app-a" 10.0.11.0/24 us-east-1a)"
DATA_SUBNET_A="$(create_subnet "$NAME-data-a" 10.0.21.0/24 us-east-1a)"
DATA_SUBNET_B="$(create_subnet "$NAME-data-b" 10.0.22.0/24 us-east-1b)"

PUBLIC_RT="$(aws ec2 describe-route-tables --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$NAME-public-rt" \
  --query 'RouteTables[0].RouteTableId' --output text)"
if [[ "$PUBLIC_RT" == "None" ]]; then
  PUBLIC_RT="$(aws ec2 create-route-table --region "$REGION" --vpc-id "$VPC_ID" \
    --tag-specifications "$(tag_spec route-table "$NAME-public-rt")" \
    --query 'RouteTable.RouteTableId' --output text)"
  aws ec2 create-route --region "$REGION" --route-table-id "$PUBLIC_RT" \
    --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
fi
aws ec2 associate-route-table --region "$REGION" --route-table-id "$PUBLIC_RT" \
  --subnet-id "$PUBLIC_SUBNET" >/dev/null 2>&1 || true
aws ec2 modify-subnet-attribute --region "$REGION" --subnet-id "$PUBLIC_SUBNET" \
  --map-public-ip-on-launch

APP_RT="$(aws ec2 describe-route-tables --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$NAME-app-rt" \
  --query 'RouteTables[0].RouteTableId' --output text)"
if [[ "$APP_RT" == "None" ]]; then
  APP_RT="$(aws ec2 create-route-table --region "$REGION" --vpc-id "$VPC_ID" \
    --tag-specifications "$(tag_spec route-table "$NAME-app-rt")" \
    --query 'RouteTable.RouteTableId' --output text)"
fi
aws ec2 associate-route-table --region "$REGION" --route-table-id "$APP_RT" \
  --subnet-id "$APP_SUBNET" >/dev/null 2>&1 || true

DATA_RT="$(aws ec2 describe-route-tables --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$NAME-data-rt" \
  --query 'RouteTables[0].RouteTableId' --output text)"
if [[ "$DATA_RT" == "None" ]]; then
  DATA_RT="$(aws ec2 create-route-table --region "$REGION" --vpc-id "$VPC_ID" \
    --tag-specifications "$(tag_spec route-table "$NAME-data-rt")" \
    --query 'RouteTable.RouteTableId' --output text)"
fi
for subnet in "$DATA_SUBNET_A" "$DATA_SUBNET_B"; do
  aws ec2 associate-route-table --region "$REGION" --route-table-id "$DATA_RT" \
    --subnet-id "$subnet" >/dev/null 2>&1 || true
done

SG_ID="$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$NAME-internal-sg" \
  --query 'SecurityGroups[0].GroupId' --output text)"
if [[ "$SG_ID" == "None" ]]; then
  SG_ID="$(aws ec2 create-security-group --region "$REGION" --vpc-id "$VPC_ID" \
    --group-name "$NAME-internal" --description "Vidalstore internal services" \
    --tag-specifications "$(tag_spec security-group "$NAME-internal-sg")" \
    --query 'GroupId' --output text)"
  aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" \
    --protocol -1 --source-group "$SG_ID" >/dev/null
fi

echo "VPC_ID=$VPC_ID"
echo "PUBLIC_SUBNET=$PUBLIC_SUBNET"
echo "APP_SUBNET=$APP_SUBNET"
echo "DATA_SUBNET_A=$DATA_SUBNET_A"
echo "DATA_SUBNET_B=$DATA_SUBNET_B"
echo "INTERNAL_SG=$SG_ID"
echo "No se lanzan instancias automáticamente; revisar estos identificadores antes del siguiente paso."

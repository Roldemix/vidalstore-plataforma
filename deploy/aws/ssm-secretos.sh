#!/usr/bin/env bash
# Guarda los .env de AWS como SecureString en Parameter Store.
# Los archivos reales viven FUERA del repositorio.
# Uso: bash deploy/aws/ssm-secretos.sh servicios ~/secretos-vidalstore/servicios.env \
#                                       gestion   ~/secretos-vidalstore/gestion.env
set -euo pipefail
export MSYS_NO_PATHCONV=1
REGION="${AWS_REGION:-us-east-1}"
while [[ $# -ge 2 ]]; do
  aws --region "$REGION" ssm put-parameter --name "/vidalstore/$1.env" \
    --type SecureString --overwrite --value "$(cat "$2")" >/dev/null
  echo "OK /vidalstore/$1.env"
  shift 2
done
aws --region "$REGION" ssm describe-parameters \
  --parameter-filters "Key=Path,Option=Recursive,Values=/vidalstore" \
  --query 'Parameters[].[Name,Type]' --output table

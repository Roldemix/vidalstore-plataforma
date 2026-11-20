#!/usr/bin/env bash
# Instala el runner (label `aws`) en la instancia `gestion` por Session Manager.
# Se ejecuta desde tu PC (Git Bash) con `gh` y `aws` autenticados.
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
REPO="${REPO:-roldemix/vidalstore-plataforma}"
USUARIO=ec2-user

ID="$(aws --region "$REGION" ec2 describe-instances \
  --filters "Name=tag:Name,Values=vidalstore-gestion" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)"
[[ "$ID" != "None" ]] || { echo "gestion no esta en ejecucion" >&2; exit 1; }

VER="$(gh api repos/actions/runner/releases/latest --jq .tag_name)"; VER="${VER#v}"
TOKEN="$(gh api -X POST "repos/$REPO/actions/runners/registration-token" --jq .token)"

SCRIPT="$(cat <<EOS
set -euo pipefail
dnf install -y git libicu tar
H=\$(getent passwd $USUARIO | cut -d: -f6)
install -d -o $USUARIO -g $USUARIO "\$H/actions-runner"
cd "\$H/actions-runner"
if [ ! -f .runner ]; then
  runuser -u $USUARIO -- curl -fsSL -o r.tar.gz https://github.com/actions/runner/releases/download/v$VER/actions-runner-linux-x64-$VER.tar.gz
  runuser -u $USUARIO -- tar xzf r.tar.gz
  rm -f r.tar.gz
  runuser -u $USUARIO -- ./config.sh --url https://github.com/$REPO --token $TOKEN --labels aws --name aws-gestion --unattended --replace
fi
./svc.sh install $USUARIO || true
./svc.sh start
./svc.sh status | head -5
EOS
)"
B64="$(printf '%s' "$SCRIPT" | base64 -w0)"
CMD="$(aws --region "$REGION" ssm send-command --document-name AWS-RunShellScript --instance-ids "$ID" \
  --parameters "{\"commands\":[\"echo $B64 | base64 -d | bash\"]}" --query Command.CommandId --output text)"
for _ in $(seq 1 60); do
  ST="$(aws --region "$REGION" ssm get-command-invocation --command-id "$CMD" --instance-id "$ID" --query Status --output text 2>/dev/null || echo Pending)"
  case "$ST" in Success|Failed|TimedOut|Cancelled) break;; esac; sleep 5
done
aws --region "$REGION" ssm get-command-invocation --command-id "$CMD" --instance-id "$ID" \
  --query '[Status,StandardOutputContent,StandardErrorContent]' --output text

#!/usr/bin/env bash
# Instala el runner (label `azure`) en la VM privada `bff` con az vm run-command.
set -euo pipefail
RG="${RG:-rg-vidalstore-e3}"
REPO="${REPO:-roldemix/vidalstore-plataforma}"
USUARIO=azureuser
VER="$(gh api repos/actions/runner/releases/latest --jq .tag_name)"; VER="${VER#v}"
TOKEN="$(gh api -X POST "repos/$REPO/actions/runners/registration-token" --jq .token)"
SCRIPT="$(cat <<EOS
set -euo pipefail
H=/home/$USUARIO
install -d -o $USUARIO -g $USUARIO \$H/actions-runner
cd \$H/actions-runner
if [ ! -f .runner ]; then
  runuser -u $USUARIO -- curl -fsSL -o r.tar.gz https://github.com/actions/runner/releases/download/v$VER/actions-runner-linux-x64-$VER.tar.gz
  runuser -u $USUARIO -- tar xzf r.tar.gz
  rm -f r.tar.gz
  ./bin/installdependencies.sh
  runuser -u $USUARIO -- ./config.sh --url https://github.com/$REPO --token $TOKEN --labels azure --name azure-bff --unattended --replace
fi
./svc.sh install $USUARIO || true
./svc.sh start
./svc.sh status | head -5
EOS
)"
B64="$(printf '%s' "$SCRIPT" | base64 -w0)"
az vm run-command invoke -g "$RG" -n bff --command-id RunShellScript \
  --scripts "echo $B64 | base64 -d | bash" --query 'value[0].message' -o tsv

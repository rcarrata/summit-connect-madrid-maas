#!/usr/bin/env bash
# Summit Connect Madrid: create sandbox with OpenCode configured for MaaS models.
#
# Creates a sandbox via OpenShell, installs OpenCode,
# configures it with both MaaS models (local GPU + cloud), and applies
# the SCM network policy (as.com yes, marca.com no).
#
# Usage:
#   MAAS_API_KEY=<key> ./setup-sandbox.sh
#   MAAS_API_KEY=<key> SANDBOX_NAME=opencode-scm ./setup-sandbox.sh
#
# Requires: OpenShell gateway deployed (install-openshell.sh) and registered
#           in the CLI (openshell gateway add --name scm-demo ...)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS="${DIR}/../manifests"
source "${DIR}/common.sh"

NAMESPACE="${NAMESPACE:-sandbox-scm}"
SANDBOX_NAME="${SANDBOX_NAME:-opencode-scm}"
SANDBOX_IMAGE="${SANDBOX_IMAGE:-}"
export OPENSHELL_GATEWAY_INSECURE="${OPENSHELL_GATEWAY_INSECURE:-true}"

# --- prerequisites ---

check_prereqs
command -v openshell >/dev/null || { error "openshell CLI not found"; exit 1; }

if [ -z "${MAAS_API_KEY:-}" ]; then
  read -rsp "MaaS API key (for desarrollador-1): " MAAS_API_KEY; echo
fi
[ -n "$MAAS_API_KEY" ] || { error "empty MaaS API key"; exit 1; }

DOMAIN=$(detect_apps_domain)
MAAS_GATEWAY="https://maas.${DOMAIN}"

info "Sandbox: ${SANDBOX_NAME}"
info "MaaS gateway: ${MAAS_GATEWAY}"

# --- render policy ---

info "Rendering network policy"
RENDERED_POLICY=$(mktemp)
render_policy "${MANIFESTS}/policy-scm.yaml.template" "$RENDERED_POLICY" "$DOMAIN"

# --- create sandbox ---

info "Creating sandbox ${SANDBOX_NAME}"
if [ -n "$SANDBOX_IMAGE" ]; then
  openshell sandbox create --name "$SANDBOX_NAME" --from "$SANDBOX_IMAGE" --policy "$RENDERED_POLICY" -- true
else
  openshell sandbox create --name "$SANDBOX_NAME" --policy "$RENDERED_POLICY" -- true
fi

# --- install opencode ---

info "Installing OpenCode in sandbox"
openshell sandbox exec --name "$SANDBOX_NAME" --no-tty -- \
  bash -c 'npm config set prefix /sandbox/.npm-global && npm install -g opencode-ai' 2>&1 | tail -3

# --- upload OpenCode config ---

info "Uploading OpenCode config (2 models: local + cloud)"
RENDERED_CONFIG=$(mktemp)
sed "s/__DOMAIN__/${DOMAIN}/g" "${MANIFESTS}/opencode-config.json" > "$RENDERED_CONFIG"
openshell sandbox exec --name "$SANDBOX_NAME" --no-tty -- \
  mkdir -p /sandbox/.config/opencode
openshell sandbox upload "$SANDBOX_NAME" "$RENDERED_CONFIG" /sandbox/.config/opencode/opencode.jsonc

# --- init script ---

info "Creating init script with MaaS credentials"
INIT_SCRIPT=$(mktemp)
cat > "$INIT_SCRIPT" << 'INITEOF'
#!/usr/bin/env bash
[ "${SANDBOX_ENV_LOADED:-}" = "1" ] && return
export SANDBOX_ENV_LOADED=1

export OPENAI_API_KEY="__MAAS_API_KEY__"
export NODE_TLS_REJECT_UNAUTHORIZED=0
export PATH=/sandbox/.npm-global/bin:$PATH

echo ""
echo "======================================"
echo "  Summit Connect Madrid - MaaS Demo"
echo "======================================"
echo ""
echo "Modelos disponibles:"
echo "  1. gpt-oss-20b   (GPU local, on-prem)"
echo "  2. opus5-cloud    (Cloud, solo desarrolladores)"
echo ""
echo "Ejecuta: opencode"
echo ""
INITEOF
sed -i.bak "s|__MAAS_API_KEY__|${MAAS_API_KEY}|g" "$INIT_SCRIPT"
rm -f "${INIT_SCRIPT}.bak"

openshell sandbox upload "$SANDBOX_NAME" "$INIT_SCRIPT" /sandbox/.sandbox-init.sh

# --- auto-source ---

info "Configuring auto-source in .bashrc and .profile"
GUARD='[ -f /sandbox/.sandbox-init.sh ] && source /sandbox/.sandbox-init.sh'
for rcfile in .bashrc .profile; do
  openshell sandbox exec --name "$SANDBOX_NAME" --no-tty -- \
    bash -c "grep -q sandbox-init.sh /sandbox/${rcfile} 2>/dev/null || echo '${GUARD}' >> /sandbox/${rcfile}" 2>/dev/null || true
done

# --- connectivity test ---

info "Testing MaaS gateway connectivity from sandbox"
TEST_RESULT=$(openshell sandbox exec --name "$SANDBOX_NAME" --no-tty -- \
  curl -sk --max-time 10 -o /dev/null -w "%{http_code}" "${MAAS_GATEWAY}/maas-api/v1/models" 2>/dev/null | tail -1 || echo "failed")
if [ "$TEST_RESULT" = "200" ] || [ "$TEST_RESULT" = "401" ]; then
  info "MaaS gateway reachable from sandbox (HTTP ${TEST_RESULT})"
else
  warn "MaaS gateway returned ${TEST_RESULT} - check network policy"
fi

# --- network policy demo test ---

info "Testing network policy (as.com vs marca.com)"
AS_RESULT=$(openshell sandbox exec --name "$SANDBOX_NAME" --no-tty -- \
  curl -sk --max-time 10 -o /dev/null -w "%{http_code}" "https://as.com" 2>/dev/null | tail -1 || echo "blocked")
MARCA_RESULT=$(openshell sandbox exec --name "$SANDBOX_NAME" --no-tty -- \
  curl -sk --max-time 10 -o /dev/null -w "%{http_code}" "https://marca.com" 2>/dev/null | tail -1 || echo "blocked")

if [ "$AS_RESULT" != "blocked" ] && [ "$AS_RESULT" != "000" ]; then
  info "as.com: HTTP ${AS_RESULT} (acceso permitido)"
else
  warn "as.com: bloqueado (deberia estar permitido)"
fi

if [ "$MARCA_RESULT" = "blocked" ] || [ "$MARCA_RESULT" = "000" ]; then
  info "marca.com: bloqueado (esperado - estamos en el Metropolitano!)"
else
  warn "marca.com: HTTP ${MARCA_RESULT} (deberia estar bloqueado)"
fi

# --- cleanup temp files ---

rm -f "$RENDERED_POLICY" "$RENDERED_CONFIG" "$INIT_SCRIPT"

echo
info "Sandbox ${SANDBOX_NAME} ready"
info "Connect: openshell sandbox connect --name ${SANDBOX_NAME}"

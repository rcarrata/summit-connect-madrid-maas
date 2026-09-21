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

_TMPFILES=()
_cleanup_tmp() { rm -f "${_TMPFILES[@]}"; }
trap _cleanup_tmp EXIT

info "Sandbox: ${SANDBOX_NAME}"
info "MaaS gateway: ${MAAS_GATEWAY}"

# --- render policy ---

info "Rendering network policy"
RENDERED_POLICY=$(mktemp); _TMPFILES+=("$RENDERED_POLICY")
render_policy "${MANIFESTS}/04-sandbox/policy-scm.yaml.template" "$RENDERED_POLICY" "$DOMAIN"

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
RENDERED_CONFIG=$(mktemp); _TMPFILES+=("$RENDERED_CONFIG")
sed "s/__DOMAIN__/${DOMAIN}/g" "${MANIFESTS}/04-sandbox/opencode-config.json" > "$RENDERED_CONFIG"
openshell sandbox exec --name "$SANDBOX_NAME" --no-tty -- \
  mkdir -p /sandbox/.config/opencode
openshell sandbox upload "$SANDBOX_NAME" "$RENDERED_CONFIG" /sandbox/.config/opencode/opencode.jsonc

# --- init script ---

info "Creating init script with MaaS credentials"
INIT_SCRIPT=$(mktemp); _TMPFILES+=("$INIT_SCRIPT")
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
echo "  2. gpt-5.5    (Cloud, solo desarrolladores)"
echo ""
echo "Ejecuta: opencode"
echo ""
INITEOF
ESCAPED_KEY=$(printf '%s\n' "$MAAS_API_KEY" | sed 's/[&/\]/\\&/g')
sed -i.bak "s|__MAAS_API_KEY__|${ESCAPED_KEY}|g" "$INIT_SCRIPT"
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

# La lista de modelos vacia es el sintoma de una API key caducada: con una key
# muerta el gateway responde 200 con {"data":[]} y luego 403 en la inferencia,
# asi que OpenCode arranca pero no ve ningun modelo.
MODEL_COUNT=$(openshell sandbox exec --name "$SANDBOX_NAME" --no-tty -- \
  bash -lc 'curl -sk --max-time 15 -H "Authorization: Bearer $OPENAI_API_KEY" '"${MAAS_GATEWAY}"'/maas-api/v1/models' 2>/dev/null \
  | grep -o '"id"' | wc -l | tr -d ' ')
if [ "${MODEL_COUNT:-0}" -ge 1 ]; then
  info "La API key ve ${MODEL_COUNT} modelo(s) desde el sandbox"
else
  error "La API key no ve ningun modelo: probablemente ha caducado. Crea otra en Gen AI studio > API keys (30 dias) y re-ejecuta este script."
fi

# OpenCode se instala en /sandbox/.npm-global, no en /usr/local/bin: si la
# politica solo autoriza la ruta clasica, la inferencia falla con policy_denied.
info "Comprobando que OpenCode puede llegar al gateway (policy check)"
OC_OUT=$(openshell sandbox exec --name "$SANDBOX_NAME" --no-tty -- \
  bash -lc 'cd /sandbox && opencode run --model local/gpt-oss-20b "responde solo: ok" 2>&1 | tail -3' 2>/dev/null | tail -3)
if printf '%s' "$OC_OUT" | grep -qi 'policy_denied'; then
  error "OpenCode bloqueado por la politica (policy_denied): revisa los binarios /sandbox/.npm-global/** en policy-scm.yaml.template"
else
  info "OpenCode responde con el modelo local"
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

echo
info "Sandbox ${SANDBOX_NAME} ready"
info "Connect: openshell sandbox connect --name ${SANDBOX_NAME}"

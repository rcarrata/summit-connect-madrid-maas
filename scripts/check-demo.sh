#!/usr/bin/env bash
# Summit Connect Madrid: comprobacion previa a la demo.
#
# Valida los fallos que hemos visto romper la demo en directo:
#   1. modelo local no Ready
#   2. modelo cloud registrado pero con ABSK caducada (401 del proveedor)
#   3. API key de MaaS caducada (403 y lista de modelos vacia)
#   4. sandbox: OpenCode bloqueado por la politica de red (policy_denied)
#
# Uso:
#   ./scripts/check-demo.sh                       # comprueba plataforma y gobernanza
#   MAAS_API_KEY=sk-oai-... ./scripts/check-demo.sh   # ademas comprueba inferencia real
#   SANDBOX=opencode-scm GATEWAY=scm-demo MAAS_API_KEY=... ./scripts/check-demo.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/common.sh"

FAIL=0
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[0;31m✗\033[0m %s\n' "$1"; FAIL=1; }
skip() { printf '  \033[0;33m-\033[0m %s\n' "$1"; }

DOMAIN=$(detect_apps_domain)
H="https://maas.${DOMAIN}"

echo "== 1. Modelos y gobernanza =="
[ "$(oc get llminferenceservice gpt-oss-20b -n llm -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ] \
  && ok "gpt-oss-20b Ready" || bad "gpt-oss-20b NO esta Ready (oc get llminferenceservice -n llm)"

for ref in llm/gpt-oss-20b external-models/opus5-cloud; do
  ns="${ref%%/*}"; name="${ref##*/}"
  [ "$(oc get maasmodelref "$name" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Ready" ] \
    && ok "MaaSModelRef ${ref} Ready" || bad "MaaSModelRef ${ref} no Ready"
done

for sub in scm-desarrolladores scm-ventas; do
  [ "$(oc get maassubscription "$sub" -n models-as-a-service -o jsonpath='{.status.phase}' 2>/dev/null)" = "Active" ] \
    && ok "suscripcion ${sub} Active" || bad "suscripcion ${sub} no Active"
done

# el presentador tiene que estar en alguna suscripcion o la UI le muestra 0 modelos
PRESENTER="${PRESENTER:-admin}"
if oc get maassubscription scm-desarrolladores -n models-as-a-service -o jsonpath='{.spec.owner.users}' 2>/dev/null | grep -q "\"${PRESENTER}\""; then
  ok "${PRESENTER} incluido en la suscripcion de desarrolladores (vera modelos en la UI)"
else
  bad "${PRESENTER} NO esta en ninguna suscripcion: la UI de MaaS le mostrara 0 modelos"
fi

echo "== 2. Visibilidad via API (token del usuario actual) =="
TOKEN=$(oc whoami -t 2>/dev/null)
MODELS=$(curl -sk -H "Authorization: Bearer ${TOKEN}" "${H}/maas-api/v1/models" 2>/dev/null)
COUNT=$(printf '%s' "$MODELS" | grep -o '"id"' | wc -l | tr -d ' ')
[ "$COUNT" -ge 1 ] && ok "$(oc whoami) ve ${COUNT} modelo(s)" || bad "$(oc whoami) ve 0 modelos: revisa suscripcion/politica"

echo "== 3. Inferencia real =="
if [ -n "${MAAS_API_KEY:-}" ]; then
  code=$(curl -sk -o /tmp/chk-local.json -w '%{http_code}' --max-time 60 \
    -H "Authorization: Bearer ${MAAS_API_KEY}" -H 'Content-Type: application/json' -X POST \
    -d '{"model":"gpt-oss-20b","messages":[{"role":"user","content":"ping"}],"max_tokens":5}' \
    "${H}/llm/gpt-oss-20b/v1/chat/completions")
  [ "$code" = "200" ] && ok "modelo local responde 200" || bad "modelo local devuelve ${code} (403 = API key caducada o sin permiso)"

  code=$(curl -sk -o /tmp/chk-cloud.json -w '%{http_code}' --max-time 60 \
    -H "Authorization: Bearer ${MAAS_API_KEY}" -H 'Content-Type: application/json' -X POST \
    -d '{"model":"opus5-cloud","messages":[{"role":"user","content":"ping"}],"max_tokens":5}' \
    "${H}/external-models/opus5-cloud/v1/chat/completions")
  case "$code" in
    200) ok "modelo cloud responde 200" ;;
    401) bad "modelo cloud 401: la ABSK del ExternalProvider ha caducado -> regenerala (README paso 3)" ;;
    403) bad "modelo cloud 403: la API key no tiene acceso al cloud (key de Ventas?)" ;;
    503) bad "modelo cloud 503: el ExternalProvider no puede hablar con el proveedor (ABSK invalida o endpoint caido)" ;;
    *)   bad "modelo cloud devuelve ${code}" ;;
  esac
else
  skip "sin MAAS_API_KEY: exporta una key de la UI para probar inferencia"
fi

echo "== 4. Sandbox + OpenCode =="
SANDBOX="${SANDBOX:-opencode-scm}"; GATEWAY="${GATEWAY:-scm-demo}"
if command -v openshell >/dev/null 2>&1; then
  export OPENSHELL_GATEWAY_INSECURE="${OPENSHELL_GATEWAY_INSECURE:-true}"
  OUT=$(openshell sandbox exec --gateway "$GATEWAY" --name "$SANDBOX" --no-tty -- \
    bash -lc 'cd /sandbox && opencode run --model local/gpt-oss-20b "responde solo: ok" 2>&1 | tail -3' 2>&1 | tail -3)
  if printf '%s' "$OUT" | grep -qi 'policy_denied'; then
    bad "OpenCode bloqueado por la politica del sandbox: añade /sandbox/.npm-global/** a los binarios y recarga con 'openshell policy set'"
  elif printf '%s' "$OUT" | grep -qiE 'forbidden|unauthorized|error'; then
    bad "OpenCode falla en el sandbox: ${OUT}"
  else
    ok "OpenCode responde desde el sandbox con el modelo local"
  fi
else
  skip "openshell CLI no encontrado: comprobacion del sandbox omitida"
fi

echo
[ "$FAIL" -eq 0 ] && { info "Todo listo para la demo"; exit 0; } || { error "Hay comprobaciones fallidas (ver arriba)"; exit 1; }

#!/usr/bin/env bash
# Summit Connect Madrid: demo de acceso diferenciado y rate limiting.
#
# Ejecuta un usuario por equipo (desarrollador-1, vendedor-1):
#   1. Visibilidad de modelos - que modelos puede ver cada equipo
#   2. Inferencia en modelos permitidos - rate limits en accion
#   3. Acceso denegado - 403 para modelos no autorizados
#
# Uso:
#   ./run-demo.sh [requests_per_model]       # default 8
#   DEMO_PASSWORD='...' ./run-demo.sh 12
set -uo pipefail

N=${1:-8}

# Models
LOCAL_RESOURCE="gpt-oss-20b"
LOCAL_NS="llm"

CLOUD_RESOURCE="opus5-cloud"
CLOUD_NS="external-models"

oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }
API=$(oc whoami --show-server)
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
H="https://maas.${CLUSTER_DOMAIN}"

if [ -z "${DEMO_PASSWORD:-}" ]; then
  read -rsp "Password for demo users: " DEMO_PASSWORD; echo
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo "MaaS endpoint: $H"
echo "Requests per model: $N"

# Warm-up: absorb stale-connection 500
curl -sk --max-time 30 -o /dev/null -H "Authorization: Bearer $(oc whoami -t)" \
  "${H}/maas-api/v1/models" 2>/dev/null || true

fire_burst() {
  local key="$1" endpoint="$2" model_name="$3" count="$4"
  local ok=0 lim=0 other=0 tok=0
  for _ in $(seq 1 "$count"); do
    code=$(curl -sk --max-time 30 -o "$TMP/r" -w "%{http_code}" \
      -H "Authorization: Bearer $key" -H "Content-Type: application/json" -X POST \
      -d "{\"model\":\"${model_name}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":4}" \
      "$endpoint")
    if [ "$code" = "500" ]; then
      code=$(curl -sk --max-time 30 -o "$TMP/r" -w "%{http_code}" \
        -H "Authorization: Bearer $key" -H "Content-Type: application/json" -X POST \
        -d "{\"model\":\"${model_name}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":4}" \
        "$endpoint")
    fi
    case "$code" in
      200) ok=$((ok+1)); tok=$((tok + $(jq -r '(.usage.total_tokens // ((.usage.input_tokens // 0) + (.usage.output_tokens // 0))) // 0' "$TMP/r" 2>/dev/null))) ;;
      429) lim=$((lim+1)) ;;
      *)   other=$((other+1)) ;;
    esac
  done
  printf '    %s requests -> %s ok / %s rate-limited / %s other  (%s tokens)\n' \
    "$count" "$ok" "$lim" "$other" "$tok"
}

fire_denied() {
  local key="$1" endpoint="$2" model_name="$3" label="$4"
  code=$(curl -sk --max-time 30 -o "$TMP/r" -w "%{http_code}" \
    -H "Authorization: Bearer $key" -H "Content-Type: application/json" -X POST \
    -d "{\"model\":\"${model_name}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":4}" \
    "$endpoint")
  if [ "$code" = "403" ]; then
    printf '    %s: 403 Forbidden (esperado)\n' "$label"
  else
    printf '    %s: %s (esperado 403!)\n' "$label" "$code"
  fi
}

login_and_key() {
  local user="$1"
  KUBECONFIG="$TMP/${user}.kubeconfig" oc login -u "$user" -p "$DEMO_PASSWORD" --server="$API" \
    --insecure-skip-tls-verify=true >/dev/null 2>&1 || { echo "  login FAILED"; return 1; }
  TOKEN=$(KUBECONFIG="$TMP/${user}.kubeconfig" oc whoami -t)

  echo "  Modelos visibles:"
  curl -sk --max-time 30 -H "Authorization: Bearer $TOKEN" "${H}/maas-api/v1/models" \
    | jq -r '.data[]?.id // empty' 2>/dev/null | sed 's/^/    /'

  RESP=$(curl -sk --max-time 30 -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" -X POST \
    -d "{\"name\":\"${user}-demo\",\"description\":\"demo\",\"expiresIn\":\"8h\"}" \
    "${H}/maas-api/v1/api-keys")
  echo "  Suscripcion resuelta: $(echo "$RESP" | jq -r '.subscription // "NO RESUELTA"')"
  KEY=$(echo "$RESP" | jq -r '.key // empty')
  [ -z "$KEY" ] && { echo "  no key issued: $(echo "$RESP" | head -c 140)"; return 1; }
  return 0
}

# --- desarrollador-1 ---
printf '\n=============================================\n'
printf '=== desarrollador-1 (scm-desarrolladores) ===\n'
printf '=============================================\n'

login_and_key "desarrollador-1" || exit 1

echo "  gpt-oss-20b (local GPU):"
fire_burst "$KEY" "${H}/${LOCAL_NS}/${LOCAL_RESOURCE}/v1/chat/completions" "${LOCAL_RESOURCE}" "$N"

echo "  opus5-cloud (cloud) - rate limit esperado ~10k tok/min:"
fire_burst "$KEY" "${H}/${CLOUD_NS}/${CLOUD_RESOURCE}/v1/chat/completions" "${CLOUD_RESOURCE}" "$N"

# --- vendedor-1 ---
printf '\n================================\n'
printf '=== vendedor-1 (scm-ventas) ===\n'
printf '================================\n'

login_and_key "vendedor-1" || exit 1

echo "  gpt-oss-20b (local GPU):"
fire_burst "$KEY" "${H}/${LOCAL_NS}/${LOCAL_RESOURCE}/v1/chat/completions" "${LOCAL_RESOURCE}" "$N"

echo "  opus5-cloud (cloud):"
fire_denied "$KEY" "${H}/${CLOUD_NS}/${CLOUD_RESOURCE}/v1/chat/completions" "${CLOUD_RESOURCE}" "opus5-cloud"

# --- summary ---
printf '\n=== Resumen ===\n'
echo "Comportamiento esperado:"
echo "  desarrollador-1: ve 2 modelos, gpt-oss-20b OK, opus5-cloud rate-limited (~10k tok/min)"
echo "  vendedor-1:      ve 1 modelo, gpt-oss-20b OK (20k tok/min), opus5-cloud 403"

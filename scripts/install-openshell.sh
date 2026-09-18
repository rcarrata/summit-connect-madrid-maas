#!/usr/bin/env bash
# Summit Connect Madrid: deploy OpenShell gateway with passthrough TLS.
#
# Installs the Agent Sandbox Operator, deploys the OpenShell Helm chart,
# enables TLS on the gateway, and exposes it via a passthrough TLS Route.
#
# Passthrough TLS is required because gRPC (HTTP/2) trailers are stripped
# by HAProxy in edge/re-encrypt routes, breaking all CLI communication.
#
# Usage:
#   ./install-openshell.sh
#   NAMESPACE=sandbox-scm ./install-openshell.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS="${DIR}/../manifests"
source "${DIR}/common.sh"

NAMESPACE="${NAMESPACE:-sandbox-scm}"
APPS_DOMAIN=$(detect_apps_domain)
ROUTE_HOST="openshell-gw-${NAMESPACE}.${APPS_DOMAIN}"

check_prereqs

# --- Agent Sandbox Operator ---

install_agent_sandbox_operator

# --- namespace ---

info "Creating namespace ${NAMESPACE}"
create_openshell_namespace "$NAMESPACE"

# --- privileged SCC ---

grant_privileged_scc "$NAMESPACE"

# --- JWT signing secret ---

create_jwt_secret "$NAMESPACE"

# --- cluster-scoped resource adoption ---

adopt_cluster_scoped_resources "$NAMESPACE"

# --- Helm install ---

info "Installing OpenShell Helm chart in ${NAMESPACE}"
HELM_ARGS=(
  upgrade --install openshell
  oci://ghcr.io/nvidia/openshell/helm-chart
  -n "$NAMESPACE"
  -f "${MANIFESTS}/04-sandbox/openshell-values.yaml"
)
[ -n "${OPENSHELL_VERSION:-}" ] && HELM_ARGS+=(--version "$OPENSHELL_VERSION")
helm "${HELM_ARGS[@]}"

wait_for_pod_ready "$NAMESPACE" "app.kubernetes.io/name=openshell" 180

# --- TLS certificate ---

info "Generating self-signed TLS certificate for passthrough route"
TMPDIR_TLS=$(mktemp -d)
OPENSSL=$(_find_openssl)
$OPENSSL req -x509 -nodes -newkey rsa:4096 \
  -keyout "${TMPDIR_TLS}/tls.key" \
  -out "${TMPDIR_TLS}/tls.crt" \
  -days 365 \
  -subj "/CN=${ROUTE_HOST}" \
  -addext "subjectAltName=DNS:${ROUTE_HOST},DNS:openshell.${NAMESPACE}.svc.cluster.local,DNS:openshell,DNS:openshell.${NAMESPACE}.svc" \
  2>/dev/null

oc create secret generic openshell-tls \
  --from-file=tls.crt="${TMPDIR_TLS}/tls.crt" \
  --from-file=tls.key="${TMPDIR_TLS}/tls.key" \
  --from-file=ca.crt="${TMPDIR_TLS}/tls.crt" \
  -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -
rm -rf "$TMPDIR_TLS"

# --- gateway config with TLS ---

info "Configuring gateway with TLS enabled"
cat > /tmp/gateway-${NAMESPACE}.toml << EOF
[openshell]
version = 1

[openshell.gateway]
bind_address          = "0.0.0.0:8080"
health_bind_address   = "0.0.0.0:8081"
metrics_bind_address  = "0.0.0.0:9090"
log_level             = "info"
sandbox_namespace     = "${NAMESPACE}"
default_image         = "ghcr.io/nvidia/openshell-community/sandboxes/base:latest"
disable_tls            = false
enable_loopback_service_http = true
client_tls_secret_name = "openshell-tls"

[openshell.gateway.tls]
cert_path = "/etc/openshell-tls/tls.crt"
key_path  = "/etc/openshell-tls/tls.key"

[openshell.gateway.auth]
allow_unauthenticated_users = true

[openshell.gateway.gateway_jwt]
signing_key_path = "/etc/openshell-jwt/signing.pem"
public_key_path  = "/etc/openshell-jwt/public.pem"
kid_path         = "/etc/openshell-jwt/kid"
gateway_id       = "openshell"
ttl_secs         = 3600

[openshell.drivers.kubernetes]
grpc_endpoint                = "https://openshell.${NAMESPACE}.svc.cluster.local:8080"
service_account_name         = "openshell-sandbox"
supervisor_sideload_method   = "init-container"
topology                     = "combined"
sa_token_ttl_secs            = 3600
app_armor_profile            = "Unconfined"
EOF

oc create configmap openshell-config \
  --from-file=gateway.toml="/tmp/gateway-${NAMESPACE}.toml" \
  -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -
rm -f "/tmp/gateway-${NAMESPACE}.toml"

# --- mount TLS secret ---

HAS_VOL=$(oc get statefulset openshell -n "$NAMESPACE" -o json \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if any(v['name']=='openshell-tls' for v in d['spec']['template']['spec'].get('volumes',[])) else 'no')" 2>/dev/null || echo "no")

if [ "$HAS_VOL" = "no" ]; then
  info "Mounting TLS secret into gateway pod"
  oc patch statefulset openshell -n "$NAMESPACE" --type='json' -p='[
    {"op":"add","path":"/spec/template/spec/volumes/-",
     "value":{"name":"openshell-tls","secret":{"secretName":"openshell-tls","defaultMode":256}}},
    {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-",
     "value":{"name":"openshell-tls","mountPath":"/etc/openshell-tls","readOnly":true}}
  ]'
fi

oc -n "$NAMESPACE" set env statefulset/openshell HOME=/var/openshell 2>/dev/null || true

# --- restart ---

info "Restarting gateway with TLS"
oc delete pod openshell-0 -n "$NAMESPACE"
oc rollout status statefulset/openshell -n "$NAMESPACE" --timeout=120s

# --- passthrough route ---

info "Creating passthrough TLS route"
oc delete route openshell-gw -n "$NAMESPACE" 2>/dev/null || true
oc create route passthrough openshell-gw \
  --service=openshell \
  --port=8080 \
  --hostname="${ROUTE_HOST}" \
  -n "$NAMESPACE"

echo
info "OpenShell gateway deployed with passthrough TLS in namespace: ${NAMESPACE}"
info "Route: https://${ROUTE_HOST}"
echo
info "Register gateway:"
info "  openshell gateway add --name scm-demo --local --gateway-insecure https://${ROUTE_HOST}"
echo
info "Next: ./setup-sandbox.sh"

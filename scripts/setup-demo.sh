#!/usr/bin/env bash
# Summit Connect Madrid: desplegar gobernanza MaaS para la demo.
#
# Crea usuarios htpasswd, grupos, modelo externo (Opus 5 cloud),
# politicas de acceso y suscripciones con limites por equipo.
#
# Requisitos previos:
#   - Cluster con MaaS desplegado (setup-maas.sh --model gpt-oss-20b --with-observability)
#   - gpt-oss-20b MaaSModelRef en estado Ready
#   - Clave ABSK de Bedrock (provision-bedrock-anthropic.sh)
#
# Uso:
#   ./setup-demo.sh
#   DEMO_PASSWORD='s3cret' ABSK_KEY='ABSK...' ./setup-demo.sh
#
# Revertir con ./cleanup-demo.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS="${DIR}/../manifests"

USERS_DEV=(desarrollador-1)
USERS_SALES=(vendedor-1)
ALL_USERS=("${USERS_DEV[@]}" "${USERS_SALES[@]}")

GROUP_DEV=scm-desarrolladores
GROUP_SALES=scm-ventas

SECRET=scm-demo-htpasswd
IDP=scm-demo
WORKDIR=${WORKDIR:-$(mktemp -d)}

# --- prerequisites ---

command -v htpasswd >/dev/null || { echo "htpasswd not found (install httpd-tools / apache2-utils)"; exit 1; }
command -v jq >/dev/null || { echo "jq not found"; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }

echo "==> Checking existing setup"
if ! oc get maasmodelref gpt-oss-20b -n llm >/dev/null 2>&1; then
  echo "ERROR: gpt-oss-20b MaaSModelRef not found in namespace llm."
  echo "Run setup-maas.sh --model gpt-oss-20b first."
  exit 1
fi

PHASE=$(oc get maasmodelref gpt-oss-20b -n llm -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
if [ "$PHASE" != "Ready" ]; then
  echo "WARNING: gpt-oss-20b phase is '${PHASE}', not Ready."
  echo "The demo may not work correctly. Continue anyway? (Ctrl+C to abort)"
  sleep 3
fi

# --- password ---

if [ -z "${DEMO_PASSWORD:-}" ]; then
  read -rsp "Password for demo users: " DEMO_PASSWORD; echo
fi
[ -n "$DEMO_PASSWORD" ] || { echo "empty password"; exit 1; }

# --- ABSK key ---

if [ -z "${ABSK_KEY:-}" ]; then
  read -rsp "ABSK key for Opus 5 (Bedrock): " ABSK_KEY; echo
fi
[ -n "$ABSK_KEY" ] || { echo "empty ABSK key"; exit 1; }

# --- oauth backup ---

echo "==> Backing up oauth/cluster to ${WORKDIR}/oauth-cluster.backup.yaml"
oc get oauth cluster -o yaml > "${WORKDIR}/oauth-cluster.backup.yaml"

# --- htpasswd users ---

echo "==> Generating htpasswd for: ${ALL_USERS[*]}"
HT="${WORKDIR}/scm-demo.htpasswd"
htpasswd -c -B -b "$HT" "${ALL_USERS[0]}" "$DEMO_PASSWORD" >/dev/null 2>&1
for u in "${ALL_USERS[@]:1}"; do htpasswd -B -b "$HT" "$u" "$DEMO_PASSWORD" >/dev/null 2>&1; done

echo "==> Creating secret ${SECRET} in openshift-config"
oc create secret generic "$SECRET" --from-file=htpasswd="$HT" -n openshift-config \
  --dry-run=client -o yaml | oc apply -f -

if oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}' | tr ' ' '\n' | grep -qx "$IDP"; then
  echo "==> Identity provider ${IDP} already present, skipping"
else
  echo "==> Adding identity provider ${IDP} (additive - existing providers untouched)"
  oc patch oauth cluster --type=json -p "[{\"op\":\"add\",\"path\":\"/spec/identityProviders/-\",\"value\":{\"name\":\"${IDP}\",\"mappingMethod\":\"claim\",\"type\":\"HTPasswd\",\"htpasswd\":{\"fileData\":{\"name\":\"${SECRET}\"}}}}]"
fi

# --- groups ---

echo "==> Creating groups"
oc adm groups new "$GROUP_DEV" "${USERS_DEV[@]}" 2>/dev/null || \
  { for u in "${USERS_DEV[@]}"; do oc adm groups add-users "$GROUP_DEV" "$u" >/dev/null 2>&1 || true; done; }
echo "  ${GROUP_DEV}: ${USERS_DEV[*]}"

oc adm groups new "$GROUP_SALES" "${USERS_SALES[@]}" 2>/dev/null || \
  { for u in "${USERS_SALES[@]}"; do oc adm groups add-users "$GROUP_SALES" "$u" >/dev/null 2>&1 || true; done; }
echo "  ${GROUP_SALES}: ${USERS_SALES[*]}"

# --- external-models namespace ---

echo "==> Creating external-models namespace"
oc apply -f "${MANIFESTS}/namespace-external-models.yaml"

# --- ABSK secret ---

echo "==> Creating ABSK secret for Opus 5"
oc create secret generic anthropic-mantle-api-key \
  --from-literal=api-key="$ABSK_KEY" -n external-models \
  --dry-run=client -o yaml | oc apply -f -
oc label secret anthropic-mantle-api-key -n external-models \
  inference.llm-d.ai/ipp-managed=true --overwrite

# --- external model ---

echo "==> Deploying ExternalProvider + ExternalModel (Opus 5 Cloud)"
oc apply -f "${MANIFESTS}/external-provider-opus5.yaml"
oc apply -f "${MANIFESTS}/external-model-opus5.yaml"

# --- MaaSModelRef ---

echo "==> Applying MaaSModelRef for opus5-cloud"
oc apply -f "${MANIFESTS}/maas-model-opus5.yaml"

echo "==> Applying compat HTTPRoute for Bedrock Mantle path rewrite"
oc apply -f "${MANIFESTS}/httproute-opus5-compat.yaml"

# --- auth policies and subscriptions ---

echo "==> Applying auth policies"
oc apply -f "${MANIFESTS}/auth-policies.yaml"

echo "==> Removing default subscriptions (conflict with SCM subscriptions)"
for sub in $(oc get maassubscription -n models-as-a-service --no-headers 2>/dev/null \
  | awk '{print $1}' | grep -v '^scm-'); do
  oc delete maassubscription "$sub" -n models-as-a-service --ignore-not-found 2>&1 | sed 's/^/  /'
done

echo "==> Applying subscriptions"
oc apply -f "${MANIFESTS}/subscriptions.yaml"

# --- wait for MaaSModelRef Ready ---

echo "==> Waiting for opus5-cloud MaaSModelRef to reach Ready (up to 3 min)..."
timeout=180; elapsed=0
while true; do
  phase=$(oc get maasmodelref opus5-cloud -n external-models -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [ "$phase" = "Ready" ]; then
    echo "  opus5-cloud: Ready"
    break
  fi
  if [ "$elapsed" -ge "$timeout" ]; then
    echo "  WARNING: opus5-cloud still in phase '${phase}' after ${timeout}s"
    echo "  Check: oc get maasmodelref opus5-cloud -n external-models -o yaml"
    break
  fi
  sleep 5; elapsed=$((elapsed+5))
done

# --- priority check ---

echo "==> Checking for priority conflicts"
CONFLICTS=$(oc get maassubscription -n models-as-a-service -o json 2>/dev/null \
  | jq -r '.items[] | select(.metadata.name | startswith("scm-") | not) | select(.spec.priority >= 30) | .metadata.name' 2>/dev/null || true)
if [ -n "$CONFLICTS" ]; then
  echo "  WARNING: These non-SCM subscriptions have priority >= 30 and may interfere:"
  echo "$CONFLICTS" | sed 's/^/    /'
fi

# --- summary ---

echo
echo "Identity providers:"
oc get oauth cluster -o jsonpath='{range .spec.identityProviders[*]}  {.name} ({.type}){"\n"}{end}'
echo
echo "Groups:"
for grp in $GROUP_DEV $GROUP_SALES; do
  members=$(oc get group "$grp" -o jsonpath='{.users[*]}' 2>/dev/null || echo "?")
  echo "  ${grp}: ${members}"
done
echo
echo "Models:"
oc get maasmodelref -A --no-headers 2>/dev/null | awk '{printf "  %-25s %-20s %s\n", $2, $1, $5}'
echo
echo "Subscriptions:"
oc get maassubscription -n models-as-a-service --no-headers 2>/dev/null | awk '{printf "  %-25s prio=%s\n", $1, $4}'
echo
echo "Setup complete. The oauth pods restart before new users can log in (usually under a minute)."
echo "Backup and htpasswd kept in: ${WORKDIR}"
echo
echo "Next: ./run-demo.sh"

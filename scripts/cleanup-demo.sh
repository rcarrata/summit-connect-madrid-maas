#!/usr/bin/env bash
# Summit Connect Madrid: eliminar todo lo creado por setup-demo.sh
#
# Borra CRs antes de namespaces para evitar bloqueos de finalizers.
# Deja intacto gpt-oss-20b (desplegado por setup-maas.sh).
#
# Uso:
#   ./cleanup-demo.sh
#   OAUTH_BACKUP=/path/oauth-cluster.backup.yaml ./cleanup-demo.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS="${DIR}/../manifests"

ALL_USERS=(desarrollador-1 vendedor-1)
GROUP_DEV=scm-desarrolladores
GROUP_SALES=scm-ventas
SECRET=scm-demo-htpasswd
IDP=scm-demo

oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }

echo "==> Removing subscriptions"
oc delete -f "${MANIFESTS}/subscriptions.yaml" --ignore-not-found 2>&1 | sed 's/^/  /'

echo "==> Removing auth policies"
oc delete -f "${MANIFESTS}/auth-policies.yaml" --ignore-not-found 2>&1 | sed 's/^/  /'

echo "==> Removing MaaSModelRef"
oc delete -f "${MANIFESTS}/maas-model-opus5.yaml" --ignore-not-found 2>&1 | sed 's/^/  /'

echo "==> Removing compat HTTPRoute"
oc delete -f "${MANIFESTS}/httproute-opus5-compat.yaml" --ignore-not-found 2>&1 | sed 's/^/  /'

echo "==> Removing ExternalModel + ExternalProvider"
oc delete -f "${MANIFESTS}/external-model-opus5.yaml" --ignore-not-found 2>&1 | sed 's/^/  /'
oc delete -f "${MANIFESTS}/external-provider-opus5.yaml" --ignore-not-found 2>&1 | sed 's/^/  /'

echo "==> Removing ABSK secret"
oc delete secret anthropic-mantle-api-key -n external-models --ignore-not-found 2>&1 | sed 's/^/  /'

echo "==> Removing external-models namespace"
oc delete -f "${MANIFESTS}/namespace-external-models.yaml" --ignore-not-found 2>&1 | sed 's/^/  /'

echo "==> Removing groups"
for grp in $GROUP_DEV $GROUP_SALES; do
  oc delete group "$grp" --ignore-not-found 2>&1 | sed 's/^/  /'
done

echo "==> Removing users and identities"
for u in "${ALL_USERS[@]}"; do
  oc delete user "$u" --ignore-not-found >/dev/null 2>&1
  oc delete identity "${IDP}:${u}" --ignore-not-found >/dev/null 2>&1
done
echo "  users and identities removed"

echo "==> Removing htpasswd secret"
oc delete secret "$SECRET" -n openshift-config --ignore-not-found 2>&1 | sed 's/^/  /'

echo "==> Removing the ${IDP} identity provider"
if [ -n "${OAUTH_BACKUP:-}" ] && [ -f "$OAUTH_BACKUP" ]; then
  oc apply -f "$OAUTH_BACKUP" 2>&1 | sed 's/^/  /'
else
  REMAINING=$(oc get oauth cluster -o json \
    | jq -c "[.spec.identityProviders[]? | select(.name != \"${IDP}\")]")
  if [ -n "$REMAINING" ] && echo "$REMAINING" | jq empty 2>/dev/null; then
    oc patch oauth cluster --type=merge -p "{\"spec\":{\"identityProviders\":${REMAINING}}}" 2>&1 | sed 's/^/  /'
  else
    echo "  WARNING: could not build IDP list, skipping oauth patch (remove ${IDP} manually)"
  fi
fi

echo "==> Removing OpenShell sandbox"
if command -v openshell >/dev/null 2>&1; then
  OPENSHELL_GATEWAY_INSECURE=true openshell sandbox delete opencode-scm 2>/dev/null | sed 's/^/  /' || echo "  sandbox not found or gateway not reachable"
else
  oc delete sandbox opencode-scm -n sandbox-scm --ignore-not-found 2>&1 | sed 's/^/  /'
fi

echo "==> Removing OpenShell namespace (sandbox-scm)"
oc delete ns sandbox-scm --ignore-not-found 2>&1 | sed 's/^/  /'

echo
echo "Identity providers now:"
oc get oauth cluster -o jsonpath='{range .spec.identityProviders[*]}  {.name} ({.type}){"\n"}{end}'
echo
echo "Cleanup complete. gpt-oss-20b was not touched."

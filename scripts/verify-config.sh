#!/bin/bash
#
# Verify cluster and namespace configuration for the RedBank demo.
#
# Environment: NAMESPACE, KEYCLOAK_REALM (from .env)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/../.env" ]; then
  set -a; source "$SCRIPT_DIR/../.env"; set +a
fi

NAMESPACE="${NAMESPACE:-redbank-demo}"
REALM="${KEYCLOAK_REALM:-$NAMESPACE}"
PASS=0
FAIL=0

ok()   { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }
check() {
  if eval "$2" > /dev/null 2>&1; then ok "$1"; else fail "$1"; fi
}

KC_URL="${KEYCLOAK_URL:-}"
if [ -z "$KC_URL" ]; then
  KC_URL="https://$(oc get route -n keycloak -o jsonpath='{.items[0].spec.host}' 2>/dev/null)"
fi

echo ""
echo "Verifying configuration for namespace: ${NAMESPACE}, realm: ${REALM}"
echo ""

# ============================================================================
# Keycloak
# ============================================================================
echo "🔐 Keycloak"

check "Keycloak pod running" \
  "oc get pods -n keycloak -l app=keycloak -o jsonpath='{.items[0].status.phase}' | grep -q Running"

KC_VERSION=$(oc exec keycloak-0 -n keycloak -- /opt/keycloak/bin/kc.sh --version 2>/dev/null | head -1 | awk '{print $2}' || echo "unknown")
echo "  ℹ️  Version: ${KC_VERSION}"

# Check features via OIDC discovery or Keycloak logs
KC_FEATURES=$(oc logs keycloak-0 -n keycloak 2>/dev/null | grep "Preview features enabled" | tail -1 || echo "")

check "Feature: token-exchange" \
  "echo '$KC_FEATURES' | grep -q 'token-exchange'"

check "Feature: spiffe:v1" \
  "echo '$KC_FEATURES' | grep -q 'spiffe'"

check "Feature: client-auth-federated:v1" \
  "echo '$KC_FEATURES' | grep -q 'client-auth-federated'"

KC_DEPRECATED=$(oc logs keycloak-0 -n keycloak 2>/dev/null | grep "Deprecated features enabled" | tail -1 || echo "")
check "Feature: admin-fine-grained-authz" \
  "echo '$KC_FEATURES $KC_DEPRECATED' | grep -q 'admin-fine-grained-authz'"

check "Feature: preview" \
  "echo '$KC_FEATURES' | grep -q 'Preview features enabled'"

check "Proxy headers (https:// issuer)" \
  "curl -sk '${KC_URL}/realms/${REALM}/.well-known/openid-configuration' | jq -r '.issuer' | grep -q '^https://'"

check "Realm '${REALM}' exists" \
  "curl -sk '${KC_URL}/realms/${REALM}/.well-known/openid-configuration' | jq -e '.issuer'"

echo ""

# ============================================================================
# SPIRE / SPIFFE
# ============================================================================
echo "🔑 SPIRE / SPIFFE"

SPIRE_NS=$(oc get ns zero-trust-workload-identity-manager -o name 2>/dev/null | sed 's|namespace/||' || echo "")
if [ -n "$SPIRE_NS" ]; then
  check "SPIRE server running" \
    "oc get pod spire-server-0 -n $SPIRE_NS -o jsonpath='{.status.phase}' | grep -q Running"

  check "SPIRE OIDC discovery provider running" \
    "oc get pods -n $SPIRE_NS -o name | grep -q oidc"

  check "OIDC set_key_use enabled" \
    "oc get configmap spire-spiffe-oidc-discovery-provider -n $SPIRE_NS -o jsonpath='{.data.oidc-discovery-provider\\.conf}' | jq -e '.set_key_use == true'"

  check "ZTWIM CREATE_ONLY_MODE" \
    "oc get subscription -n $SPIRE_NS -o json | jq -e '.items[0].spec.config.env[] | select(.name==\"CREATE_ONLY_MODE\") | .value == \"true\"'"

  # Check SPIFFE IDP in Keycloak
  KC_ADMIN_USER=$(kubectl get secret keycloak-initial-admin -n keycloak -o go-template='{{.data.username | base64decode}}' 2>/dev/null)
  KC_ADMIN_PASS=$(kubectl get secret keycloak-initial-admin -n keycloak -o go-template='{{.data.password | base64decode}}' 2>/dev/null)
  if [ -n "$KC_ADMIN_USER" ]; then
    TOKEN=$(curl -sk "${KC_URL}/realms/master/protocol/openid-connect/token" \
      -d "grant_type=password" -d "client_id=admin-cli" \
      -d "username=${KC_ADMIN_USER}" -d "password=${KC_ADMIN_PASS}" | jq -r '.access_token // empty')
    if [ -n "$TOKEN" ]; then
      check "SPIFFE IDP in realm '${REALM}'" \
        "curl -sk '${KC_URL}/admin/realms/${REALM}/identity-provider/instances' -H 'Authorization: Bearer $TOKEN' | jq -e '.[] | select(.providerId == \"spiffe\")'"
    fi
  fi
else
  fail "SPIRE namespace not found"
fi

echo ""

# ============================================================================
# Namespace: kagenti
# ============================================================================
echo "🏷️  Namespace: ${NAMESPACE}"

check "kagenti-enabled label" \
  "kubectl get ns ${NAMESPACE} -o jsonpath='{.metadata.labels.kagenti-enabled}' | grep -q true"

check "Pod security: privileged" \
  "kubectl get ns ${NAMESPACE} -o jsonpath='{.metadata.labels.pod-security\\.kubernetes\\.io/audit}' | grep -q privileged"

check "authbridge-config exists" \
  "kubectl get configmap authbridge-config -n ${NAMESPACE}"

check "authbridge-runtime-config exists" \
  "kubectl get configmap authbridge-runtime-config -n ${NAMESPACE}"

check "spiffe-helper-config exists" \
  "kubectl get configmap spiffe-helper-config -n ${NAMESPACE}"

check "envoy-config exists" \
  "kubectl get configmap envoy-config -n ${NAMESPACE}"

check "keycloak-admin-secret exists" \
  "kubectl get secret keycloak-admin-secret -n ${NAMESPACE}"

# Check SPIFFE mode
CLIENT_AUTH=$(kubectl get configmap authbridge-config -n "${NAMESPACE}" -o jsonpath='{.data.CLIENT_AUTH_TYPE}' 2>/dev/null)
SPIRE_ON=$(kubectl get configmap authbridge-config -n "${NAMESPACE}" -o jsonpath='{.data.SPIRE_ENABLED}' 2>/dev/null)
echo "  ℹ️  CLIENT_AUTH_TYPE: ${CLIENT_AUTH:-not set}"
echo "  ℹ️  SPIRE_ENABLED: ${SPIRE_ON:-not set}"

echo ""

# ============================================================================
# Workloads
# ============================================================================
echo "🚢 Workloads"

for DEPLOY in redbank-orchestrator redbank-banking-agent redbank-knowledge-agent redbank-mcp-server; do
  READY=$(kubectl get deploy "$DEPLOY" -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  CONTAINERS=$(kubectl get pod -n "${NAMESPACE}" -l "app=$DEPLOY" -o jsonpath='{.items[0].spec.containers[*].name}' 2>/dev/null | wc -w | tr -d ' ')
  if [ "${READY:-0}" -ge 1 ] && [ "${CONTAINERS:-1}" -ge 3 ]; then
    ok "$DEPLOY: ${READY} ready, ${CONTAINERS} containers (sidecars injected)"
  elif [ "${READY:-0}" -ge 1 ]; then
    fail "$DEPLOY: ${READY} ready, ${CONTAINERS} containers (sidecars missing)"
  else
    fail "$DEPLOY: not ready"
  fi
done

check "redbank-playground running" \
  "kubectl get deploy redbank-playground -n ${NAMESPACE} -o jsonpath='{.status.readyReplicas}' | grep -q '[1-9]'"

check "postgresql running" \
  "kubectl get deploy postgresql -n ${NAMESPACE} -o jsonpath='{.status.readyReplicas}' | grep -q '[1-9]'"

# Check SPIFFE client IDs
SECRETS=$(kubectl get secrets -n "${NAMESPACE}" -o name | grep kagenti-keycloak-client-credentials | wc -l | tr -d ' ')
if [ "$SECRETS" -ge 4 ]; then
  ok "Keycloak client credentials: ${SECRETS} secrets"
  SAMPLE_CID=$(kubectl get secret $(kubectl get secrets -n "${NAMESPACE}" -o name | grep kagenti-keycloak-client-credentials | head -1 | sed 's|secret/||') -n "${NAMESPACE}" -o jsonpath='{.data.client-id\.txt}' | base64 -d)
  if echo "$SAMPLE_CID" | grep -q "spiffe://"; then
    echo "  ℹ️  Client ID format: SPIFFE"
  else
    echo "  ℹ️  Client ID format: namespace/workload"
  fi
else
  fail "Keycloak client credentials: only ${SECRETS} secrets (expected 4+)"
fi

echo ""

# ============================================================================
# Summary
# ============================================================================
TOTAL=$((PASS + FAIL))
echo "=========================================="
if [ "$FAIL" -eq 0 ]; then
  echo "✅ All ${TOTAL} checks passed"
else
  echo "❌ ${FAIL}/${TOTAL} checks failed"
fi
echo "=========================================="

[ "$FAIL" -eq 0 ]

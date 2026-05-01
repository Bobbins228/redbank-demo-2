#!/bin/bash
#
# Configure OAuth 2.0 Token Exchange for RedBank demo
#
# This script automates the Keycloak UI steps documented in TOKEN_EXCHANGE_SETUP.md:
# 1. Enable token exchange on redbank-mcp client
# 2. Enable authorization on knowledge-agent SPIFFE client
# 3. Create client policy allowing token exchange
# 4. Create token-exchange permission linking policy to account client
#
# Requires: curl, jq
# Environment: KEYCLOAK_URL, KEYCLOAK_ADMIN, KEYCLOAK_PASSWORD

set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-}"
if [[ -z "${KEYCLOAK_URL}" ]]; then
  KEYCLOAK_URL="https://$(oc get route -n keycloak -o jsonpath='{.items[0].spec.host}' 2>/dev/null)" || true
fi
if [[ -z "${KEYCLOAK_URL}" || "${KEYCLOAK_URL}" == "https://" ]]; then
  echo "ERROR: KEYCLOAK_URL is required" >&2
  exit 1
fi

KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:?KEYCLOAK_ADMIN is required}"
KEYCLOAK_PASSWORD="${KEYCLOAK_PASSWORD:?KEYCLOAK_PASSWORD is required}"
REALM="${KEYCLOAK_REALM:-$NAMESPACE}"
NAMESPACE="${NAMESPACE:-redbank-demo}"

# Detect cluster domain from OpenShift route
CLUSTER_DOMAIN=$(oc get route -n keycloak keycloak -o jsonpath='{.spec.host}' | sed 's/^keycloak-keycloak\.//')

# Client IDs
TARGET_CLIENT="redbank-mcp"
SUBJECT_CLIENT_PREFIX="spiffe://apps.${CLUSTER_DOMAIN}/ns/${NAMESPACE}/sa/"

function _out() {
  echo "$(date +'%F %H:%M:%S') $@"
}

function get_admin_token() {
  curl -sf "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -d "grant_type=password" \
    -d "client_id=admin-cli" \
    -d "username=${KEYCLOAK_ADMIN}" \
    -d "password=${KEYCLOAK_PASSWORD}" | jq -r '.access_token'
}

function kc_api() {
  local method="$1"
  local path="$2"
  shift 2
  curl -sf -X "${method}" \
    "${KEYCLOAK_URL}/admin/realms${path}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    "$@"
}

# --- Get admin token ---------------------------------------------------------

_out "Authenticating as ${KEYCLOAK_ADMIN}"
TOKEN=$(get_admin_token)
if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo "ERROR: Failed to get admin token" >&2
  exit 1
fi

# --- Step 1: Configure redbank-mcp client ------------------------------------

_out "Configuring ${TARGET_CLIENT} client for token exchange..."

TARGET_UUID=$(kc_api GET "/${REALM}/clients?clientId=${TARGET_CLIENT}" | jq -r '.[0].id')
if [[ -z "$TARGET_UUID" || "$TARGET_UUID" == "null" ]]; then
  echo "ERROR: Client ${TARGET_CLIENT} not found" >&2
  exit 1
fi

# Enable client authentication and service accounts
kc_api PUT "/${REALM}/clients/${TARGET_UUID}" -d "{
  \"clientId\": \"${TARGET_CLIENT}\",
  \"publicClient\": false,
  \"serviceAccountsEnabled\": true,
  \"authorizationServicesEnabled\": false,
  \"attributes\": {
    \"oauth2.device.authorization.grant.enabled\": \"false\",
    \"oidc.ciba.grant.enabled\": \"false\",
    \"client.secret.creation.time\": \"$(date +%s)\"
  }
}" >/dev/null

_out "✅ ${TARGET_CLIENT} configured (client authentication + service accounts enabled)"

# --- Step 2: Configure knowledge-agent SPIFFE client -------------------------

_out "Configuring knowledge-agent SPIFFE client for authorization..."

KNOWLEDGE_AGENT_CLIENT="${SUBJECT_CLIENT_PREFIX}redbank-knowledge-agent"
KNOWLEDGE_UUID=$(kc_api GET "/${REALM}/clients?clientId=$(echo "$KNOWLEDGE_AGENT_CLIENT" | jq -sRr @uri)" | jq -r '.[0].id')

if [[ -z "$KNOWLEDGE_UUID" || "$KNOWLEDGE_UUID" == "null" ]]; then
  _out "WARNING: Knowledge agent SPIFFE client not found: ${KNOWLEDGE_AGENT_CLIENT}"
  _out "         This is expected if agents haven't been deployed yet."
else
  # Enable authorization
  kc_api PUT "/${REALM}/clients/${KNOWLEDGE_UUID}" -d "{
    \"authorizationServicesEnabled\": true
  }" >/dev/null

  _out "✅ Authorization enabled on knowledge-agent SPIFFE client"

  # --- Step 3: Create client policy ------------------------------------------

  _out "Creating client policy for token exchange..."

  MCP_SERVER_CLIENT="${SUBJECT_CLIENT_PREFIX}redbank-mcp-server"

  # Create or update client policy
  kc_api POST "/${REALM}/clients/${KNOWLEDGE_UUID}/authz/resource-server/policy/client" -d "{
    \"type\": \"client\",
    \"logic\": \"POSITIVE\",
    \"decisionStrategy\": \"UNANIMOUS\",
    \"name\": \"clients-allowed-to-exchange\",
    \"description\": \"Clients allowed to exchange tokens with knowledge-agent\",
    \"clients\": [\"${MCP_SERVER_CLIENT}\"]
  }" 2>/dev/null || _out "Client policy already exists"

  _out "✅ Client policy created"

  # --- Step 4: Create token-exchange permission ------------------------------

  _out "Creating token-exchange permission on account client..."

  ACCOUNT_UUID=$(kc_api GET "/${REALM}/clients?clientId=account" | jq -r '.[0].id')
  if [[ -z "$ACCOUNT_UUID" || "$ACCOUNT_UUID" == "null" ]]; then
    echo "ERROR: account client not found" >&2
    exit 1
  fi

  # Get policy ID
  POLICY_ID=$(kc_api GET "/${REALM}/clients/${KNOWLEDGE_UUID}/authz/resource-server/policy?name=clients-allowed-to-exchange" | jq -r '.[0].id')

  # Get token-exchange resource
  RESOURCE_ID=$(kc_api GET "/${REALM}/clients/${ACCOUNT_UUID}/authz/resource-server/resource?name=token-exchange" | jq -r '.[0]._id')

  if [[ -n "$RESOURCE_ID" && "$RESOURCE_ID" != "null" ]]; then
    # Create permission
    kc_api POST "/${REALM}/clients/${ACCOUNT_UUID}/authz/resource-server/permission/resource" -d "{
      \"type\": \"resource\",
      \"logic\": \"POSITIVE\",
      \"decisionStrategy\": \"UNANIMOUS\",
      \"name\": \"token-exchange-permission\",
      \"description\": \"Permission for clients to exchange tokens\",
      \"resources\": [\"${RESOURCE_ID}\"],
      \"policies\": [\"${POLICY_ID}\"]
    }" 2>/dev/null || _out "Permission already exists"

    _out "✅ Token-exchange permission created"
  else
    _out "WARNING: token-exchange resource not found on account client"
    _out "         This may be normal if FGAP v1 is not fully initialized yet"
  fi
fi

# --- Verify ------------------------------------------------------------------

_out ""
_out "Token exchange configuration complete!"
_out ""
_out "Configuration summary:"
_out "  Realm:            ${REALM}"
_out "  Target client:    ${TARGET_CLIENT}"
_out "  Subject client:   ${KNOWLEDGE_AGENT_CLIENT}"
_out "  MCP server:       ${MCP_SERVER_CLIENT}"
_out ""
_out "To test: make test-token-exchange"

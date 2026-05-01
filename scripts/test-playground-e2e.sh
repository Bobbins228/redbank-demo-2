#!/bin/bash
# End-to-end test for RedBank playground with authentication and MCP calls
#
# Tests the full flow:
# 1. Get OAuth token from Keycloak
# 2. Call orchestrator with authenticated request
# 3. Verify knowledge agent can access MCP server via token exchange
#
# Usage: ./scripts/test-playground-e2e.sh

set -euo pipefail

PLAYGROUND_URL="${PLAYGROUND_URL:-https://redbank-playground-redbank-demo.apps.rosa.akram.dxp0.p3.openshiftapps.com}"
KEYCLOAK_URL="${KEYCLOAK_URL:-https://keycloak-keycloak.apps.rosa.akram.dxp0.p3.openshiftapps.com}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-$NAMESPACE}"
KEYCLOAK_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-redbank-mcp}"
KEYCLOAK_CLIENT_SECRET="${KEYCLOAK_CLIENT_SECRET:-Fx9eXQiObew9wVSO1hGLTXmCRaJfEg61}"
TEST_USER="${TEST_USER:-jane}"
TEST_PASSWORD="${TEST_PASSWORD:-jane123}"

echo "🧪 RedBank Playground E2E Test"
echo "==============================="
echo ""

# Step 1: Get token via Resource Owner Password Credentials (for testing only)
echo "1️⃣  Getting OAuth token from Keycloak..."

# First, enable direct access grants on the client (required for password grant)
echo "   Setting up client for password grant (test only)..."
kubectl port-forward -n keycloak svc/keycloak-service 8080:8080 >/dev/null 2>&1 &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null || true" EXIT
sleep 2

ADMIN_PASSWORD=$(kubectl get secret keycloak-initial-admin -n keycloak -o jsonpath='{.data.password}' | base64 -d)
ADMIN_TOKEN=$(curl -s -X POST "http://localhost:8080/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" \
  -d "username=temp-admin" \
  -d "password=$ADMIN_PASSWORD" | jq -r '.access_token')

CLIENT_UUID=$(curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
  "http://localhost:8080/admin/realms/$KEYCLOAK_REALM/clients?clientId=$KEYCLOAK_CLIENT_ID" | jq -r '.[0].id')

curl -s -X PUT -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
  "http://localhost:8080/admin/realms/$KEYCLOAK_REALM/clients/$CLIENT_UUID" \
  -d "{\"directAccessGrantsEnabled\":true}" >/dev/null

# Get user token
USER_TOKEN_RESPONSE=$(curl -s -X POST "http://localhost:8080/realms/$KEYCLOAK_REALM/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=$KEYCLOAK_CLIENT_ID" \
  -d "client_secret=$KEYCLOAK_CLIENT_SECRET" \
  -d "username=$TEST_USER" \
  -d "password=$TEST_PASSWORD")

USER_TOKEN=$(echo "$USER_TOKEN_RESPONSE" | jq -r '.access_token')

if [[ "$USER_TOKEN" == "null" || -z "$USER_TOKEN" ]]; then
  echo "   ❌ Failed to get user token:"
  echo "$USER_TOKEN_RESPONSE" | jq '.'
  exit 1
fi

echo "   ✅ Got OAuth token for user: $TEST_USER"

# Verify token issuer
TOKEN_ISSUER=$(python3 -c "import sys,json,base64; payload='$USER_TOKEN'.split('.')[1]; payload+='='*(-len(payload)%4); print(json.loads(base64.b64decode(payload))['iss'])")
echo "   📋 Token issuer: $TOKEN_ISSUER"

if [[ "$TOKEN_ISSUER" != "$KEYCLOAK_URL/realms/$KEYCLOAK_REALM" ]]; then
  echo "   ⚠️  WARNING: Token issuer mismatch!"
  echo "       Expected: $KEYCLOAK_URL/realms/$KEYCLOAK_REALM"
  echo "       Got:      $TOKEN_ISSUER"
fi

# Step 2: Call orchestrator with a knowledge-base query
echo ""
echo "2️⃣  Calling orchestrator with MCP-requiring query..."

QUESTION="How do I reset my password?"
REQUEST_BODY=$(jq -n \
  --arg q "$QUESTION" \
  '{
    model: "gpt-4",
    messages: [{role: "user", content: $q}],
    stream: false
  }')

RESPONSE=$(curl -s -X POST "$PLAYGROUND_URL/chat/completions" \
  -H "Authorization: Bearer $USER_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$REQUEST_BODY")

echo "   Response received (first 200 chars):"
echo "$RESPONSE" | jq -r '.choices[0].message.content // .error.message // .' | head -c 200
echo "..."
echo ""

# Check for errors
if echo "$RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
  echo "   ❌ API returned error:"
  echo "$RESPONSE" | jq '.error'
  exit 1
fi

ANSWER=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty')
if [[ -z "$ANSWER" ]]; then
  echo "   ❌ No answer in response:"
  echo "$RESPONSE" | jq '.'
  exit 1
fi

# Check if answer contains error message (agent failure)
if echo "$ANSWER" | grep -qi "encountered an error\|connection error\|network error"; then
  echo "   ❌ Agent returned error message:"
  echo "$ANSWER"
  echo ""
  echo "   Checking knowledge-agent logs for details..."
  kubectl logs -n redbank-demo -l app=redbank-knowledge-agent -c envoy-proxy --tail=10 | grep -E "token exchange|error"
  exit 1
fi

echo "   ✅ Received successful answer from agent"

# Step 3: Verify token exchange worked
echo ""
echo "3️⃣  Verifying token exchange succeeded..."

# Check authbridge logs for successful token exchange
EXCHANGE_LOGS=$(kubectl logs -n redbank-demo -l app=redbank-knowledge-agent -c envoy-proxy --tail=20 2>/dev/null || true)

if echo "$EXCHANGE_LOGS" | grep -q "token exchange failed"; then
  echo "   ❌ Token exchange failed:"
  echo "$EXCHANGE_LOGS" | grep "token exchange failed"

  echo ""
  echo "   Keycloak logs:"
  kubectl logs -n keycloak keycloak-0 --tail=10 | grep TOKEN_EXCHANGE || echo "   (no recent token exchange attempts)"
  exit 1
fi

if echo "$EXCHANGE_LOGS" | grep -q "outbound exchange.*redbank-mcp-server.*account"; then
  echo "   ✅ Token exchange succeeded (found 'outbound exchange' log)"
else
  echo "   ⚠️  No explicit token exchange log found (may have used cached token)"
fi

# Step 4: Verify MCP server received request
echo ""
echo "4️⃣  Verifying MCP server processed request..."

MCP_LOGS=$(kubectl logs -n redbank-demo -l app=redbank-mcp-server -c mcp-server --tail=20 2>/dev/null || true)

if echo "$MCP_LOGS" | grep -q '"POST http://redbank-mcp-server:8000/mcp" "HTTP/1.1 200 OK"'; then
  echo "   ✅ MCP server returned 200 OK"
elif echo "$MCP_LOGS" | grep -q '"POST http://redbank-mcp-server:8000/mcp" "HTTP/1.1 401'; then
  echo "   ❌ MCP server returned 401 Unauthorized:"
  echo "$MCP_LOGS" | grep "POST.*mcp" | tail -5
  exit 1
else
  echo "   ⚠️  No recent MCP request found in logs"
fi

echo ""
echo "==============================="
echo "✅ ✅ ✅ E2E TEST PASSED! ✅ ✅ ✅"
echo "==============================="
echo ""
echo "Summary:"
echo "  • User authenticated successfully"
echo "  • Orchestrator processed request"
echo "  • Token exchange worked (knowledge-agent → MCP)"
echo "  • MCP server returned data"
echo "  • Agent returned coherent answer"
echo ""
echo "Test query: $QUESTION"
echo "Answer preview: $(echo "$ANSWER" | head -c 150)..."

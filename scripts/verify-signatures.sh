#!/usr/bin/env bash
##
# Verify SPIRE agent card signing for RedBank agents.
# Adapted from kagenti-operator/demos/agentcard-spire-signing/run-demo-commands.sh
#
set -euo pipefail

NAMESPACE="${NAMESPACE:-redbank-demo}"

echo "=== Pre-flight: Namespace Labels ==="
AGENTCARD_LABEL=$(oc get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.agentcard}' 2>/dev/null || true)
echo "  agentcard label: ${AGENTCARD_LABEL:-<not set>}"
if [[ "$AGENTCARD_LABEL" != "true" ]]; then
  echo "  WARNING: namespace '${NAMESPACE}' is not labeled agentcard=true — SPIRE identity registration may not work"
fi
echo ""

AGENTS=(
  "redbank-banking-agent:banking-agent:8001"
  "redbank-knowledge-agent:knowledge-agent:8002"
)

for ENTRY in "${AGENTS[@]}"; do
  IFS=: read -r AGENT_NAME CONTAINER_NAME PORT <<< "$ENTRY"
  CARD_NAME="${AGENT_NAME}-deployment-card"

  echo ""
  echo "========================================"
  echo " ${AGENT_NAME}"
  echo "========================================"

  POD=$(oc get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=${AGENT_NAME}" \
    --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -z "$POD" ]]; then
    echo "  (no running pod found — skipping)"
    continue
  fi

  echo "=== 1. Init-Container Signing Logs ==="
  oc logs -n "$NAMESPACE" "$POD" -c sign-agentcard 2>/dev/null || echo "  (no init-container logs)"
  echo ""

  echo "=== 2. Pod Containers (expect: sign-agentcard init + main only, no sidecars) ==="
  echo "  Init containers:"
  oc get pod "$POD" -n "$NAMESPACE" \
    -o jsonpath='{range .spec.initContainers[*]}{.name}{"\n"}{end}' \
    2>/dev/null | while read -r name; do echo "    - $name"; done
  echo "  Containers:"
  oc get pod "$POD" -n "$NAMESPACE" \
    -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}' \
    2>/dev/null | while read -r name; do echo "    - $name"; done
  CONTAINER_COUNT=$(oc get pod "$POD" -n "$NAMESPACE" \
    -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}' 2>/dev/null | grep -c . || echo 0)
  if [[ "$CONTAINER_COUNT" -gt 1 ]]; then
    echo "  WARNING: unexpected extra containers detected (expected 1, found ${CONTAINER_COUNT})"
  else
    echo "  OK: single container (no sidecars)"
  fi
  echo ""

  echo "=== 3. Signed Card Verification ==="
  oc exec -n "$NAMESPACE" "$POD" -c "$CONTAINER_NAME" -- python3 -c "
import json
with open('/opt/app-root/.well-known/agent-card.json') as f:
    d = json.load(f)
print(f'  Name:       {d.get(\"name\")}')
print(f'  Signed:     {\"signatures\" in d}')
print(f'  Signatures: {len(d.get(\"signatures\", []))}')
" 2>/dev/null || echo "  (could not exec into pod)"
  echo ""

  echo "=== 4. JWS Protected Header ==="
  oc get agentcard "$CARD_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.card.signatures[0].protected}' 2>/dev/null | python3 -c "
import sys, base64, json
b64 = sys.stdin.read().strip()
if b64:
    header = json.loads(base64.urlsafe_b64decode(b64 + '=='))
    print(f'  Algorithm:  {header.get(\"alg\")}')
    print(f'  Type:       {header.get(\"typ\")}')
    print(f'  Key ID:     {header.get(\"kid\")}')
    print(f'  x5c certs:  {len(header.get(\"x5c\", []))}')
else:
    print('  (no protected header yet)')
" || echo "  (AgentCard CR not found)"
  echo ""

  echo "=== 5. Operator Verification Status ==="
  oc get agentcard "$CARD_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions}' 2>/dev/null | python3 -c "
import sys, json
try:
    for c in json.loads(sys.stdin.read()):
        if c['type'] in ('SignatureVerified', 'Bound', 'Synced'):
            pad = ' ' * (20 - len(c['type']))
            print(f'  {c[\"type\"]}:{pad}{c[\"status\"]}  ({c[\"reason\"]})')
except:
    print('  (no conditions yet)')
" || echo "  (AgentCard CR not found)"
  echo ""

  echo "=== 6. Identity Binding ==="
  oc get agentcard "$CARD_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status}' 2>/dev/null | python3 -c "
import sys, json
try:
    s = json.loads(sys.stdin.read())
    print(f'  SPIFFE ID:      {s.get(\"signatureSpiffeId\", \"(none)\")}')
    print(f'  Identity Match: {s.get(\"signatureIdentityMatch\")}')
    print(f'  Bound:          {s.get(\"bindingStatus\", {}).get(\"bound\")}')
except:
    print('  (no status yet)')
" || echo "  (AgentCard CR not found)"
  echo ""

  echo "=== 7. Signature Label ==="
  LABEL=$(oc get deployment "$AGENT_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.spec.template.metadata.labels.agent\.kagenti\.dev/signature-verified}' 2>/dev/null || true)
  echo "  agent.kagenti.dev/signature-verified: ${LABEL:-<not set>}"
  echo ""

done

echo "=== 8. AgentCard Summary ==="
oc get agentcard -n "$NAMESPACE" 2>/dev/null || echo "(no AgentCard CRs found)"

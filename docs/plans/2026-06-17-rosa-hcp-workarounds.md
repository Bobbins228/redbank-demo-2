# ROSA HCP Workarounds Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make `make test-token-exchange` work end-to-end on ROSA HCP, including with SPIRE enabled, by incorporating all known workarounds into the setup scripts.

**Architecture:** The kagenti operator (post PR #408) introduced breaking defaults: empty `mtls:` block defaults to permissive (requires SPIRE), and proxy-init requires iptables (broken on ROSA HCP). We fix this by updating `enable-kagenti.sh` to generate correct ConfigMaps (egressEnforcement, mtls), set the SPIRE trust domain env var, apply RBAC workarounds, and fix Keycloak route detection. Also fix the same route detection in `configure-token-exchange-v2.sh` and `test-token-exchange.sh`.

**Tech Stack:** Bash scripts, OpenShift CLI (`oc`/`kubectl`), ConfigMaps, ClusterRoles

---

### Task 1: Fix Keycloak route detection in enable-kagenti.sh

**Files:**
- Modify: `scripts/enable-kagenti.sh:14-19`

**Context:** The current detection uses `oc get route -n keycloak -o jsonpath='{.items[0].spec.host}'` which picks whichever route comes first. On ROSA HCP, the auto-generated route is named `keycloak-ingress-dqtcl`, not `keycloak`. The operator expects a route named `keycloak`. The script should try the `keycloak` route first, then fall back to `items[0]`.

**Step 1: Edit the route detection block**

Replace lines 14-19 in `scripts/enable-kagenti.sh` with:

```bash
# Try the canonical 'keycloak' route first, fall back to any route in the namespace
KC_ROUTE_HOST=$(oc get route keycloak -n keycloak -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [ -z "$KC_ROUTE_HOST" ]; then
  KC_ROUTE_HOST=$(oc get route -n keycloak -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)
fi
if [ -z "$KC_ROUTE_HOST" ]; then
  echo "ERROR: Cannot detect Keycloak route in namespace keycloak." >&2
  echo "  Create a route named 'keycloak' or set KEYCLOAK_HOST." >&2
  exit 1
fi
CLUSTER_DOMAIN=$(echo "$KC_ROUTE_HOST" | sed 's/^keycloak-keycloak\.//' | sed 's/^keycloak\.//')
KEYCLOAK_HOST="${KEYCLOAK_HOST:-keycloak-keycloak.${CLUSTER_DOMAIN}}"
```

**Step 2: Verify script parses**

Run: `bash -n scripts/enable-kagenti.sh`
Expected: no output (clean parse)

**Step 3: Commit**

```bash
git add scripts/enable-kagenti.sh
git commit -m "fix(enable-kagenti): robust Keycloak route detection for ROSA HCP"
```

---

### Task 2: Add egressEnforcement and mtls to authbridge-runtime-config

**Files:**
- Modify: `scripts/enable-kagenti.sh:213-243` (authbridge-runtime-config ConfigMap)

**Context:** On ROSA HCP, `proxy-init` crashes because the `iptable_nat` kernel module is absent and SELinux blocks it. Setting `egressEnforcement: none` disables iptables-based traffic interception. The new operator (PR #408) adds an empty `mtls:` block that defaults to `permissive`, which requires SPIRE. Without SPIRE configured, authbridge-proxy exits with `mtls requires the spiffe block to be configured`. We add `mtls: mode: disabled` by default.

**Step 1: Update the authbridge-runtime-config heredoc**

Replace the ConfigMap data section (the `cat <<EOF ... EOF` block starting at line 215) so the `config.yaml` value includes two new fields:

```yaml
    mode: proxy-sidecar
    egressEnforcement: none
    mtls:
      mode: disabled
    bypass:
      inbound_paths:
        - "/.well-known/*"
        - "/health"
        - "/healthz"
        - "/readyz"
        - "/livez"
    identity:
      type: "client-secret"
      client_id_file: "/shared/client-id.txt"
      client_secret_file: "/shared/client-secret.txt"
    inbound:
      issuer: "https://${KEYCLOAK_HOST}/realms/${REALM}"
      expected_audience: "${KEYCLOAK_CLIENT_ID:-redbank-mcp}"
    outbound:
      keycloak_url: "https://${KEYCLOAK_HOST}"
      keycloak_realm: "${REALM}"
      default_policy: "passthrough"
    routes:
      file: "/etc/authproxy/routes.yaml"
```

**Step 2: Verify script parses**

Run: `bash -n scripts/enable-kagenti.sh`
Expected: no output

**Step 3: Commit**

```bash
git add scripts/enable-kagenti.sh
git commit -m "fix(enable-kagenti): add egressEnforcement:none and mtls:disabled for ROSA HCP"
```

---

### Task 3: Set KAGENTI_SPIRE_TRUST_DOMAIN on controller-manager

**Files:**
- Modify: `scripts/enable-kagenti.sh` (add new section after NAMESPACES2WATCH block, before final echo)

**Context:** The operator's client registration depends on auto-discovering the SPIRE trust domain via ZTWIM CRD or spire-bundle ConfigMap. Both fail on ROSA HCP. Setting `KAGENTI_SPIRE_TRUST_DOMAIN` env var on the controller-manager deployment provides the trust domain directly. The trust domain matches the cluster's apps domain.

**Step 1: Add trust domain section**

Insert this block after the NAMESPACES2WATCH section (after `fi` on line 336), before the final echo block:

```bash
# --- Set SPIRE trust domain on operator (if not already set) ------------------

echo "Checking KAGENTI_SPIRE_TRUST_DOMAIN on operator..."
if [ -n "$OPERATOR_DEPLOY" ]; then
  CURRENT_TD=$(oc get deploy "$OPERATOR_DEPLOY" -n kagenti-system \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KAGENTI_SPIRE_TRUST_DOMAIN")].value}' 2>/dev/null || true)
  if [ -z "$CURRENT_TD" ]; then
    # Derive trust domain from cluster apps domain
    TRUST_DOMAIN="${CLUSTER_DOMAIN}"
    echo "  Setting KAGENTI_SPIRE_TRUST_DOMAIN=${TRUST_DOMAIN}"
    HAS_ENV=$(oc get deploy "$OPERATOR_DEPLOY" -n kagenti-system -o jsonpath='{.spec.template.spec.containers[0].env}' 2>/dev/null)
    if [ -n "$HAS_ENV" ] && [ "$HAS_ENV" != "null" ]; then
      oc patch deploy "$OPERATOR_DEPLOY" -n kagenti-system --type=json \
        -p="[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/env/-\",\"value\":{\"name\":\"KAGENTI_SPIRE_TRUST_DOMAIN\",\"value\":\"${TRUST_DOMAIN}\"}}]"
    else
      oc patch deploy "$OPERATOR_DEPLOY" -n kagenti-system --type=json \
        -p="[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/env\",\"value\":[{\"name\":\"KAGENTI_SPIRE_TRUST_DOMAIN\",\"value\":\"${TRUST_DOMAIN}\"}]}]"
    fi
  else
    echo "  Already set: ${CURRENT_TD}"
  fi
fi
```

**Step 2: Verify script parses**

Run: `bash -n scripts/enable-kagenti.sh`
Expected: no output

**Step 3: Commit**

```bash
git add scripts/enable-kagenti.sh
git commit -m "fix(enable-kagenti): set KAGENTI_SPIRE_TRUST_DOMAIN for ROSA HCP"
```

---

### Task 4: Apply RBAC workarounds for cert-manager and DataScienceCluster

**Files:**
- Modify: `scripts/enable-kagenti.sh` (add new section after SCC grant, before NAMESPACES2WATCH)

**Context:** SharedTrust and MLflow controllers in the operator crash with RBAC errors if cert-manager or OpenDataHub CRDs are present but the operator lacks permission to list them. This blocks the entire manager (including client registration). The workaround is to create ClusterRoles and ClusterRoleBindings.

**Step 1: Add RBAC section**

Insert after the SCC grant block (after `echo "SCC granted"` on line 301):

```bash
# --- RBAC workarounds for optional CRD controllers ----------------------------
# The operator's SharedTrust and MLflow controllers crash if their CRDs exist
# but the ServiceAccount lacks list/watch permissions. These are safe no-ops
# if the CRDs don't exist.

echo "Applying RBAC workarounds for optional controllers..."

# cert-manager certificates
if oc get crd certificates.cert-manager.io &>/dev/null; then
  oc create clusterrole kagenti-cert-manager-reader \
    --verb=get,list,watch --resource=certificates.cert-manager.io \
    --dry-run=client -o yaml | oc apply -f -
  oc create clusterrolebinding kagenti-cert-manager-reader \
    --clusterrole=kagenti-cert-manager-reader \
    --serviceaccount=kagenti-system:controller-manager \
    --dry-run=client -o yaml | oc apply -f -
  echo "  cert-manager RBAC applied"
fi

# OpenDataHub DataScienceCluster
if oc get crd datascienceclusters.datasciencecluster.opendatahub.io &>/dev/null; then
  oc create clusterrole kagenti-datasciencecluster-reader \
    --verb=get,list,watch --resource=datascienceclusters.datasciencecluster.opendatahub.io \
    --dry-run=client -o yaml | oc apply -f -
  oc create clusterrolebinding kagenti-datasciencecluster-reader \
    --clusterrole=kagenti-datasciencecluster-reader \
    --serviceaccount=kagenti-system:controller-manager \
    --dry-run=client -o yaml | oc apply -f -
  echo "  DataScienceCluster RBAC applied"
fi
```

**Step 2: Verify script parses**

Run: `bash -n scripts/enable-kagenti.sh`
Expected: no output

**Step 3: Commit**

```bash
git add scripts/enable-kagenti.sh
git commit -m "fix(enable-kagenti): RBAC workarounds for cert-manager and ODH controllers"
```

---

### Task 5: Fix Keycloak route detection in configure-token-exchange-v2.sh

**Files:**
- Modify: `scripts/configure-token-exchange-v2.sh:25-27`

**Context:** Same issue as Task 1 -- uses `items[0]` which may not be the canonical `keycloak` route.

**Step 1: Update route detection**

Replace lines 24-27 with:

```bash
KC_URL="${KEYCLOAK_URL:-}"
if [ -z "$KC_URL" ]; then
  KC_HOST=$(oc get route keycloak -n keycloak -o jsonpath='{.spec.host}' 2>/dev/null \
    || oc get route -n keycloak -o jsonpath='{.items[0].spec.host}')
  KC_URL="https://${KC_HOST}"
fi
```

**Step 2: Verify script parses**

Run: `bash -n scripts/configure-token-exchange-v2.sh`
Expected: no output

**Step 3: Commit**

```bash
git add scripts/configure-token-exchange-v2.sh
git commit -m "fix(configure-token-exchange): robust Keycloak route detection"
```

---

### Task 6: Fix Keycloak route detection in test-token-exchange.sh

**Files:**
- Modify: `scripts/test-token-exchange.sh:165-170`

**Context:** Same route detection issue.

**Step 1: Update route detection**

Replace lines 165-170 with:

```bash
if [ -n "${KEYCLOAK_URL:-}" ]; then
  KC_URL="$KEYCLOAK_URL"
else
  KC_HOST=$(oc get route keycloak -n keycloak -o jsonpath='{.spec.host}' 2>/dev/null \
    || oc get route -n keycloak -o jsonpath='{.items[0].spec.host}')
  KC_URL="https://${KC_HOST}"
fi
KEYCLOAK_URL="$KC_URL"
```

**Step 2: Verify script parses**

Run: `bash -n scripts/test-token-exchange.sh`
Expected: no output

**Step 3: Commit**

```bash
git add scripts/test-token-exchange.sh
git commit -m "fix(test-token-exchange): robust Keycloak route detection"
```

---

### Task 7: Update enable-spiffe.sh to set mtls mode to permissive

**Files:**
- Modify: `scripts/enable-spiffe.sh:58-84`

**Context:** When SPIFFE is enabled, `enable-spiffe.sh` already updates identity type from `client-secret` to `spiffe`. It should also set `mtls.mode` from `disabled` to `permissive` (or `strict` if desired). Without this, mtls stays disabled even after enabling SPIFFE.

**Step 1: Update the Python rewriter in enable-spiffe.sh**

Replace the Python block (lines 62-82) with:

```python
UPDATED_YAML=$(echo "$RUNTIME_YAML" | python3 -c "
import sys
lines = []
has_svid = False
for line in sys.stdin:
    stripped = line.rstrip()
    if 'jwt_svid_path' in stripped:
        has_svid = True
    lines.append(stripped)
# Rewrite with correct identity type, jwt_svid_path, and mtls mode
result = []
for line in lines:
    if 'type: \"client-secret\"' in line:
        result.append(line.replace('client-secret', 'spiffe'))
    elif 'mode: disabled' in line and 'mtls' not in line:
        # mtls.mode line — switch to permissive
        result.append(line.replace('disabled', 'permissive'))
    else:
        result.append(line)
    if 'client_secret_file' in line and not has_svid:
        indent = len(line) - len(line.lstrip())
        result.append(' ' * indent + 'jwt_svid_path: \"/opt/jwt_svid.token\"')
print('\n'.join(result))
")
```

**Note:** The `'mode: disabled' in line and 'mtls' not in line` check targets the indented `mode: disabled` line under the `mtls:` block. The `proxy-sidecar` mode line says `mode: proxy-sidecar` so won't match.

**Step 2: Verify script parses**

Run: `bash -n scripts/enable-spiffe.sh`
Expected: no output

**Step 3: Commit**

```bash
git add scripts/enable-spiffe.sh
git commit -m "fix(enable-spiffe): set mtls mode to permissive when enabling SPIFFE"
```

---

### Task 8: Add verify-config checks for new fields

**Files:**
- Modify: `scripts/verify-config.sh:120-140` (after authbridge-config checks)

**Step 1: Add checks for egressEnforcement and mtls**

After the `authbridge-runtime-config exists` check (line 125), add:

```bash
# Check ROSA HCP workarounds
EGRESS_MODE=$(kubectl get configmap authbridge-runtime-config -n "${NAMESPACE}" -o jsonpath='{.data.config\.yaml}' | grep -o 'egressEnforcement:.*' | awk '{print $2}')
if [ "$EGRESS_MODE" = "none" ]; then
  ok "egressEnforcement: none (ROSA HCP)"
else
  echo "  ℹ️  egressEnforcement: ${EGRESS_MODE:-not set}"
fi

MTLS_MODE=$(kubectl get configmap authbridge-runtime-config -n "${NAMESPACE}" -o jsonpath='{.data.config\.yaml}' | grep -A1 'mtls:' | grep 'mode:' | awk '{print $2}')
echo "  ℹ️  mTLS mode: ${MTLS_MODE:-not set}"

# Check SPIRE trust domain on operator
TD=$(oc get deploy kagenti-controller-manager -n kagenti-system -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KAGENTI_SPIRE_TRUST_DOMAIN")].value}' 2>/dev/null)
if [ -n "$TD" ]; then
  ok "SPIRE trust domain: ${TD}"
else
  echo "  ℹ️  KAGENTI_SPIRE_TRUST_DOMAIN: not set on operator"
fi
```

**Step 2: Verify script parses**

Run: `bash -n scripts/verify-config.sh`
Expected: no output

**Step 3: Commit**

```bash
git add scripts/verify-config.sh
git commit -m "feat(verify-config): check egressEnforcement, mtls, and trust domain"
```

---

### Task 9: Add Makefile target for standalone RBAC fix

**Files:**
- Modify: `Makefile` (add target in Setup section, after `enable-kagenti`)

**Step 1: Add fix-rbac target**

After the `enable-kagenti` target (line 69), add:

```makefile
fix-rbac: ##@setup 3b. Apply RBAC workarounds for cert-manager/ODH (auto-run by enable-kagenti)
	@oc get crd certificates.cert-manager.io &>/dev/null && \
	  oc create clusterrole kagenti-cert-manager-reader --verb=get,list,watch --resource=certificates.cert-manager.io --dry-run=client -o yaml | oc apply -f - && \
	  oc create clusterrolebinding kagenti-cert-manager-reader --clusterrole=kagenti-cert-manager-reader --serviceaccount=kagenti-system:controller-manager --dry-run=client -o yaml | oc apply -f - && \
	  echo "cert-manager RBAC applied" || true
	@oc get crd datascienceclusters.datasciencecluster.opendatahub.io &>/dev/null && \
	  oc create clusterrole kagenti-datasciencecluster-reader --verb=get,list,watch --resource=datascienceclusters.datasciencecluster.opendatahub.io --dry-run=client -o yaml | oc apply -f - && \
	  oc create clusterrolebinding kagenti-datasciencecluster-reader --clusterrole=kagenti-datasciencecluster-reader --serviceaccount=kagenti-system:controller-manager --dry-run=client -o yaml | oc apply -f - && \
	  echo "DataScienceCluster RBAC applied" || true
```

Also add `fix-rbac` to the `.PHONY` list.

**Step 2: Verify Makefile parses**

Run: `make -n fix-rbac` (dry run)
Expected: shows the commands that would run

**Step 3: Commit**

```bash
git add Makefile
git commit -m "feat(Makefile): add fix-rbac target for ROSA HCP RBAC workarounds"
```

---

### Task 10: End-to-end test

**Step 1: Run verify-config**

Run: `make verify-config`
Expected: egressEnforcement, mtls, trust domain checks appear

**Step 2: Run test-token-exchange without SPIFFE**

Run: `make test-token-exchange`
Expected: ALL TESTS PASSED (3/3)

**Step 3: Enable SPIFFE and re-test**

```bash
make setup-keycloak-spiffe
make enable-spiffe
make configure-token-exchange
# Wait for pods to be 3/3 Running
oc get pods -n redbank-demo-test-ee -w
make test-token-exchange
```

Expected: ALL TESTS PASSED (3/3) with SPIFFE mode

---

## Execution Order Summary

```
Task 1  — Fix route detection in enable-kagenti.sh
Task 2  — Add egressEnforcement + mtls to runtime config
Task 3  — Set SPIRE trust domain env var
Task 4  — Apply RBAC workarounds
Task 5  — Fix route detection in configure-token-exchange-v2.sh
Task 6  — Fix route detection in test-token-exchange.sh
Task 7  — Update enable-spiffe.sh for mtls mode
Task 8  — Add verify-config checks
Task 9  — Add Makefile fix-rbac target
Task 10 — End-to-end test
```

Tasks 1-4 modify `enable-kagenti.sh` and should be applied sequentially.
Tasks 5-9 are independent of each other and can be done in parallel.
Task 10 requires all prior tasks.

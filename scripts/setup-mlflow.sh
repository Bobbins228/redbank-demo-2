#!/bin/bash
#
# Configure MLflow tracing for agent workloads.
#
# MLflow on OpenShift AI uses kubernetes-auth: the pod's service account token
# is sent as a Bearer token. This script creates a long-lived SA token secret
# and stores it so the deploy scripts can inject MLFLOW_TRACKING_TOKEN.
#
# Environment: NAMESPACE

set -euo pipefail

NAMESPACE="${NAMESPACE:?NAMESPACE is required}"
MLFLOW_NS="redhat-ods-applications"
SA_NAME="mlflow-agent"
SECRET_NAME="mlflow-tracking-credentials"

function _out() {
  echo "$(date +'%F %H:%M:%S') $@"
}

# --- Check MLflow is available -----------------------------------------------

if ! oc get svc mlflow -n "${MLFLOW_NS}" &>/dev/null; then
  _out "MLflow service not found in ${MLFLOW_NS} — skipping"
  exit 0
fi

_out "Configuring MLflow tracing for namespace ${NAMESPACE}"

# --- Create a service account for MLflow access ------------------------------

_out "Creating service account ${SA_NAME}"
oc create sa "${SA_NAME}" -n "${NAMESPACE}" 2>/dev/null || true

# --- Grant the SA permission to authenticate with MLflow ---------------------
# MLflow's kubernetes-auth validates tokens via TokenReview and checks if the
# SA has access to the mlflow namespace. We grant view access.

_out "Granting MLflow access to ${SA_NAME}"
oc adm policy add-role-to-user view \
  "system:serviceaccount:${NAMESPACE}:${SA_NAME}" \
  -n "${MLFLOW_NS}" 2>/dev/null || true

# Also grant to the default SA (used by agent pods)
oc adm policy add-role-to-user view \
  "system:serviceaccount:${NAMESPACE}:default" \
  -n "${MLFLOW_NS}" 2>/dev/null || true

# --- Create a long-lived token secret ----------------------------------------

_out "Creating long-lived token secret"
cat <<EOF | oc apply -n "${NAMESPACE}" -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  annotations:
    kubernetes.io/service-account.name: ${SA_NAME}
type: kubernetes.io/service-account-token
EOF

# Wait for the token to be populated
for i in $(seq 1 10); do
  TOKEN=$(oc get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)
  if [ -n "$TOKEN" ]; then break; fi
  sleep 1
done

if [ -z "$TOKEN" ]; then
  _out "ERROR: Token not populated in secret ${SECRET_NAME}"
  exit 1
fi

# --- Store MLflow config in a secret for deploy scripts ----------------------

MLFLOW_URI="https://mlflow.${MLFLOW_NS}.svc:8443"

# --- Create MLflow workspace for this namespace ------------------------------

_out "Creating MLflow workspace '${NAMESPACE}'..."
# Use a running pod to reach the in-cluster MLflow service
EXEC_POD=$(oc get pod -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' --field-selector=status.phase=Running 2>/dev/null)
if [ -n "$EXEC_POD" ]; then
  EXEC_CONTAINER=$(oc get pod "$EXEC_POD" -n "${NAMESPACE}" -o jsonpath='{.spec.containers[0].name}')
  WORKSPACE_RESULT=$(oc exec "$EXEC_POD" -n "${NAMESPACE}" -c "$EXEC_CONTAINER" -- \
    curl -sk -X POST "${MLFLOW_URI}/api/2.0/mlflow/workspaces" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"name\": \"${NAMESPACE}\"}" 2>/dev/null) || true
  if echo "$WORKSPACE_RESULT" | jq -e '.workspace.id' &>/dev/null; then
    _out "  Workspace created: ${NAMESPACE}"
  else
    _out "  Workspace may already exist or could not be created: $(echo "$WORKSPACE_RESULT" | jq -r '.message // "ok"' 2>/dev/null)"
  fi
else
  _out "  WARNING: No running pod found to create workspace — create it manually later"
fi

# --- Store MLflow config in a secret for deploy scripts ----------------------

oc create secret generic mlflow-credentials \
  --from-literal=MLFLOW_TRACKING_URI="${MLFLOW_URI}" \
  --from-literal=MLFLOW_TRACKING_TOKEN="${TOKEN}" \
  -n "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

_out ""
_out "MLflow tracing configured!"
_out "  URI:    ${MLFLOW_URI}"
_out "  Token:  ${SECRET_NAME} (service-account-token, long-lived)"
_out "  Secret: mlflow-credentials (for deploy scripts)"
_out ""
_out "Agents will pick up MLflow credentials automatically on next deploy."
_out "If MLflow's kubernetes-auth rejects requests, the SA may need additional"
_out "RBAC in the workspace namespace. Agents will still start — MLflow errors"
_out "are non-fatal when MLFLOW_TRACKING_URI is set but the connection fails."

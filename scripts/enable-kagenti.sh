#!/bin/bash
#
# Enable kagenti sidecar injection in the target namespace.
# Creates namespace labels, pod security, and required configmaps
# (spiffe-helper-config, envoy-config, authproxy-routes).
#
# Environment: NAMESPACE, KEYCLOAK_REALM, KEYCLOAK_HOST (optional)

set -euo pipefail

NAMESPACE="${NAMESPACE:?NAMESPACE is required}"
REALM="${KEYCLOAK_REALM:-$NAMESPACE}"

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

echo "Enabling kagenti in namespace ${NAMESPACE} (cluster: ${CLUSTER_DOMAIN}, realm: ${REALM})"

# --- Namespace labels --------------------------------------------------------

oc label namespace "${NAMESPACE}" \
  kagenti-enabled=true \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/audit-version=latest \
  pod-security.kubernetes.io/warn=privileged \
  pod-security.kubernetes.io/warn-version=latest \
  --overwrite

echo "Namespace labels applied"

# --- spiffe-helper-config ----------------------------------------------------

echo "Creating spiffe-helper-config..."
cat <<EOF | oc apply -n "${NAMESPACE}" -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: spiffe-helper-config
data:
  helper.conf: |
    agent_address = "/spiffe-workload-api/spire-agent.sock"
    cmd = ""
    cmd_args = ""
    svid_file_name = "/opt/svid.pem"
    svid_key_file_name = "/opt/svid_key.pem"
    svid_bundle_file_name = "/opt/svid_bundle.pem"
    cert_file_mode = 0644
    key_file_mode = 0640
    jwt_svids = [{jwt_audience="https://${KEYCLOAK_HOST}/realms/${REALM}", jwt_svid_file_name="/opt/jwt_svid.token"}]
    jwt_svid_file_mode = 0644
    include_federated_domains = true
EOF

# --- envoy-config ------------------------------------------------------------

echo "Creating envoy-config..."
cat <<'EOF' | oc apply -n "${NAMESPACE}" -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: envoy-config
data:
  envoy.yaml: |
    admin:
      address:
        socket_address:
          protocol: TCP
          address: 127.0.0.1
          port_value: 9901

    static_resources:
      listeners:
      - name: outbound_listener
        address:
          socket_address:
            protocol: TCP
            address: 0.0.0.0
            port_value: 15123
        listener_filters:
        - name: envoy.filters.listener.original_dst
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.listener.original_dst.v3.OriginalDst
        - name: envoy.filters.listener.tls_inspector
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.listener.tls_inspector.v3.TlsInspector
        filter_chains:
        - filter_chain_match:
            transport_protocol: tls
          filters:
          - name: envoy.filters.network.tcp_proxy
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.network.tcp_proxy.v3.TcpProxy
              stat_prefix: outbound_tls_passthrough
              cluster: original_destination
        - filter_chain_match:
            transport_protocol: raw_buffer
          filters:
          - name: envoy.filters.network.http_connection_manager
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
              stat_prefix: outbound_http
              codec_type: AUTO
              route_config:
                name: outbound_routes
                virtual_hosts:
                - name: catch_all
                  domains: ["*"]
                  routes:
                  - match:
                      prefix: "/"
                    route:
                      cluster: original_destination
                      timeout: 300s
              http_filters:
              - name: envoy.filters.http.ext_proc
                typed_config:
                  "@type": type.googleapis.com/envoy.extensions.filters.http.ext_proc.v3.ExternalProcessor
                  grpc_service:
                    envoy_grpc:
                      cluster_name: ext_proc_cluster
                    timeout: 300s
                  processing_mode:
                    request_header_mode: SEND
                    response_header_mode: SKIP
                    request_body_mode: NONE
                    response_body_mode: NONE
              - name: envoy.filters.http.router
                typed_config:
                  "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router

      - name: inbound_listener
        address:
          socket_address:
            protocol: TCP
            address: 0.0.0.0
            port_value: 15124
        listener_filters:
        - name: envoy.filters.listener.original_dst
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.listener.original_dst.v3.OriginalDst
        filter_chains:
        - filters:
          - name: envoy.filters.network.http_connection_manager
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
              stat_prefix: inbound_http
              codec_type: AUTO
              route_config:
                name: inbound_routes
                virtual_hosts:
                - name: local_app
                  domains: ["*"]
                  routes:
                  - match:
                      prefix: "/"
                    route:
                      cluster: original_destination
                      timeout: 300s
              http_filters:
              - name: envoy.filters.http.lua
                typed_config:
                  "@type": type.googleapis.com/envoy.extensions.filters.http.lua.v3.Lua
                  inline_code: |
                    function envoy_on_request(request_handle)
                      request_handle:headers():add("x-authbridge-direction", "inbound")
                    end
              - name: envoy.filters.http.ext_proc
                typed_config:
                  "@type": type.googleapis.com/envoy.extensions.filters.http.ext_proc.v3.ExternalProcessor
                  grpc_service:
                    envoy_grpc:
                      cluster_name: ext_proc_cluster
                    timeout: 300s
                  processing_mode:
                    request_header_mode: SEND
                    response_header_mode: SKIP
                    request_body_mode: NONE
                    response_body_mode: NONE
              - name: envoy.filters.http.router
                typed_config:
                  "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router

      clusters:
      - name: original_destination
        connect_timeout: 30s
        type: ORIGINAL_DST
        lb_policy: CLUSTER_PROVIDED
        original_dst_lb_config:
          use_http_header: false

      - name: ext_proc_cluster
        connect_timeout: 5s
        type: STATIC
        lb_policy: ROUND_ROBIN
        http2_protocol_options: {}
        load_assignment:
          cluster_name: ext_proc_cluster
          endpoints:
          - lb_endpoints:
            - endpoint:
                address:
                  socket_address:
                    address: 127.0.0.1
                    port_value: 9090
EOF

# --- authbridge-runtime-config (base template for per-agent configs) ---------

echo "Creating authbridge-runtime-config..."
KC_INTERNAL="http://keycloak-service.keycloak.svc:8080"
cat <<EOF | oc apply -n "${NAMESPACE}" -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: authbridge-runtime-config
data:
  config.yaml: |
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
EOF

# --- authproxy-routes --------------------------------------------------------

echo "Creating authproxy-routes..."
cat <<'EOF' | oc apply -n "${NAMESPACE}" -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: authproxy-routes
data:
  routes.yaml: ""
EOF

# --- authbridge-config -------------------------------------------------------

echo "Creating authbridge-config..."
cat <<EOF | oc apply -n "${NAMESPACE}" -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: authbridge-config
data:
  KEYCLOAK_URL: "https://${KEYCLOAK_HOST}"
  KEYCLOAK_REALM: "${REALM}"
  KEYCLOAK_NAMESPACE: "keycloak"
  ISSUER: "https://${KEYCLOAK_HOST}/realms/${REALM}"
  SPIRE_ENABLED: "false"
  CLIENT_AUTH_TYPE: "client-secret"
  SPIFFE_IDP_ALIAS: "spire-spiffe"
  JWT_AUDIENCE: "https://${KEYCLOAK_HOST}/realms/${REALM}"
  EXPECTED_AUDIENCE: "redbank-mcp"
  DEFAULT_OUTBOUND_POLICY: "passthrough"
EOF

# --- keycloak-admin-secret ---------------------------------------------------
# The operator reads this from the workload namespace. Credentials are sourced
# from the keycloak-initial-admin secret in the keycloak namespace.

echo "Creating keycloak-admin-secret..."
KC_ADMIN_USER=$(kubectl get secret keycloak-initial-admin -n keycloak -o go-template='{{.data.username | base64decode}}' 2>/dev/null)
KC_ADMIN_PASS=$(kubectl get secret keycloak-initial-admin -n keycloak -o go-template='{{.data.password | base64decode}}' 2>/dev/null)

if [ -n "$KC_ADMIN_USER" ] && [ -n "$KC_ADMIN_PASS" ]; then
  oc create secret generic keycloak-admin-secret \
    --from-literal=KEYCLOAK_ADMIN_USERNAME="$KC_ADMIN_USER" \
    --from-literal=KEYCLOAK_ADMIN_PASSWORD="$KC_ADMIN_PASS" \
    -n "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
else
  echo "  WARNING: keycloak-initial-admin secret not found in keycloak namespace"
  echo "           The operator will wait for keycloak-admin-secret before registering clients"
fi

# --- Grant kagenti-authbridge SCC to namespace service accounts ----------------

echo "Granting kagenti-authbridge SCC to namespace service accounts..."
oc adm policy add-scc-to-group kagenti-authbridge "system:serviceaccounts:${NAMESPACE}" 2>/dev/null || true
echo "SCC granted"

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

# --- Add namespace to operator's NAMESPACES2WATCH ---------------------------

echo "Adding ${NAMESPACE} to kagenti operator NAMESPACES2WATCH..."
OPERATOR_DEPLOY=$(oc get deploy -n kagenti-system -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
# Prefer kagenti-controller-manager if it exists
oc get deploy kagenti-controller-manager -n kagenti-system &>/dev/null && OPERATOR_DEPLOY="kagenti-controller-manager"

if [ -n "$OPERATOR_DEPLOY" ]; then
  CURRENT=$(oc get deploy "$OPERATOR_DEPLOY" -n kagenti-system -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="NAMESPACES2WATCH")].value}' 2>/dev/null || true)
  if [ -n "$CURRENT" ]; then
    # NAMESPACES2WATCH exists — check if namespace already listed
    if echo ",$CURRENT," | grep -q ",${NAMESPACE},"; then
      echo "  ${NAMESPACE} already in NAMESPACES2WATCH"
    else
      NEW="${CURRENT},${NAMESPACE}"
      IDX=$(oc get deploy "$OPERATOR_DEPLOY" -n kagenti-system -o json | jq '.spec.template.spec.containers[0].env // [] | to_entries[] | select(.value.name=="NAMESPACES2WATCH") | .key')
      oc patch deploy "$OPERATOR_DEPLOY" -n kagenti-system --type=json \
        -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/env/${IDX}/value\",\"value\":\"${NEW}\"}]"
      echo "  Updated NAMESPACES2WATCH: ${NEW}"
    fi
  else
    # NAMESPACES2WATCH doesn't exist — add it
    HAS_ENV=$(oc get deploy "$OPERATOR_DEPLOY" -n kagenti-system -o jsonpath='{.spec.template.spec.containers[0].env}' 2>/dev/null)
    if [ -n "$HAS_ENV" ] && [ "$HAS_ENV" != "null" ]; then
      oc patch deploy "$OPERATOR_DEPLOY" -n kagenti-system --type=json \
        -p="[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/env/-\",\"value\":{\"name\":\"NAMESPACES2WATCH\",\"value\":\"${NAMESPACE}\"}}]"
    else
      oc patch deploy "$OPERATOR_DEPLOY" -n kagenti-system --type=json \
        -p="[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/env\",\"value\":[{\"name\":\"NAMESPACES2WATCH\",\"value\":\"${NAMESPACE}\"}]}]"
    fi
    echo "  Added NAMESPACES2WATCH: ${NAMESPACE}"
  fi
else
  echo "  WARNING: No kagenti operator deployment found in kagenti-system"
fi

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

echo ""
echo "kagenti enabled in namespace ${NAMESPACE}"
echo "  Restart deployments to pick up sidecars: oc rollout restart deployment -n ${NAMESPACE}"

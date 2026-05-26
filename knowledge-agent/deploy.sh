#!/bin/bash

# Deploy the RedBank Knowledge Agent to OpenShift.

SCRIPT_FOLDER="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

function _out() {
  echo "$(date +'%F %H:%M:%S') $@"
}

function setup() {
  local ns="${NAMESPACE:-redbank-demo}"
  _out "Deploying redbank-knowledge-agent to namespace: ${ns}"

  if [[ -z "${LLM_BASE_URL:-}" || -z "${LLM_MODEL:-}" ]]; then
    echo "ERROR: LLM_BASE_URL and LLM_MODEL are required." >&2
    echo "Example: LLM_BASE_URL=http://vllm:8000/v1 LLM_MODEL=my-model bash deploy.sh" >&2
    exit 1
  fi

  oc new-project "${ns}" 2>/dev/null || oc project "${ns}"

  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    _out "Creating/updating llm-credentials secret"
    oc create secret generic llm-credentials \
      --from-literal=OPENAI_API_KEY="${OPENAI_API_KEY}" \
      --dry-run=client -o yaml | oc apply -f -
  fi

  cd "${SCRIPT_FOLDER}"

  if [[ "${DEPLOY_ONLY:-}" != "true" ]]; then
    _out "Building knowledge agent image"
    oc new-build --name build-redbank-knowledge-agent --binary --strategy docker \
      --to="image-registry.openshift-image-registry.svc:5000/${ns}/redbank-knowledge-agent:latest" 2>/dev/null || true
    oc start-build build-redbank-knowledge-agent --from-dir=. --follow
  fi

  if [[ "${BUILD_ONLY:-}" != "true" ]]; then
    oc create sa redbank-knowledge-agent -n "${ns}" 2>/dev/null || true
    _out Deploying knowledge agent
    NAMESPACE="${ns}" \
      LLM_BASE_URL="${LLM_BASE_URL:-}" \
      LLM_MODEL="${LLM_MODEL:-}" \
      envsubst '${NAMESPACE} ${LLM_BASE_URL} ${LLM_MODEL}' \
      < ./knowledge-agent.yaml | oc apply -f -

    _out Applying AgentRuntime CR
    oc apply -f ./agentruntime.yaml
  fi

  _out Done
}

setup

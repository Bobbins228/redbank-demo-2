#!/bin/bash

# Deploy the RedBank MCP server to OpenShift.

SCRIPT_FOLDER="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

function _out() {
  echo "$(date +'%F %H:%M:%S') $@"
}

function setup() {
  _out Deploying redbank-mcp-server

  # oc new-project redbank-demo 2>/dev/null || oc project redbank-demo
  # oc project redbank-demo
  oc project mark-test

  cd "${SCRIPT_FOLDER}"

  _out Building MCP server image
  oc new-build --name build-redbank-mcp-server --binary --strategy docker \
    --to=image-registry.openshift-image-registry.svc:5000/mark-test/redbank-mcp-server:latest
  oc start-build build-redbank-mcp-server --from-dir=. --follow

  _out Deploying MCP server
  oc apply -f ./mcp-server.yaml

  _out Done deploying redbank-mcp-server
}

setup

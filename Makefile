SHELL := bash

NAMESPACE ?= redbank-demo
export NAMESPACE

LOAD_ENV = [ -f .env ] || { echo "ERROR: .env not found — run 'make init' first"; exit 1; } && set -a && source .env && set +a

PG_LOCAL_PORT ?= 15432
VENV_DIR := langchain-pgvector/.venv

# Colors
CYAN    := \033[36m
GREEN   := \033[32m
YELLOW  := \033[33m
BOLD    := \033[1m
RESET   := \033[0m

.DEFAULT_GOAL := help

help: ## Show this help
	@printf "\n"
	@printf "  \033[1mRedBank Kagenti Demo\033[0m\n"
	@printf "\n"
	@printf "  \033[1;32m🚀 Init\033[0m\n"
	@grep -E '^[a-zA-Z_-]+:.*##@init' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*##@init "}; {printf "    \033[36m%-28s\033[0m %s\n", $$1, $$2}'
	@printf "\n"
	@printf "  \033[1;32m🔧 Setup\033[0m\n"
	@grep -E '^[a-zA-Z_-]+:.*##@setup' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*##@setup "}; {printf "    \033[36m%-28s\033[0m %s\n", $$1, $$2}'
	@printf "\n"
	@printf "  \033[1;32m📦 Build\033[0m\n"
	@grep -E '^[a-zA-Z_-]+:.*##@build' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*##@build "}; {printf "    \033[36m%-28s\033[0m %s\n", $$1, $$2}'
	@printf "\n"
	@printf "  \033[1;32m🚢 Deploy\033[0m\n"
	@grep -E '^[a-zA-Z_-]+:.*##@deploy' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*##@deploy "}; {printf "    \033[36m%-28s\033[0m %s\n", $$1, $$2}'
	@printf "\n"
	@printf "  \033[1;32m💾 Data\033[0m\n"
	@grep -E '^[a-zA-Z_-]+:.*##@data' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*##@data "}; {printf "    \033[36m%-28s\033[0m %s\n", $$1, $$2}'
	@printf "\n"
	@printf "  \033[1;32m🧪 Test\033[0m\n"
	@grep -E '^[a-zA-Z_-]+:.*##@test' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*##@test "}; {printf "    \033[36m%-28s\033[0m %s\n", $$1, $$2}'
	@printf "\n"
	@printf "  \033[1;32m🧹 Clean\033[0m\n"
	@grep -E '^[a-zA-Z_-]+:.*##@clean' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*##@clean "}; {printf "    \033[36m%-28s\033[0m %s\n", $$1, $$2}'
	@printf "\n"

# ============================================================================
# Init
# ============================================================================

init: ##@init Create .env from .env.example
	@if [ ! -f .env ]; then cp .env.example .env && echo "Created .env from .env.example — edit it with your configuration"; else echo ".env already exists — skipping"; fi

# ============================================================================
# Setup — run in order: install-keycloak → setup-keycloak → enable-kagenti
#          → (optional) setup-keycloak-spiffe → enable-spiffe
#          → configure-token-exchange → (optional) setup-mlflow
# ============================================================================

install-keycloak: ##@setup 1. Install RHBK operator and Keycloak (26.4)
	@bash scripts/install-keycloak.sh rhbk

install-keycloak-community: ##@setup 1. Install community Keycloak (26.6.0, full SPIFFE support)
	@bash scripts/install-keycloak.sh community

setup-keycloak: ##@setup 2. Configure Keycloak realm, clients, and users
	@$(LOAD_ENV) && bash scripts/setup-keycloak.sh

enable-kagenti: ##@setup 3. Label namespace, create configmaps for sidecar injection
	@$(LOAD_ENV) && bash scripts/enable-kagenti.sh

setup-keycloak-spiffe: ##@setup 4. Create SPIFFE Identity Provider in Keycloak (optional)
	@$(LOAD_ENV) && bash scripts/setup-keycloak-spiffe.sh

enable-spiffe: ##@setup 5. Enable SPIFFE identity for all workloads (optional)
	@$(LOAD_ENV) && bash scripts/enable-spiffe.sh

configure-token-exchange: ##@setup 6. Configure FGAP token exchange for all agents
	@bash scripts/configure-token-exchange-v2.sh

setup-mlflow: ##@setup 7. Configure MLflow tracing (optional)
	@$(LOAD_ENV) && bash scripts/setup-mlflow.sh

disable-mlflow: ##@setup Disable MLflow tracing
	@$(LOAD_ENV) && \
	  oc delete secret mlflow-credentials -n $${NAMESPACE} --ignore-not-found && \
	  echo "MLflow credentials removed. Restarting agents..." && \
	  oc rollout restart deployment/redbank-banking-agent deployment/redbank-knowledge-agent -n $${NAMESPACE} 2>/dev/null || true && \
	  echo "MLflow tracing disabled in namespace $${NAMESPACE}"

# ============================================================================
# Build — container images (OpenShift BuildConfigs)
# ============================================================================

build: build-mcp build-banking build-knowledge build-orchestrator build-playground ##@build Build all container images

build-mcp: ##@build Build MCP server image
	@$(LOAD_ENV) && cd mcp-server && BUILD_ONLY=true bash deploy.sh

build-banking: ##@build Build banking agent image
	@$(LOAD_ENV) && cd banking-agent && BUILD_ONLY=true bash deploy.sh

build-knowledge: ##@build Build knowledge agent image
	@$(LOAD_ENV) && cd knowledge-agent && BUILD_ONLY=true bash deploy.sh

build-orchestrator: ##@build Build orchestrator agent image
	@$(LOAD_ENV) && cd orchestrator-agent && BUILD_ONLY=true bash deploy.sh

build-playground: ##@build Build playground UI image
	@$(LOAD_ENV) && cd playground && BUILD_ONLY=true bash deploy.sh

# ============================================================================
# Deploy — apply workloads (images must be built first, or use 'make deploy')
# ============================================================================

deploy: setup-keycloak deploy-db enable-kagenti build deploy-mcp deploy-banking deploy-knowledge deploy-orchestrator deploy-playground ##@deploy Full deploy: setup + build + deploy all
	@echo "" && echo "RedBank Kagenti demo deployed to namespace $${NAMESPACE:-redbank-demo}"

deploy-from: ##@deploy Import images from IMAGE_NAMESPACE and deploy all (no build)
	@$(LOAD_ENV) && \
	  IMAGE_NS=$${IMAGE_NAMESPACE:?Usage: IMAGE_NAMESPACE=redbank-demo make deploy-from} && \
	  echo "Importing images from $${IMAGE_NS} to $${NAMESPACE}..." && \
	  oc new-project $${NAMESPACE} 2>/dev/null || oc project $${NAMESPACE} && \
	  for IMG in redbank-mcp-server redbank-banking-agent redbank-knowledge-agent redbank-orchestrator redbank-playground; do \
	    oc tag "$${IMAGE_NS}/$${IMG}:latest" "$${IMG}:latest" -n $${NAMESPACE}; \
	  done && \
	  echo "Images imported" && \
	  $(MAKE) setup-keycloak deploy-db enable-kagenti deploy-mcp deploy-banking deploy-knowledge deploy-orchestrator deploy-playground && \
	  echo "" && echo "RedBank deployed to $${NAMESPACE} (images from $${IMAGE_NS})"

deploy-db: ##@deploy Deploy PostgreSQL database
	@$(LOAD_ENV) && \
	  oc new-project $${NAMESPACE} 2>/dev/null || oc project $${NAMESPACE} && \
	  cd postgres-db && oc apply -k .

deploy-mcp: ##@deploy Deploy MCP server
	@$(LOAD_ENV) && cd mcp-server && DEPLOY_ONLY=true bash deploy.sh

deploy-banking: ##@deploy Deploy banking agent
	@$(LOAD_ENV) && cd banking-agent && DEPLOY_ONLY=true bash deploy.sh

deploy-knowledge: ##@deploy Deploy knowledge agent
	@$(LOAD_ENV) && cd knowledge-agent && DEPLOY_ONLY=true bash deploy.sh

deploy-orchestrator: ##@deploy Deploy orchestrator agent
	@$(LOAD_ENV) && cd orchestrator-agent && DEPLOY_ONLY=true bash deploy.sh

deploy-playground: ##@deploy Deploy playground UI
	@$(LOAD_ENV) && cd playground && DEPLOY_ONLY=true bash deploy.sh

# ============================================================================
# Data — RAG pipeline ingestion
# ============================================================================

$(VENV_DIR)/bin/python: langchain-pgvector/requirements.txt
	@echo "--- Creating virtualenv and installing dependencies ---"
	python3 -m venv $(VENV_DIR)
	$(VENV_DIR)/bin/pip install --quiet --upgrade pip
	$(VENV_DIR)/bin/pip install --quiet -r langchain-pgvector/requirements.txt
	@touch $(VENV_DIR)/bin/python

compile-pipeline: ##@data Compile the KFP RAG pipeline
	cd langchain-pgvector/pipeline && python3 pgvector_rag_pipeline.py

ingest-local: $(VENV_DIR)/bin/python ##@data Run RAG ingestion locally (port-forward + embed + store)
	@$(LOAD_ENV) && \
	  echo "--- Port-forwarding PostgreSQL from $${NAMESPACE} on localhost:$(PG_LOCAL_PORT) ---" && \
	  oc port-forward svc/postgresql -n $${NAMESPACE} $(PG_LOCAL_PORT):5432 &>/dev/null & \
	  PF_PID=$$!; \
	  $(LOAD_ENV) && \
	  sleep 2; \
	  if ! kill -0 $$PF_PID 2>/dev/null; then \
	    echo "ERROR: port-forward failed — is the PostgreSQL pod running in $${NAMESPACE}?"; exit 1; \
	  fi; \
	  echo "--- Granting schema CREATE to app role ---"; \
	  PGPASSWORD=app psql -h localhost -p $(PG_LOCAL_PORT) -U user -d db -c "GRANT CREATE ON SCHEMA public TO app;" 2>/dev/null \
	    || oc exec deploy/postgresql -n $${NAMESPACE} -- psql -U user -d db -c "GRANT CREATE ON SCHEMA public TO app;"; \
	  echo "--- Running RAG ingestion ---"; \
	  $(VENV_DIR)/bin/python langchain-pgvector/pipeline/ingest_local.py --pg-port $(PG_LOCAL_PORT) $(INGEST_ARGS); \
	  RC=$$?; \
	  kill $$PF_PID 2>/dev/null; \
	  exit $$RC

# ============================================================================
# Test
# ============================================================================

test-pgvector: ##@test Run PGVector schema and RLS tests
	cd langchain-pgvector && python3 -m pytest tests/ -v

test-token-exchange: ##@test Run token exchange test (Keycloak)
	@$(LOAD_ENV) && bash scripts/test-token-exchange.sh

test-knowledge-agent: ##@test Test knowledge agent (port-forward + query)
	@echo "Port-forwarding knowledge agent (background)..."
	@oc port-forward svc/redbank-knowledge-agent 8002:8002 &
	@sleep 2
	@bash scripts/test-knowledge-agent.sh; RC=$$?; kill %1 2>/dev/null; exit $$RC

test-e2e: ##@test Run end-to-end playground test
	@$(LOAD_ENV) && bash scripts/test-playground-e2e.sh

verify-config: ##@test Verify cluster and namespace configuration
	@$(LOAD_ENV) && bash scripts/verify-config.sh

test-all: test-token-exchange test-e2e ##@test Run all tests
	@echo "" && echo "All tests completed!"

# ============================================================================
# Clean
# ============================================================================

clean: ##@clean Remove all RedBank workloads (keeps namespace and images)
	@$(LOAD_ENV) 2>/dev/null; bash scripts/cleanup.sh

uninstall-keycloak: ##@clean Uninstall Keycloak (both RHBK and community)
	@bash scripts/uninstall-keycloak.sh

.PHONY: help init \
	install-keycloak install-keycloak-community uninstall-keycloak \
	setup-keycloak enable-kagenti configure-token-exchange setup-keycloak-spiffe enable-spiffe setup-mlflow disable-mlflow \
	build build-mcp build-banking build-knowledge build-orchestrator build-playground \
	deploy deploy-from deploy-db deploy-mcp deploy-banking deploy-knowledge deploy-orchestrator deploy-playground \
	compile-pipeline ingest-local \
	test-pgvector test-token-exchange test-knowledge-agent test-e2e verify-config test-all \
	clean

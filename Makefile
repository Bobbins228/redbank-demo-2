.PHONY: deploy-db deploy-mcp deploy-all

NAMESPACE ?= redbank-demo

deploy-db:
	oc new-project $(NAMESPACE) 2>/dev/null || oc project $(NAMESPACE)
	cd postgres-db && oc apply -k .

deploy-mcp:
	cd mcp-server && bash deploy.sh

deploy-all: deploy-db deploy-mcp
	@echo "RedBank Kagenti demo deployed to namespace $(NAMESPACE)"

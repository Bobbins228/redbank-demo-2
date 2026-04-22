# RedBank Orchestrator Agent

Multi-agent orchestrator for the RedBank demo. Classifies user intent and routes queries to specialist agents via the A2A protocol.

## Architecture

```
User / Chat UI
    │
    ▼
Orchestrator (this agent)
    │
    ├── A2A ──▶ Knowledge Agent (B)
    │           • Document / policy queries (PGVector RAG)
    │           • Account data retrieval (PostgreSQL MCP, read-only, RLS-scoped)
    │
    └── A2A ──▶ Banking Operations Agent (C)
                • Account updates, transaction creation (PostgreSQL MCP, admin-only)
```

The LLM classifies each user message and calls the appropriate tool. Each tool is an A2A client call (`message/send` JSON-RPC) to a downstream agent. The orchestrator itself is also A2A-callable — it exposes `/.well-known/agent-card.json` and `POST /` via the `a2a-sdk`.

## Auth Token Propagation

The orchestrator extracts the `Authorization` header from incoming requests and forwards it through the A2A call chain. This enables:

- **Agent-level gating** — Banking Agent rejects non-admin tokens before executing write operations
- **Data scoping** — Knowledge Agent returns RLS-scoped results based on the user's JWT identity

## Configuration

| Variable | Required | Description |
|----------|----------|-------------|
| `API_KEY` | Yes | LLM API key |
| `BASE_URL` | Yes | LLM API endpoint (e.g. `https://litellm.example.com/v1`) |
| `MODEL_ID` | Yes | LLM model identifier (e.g. `llama-scout-17b`) |
| `CONTAINER_IMAGE` | Yes | Container image reference for build/deploy (auto-set by `make build-openshift`) |
| `NAMESPACE` | No | Target K8s/OpenShift namespace (defaults to current context) |
| `PORT` | No | Server port (default: `8000` locally, `8080` in container) |

In-cluster, peer agents are discovered automatically via kagenti `AgentCard` CRDs. Re-discovery runs every 15 seconds so new agents are picked up without restarting.

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/chat/completions` | OpenAI-compatible chat completions (JSON + SSE) |
| `POST` | `/` | A2A JSON-RPC `message/send` (for inter-agent calls) |
| `GET` | `/.well-known/agent-card.json` | A2A agent card for discovery |
| `GET` | `/health` | Health check |
| `GET` | `/` | Playground chat UI |

## Deployment (OpenShift)

### Prerequisites

- OpenShift cluster with `oc` CLI and Helm
- Knowledge Agent (B) and Banking Agent (C) deployed and accessible in-cluster
- LLM endpoint accessible from the cluster

### 1. Configure

```bash
make init   # creates .env from .env.example
```

Edit `.env` with your environment values:

```bash
API_KEY=<your-llm-api-key>
BASE_URL=http://localhost:8321/v1
MODEL_ID=ollama/llama3.1:8b
NAMESPACE=redbank-demo
```

### 2. Build

Build the container image in-cluster via OpenShift BuildConfig:

```bash
make build-openshift
```

This builds in the configured `NAMESPACE` and automatically sets `CONTAINER_IMAGE` in `.env`.

Alternatively, build and push from a local machine:

```bash
make build && make push
```

### 3. Deploy

```bash
make deploy
```

This runs `helm upgrade --install` with the shared chart and applies the `protocol.kagenti.io/a2a` label for peer discovery.

### Verify

```bash
# Health check
curl -s https://$(oc get route redbank-orchestrator -o jsonpath='{.spec.host}')/health

# Agent card
curl -s https://$(oc get route redbank-orchestrator -o jsonpath='{.spec.host}')/.well-known/agent-card.json

# Chat
curl -s https://$(oc get route redbank-orchestrator -o jsonpath='{.spec.host}')/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"What is my account balance?"}]}'
```

### Other Targets

```bash
make dry-run     # Preview Helm manifests without deploying
make undeploy    # Remove from cluster
```

## Local Development

### Setup

```bash
make init        # Create .env from template
make env         # Create venv + install dependencies
make run-app     # Start on port 8000 with hot-reload
```

### Testing with Mock Agents

The `examples/mock_agents.py` script starts two mock A2A agents locally for end-to-end testing:

```bash
# Terminal 1 — start mock Knowledge Agent (8001) + Banking Agent (8002)
uv run python examples/mock_agents.py

# Terminal 2 — start the orchestrator
make run-app

# Terminal 3 — test
curl -s http://localhost:8000/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"What is my account balance?"}]}'

curl -s http://localhost:8000/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Transfer 500 to account 12345"}]}'
```

### Run Tests

```bash
make test        # 15 unit tests
```

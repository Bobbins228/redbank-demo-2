# RedBank Demo — Kagenti Edition

PostgreSQL database, MCP server, and A2A agents for the RedBank multi-agent banking demo, adapted for Kagenti deployment with Row-Level Security (RLS).

Part of RHAISTRAT-1459 / RHAIENG-4555 (Epic) / RHAIENG-4556 (MCP Server) / RHAIENG-4558 (Knowledge Agent) / RHAIENG-4559 (Banking Agent) / RHAIENG-4641 (SPIRE Signature Verification).

## Directory Layout

```
redbank-demo-2/
├── .env.example                  Consolidated deployment config template
├── Makefile                      Single Makefile for all deployment targets
├── postgres-db/                  PostgreSQL schema, seed data, RLS policies
│   ├── init.sql                  Schema + RLS + seed data
│   ├── init-db.sh                Startup init script
│   ├── postgres.yaml             Secret + Deployment + Service
│   └── kustomization.yaml
├── langchain-pgvector/           LangChain + PGVector RAG pipeline
│   ├── tests/                    Schema + RLS tests (testcontainers)
│   ├── pipeline/                 KFP ingestion pipeline
│   ├── notebook/                 Query notebook (admin vs user RLS demo)
│   └── requirements.txt
├── mcp-server/                   FastMCP server with auth-aware tools
│   ├── redbank-mcp/
│   │   ├── mcp_server.py         Tool definitions + JWT auth
│   │   ├── database_manager.py   Connection pool + RLS context
│   │   └── logger.py
│   ├── requirements.txt
│   ├── Dockerfile
│   ├── mcp-server.yaml           Deployment + Service
│   ├── agentruntime.yaml         AgentRuntime CR (type: tool)
│   └── deploy.sh                 OpenShift build + deploy
├── banking-agent/                A2A Banking Operations Agent (Agent C — admin CRUD)
│   ├── src/banking_agent/
│   │   ├── __main__.py           A2A server startup, signed card loading, MLflow init
│   │   ├── agent.py              LangGraph ReAct agent + MCP client setup
│   │   └── agent_executor.py     A2A <-> LangGraph bridge with token propagation
│   ├── pyproject.toml
│   ├── Dockerfile
│   ├── banking-agent.yaml        ConfigMap (unsigned card) + Deployment + Service
│   ├── agentcard.yaml            AgentCard CR (strict identity binding)
│   ├── agentruntime.yaml         AgentRuntime CR (type: agent)
│   └── deploy.sh                 OpenShift build + deploy
├── knowledge-agent/              A2A Knowledge Agent (Agent B — read-only RAG + data)
│   ├── src/knowledge_agent/
│   │   ├── __main__.py           A2A server startup, signed card loading, MLflow init
│   │   ├── agent.py              LangGraph ReAct agent + allow-list filter
│   │   └── agent_executor.py     A2A <-> LangGraph bridge with token propagation
│   ├── tests/                    Unit tests (mocked, no infra needed)
│   ├── pyproject.toml
│   ├── Dockerfile
│   ├── knowledge-agent.yaml      ConfigMap (unsigned card) + Deployment + Service
│   ├── agentcard.yaml            AgentCard CR (strict identity binding)
│   ├── agentruntime.yaml         AgentRuntime CR (type: agent)
│   └── deploy.sh                 OpenShift build + deploy
├── orchestrator-agent/           A2A Orchestrator Agent (Agent A — intent routing)
│   ├── src/redbank_orchestrator/
│   │   ├── server.py             Starlette app, A2A + /chat/completions + re-discovery
│   │   ├── agent.py              LangGraph agent builder from discovered peers
│   │   ├── discovery.py          Peer discovery via K8s AgentCard CRDs
│   │   ├── k8s_discovery.py      Kubernetes API client for AgentCard lookup
│   │   ├── a2a_client.py         A2A message sender with token forwarding
│   │   ├── tools.py              Dynamic tool creation from peer agent cards
│   │   └── tracing.py            MLflow autolog configuration
│   ├── charts/agent/             Helm chart for deployment
│   ├── examples/mock_agents.py   Mock agents for local testing
│   ├── tests/                    Unit tests
│   ├── pyproject.toml + uv.lock
│   ├── Dockerfile
│   └── deploy.sh                 OpenShift build + Helm deploy
├── playground/                   Standalone chat UI for the orchestrator
│   ├── playground/templates/     HTML chat interface
│   ├── server.py                 Starlette proxy (auth, chat, health)
│   ├── charts/agent/             Helm chart for deployment
│   ├── pyproject.toml
│   ├── Dockerfile
│   └── deploy.sh                 OpenShift build + Helm deploy
├── spire/                        SPIRE identity resources
│   └── clusterspiffeid.yaml      ClusterSPIFFEID template for agent pods
├── scripts/
│   ├── setup-keycloak.sh         Provision Keycloak realm, client, users, audience mapper
│   ├── test-knowledge-agent.sh   Manual A2A agent test with Keycloak JWTs
│   ├── test-search-knowledge.sh  Manual MCP tool test with Keycloak JWTs
│   ├── verify-signatures.sh     Verify SPIRE agent card signing and identity binding
│   └── cleanup.sh                Tear down deployed workloads + Keycloak realm
├── tests/
│   └── test_mcp_rls.py           MCP-level integration tests (pytest)
└── README.md
```

## How It Works

### Overview

The MCP server is a [FastMCP](https://github.com/jlowin/fastmcp) application that exposes banking data tools over the MCP Streamable HTTP transport. It sits between Kagenti agents and a PostgreSQL database, enforcing access control at two levels:

1. **Application-level gating** — Write tools (`update_account`, `create_transaction`) are decorated with `@admin_only` and reject non-admin callers before any SQL runs.
2. **Database-level Row-Level Security (RLS)** — PostgreSQL policies filter query results based on session variables, so even if application logic has a bug, users can only see their own data.

### Request Flow

```
Agent (A2A/MCP client)
  │
  │  Authorization: Bearer <JWT>
  ▼
┌──────────────────────────────────────────────┐
│  AuthBridge Sidecar (Envoy + go-processor)   │
│                                              │
│  1. Validate JWT (signature, exp, issuer)    │
│  2. Token exchange (RFC 8693) for tool aud   │
│  3. Forward with exchanged Bearer token      │
└──────────────────┬───────────────────────────┘
                   │
                   │  Authorization: Bearer <exchanged-JWT>
                   ▼
┌──────────────────────────────────────────────┐
│  FastMCP HTTP Server (:8000/mcp)             │
│                                              │
│  1. Verify JWT (JWKS) or decode (trusted)    │
│  2. Extract email + role from claims         │
│  3. Check @admin_only (write tools)          │
│  4. Open pooled DB connection                │
│  5. SET app.current_role, app.current_email  │
│  6. Execute query (RLS filters rows)         │
│  7. Return structured result                 │
└──────────────────┬───────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────┐
│  PostgreSQL 16                               │
│                                              │
│  RLS policies on: customers, statements,     │
│  transactions                                │
│                                              │
│  Admin: sees all rows, can INSERT/UPDATE     │
│  User:  sees only own customer_id (SELECT)   │
└──────────────────────────────────────────────┘
```

### AuthBridge Integration

In a Kagenti deployment, the AuthBridge sidecar (Envoy + go-processor) handles JWT validation and RFC 8693 token exchange automatically. The flow is:

1. Caller authenticates with Keycloak and receives a JWT
2. Caller sends the request with `Authorization: Bearer <JWT>` to the MCP server
3. The AuthBridge Envoy sidecar intercepts the request, validates the JWT (signature, expiration, issuer) via JWKS, and exchanges the token for an audience-scoped token targeting this tool
4. The exchanged token reaches the MCP server container on the `Authorization` header

The MCP server operates in two modes:

**AuthBridge trusted mode** (`JWT_VERIFY=false`, default) — The sidecar has already validated the token. The server decodes the JWT without signature verification to extract identity claims. This is the standard Kagenti deployment model.

**Standalone mode** (`JWT_VERIFY=true`) — No sidecar present. The server fetches signing keys from `JWKS_URL` (Keycloak JWKS endpoint) and verifies the JWT itself. Use for dev clusters without Kagenti or as defense-in-depth.

Identity is extracted from Keycloak JWT claims:
- **email**: `claims.email` → `claims.preferred_username` → `claims.sub` (fallback chain)
- **role**: `"admin"` if the `ADMIN_ROLE_CLAIM` value (default `"admin"`) appears in `realm_access.roles`, `resource_access.account.roles`, or `scope`

When no Bearer token is present, the server falls back to `DEFAULT_ROLE` and `DEFAULT_EMAIL` environment variables. In production with AuthBridge, unauthenticated requests are rejected by the sidecar before they reach the MCP server.

### Row-Level Security

RLS is enabled and forced (`FORCE ROW LEVEL SECURITY`) on `customers`, `statements`, `transactions`, and `embeddings`. The table owner (`$POSTGRESQL_USER`) is the same role the MCP server and RAG pipeline connect as, so `FORCE` ensures policies apply even to the owner. All tables use the same session-variable RLS pattern via `app.current_role`.

Before each query, the `@authenticated` decorator opens a connection from the pool and sets two session variables inside a transaction:

```sql
SELECT set_config('app.current_role', 'admin', true);
SELECT set_config('app.current_user_email', 'jane@redbank.demo', true);
```

The `true` parameter scopes these to the current transaction, so they're automatically cleared when the connection returns to the pool.

RLS policies then filter based on these variables:
- **Admin policies** (`FOR ALL`): allow full read/write when `app.current_role = 'admin'`
- **User policies** (`FOR SELECT`): restrict to rows matching the `customer_id` mapped in the `user_accounts` table for the current email

### MCP Tools

**Read tools** (all roles):
| Tool | Description |
|------|-------------|
| `get_customer` | Look up a customer by email or phone |
| `get_customer_transactions` | List transactions with optional date range filter |
| `get_account_summary` | Customer info + statement count + latest balance |
| `search_knowledge` | Semantic similarity search across role-scoped document collections |

**Write tools** (admin only):
| Tool | Description |
|------|-------------|
| `update_account` | Update customer phone, address, or account type |
| `create_transaction` | Insert a new transaction on the latest statement |

The `search_knowledge` tool uses `PGVectorStore` (from `langchain-postgres`) to query the `embeddings` table. It selects the admin or user store based on the caller's JWT role, so RLS scoping is enforced automatically. The embedding model (`nomic-ai/nomic-embed-text-v1.5`) is baked into the MCP server container image.

### Security Model

| Role | Read access | Write access |
|------|-------------|--------------|
| `user` | Own customer record, statements, transactions only (RLS) | None (rejected by `@admin_only`) |
| `admin` | All records | `update_account`, `create_transaction` |

### Demo Users

| Keycloak identity | Role | Customer record |
|-------------------|------|-----------------|
| `john@redbank.demo` | user | John Doe (customer_id 5) |
| `jane@redbank.demo` | admin | All customers (no customer_id binding) |

Seed data includes 5 customers (Alice, Bob, Carol, David, John), 13 statements, and 27 transactions.

### Kagenti Integration

Each workload is enrolled into the Kagenti platform via an `AgentRuntime` custom resource (`agent.kagenti.dev/v1alpha1`). The `AgentRuntime` references the Deployment via `targetRef` — the operator then manages `kagenti.io/type` labels, sets a `kagenti.io/config-hash` annotation for rollout coordination, and enables AuthBridge sidecar injection at Pod admission.

| Workload | AgentRuntime | `spec.type` | AgentCard | Protocol label |
|----------|-------------|-------------|-----------|----------------|
| `redbank-mcp-server` | `redbank-mcp-server-runtime` | `tool` | — | `protocol.kagenti.io/mcp: "true"` (Service) |
| `redbank-banking-agent` | `redbank-banking-agent-runtime` | `agent` | `redbank-banking-agent-card` | `protocol.kagenti.io/a2a: ""` (Deployment + Service) |
| `redbank-knowledge-agent` | `redbank-knowledge-agent-runtime` | `agent` | `redbank-knowledge-agent-card` | `protocol.kagenti.io/a2a: ""` (Deployment + Service) |
| `redbank-orchestrator` | via Helm chart `agentruntime.yaml` | `agent` | — | `protocol.kagenti.io/a2a: ""` (Deployment) |

The `kagenti.io/type` label on Deployments is managed by the operator — do not set it manually. Protocol labels on Services (`protocol.kagenti.io/a2a`, `protocol.kagenti.io/mcp`) remain in the Service manifests since they drive AgentCard sync and tool discovery independently.

### SPIRE AgentCard Signature Verification (RHAIENG-4641)

Both A2A agents use SPIRE-based cryptographic identity to sign their AgentCards. This ensures that each agent's identity is cryptographically bound to its SPIFFE ID, preventing card spoofing.

**How it works:**

1. A `ClusterSPIFFEID` (`spire/clusterspiffeid.yaml`) registers a SPIFFE ID template for pods labeled `kagenti.io/type: agent`
2. The kagenti operator's **mutating webhook** injects SPIRE infrastructure (CSI volume, spiffe-helper sidecar, envoy-proxy, proxy-init) into agent pods automatically
3. A `sign-agentcard` init container fetches a SPIRE SVID and signs the unsigned agent card (from a ConfigMap) with a JWS ES256 signature
4. The signed card is mounted into the main container, which loads it at startup via `_load_agent_card()` (falling back to in-memory construction for local dev)
5. The operator's AgentCard controller fetches the served card, verifies the JWS signature against the SPIRE trust bundle, and confirms the SPIFFE ID matches the expected identity

**AgentCard CRs** (`agentcard.yaml`) are created with `identityBinding.strict: true`, which requires the operator to verify both the cryptographic signature and the SPIFFE identity binding before marking the agent as trusted.

**Verification status:**

| Field | Description |
|-------|-------------|
| `SignatureVerified` | JWS signature is valid (ES256, verified against SPIRE trust bundle) |
| `Bound` | SPIFFE ID from x5c certificate matches the expected trust domain |
| `signatureIdentityMatch` | Both signature and identity binding pass |
| `agent.kagenti.dev/signature-verified` | Label propagated to pod template when verified |

**SPIFFE IDs follow the pattern:**
```
spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>
```

For example: `spiffe://apps.rosa.redbank-demo2.ij5f.p3.openshiftapps.com/ns/redbank-dev/sa/redbank-banking-agent`

Verify enrollment:

```bash
oc get agentruntimes
# NAME                                TYPE    TARGET                    PHASE   AGE
# redbank-banking-agent-runtime       agent   redbank-banking-agent     Active  ...
# redbank-knowledge-agent-runtime     agent   redbank-knowledge-agent   Active  ...
# redbank-mcp-server-runtime          tool    redbank-mcp-server        Active  ...
# redbank-orchestrator-runtime        agent   redbank-orchestrator      Active  ...

oc get agentcards
# NAME                                  PROTOCOL   KIND         TARGET                    AGENT                        VERIFIED   BOUND   SYNCED
# redbank-banking-agent-card            a2a        Deployment   redbank-banking-agent     RedBank Banking...           true       true    True
# redbank-knowledge-agent-card          a2a        Deployment   redbank-knowledge-agent   RedBank Knowledge...         true       true    True
# redbank-orchestrator-deployment-card  a2a        Deployment   redbank-orchestrator      RedBank Orchestrator...                         True
```

### Banking Operations Agent (Agent C)

The Banking Operations Agent is an A2A service built with LangGraph that provides admin-level CRUD access to the RedBank customer database. It connects to the MCP server via `MultiServerMCPClient` from `langchain-mcp-adapters`.

**Architecture:**
- **Protocol**: A2A (Agent-to-Agent) — exposes `/.well-known/agent-card.json` for Kagenti discovery
- **Agent framework**: LangGraph `create_react_agent` with a system prompt for banking operations
- **MCP client**: `MultiServerMCPClient` connected to the PostgreSQL MCP server over HTTP
- **LLM**: Configurable — vLLM (default) or OpenAI via `ChatOpenAI` with `base_url` override
- **Observability**: MLflow LangChain autolog (`mlflow.langchain.autolog()`)
- **Auth**: Trusts AuthBridge sidecar for Tier 1 admin gating. Propagates the incoming Bearer JWT to the MCP server so RLS policies apply.

**Error handling:**
- MCP tool errors (auth denials, validation failures, DB errors) are intercepted and returned to the LLM as text rather than crashing the agent. The system prompt instructs the LLM to relay permission errors and empty results to the user without hallucinating data.
- LLM rate limit errors (`429 Too Many Requests`) are caught separately and return a user-friendly "service temporarily overloaded" message.
- All other agent execution errors are caught and returned as a generic error message.

**Kagenti enrollment:**
- **AgentRuntime**: `redbank-banking-agent-runtime` (type: `agent`) — operator manages `kagenti.io/type` label and AuthBridge injection
- **AgentCard**: `redbank-banking-agent-card` — strict identity binding, SPIRE signature verification
- **Service**: `protocol.kagenti.io/a2a: ""` — enables AgentCard sync and A2A discovery

**Token flow:**
1. Caller sends A2A request with `Authorization: Bearer <JWT>`
2. AuthBridge sidecar validates the token and rejects non-admin users (Tier 1)
3. Agent extracts the Bearer token from the incoming request
4. Agent passes the token as a header to `MultiServerMCPClient`
5. MCP server applies RLS based on the JWT claims (Tier 2)

### Knowledge Agent (Agent B)

The Knowledge Agent is a read-only A2A service built with LangGraph that provides semantic document search (RAG) and customer data retrieval. It routes queries between the `search_knowledge` tool for policy/FAQ questions and the customer data tools for account lookups.

**Architecture:**
- **Protocol**: A2A — exposes `/.well-known/agent-card.json` on port 8002
- **Agent framework**: LangGraph `create_react_agent` with routing guidance in the system prompt
- **MCP client**: `MultiServerMCPClient` connected to the PostgreSQL MCP server over HTTP
- **Tool allow-list**: Only `get_customer`, `get_customer_transactions`, `get_account_summary`, and `search_knowledge` — write tools are filtered out so they cannot be invoked even if the LLM attempts to call them
- **LLM**: Configurable via `LLM_BASE_URL` and `LLM_MODEL`
- **Observability**: MLflow LangChain autolog

**Query routing** (guided by system prompt):
- "how do I...", "what is the policy on..." → `search_knowledge`
- "look up customer...", "what is my balance..." → customer data tools
- May combine both in a single turn

**RLS scoping:**
- Knowledge search: admin sees docs from all collections; user sees only `user` collection
- Customer data: admin sees all records; user sees only their own (same as Banking Agent)

**Kagenti enrollment:**
- **AgentRuntime**: `redbank-knowledge-agent-runtime` (type: `agent`)
- **AgentCard**: `redbank-knowledge-agent-card` — strict identity binding, SPIRE signature verification
- **Deployment + Service**: `protocol.kagenti.io/a2a: ""` label for AgentCard discovery

### Orchestrator Agent (Agent A)

The Orchestrator Agent is the entry point for user interactions. It classifies user intent and routes queries to specialist agents (Knowledge or Banking) via A2A protocol. It discovers peers dynamically via Kubernetes AgentCard CRDs and rebuilds its routing graph every 15 seconds when peers change.

**Architecture:**
- **Protocol**: A2A + OpenAI-compatible `/chat/completions` HTTP endpoint (with SSE streaming)
- **Agent framework**: LangGraph `create_agent` with dynamic tools built from discovered peer agent cards
- **Discovery**: Queries `AgentCard` CRDs (`agent.kagenti.dev/v1alpha1`) with `protocol.kagenti.io/a2a` labels — no manual configuration needed
- **LLM**: Configurable via `LLM_BASE_URL`, `LLM_MODEL`, `OPENAI_API_KEY`
- **Observability**: MLflow LangChain autolog (optional via `MLFLOW_TRACKING_URI`)
- **State**: Module-level `MemorySaver` checkpointer preserves conversation context across graph rebuilds
- **Deployment**: Helm chart (`charts/agent/`) with `values.yaml` for configuration

**Dynamic routing:**
- Each discovered peer becomes a LangChain `StructuredTool` with name and description derived from the peer's agent card
- The system prompt is rebuilt dynamically from discovered agent card metadata (names, descriptions, skills, examples)
- If no peers are discovered, the orchestrator informs the user that the system is starting up

**Token propagation:**
1. User sends request with `Authorization: Bearer <JWT>` to `/chat/completions`
2. Orchestrator extracts the token and passes it through the LangGraph `RunnableConfig` as `auth_token`
3. Each peer tool forwards the token in the A2A `Authorization` header
4. Downstream agents pass it to the MCP server for RLS enforcement

### Playground UI

The Playground is a standalone Starlette web app that provides a chat interface for the orchestrator. It handles Keycloak OIDC authentication directly and proxies all `/chat/completions` requests to the orchestrator backend.

**Features:**
- HTML chat interface served at `/`
- Keycloak OIDC auth (`/auth/config`, `/auth/token`) — server-side proxy avoids CORS issues
- Proxies `/chat/completions` and `/health` to the orchestrator (supports SSE streaming)
- Configurable via `ORCHESTRATOR_URL`, `KEYCLOAK_*` env vars

### Agent Integration

The Banking Agent (Agent C) and Knowledge Agent (Agent B) are designed to be called by the Orchestrator via A2A. The orchestrator classifies user intent and routes write operations (update account, create transaction) to the Banking Agent while sending read-only queries to the Knowledge Agent.

**Integration points:**
- **Discovery**: The orchestrator discovers peers via `protocol.kagenti.io/a2a` service labels
- **A2A protocol**: Agents accept `message/send` JSON-RPC requests at their service URL
- **Token propagation**: The orchestrator forwards the user's Bearer JWT in the `Authorization` header. Agents pass it through to the MCP server, preserving the full identity chain.
- **Access gating**: With AuthBridge deployed, non-admin users are rejected at the network level (Tier 1) before reaching the Banking Agent. Without AuthBridge, the MCP server's `@admin_only` decorator enforces this at the tool level (Tier 2).

## RAG Pipeline (LangChain + PGVector)

### Overview

A document ingestion pipeline using LangChain + PGVector for retrieval-augmented generation (RAG) with role-scoped access. Admin documents and user documents are ingested into separate collections in the same `embeddings` table, and PostgreSQL RLS ensures each role sees only its authorized documents.

This reuses the **existing PostgreSQL instance** deployed via `postgres-db/`. The pgvector extension, `embeddings` table, and role-based RLS policies are all defined in `postgres-db/init.sql`.

### Embedding Model

Uses `nomic-ai/nomic-embed-text-v1.5` via **sentence-transformers** (`langchain-huggingface`). Produces 768-dimensional vectors and runs locally — no external embedding API endpoint needed.

### Document Source

6 RedBank PDF documents hosted on GitHub, fetched by the pipeline at runtime:

- **Admin** (`admin/`): `redbank_compliance_procedures.pdf`, `redbank_transaction_operations.pdf`, `redbank_user_management.pdf`
- **User** (`user/`): `redbank_account_selfservice.pdf`, `redbank_password_and_security.pdf`, `redbank_payments_and_transfers.pdf`

### Embeddings Table Schema

Each row represents a single chunk of a source PDF document. PDFs are split into chunks by `RecursiveCharacterTextSplitter`, and each chunk is embedded and stored as one row.

| Column | Type | Description |
|--------|------|-------------|
| `langchain_id` | `UUID` (PK) | Unique identifier for each chunk |
| `collection` | `VARCHAR(64)` | `admin` or `user` — determines RLS visibility |
| `content` | `TEXT` | The text content of the chunk |
| `embedding` | `vector(768)` | 768-dim embedding from nomic-embed-text-v1.5 |
| `langchain_metadata` | `JSONB` | Source metadata (page number, source PDF, creator) |

### RLS for Embeddings

Access control on the `embeddings` table uses the same session-variable RLS as the MCP tables — the caller's Keycloak JWT determines `app.current_role`:

| `app.current_role` | Identity | Read | Write | Collections visible |
|---------------------|----------|------|-------|---------------------|
| `admin` | Jane (Keycloak admin role) | All rows | INSERT/UPDATE/DELETE | `admin`, `user` |
| `user` | John (no admin role) | `user` collection only | None | `user` |

The pipeline sets `app.current_role=admin` via connection options. The notebook extracts the role from the Keycloak JWT and sets it the same way.

### Pipeline

`langchain-pgvector/pipeline/pgvector_rag_pipeline.py` is a KFP pipeline that:

1. Downloads PDFs from GitHub via `base_url` + `filenames`
2. Loads and chunks documents with `RecursiveCharacterTextSplitter`
3. Embeds with `HuggingFaceEmbeddings` (nomic-embed-text)
4. Stores in PGVector via `PGVectorStore` with collection-scoped access

Admin and user document sets are ingested in parallel as separate pipeline tasks.

Compile the pipeline: `make compile-pipeline`

### Query Notebook

`langchain-pgvector/notebook/pgvector_query_notebook.ipynb` demonstrates:

1. Keycloak authentication — get JWTs for Jane (admin) and John (user)
2. Role extraction from JWT claims (same logic as MCP server)
3. Jane's similarity search — results from both `admin` and `user` collections
4. John's similarity search — results from `user` collection only (RLS enforced)
5. Direct SQL verification that `app.current_role='user'` cannot see admin rows
6. Document count per collection

### PostgreSQL Infrastructure

`postgres-db/init.sql` includes the pgvector extension (`CREATE EXTENSION IF NOT EXISTS vector`), `embeddings` table, and role-based RLS policies alongside the existing MCP schema. `postgres-db/postgres.yaml` uses the `pgvector/pgvector:pg16` image (community PostgreSQL with pgvector pre-installed) and includes:

- A **PersistentVolumeClaim** (`postgres-pvc`, 10Gi) mounted at `/var/lib/postgresql/data` for data persistence
- **`PGDATA`** set to a subdirectory (`/var/lib/postgresql/data/pgdata`) to avoid the `lost+found` conflict on PVC mount points

### Tests

Schema and RLS tests use **testcontainers** with the `pgvector/pgvector:pg16` container image (via Podman):

```bash
make test-pgvector   # requires Podman
```

## Deployment

All deployment is driven through a single top-level `Makefile` and `.env` file. There are no individual Makefiles in subdirectories — each component has a `deploy.sh` script called by the Makefile.

### Prerequisites

- OpenShift cluster with `oc` CLI authenticated
- Keycloak deployed (the setup script provisions a realm and demo users)
- `helm` CLI installed (for orchestrator and playground)
- SPIRE deployed with CSI driver (for agent card signing)
- An OpenAI-compatible LLM endpoint (e.g. vLLM)

### Quick Start

```bash
# 1. Create .env from template
make init

# 2. Edit .env with your configuration (see below)
vi .env

# 3. Deploy everything (Keycloak setup + SPIRE + DB + MCP + agents + playground)
make deploy

# 4. Grant schema CREATE to 'app' role (required for PGVector metadata tables)
oc exec deployment/postgresql -- psql -U user -d db -c "GRANT CREATE ON SCHEMA public TO app;"

# 5. Ingest documents into PGVector (compile + run KFP pipeline)
make compile-pipeline
# Upload and run pgvector_rag_pipeline.yaml in OpenShift AI

# 7. Verify
oc get pods
oc get agentruntimes
oc get agentcards   # expect VERIFIED=true, BOUND=true for both agents
make verify-signatures
```

### Environment Variables (.env)

All configuration lives in a single `.env` file at the project root. Run `make init` to create it from `.env.example`.

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `NAMESPACE` | yes | `redbank-demo` | OpenShift namespace for all workloads |
| `OPENAI_API_KEY` | yes | | API key for the LLM endpoint (vLLM or OpenAI) |
| `LLM_BASE_URL` | yes | | LLM base URL (e.g. `https://vllm.example.com/v1`) |
| `LLM_MODEL` | yes | | Model name (e.g. `llama-scout-17b`) |
| `KEYCLOAK_ADMIN` | yes | `admin` | Keycloak admin username (for setup and cleanup) |
| `KEYCLOAK_PASSWORD` | yes | | Keycloak admin password |
| `KEYCLOAK_HOST` | no | auto-detected | Keycloak hostname for MCP server JWKS URL |
| `PGVECTOR_USER` | no | `app` | PGVector database user |
| `PGVECTOR_PASSWORD` | no | `app` | PGVector database password |
| `ORCHESTRATOR_URL` | no | auto-derived | Playground → orchestrator URL (derived from NAMESPACE) |
| `KEYCLOAK_URL` | no | | Playground Keycloak OIDC base URL |
| `KEYCLOAK_REALM` | no | | Playground Keycloak realm |
| `KEYCLOAK_CLIENT_ID` | no | | Playground Keycloak client ID |
| `MLFLOW_TRACKING_URI` | no | auto-detected | MLflow tracking endpoint |

### Makefile Targets

| Target | Description |
|--------|-------------|
| `make help` | Show all available targets |
| `make init` | Create `.env` from `.env.example` |
| `make deploy` | Deploy everything (Keycloak + DB + MCP + all agents + playground) |
| `make setup-keycloak` | Provision Keycloak realm, client, audience mapper, roles, and demo users |
| `make deploy-db` | Create namespace and apply Kustomize (Secret + ConfigMap + Deployment + Service) |
| `make deploy-mcp` | Build MCP server image via `oc new-build` and deploy |
| `make deploy-banking` | Build and deploy Banking Operations Agent |
| `make deploy-knowledge` | Build and deploy Knowledge Agent |
| `make deploy-orchestrator` | Build and deploy Orchestrator Agent (Helm) |
| `make deploy-playground` | Build and deploy Playground UI (Helm) |
| `make clean` | Tear down all workloads + Keycloak realm (keeps namespace and build configs) |
| `make test-pgvector` | Run pgvector schema + RLS tests (requires Podman) |
| `make test-knowledge-agent` | Run A2A tests against Knowledge Agent with Keycloak JWTs |
| `make compile-pipeline` | Compile the KFP pipeline to YAML |

`make deploy` runs the targets in order: `setup-keycloak` → `deploy-db` → `deploy-mcp` → `deploy-banking` → `deploy-knowledge` → `deploy-orchestrator` → `deploy-playground`.

### Deploy Individual Components

You can deploy components individually after the initial setup:

```bash
make deploy-orchestrator   # rebuild and redeploy just the orchestrator
make deploy-playground     # rebuild and redeploy just the playground
```

### Cleanup

```bash
make clean
```

This removes:
- All AgentRuntime and AgentCard CRs
- Agent deployments and services
- Helm releases (orchestrator + playground)
- Unsigned card ConfigMaps
- PostgreSQL deployment, service, and PVC
- Secrets and configmaps
- Keycloak `redbank` realm (including users, client, roles)

The namespace, ClusterSPIFFEID, and OpenShift build configs are retained.

> **Note:** Tier 1 access gating (non-admin rejection at the network level) requires the Kagenti AuthBridge sidecar, which is injected by the Kagenti operator. Without it, the MCP server's `@admin_only` decorator still enforces write restrictions at the tool level (Tier 2), and RLS enforces read scoping at the database level.

## Manual Testing

### Prerequisites

- The demo is deployed (`make deploy`)
- Port-forward is active in a separate terminal:

```bash
oc port-forward svc/redbank-mcp-server 8000:8000
```

### Step 1 — Verify database seed data

Run from your local terminal (not inside the pod):

```bash
oc rsh deployment/postgresql psql -U user -d db -c "
  SELECT set_config('app.current_role', 'admin', false);
  SELECT set_config('app.current_user_email', 'jane@redbank.demo', false);
  SELECT count(*) FROM customers;
  SELECT count(*) FROM statements;
  SELECT count(*) FROM transactions;
  SELECT count(*) FROM user_accounts;
"
```

Expected: 5 customers, 13 statements, 27 transactions, 2 user_accounts.

Verify RLS is enabled and forced:

```bash
oc rsh deployment/postgresql psql -U user -d db -c "
  SELECT set_config('app.current_role', 'admin', false);
  SELECT relname, relrowsecurity, relforcerowsecurity
  FROM pg_class
  WHERE relname IN ('customers', 'statements', 'transactions');
"
```

Expected: all rows show `t` / `t`.

### Step 2 — Verify RLS scoping

Switch to John's user context and confirm he can only see his own data:

```bash
oc rsh deployment/postgresql psql -U user -d db -c "
  SELECT set_config('app.current_role', 'user', false);
  SELECT set_config('app.current_user_email', 'john@redbank.demo', false);
  SELECT customer_id, name FROM customers;
  SELECT count(*) FROM transactions;
"
```

Expected: only customer_id=5 (John Doe), and only John's transactions (8 from seed data).

### Step 3 — Initialize an MCP session

The MCP server uses FastMCP's Streamable HTTP transport, which requires a session. All curl commands need these headers:

```
Content-Type: application/json
Accept: application/json, text/event-stream
```

Initialize a session and capture the session ID:

```bash
SESSION_ID=$(curl -si http://localhost:8000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"curl-test","version":"1.0"}}}' \
  2>&1 | grep -i 'mcp-session-id' | tr -d '\r' | awk '{print $2}')

echo "Session: $SESSION_ID"
```

### Step 4 — List tools

```bash
curl -s http://localhost:8000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

Expected: 6 tools (`get_customer`, `get_customer_transactions`, `get_account_summary`, `search_knowledge`, `update_account`, `create_transaction`).

### Step 5 — Get Keycloak tokens

Fetch real tokens from Keycloak for the demo users. Requires `make setup-keycloak` to have been run first (this is included in `make deploy`).

```bash
KEYCLOAK_URL="https://$(oc get route keycloak -n keycloak -o jsonpath='{.spec.host}')"

# John (regular user)
JOHN_JWT=$(curl -sf "${KEYCLOAK_URL}/realms/redbank/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=redbank-mcp" \
  -d "username=john" \
  -d "password=john123" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Jane (admin)
JANE_JWT=$(curl -sf "${KEYCLOAK_URL}/realms/redbank/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=redbank-mcp" \
  -d "username=jane" \
  -d "password=jane123" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
```

### Step 6 — Admin read

```bash
curl -s http://localhost:8000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -H "Authorization: Bearer $JANE_JWT" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_customer","arguments":{"email":"alice.johnson@email.com"}}}'
```

Expected: Alice Johnson's full customer record.

### Step 7 — User read (RLS scoped)

John can see his own data:

```bash
curl -s http://localhost:8000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -H "Authorization: Bearer $JOHN_JWT" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_customer","arguments":{"email":"john@redbank.demo"}}}'
```

Expected: John Doe's customer record (customer_id 5).

John cannot see other customers:

```bash
curl -s http://localhost:8000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -H "Authorization: Bearer $JOHN_JWT" \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_customer","arguments":{"email":"bob.smith@email.com"}}}'
```

Expected: empty `{}` — RLS blocks access to Bob's record.

### Step 8 — User write (blocked)

```bash
curl -s http://localhost:8000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -H "Authorization: Bearer $JOHN_JWT" \
  -d '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"update_account","arguments":{"customer_id":5,"phone":"555-0000"}}}'
```

Expected: `"isError": true` with `"This operation requires admin privileges"`.

### Step 9 — Admin write (allowed)

```bash
curl -s http://localhost:8000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -H "Authorization: Bearer $JANE_JWT" \
  -d '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"update_account","arguments":{"customer_id":5,"phone":"555-9999"}}}'
```

Expected: updated customer record with `phone: "555-9999"`.

### Step 10 — Test the Knowledge Agent (A2A)

The Knowledge Agent test script sends A2A requests with Keycloak JWTs and verifies RAG search, customer data access, RLS scoping, and write tool blocking.

**Automated (with port-forward):**

```bash
make test-knowledge-agent
```

This port-forwards the agent, runs 6 tests, and cleans up. The tests verify:

1. **Jane (admin) — knowledge search**: returns docs from all collections
2. **John (user) — knowledge search**: returns docs from `user` collection only
3. **Jane (admin) — customer data**: can see any customer's account
4. **John (user) — own data**: sees his own balance
5. **John (user) — other customers**: blocked by RLS ("No data was found")
6. **John (user) — write tools**: blocked by allow-list ("I don't have permission")

**Manual (port-forward yourself):**

```bash
oc port-forward svc/redbank-knowledge-agent 8002:8002
bash scripts/test-knowledge-agent.sh
```

### Step 11 — Verify Kagenti enrollment

```bash
oc get agentruntime
# expect: all four runtimes in Active phase

oc get deployment redbank-mcp-server -o jsonpath='{.metadata.labels.kagenti\.io/type}'
# expect: tool (set by operator)

oc get svc redbank-mcp-server -o jsonpath='{.metadata.labels.protocol\.kagenti\.io/mcp}'
# expect: true
```

## Automated Tests

Integration tests cover tool discovery, admin reads, user RLS scoping, write enforcement, and Keycloak token acquisition.

### Prerequisites

- MCP server deployed and running
- Port-forward active: `oc port-forward svc/redbank-mcp-server 8000:8000`
- Keycloak realm configured (included in `make deploy`)

### Run

```bash
pip install requests pytest
pytest tests/test_mcp_rls.py -v
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MCP_URL` | `http://localhost:8000/mcp` | MCP server endpoint |
| `KEYCLOAK_URL` | cluster route | Keycloak base URL |
| `KEYCLOAK_REALM` | `redbank` | Keycloak realm |
| `KEYCLOAK_CLIENT` | `redbank-mcp` | Keycloak client ID |
| `JOHN_PASSWORD` | `john123` | Password for john |
| `JANE_PASSWORD` | `jane123` | Password for jane |
| `USE_FAKE_JWT` | `false` | Set `true` to use unsigned JWTs (for `JWT_VERIFY=false` mode) |

By default, tests fetch real access tokens from Keycloak. Set `USE_FAKE_JWT=true` for local dev without Keycloak.

## Per-Component Environment Variables

These are the env vars each component reads at runtime (set automatically by the deploy scripts and Helm charts from the top-level `.env`).

### MCP Server

| Variable | Default | Description |
|----------|---------|-------------|
| `HOST` | `0.0.0.0` | Bind address |
| `PORT` | `8000` | Bind port |
| `POSTGRES_HOST` | `localhost` | PostgreSQL host |
| `POSTGRES_DATABASE` | `db` | Database name |
| `POSTGRES_USER` | `user` | Database user |
| `POSTGRES_PASSWORD` | `pass` | Database password |
| `POSTGRES_PORT` | `5432` | Database port |
| `JWT_VERIFY` | `false` | `false` = trust AuthBridge sidecar; `true` = verify JWT via JWKS |
| `JWT_ALGORITHMS` | `RS256` | Comma-separated JWT algorithms |
| `JWKS_URL` | (empty) | Keycloak JWKS endpoint (required when `JWT_VERIFY=true`) |
| `JWT_AUDIENCE` | (empty) | Expected JWT `aud` claim |
| `ADMIN_ROLE_CLAIM` | `admin` | Role name that grants admin access |
| `DEFAULT_ROLE` | `admin` | Fallback role when no Bearer token present |
| `DEFAULT_EMAIL` | `jane@redbank.demo` | Fallback email when no Bearer token present |
| `PGVECTOR_USER` | `app` | Database user for PGVector connections |
| `PGVECTOR_PASSWORD` | `app` | Password for PGVector database user |
| `EMBEDDING_MODEL` | `nomic-ai/nomic-embed-text-v1.5` | HuggingFace embedding model for `search_knowledge` |

### Banking Agent

| Variable | Default | Description |
|----------|---------|-------------|
| `HOST` | `0.0.0.0` | Bind address |
| `PORT` | `8001` | Bind port |
| `MCP_SERVER_URL` | `http://redbank-mcp-server:8000/mcp` | MCP server endpoint (in-cluster service) |
| `LLM_BASE_URL` | (required) | vLLM or OpenAI API base URL |
| `LLM_MODEL` | (required) | Model name |
| `OPENAI_API_KEY` | (required) | API key for the LLM endpoint |
| `MLFLOW_TRACKING_URI` | (optional) | MLflow tracking endpoint |
| `AGENT_URL` | `http://redbank-banking-agent:8001` | Agent's own URL (used in agent card) |
| `AGENT_CARD_PATH` | `/opt/app-root/.well-known/agent-card.json` | Path to SPIRE-signed agent card (falls back to in-memory card if not found) |

### Knowledge Agent

| Variable | Default | Description |
|----------|---------|-------------|
| `HOST` | `0.0.0.0` | Bind address |
| `PORT` | `8002` | Bind port |
| `MCP_SERVER_URL` | `http://redbank-mcp-server:8000/mcp` | MCP server endpoint (in-cluster service) |
| `LLM_BASE_URL` | (required) | vLLM or OpenAI API base URL |
| `LLM_MODEL` | (required) | Model name |
| `OPENAI_API_KEY` | (required) | API key for the LLM endpoint |
| `MLFLOW_TRACKING_URI` | (optional) | MLflow tracking endpoint |
| `AGENT_URL` | `http://redbank-knowledge-agent:8002` | Agent's own URL (used in agent card) |
| `AGENT_CARD_PATH` | `/opt/app-root/.well-known/agent-card.json` | Path to SPIRE-signed agent card (falls back to in-memory card if not found) |

### Orchestrator Agent

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8080` | Bind port |
| `OPENAI_API_KEY` | (required) | API key for the LLM endpoint |
| `LLM_BASE_URL` | (required) | LLM base URL (auto-appends `/v1` if missing) |
| `LLM_MODEL` | (required) | Model name |
| `MLFLOW_TRACKING_URI` | (optional) | MLflow tracking endpoint |
| `MLFLOW_EXPERIMENT_NAME` | `default-agent-experiment` | MLflow experiment name |
| `AGENT_PUBLIC_URL` | `http://localhost:{PORT}` | Public URL for agent card |
| `LOG_LEVEL` | `INFO` | Logging level |

### Playground

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8080` | Bind port |
| `ORCHESTRATOR_URL` | `http://localhost:8000` | URL of the orchestrator backend |
| `KEYCLOAK_URL` | (optional) | Keycloak base URL — enables OIDC auth when set with `KEYCLOAK_REALM` and `KEYCLOAK_CLIENT_ID` |
| `KEYCLOAK_REALM` | (optional) | Keycloak realm name |
| `KEYCLOAK_CLIENT_ID` | (optional) | Keycloak client ID |
| `LOG_LEVEL` | `INFO` | Logging level |

### Production Configuration

**With AuthBridge sidecar** (standard Kagenti deployment) — the sidecar validates and exchanges tokens upstream. The MCP server decodes the trusted token without re-verifying the signature:

```yaml
- name: JWT_VERIFY
  value: "false"
- name: JWT_AUDIENCE
  value: "redbank-mcp"   # AuthBridge token exchange sets this audience
- name: DEFAULT_ROLE
  value: "user"           # fail-safe: no token = restricted access
```

**Standalone deployment** (no AuthBridge, e.g. dev cluster) — the MCP server verifies JWT signatures directly via JWKS:

```yaml
- name: JWT_VERIFY
  value: "true"
- name: JWKS_URL
  value: "https://keycloak.example.com/realms/redbank/protocol/openid-connect/certs"
- name: JWT_AUDIENCE
  value: "account"        # or "redbank-mcp" if audience mapper is configured
- name: DEFAULT_ROLE
  value: "user"           # fail-safe: no token = restricted access
```

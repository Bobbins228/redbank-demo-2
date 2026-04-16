# RedBank Demo — Kagenti Edition

PostgreSQL database and MCP server for the RedBank multi-agent banking demo, adapted for Kagenti deployment with Row-Level Security (RLS).

Part of RHAISTRAT-1459 / RHAIENG-4556.

## Directory Layout

```
redbank-demo-2/
├── postgres-db/              PostgreSQL schema, seed data, RLS policies
│   ├── init.sql              Schema + RLS + seed data
│   ├── init-db.sh            Startup init script
│   ├── postgres.yaml         Secret + Deployment + Service
│   └── kustomization.yaml
├── mcp-server/               FastMCP server with auth-aware tools
│   ├── redbank-mcp/
│   │   ├── mcp_server.py     Tool definitions + JWT auth
│   │   ├── database_manager.py  Connection pool + RLS context
│   │   └── logger.py
│   ├── requirements.txt
│   ├── Dockerfile
│   ├── mcp-server.yaml       Deployment + Service (Kagenti labels)
│   └── deploy.sh             OpenShift build + deploy
├── scripts/
│   ├── setup-keycloak.sh     Provision Keycloak realm, client, users, audience mapper
│   └── cleanup.sh            Tear down deployed workloads
├── tests/
│   └── test_mcp_rls.py       Integration tests (pytest)
├── Makefile
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

RLS is enabled and forced (`FORCE ROW LEVEL SECURITY`) on `customers`, `statements`, and `transactions`. The table owner (`$POSTGRESQL_USER`) is the same role the MCP server connects as, so `FORCE` ensures policies apply even to the owner.

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

**Write tools** (admin only):
| Tool | Description |
|------|-------------|
| `update_account` | Update customer phone, address, or account type |
| `create_transaction` | Insert a new transaction on the latest statement |

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

### Kagenti Labels

The MCP server workloads carry Kagenti discovery labels:

- **Deployment**: `kagenti.io/type: tool`
- **Service**: `protocol.kagenti.io/mcp: "true"`

These enable the Kagenti operator to discover the MCP server automatically without namespace-level labels or additional CRDs.

## Deployment

All operations are driven through the Makefile. The default namespace is `redbank-demo` — override with `NAMESPACE=my-namespace`.

### Makefile Targets

| Target | Description |
|--------|-------------|
| `deploy-all` | Deploy everything (Postgres + MCP server) |
| `deploy-db` | Create namespace and apply Kustomize (Secret + ConfigMap + Deployment + Service) |
| `deploy-mcp` | Build MCP server image via `oc new-build` and deploy |
| `setup-keycloak` | Provision Keycloak realm, client, audience mapper, roles, and demo users |
| `clean` | Tear down deployed workloads (deployments, services, secrets, configmaps) |

### Quick Start

```bash
# 1. Deploy the database and MCP server
make deploy-all
# or with a custom namespace:
NAMESPACE=my-namespace make deploy-all

# 2. Configure Keycloak (creates realm, client, users, audience mapper)
KEYCLOAK_ADMIN=<admin-user> KEYCLOAK_PASSWORD=<admin-password> make setup-keycloak

# 3. Verify
oc get pods
```

### Keycloak Setup Details

`make setup-keycloak` runs `scripts/setup-keycloak.sh`, which creates:

- Realm `redbank` with client `redbank-mcp` (public, direct access grants enabled)
- An audience mapper that adds `redbank-mcp` to the access token `aud` claim
- Realm role `admin`
- Users `john` (user) and `jane` (admin, with `admin` realm role)

Required environment variables:

| Variable | Description |
|----------|-------------|
| `KEYCLOAK_ADMIN` | Keycloak admin username |
| `KEYCLOAK_PASSWORD` | Keycloak admin password |

Optional — auto-detected from `oc get route keycloak -n keycloak` if not set:

| Variable | Description |
|----------|-------------|
| `KEYCLOAK_URL` | Keycloak base URL (e.g. `https://keycloak.example.com`) |

### Cleanup

```bash
make clean                         # uses default namespace
NAMESPACE=my-namespace make clean  # override namespace
```

This removes deployments, services, secrets, and configmaps for both Postgres and the MCP server. It does not remove the namespace or Keycloak resources.

## Manual Testing

### Prerequisites

- OpenShift cluster with `oc` CLI authenticated
- The demo is deployed (`make deploy-all`)
- Keycloak realm configured (`make setup-keycloak`)
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

Expected: 5 tools (`get_customer`, `get_customer_transactions`, `get_account_summary`, `update_account`, `create_transaction`).

### Step 5 — Get Keycloak tokens

Fetch real tokens from Keycloak for the demo users. Requires `make setup-keycloak` to have been run first.

```bash
# Get the Keycloak route from your cluster
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

### Step 10 — Verify Kagenti labels

```bash
oc get deployment redbank-mcp-server -o jsonpath='{.metadata.labels.kagenti\.io/type}'
# expect: tool

oc get svc redbank-mcp-server -o jsonpath='{.metadata.labels.protocol\.kagenti\.io/mcp}'
# expect: true
```

## Automated Tests

Integration tests cover tool discovery, admin reads, user RLS scoping, write enforcement, and Keycloak token acquisition.

### Prerequisites

- MCP server deployed and running
- Port-forward active: `oc port-forward svc/redbank-mcp-server 8000:8000`
- Keycloak realm configured: `make setup-keycloak`

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

## Environment Variables

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
| `JWT_AUDIENCE` | (empty) | Expected JWT `aud` claim. Use `account` for default Keycloak tokens, or `redbank-mcp` after adding an audience mapper. Tokens are rejected if the claim doesn't match. |
| `ADMIN_ROLE_CLAIM` | `admin` | Role name that grants admin access |
| `DEFAULT_ROLE` | `admin` | Fallback role when no Bearer token present |
| `DEFAULT_EMAIL` | `jane@redbank.demo` | Fallback email when no Bearer token present |

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

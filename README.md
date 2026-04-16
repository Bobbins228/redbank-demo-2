# RedBank Demo — Kagenti Edition

PostgreSQL database and MCP server for the RedBank multi-agent banking demo, adapted for Kagenti deployment with Row-Level Security (RLS).

Part of RHAISTRAT-1459 / RHAIENG-4556.

## Directory Layout

```
redbank-demo-kagenti/
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
  │  Bearer JWT (from Keycloak via AuthBridge)
  ▼
┌──────────────────────────────────────────────┐
│  FastMCP HTTP Server (:8000/mcp)             │
│                                              │
│  1. Extract JWT from Authorization header    │
│  2. Decode claims (email, realm_access)      │
│  3. Determine role: admin or user            │
│  4. Check @admin_only (write tools)          │
│  5. Open pooled DB connection                │
│  6. SET app.current_role, app.current_email  │
│  7. Execute query (RLS filters rows)         │
│  8. Return structured result                 │
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

### JWT Auth

The server reads `Authorization: Bearer <token>` from the incoming MCP request. When `JWT_VERIFY=false` (the default for local dev), the token is decoded without signature verification — the assumption is that AuthBridge has already validated it upstream.

Identity is extracted from the JWT claims:
- **email**: `claims.email` → `claims.preferred_username` → `claims.sub` (fallback chain)
- **role**: `"admin"` if `"admin"` is in `claims.realm_access.roles`, otherwise `"user"`

When no Bearer token is present, the server falls back to `DEFAULT_ROLE` and `DEFAULT_EMAIL` environment variables (admin by default for local dev convenience).

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

### Deploy to OpenShift/Kagenti

```bash
# Deploy everything (Postgres + MCP server)
make deploy-all

# Or step by step
make deploy-db    # Creates namespace, applies Kustomize (ConfigMap + Deployment + Service + Secret)
make deploy-mcp   # Builds image via oc new-build, deploys MCP server
```

The default namespace is `redbank-demo`. Override with `make deploy-all NAMESPACE=my-namespace`.

## Manual Testing

### Prerequisites

- OpenShift cluster with `oc` CLI authenticated
- The demo is deployed (`make deploy-all`)
- Port-forward is active in a separate terminal:

```bash
oc port-forward svc/redbank-mcp-server 8000:8000
```

### Step 1 — Verify database seed data

```bash
oc rsh deployment/postgresql
psql -U user -d db
```

```sql
-- Set admin context to see all rows (RLS is enforced even for table owner)
SELECT set_config('app.current_role', 'admin', false);
SELECT set_config('app.current_user_email', 'jane@redbank.demo', false);

SELECT count(*) FROM customers;       -- expect 5
SELECT count(*) FROM statements;      -- expect 13
SELECT count(*) FROM transactions;    -- expect 27
SELECT count(*) FROM user_accounts;   -- expect 2

-- Verify RLS is enabled and forced
SELECT relname, relrowsecurity, relforcerowsecurity
FROM pg_class
WHERE relname IN ('customers', 'statements', 'transactions');
-- expect all t / t
```

### Step 2 — Verify RLS scoping in psql

```sql
-- Switch to user context (John, customer_id=5)
SELECT set_config('app.current_role', 'user', false);
SELECT set_config('app.current_user_email', 'john@redbank.demo', false);

SELECT customer_id, name FROM customers;
-- expect: only customer_id=5 (John Doe)

SELECT count(*) FROM transactions;
-- expect: only John's transactions (8 from seed data)
```

Exit with `\q` then `exit`.

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

### Step 5 — Admin read (no Bearer token)

Without a Bearer token, the server defaults to admin (`jane@redbank.demo`):

```bash
curl -s http://localhost:8000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_customer","arguments":{"email":"alice.johnson@email.com"}}}'
```

Expected: Alice Johnson's full customer record.

### Step 6 — Create a test JWT for John (user)

Since `JWT_VERIFY=false`, the server accepts unsigned tokens:

```bash
JOHN_JWT=$(python3 -c "
import base64, json
header = base64.urlsafe_b64encode(json.dumps({'alg':'none','typ':'JWT'}).encode()).rstrip(b'=').decode()
payload = base64.urlsafe_b64encode(json.dumps({'sub':'john','email':'john@redbank.demo','realm_access':{'roles':['user']}}).encode()).rstrip(b'=').decode()
print(f'{header}.{payload}.')
")
```

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

Integration tests cover tool discovery, admin reads, user RLS scoping, and write enforcement:

```bash
cd product/rag/demos/redbank-demo-kagenti
pip install requests pytest
pytest tests/test_mcp_rls.py -v
```

Requires a port-forward to be active (`oc port-forward svc/redbank-mcp-server 8000:8000`). Override the endpoint with `MCP_URL=http://host:port/mcp`.

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
| `JWT_VERIFY` | `false` | Enable JWT signature verification |
| `JWT_ALGORITHMS` | `RS256` | Comma-separated JWT algorithms |
| `JWKS_URL` | (empty) | Keycloak JWKS endpoint for key retrieval |
| `JWT_AUDIENCE` | (empty) | Expected JWT audience claim |
| `DEFAULT_ROLE` | `admin` | Fallback role when no Bearer token present |
| `DEFAULT_EMAIL` | `jane@redbank.demo` | Fallback email when no Bearer token present |

### Production Configuration

For production with AuthBridge, set these env vars on the MCP server Deployment:

```yaml
- name: JWT_VERIFY
  value: "true"
- name: JWKS_URL
  value: "https://keycloak.example.com/realms/redbank/protocol/openid-connect/certs"
- name: JWT_AUDIENCE
  value: "redbank-mcp"
- name: DEFAULT_ROLE
  value: "user"  # fail-safe: no token = restricted access
```

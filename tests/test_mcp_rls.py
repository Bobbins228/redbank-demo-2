"""
Integration tests for the RedBank MCP Server with PostgreSQL Row-Level Security.

Prerequisites:
    - MCP server is deployed and running
    - Port-forward is active:  oc port-forward svc/redbank-mcp-server 8000:8000
    - Database has been seeded with init.sql

Usage:
    pip install requests pytest
    pytest tests/test_mcp_rls.py -v

Override the MCP endpoint:
    MCP_URL=http://localhost:9000/mcp pytest tests/test_mcp_rls.py -v
"""

from __future__ import annotations

import base64
import json
import os
import uuid

import pytest
import requests

MCP_URL = os.getenv("MCP_URL", "http://localhost:8000/mcp")

HEADERS = {
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream",
}


# -- Helpers ------------------------------------------------------------------


def _make_jwt(email: str, roles: list[str]) -> str:
    """Build an unsigned JWT. The server has JWT_VERIFY=false."""
    header = base64.urlsafe_b64encode(
        json.dumps({"alg": "none", "typ": "JWT"}).encode()
    ).rstrip(b"=").decode()
    payload = base64.urlsafe_b64encode(
        json.dumps({
            "sub": email.split("@")[0],
            "email": email,
            "realm_access": {"roles": roles},
        }).encode()
    ).rstrip(b"=").decode()
    return f"{header}.{payload}."


JOHN_JWT = _make_jwt("john@redbank.demo", ["user"])
JANE_JWT = _make_jwt("jane@redbank.demo", ["admin"])


def _init_session(bearer: str | None = None) -> str:
    """Initialize an MCP session and return the session ID."""
    hdrs = {**HEADERS}
    if bearer:
        hdrs["Authorization"] = f"Bearer {bearer}"

    resp = requests.post(MCP_URL, headers=hdrs, json={
        "jsonrpc": "2.0",
        "id": str(uuid.uuid4()),
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": {"name": "pytest", "version": "1.0"},
        },
    })
    resp.raise_for_status()
    session_id = resp.headers.get("Mcp-Session-Id")
    assert session_id, "Server did not return Mcp-Session-Id header"
    return session_id


def _call(
    method: str,
    session_id: str,
    params: dict | None = None,
    bearer: str | None = None,
) -> dict:
    """Send a JSON-RPC request and parse the SSE response."""
    hdrs = {**HEADERS, "Mcp-Session-Id": session_id}
    if bearer:
        hdrs["Authorization"] = f"Bearer {bearer}"

    body: dict = {
        "jsonrpc": "2.0",
        "id": str(uuid.uuid4()),
        "method": method,
    }
    if params:
        body["params"] = params

    resp = requests.post(MCP_URL, headers=hdrs, json=body)
    resp.raise_for_status()

    for line in resp.text.splitlines():
        if line.startswith("data: "):
            return json.loads(line[6:])

    return json.loads(resp.text)


def _tool_call(
    session_id: str,
    tool_name: str,
    arguments: dict,
    bearer: str | None = None,
) -> dict:
    """Call an MCP tool and return the result object."""
    data = _call(
        "tools/call",
        session_id,
        params={"name": tool_name, "arguments": arguments},
        bearer=bearer,
    )
    return data.get("result", data.get("error", {}))


def _tool_content(result: dict) -> dict | list | str:
    """Extract structured content or text from a tool result."""
    if "structuredContent" in result:
        sc = result["structuredContent"]
        # FastMCP wraps non-object returns (e.g. list) in {"result": [...]}
        if isinstance(sc, dict) and "result" in sc and len(sc) == 1:
            return sc["result"]
        return sc
    content = result.get("content", [])
    if content and content[0].get("type") == "text":
        text = content[0]["text"]
        try:
            parsed = json.loads(text)
            if isinstance(parsed, dict) and "result" in parsed and len(parsed) == 1:
                return parsed["result"]
            return parsed
        except (json.JSONDecodeError, TypeError):
            return text
    return result


# -- Fixtures -----------------------------------------------------------------


@pytest.fixture(scope="module")
def admin_session() -> str:
    """MCP session with no Bearer token (defaults to admin)."""
    return _init_session()


@pytest.fixture(scope="module")
def john_session() -> str:
    """MCP session initialized for John (user role)."""
    return _init_session(bearer=JOHN_JWT)


# -- Tests: Tool Discovery ----------------------------------------------------


class TestToolDiscovery:
    def test_lists_all_tools(self, admin_session: str):
        data = _call("tools/list", admin_session)
        tools = data["result"]["tools"]
        names = {t["name"] for t in tools}
        assert names == {
            "get_customer",
            "get_customer_transactions",
            "get_account_summary",
            "update_account",
            "create_transaction",
        }


# -- Tests: Admin Reads -------------------------------------------------------


class TestAdminReads:
    def test_get_customer_by_email(self, admin_session: str):
        result = _tool_call(admin_session, "get_customer", {"email": "alice.johnson@email.com"})
        content = _tool_content(result)
        assert content["name"] == "Alice Johnson"
        assert content["customer_id"] == 1

    def test_get_customer_by_phone(self, admin_session: str):
        result = _tool_call(admin_session, "get_customer", {"phone": "555-0102"})
        content = _tool_content(result)
        assert content["name"] == "Bob Smith"

    def test_get_all_customers_visible(self, admin_session: str):
        """Admin can see every customer individually."""
        for cid in range(1, 6):
            result = _tool_call(admin_session, "get_account_summary", {"customer_id": cid})
            content = _tool_content(result)
            assert content.get("customer_id") == cid, f"Admin could not see customer {cid}"

    def test_get_customer_transactions(self, admin_session: str):
        result = _tool_call(admin_session, "get_customer_transactions", {"customer_id": 1})
        content = _tool_content(result)
        assert isinstance(content, list)
        assert len(content) > 0

    def test_get_account_summary(self, admin_session: str):
        result = _tool_call(admin_session, "get_account_summary", {"customer_id": 5})
        content = _tool_content(result)
        assert content["name"] == "John Doe"
        assert content["email"] == "john@redbank.demo"
        assert content["total_statements"] == 2


# -- Tests: User RLS Scoping --------------------------------------------------


class TestUserRLSScoping:
    """John (user, customer_id=5) should only see his own data."""

    def test_john_sees_own_customer_record(self, john_session: str):
        result = _tool_call(
            john_session, "get_customer", {"email": "john@redbank.demo"}, bearer=JOHN_JWT
        )
        content = _tool_content(result)
        assert content["name"] == "John Doe"
        assert content["customer_id"] == 5

    def test_john_cannot_see_alice(self, john_session: str):
        result = _tool_call(
            john_session, "get_customer", {"email": "alice.johnson@email.com"}, bearer=JOHN_JWT
        )
        content = _tool_content(result)
        assert content == {}, f"RLS leak: John saw Alice's record: {content}"

    def test_john_cannot_see_bob(self, john_session: str):
        result = _tool_call(
            john_session, "get_customer", {"email": "bob.smith@email.com"}, bearer=JOHN_JWT
        )
        content = _tool_content(result)
        assert content == {}, f"RLS leak: John saw Bob's record: {content}"

    def test_john_cannot_see_other_account_summary(self, john_session: str):
        result = _tool_call(
            john_session, "get_account_summary", {"customer_id": 1}, bearer=JOHN_JWT
        )
        content = _tool_content(result)
        assert content == {}, f"RLS leak: John saw customer 1 summary: {content}"

    def test_john_sees_own_account_summary(self, john_session: str):
        result = _tool_call(
            john_session, "get_account_summary", {"customer_id": 5}, bearer=JOHN_JWT
        )
        content = _tool_content(result)
        assert content["customer_id"] == 5
        assert content["total_statements"] == 2

    def test_john_sees_own_transactions(self, john_session: str):
        result = _tool_call(
            john_session, "get_customer_transactions", {"customer_id": 5}, bearer=JOHN_JWT
        )
        content = _tool_content(result)
        assert isinstance(content, list)
        assert len(content) >= 8, f"Expected at least 8 transactions, got {len(content)}"
        for txn in content:
            assert txn["customer_name"] == "John Doe"

    def test_john_cannot_see_other_transactions(self, john_session: str):
        result = _tool_call(
            john_session, "get_customer_transactions", {"customer_id": 1}, bearer=JOHN_JWT
        )
        content = _tool_content(result)
        assert content == [], \
            f"RLS leak: John saw customer 1 transactions: {content}"

    def test_john_transaction_date_filter(self, john_session: str):
        result = _tool_call(
            john_session,
            "get_customer_transactions",
            {"customer_id": 5, "start_date": "2025-02-01", "end_date": "2025-02-28"},
            bearer=JOHN_JWT,
        )
        content = _tool_content(result)
        assert isinstance(content, list)
        assert len(content) >= 3, f"Expected at least 3 Feb transactions, got {len(content)}"
        for txn in content:
            assert txn["customer_name"] == "John Doe"


# -- Tests: Admin-Only Write Enforcement --------------------------------------


class TestWriteEnforcement:
    def test_user_cannot_update_account(self, john_session: str):
        result = _tool_call(
            john_session,
            "update_account",
            {"customer_id": 5, "phone": "555-0000"},
            bearer=JOHN_JWT,
        )
        assert result.get("isError") is True
        error_text = result["content"][0]["text"]
        assert "admin privileges" in error_text

    def test_user_cannot_create_transaction(self, john_session: str):
        result = _tool_call(
            john_session,
            "create_transaction",
            {
                "customer_id": 5,
                "amount": 100.0,
                "description": "Unauthorized",
                "transaction_type": "CREDIT",
            },
            bearer=JOHN_JWT,
        )
        assert result.get("isError") is True
        error_text = result["content"][0]["text"]
        assert "admin privileges" in error_text

    def test_admin_can_update_account(self, admin_session: str):
        result = _tool_call(
            admin_session,
            "update_account",
            {"customer_id": 5, "phone": "555-0199"},
        )
        content = _tool_content(result)
        assert content["phone"] == "555-0199"

        # Restore original value
        _tool_call(admin_session, "update_account", {"customer_id": 5, "phone": "555-0105"})

    def test_admin_can_create_transaction(self, admin_session: str):
        result = _tool_call(
            admin_session,
            "create_transaction",
            {
                "customer_id": 5,
                "amount": -10.00,
                "description": "Test transaction",
                "transaction_type": "DEBIT",
                "merchant": "Test Merchant",
                "transaction_date": "2025-02-20",
            },
        )
        content = _tool_content(result)
        assert result.get("isError") is not True
        assert float(content["amount"]) == -10.00
        assert content["transaction_type"] == "DEBIT"


# -- Tests: Admin via explicit JWT --------------------------------------------


class TestAdminJWT:
    """Verify admin access works via explicit JWT (not just default fallback)."""

    @pytest.fixture(scope="class")
    def jane_session(self) -> str:
        return _init_session(bearer=JANE_JWT)

    def test_jane_sees_all_customers(self, jane_session: str):
        for cid in range(1, 6):
            result = _tool_call(
                jane_session, "get_account_summary", {"customer_id": cid}, bearer=JANE_JWT
            )
            content = _tool_content(result)
            assert content.get("customer_id") == cid

    def test_jane_can_write(self, jane_session: str):
        result = _tool_call(
            jane_session,
            "update_account",
            {"customer_id": 3, "address": "999 Test St, Seattle, WA"},
            bearer=JANE_JWT,
        )
        content = _tool_content(result)
        assert content["address"] == "999 Test St, Seattle, WA"

        # Restore
        _tool_call(
            jane_session,
            "update_account",
            {"customer_id": 3, "address": "789 Pine Road, Seattle, WA"},
            bearer=JANE_JWT,
        )

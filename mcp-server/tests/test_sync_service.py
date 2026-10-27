"""Black-box REST and actual Streamable HTTP MCP isolation checks."""
from starlette.testclient import TestClient
from mcp.server.auth.provider import AccessToken
import pytest

from smartspend_mcp.sync_service import SyncRepository, create_app
from conftest import LEDGER, EXPENSE, CATEGORY, key, snapshot, item


class Verifier:
    issuer = "https://issuer.example"

    def __init__(self, ledger_a, ledger_b):
        self.tokens = {
            "owner-a": (ledger_a,["ledger:read","ledger:write"]),
            "owner-b": (ledger_b,["ledger:read","ledger:write"]),
            "read-a": (ledger_a,["ledger:read"]),
        }

    async def verify_token(self, token):
        value = self.tokens.get(token)
        return AccessToken(token=token,client_id="test",scopes=value[1],resource="https://sync.example/mcp",
                           claims={"ledgerId":value[0]}) if value else None


@pytest.fixture
def setup_service(tmp_path):
    repository = SyncRepository(tmp_path / "private")
    other = key()
    repository.ledger(LEDGER).bootstrap(snapshot())
    repository.ledger(other).bootstrap(snapshot(ledgerId=other,expenses=[item(title="Second owner")]))
    verifier = Verifier(LEDGER,other)
    return repository,other,create_app(repository,public_url="https://sync.example",oauth=verifier)


def headers(token):
    return {"Authorization":"Bearer "+token,"Host":"sync.example"}


def exchange(*ops,**changes):
    return {"schemaVersion":1,"ledgerId":LEDGER,"currency":"UZS","clientId":key(),
            "afterSequence":0,"operations":list(ops),**changes}


def test_rest_opaque_grants_401_403_crossledger_and_revoke(setup_service):
    repository,other,app = setup_service
    grant,token = repository.grants.issue(LEDGER,["ledger:read"])
    with TestClient(app,base_url="https://sync.example") as client:
        assert client.get("/v1/sync/context").status_code == 401
        assert client.get("/v1/sync/context",headers=headers("bad")).status_code == 401
        assert client.get("/v1/sync/context",headers=headers(token)).json()["ledgerId"] == LEDGER
        assert client.post("/v1/sync/exchange",headers=headers(token),json=exchange()).status_code == 403
        assert client.post("/v1/sync/exchange",headers=headers("owner-a"),json=exchange(ledgerId=other)).status_code == 403
        repository.grants.revoke(grant)
        assert client.get("/v1/sync/context",headers=headers(token)).status_code == 401


def test_rest_source_bound_no_empty_delete_and_scoped_history(setup_service):
    repository,other,app = setup_service
    operation = {"id":key(),"kind":"update","expenseId":EXPENSE,"baseRevision":1,"expense":item(title="App edit")}
    with TestClient(app,base_url="https://sync.example") as client:
        result = client.post("/v1/sync/exchange",headers=headers("owner-a"),
                             json=exchange(operation,source="notion")).json()
        assert result["changes"][-1]["source"] == "app"
        assert client.post("/v1/sync/exchange",headers=headers("owner-a"),json=exchange()).status_code == 200
        snap = client.get("/v1/sync/snapshot",headers=headers("owner-b")).json()
        assert snap["records"][0]["expense"]["title"] == "Second owner"
        history = client.get(f"/v1/sync/history/{EXPENSE}",headers=headers("owner-b")).json()
        assert len(history["items"]) == 1
        assert history["items"][0]["after"]["expense"]["title"] == "Second owner"
        assert not repository.ledger(LEDGER).state_snapshot()["records"][0]["archived"]


@pytest.mark.parametrize("payload",[[],{},exchange(afterSequence=-1),exchange(currency="USD"),
                                       exchange(operations=[{}]),exchange(schemaVersion=True)])
def test_rest_invalid_requests_dont_mutate(setup_service,payload):
    repository,_,app = setup_service
    before = repository.ledger(LEDGER).state_snapshot()
    with TestClient(app,base_url="https://sync.example") as client:
        result = client.post("/v1/sync/exchange",headers=headers("owner-a"),json=payload)
        assert result.status_code in (403,409)
        assert "Lunch" not in result.text
    assert repository.ledger(LEDGER).state_snapshot() == before


def test_rest_malformed_json_content_type_host(setup_service):
    _,_,app = setup_service
    with TestClient(app,base_url="https://sync.example") as client:
        assert client.post("/v1/sync/exchange",headers=headers("owner-a"),content="not json").status_code == 409
        assert client.post("/v1/sync/exchange",headers={**headers("owner-a"),"Content-Type":"application/json"},content="{").status_code == 409
        assert client.get("/v1/sync/context",headers={**headers("owner-a"),"Host":"attacker.example"}).status_code == 400


def rpc(client,token,method,params=None,identifier=1):
    return client.post("/mcp",headers={**headers(token),"Accept":"application/json, text/event-stream",
                                       "MCP-Protocol-Version":"2025-06-18"},
                       json={"jsonrpc":"2.0","id":identifier,"method":method,"params":params or {}})


def initialize(client,token):
    response = rpc(client,token,"initialize",{"protocolVersion":"2025-06-18","capabilities":{},
                                             "clientInfo":{"name":"test","version":"1"}})
    assert response.status_code == 200,response.text
    assert "serverInfo" in response.json()["result"]


def structured(response):
    assert response.status_code == 200,response.text
    result = response.json()["result"]
    if "structuredContent" in result:
        return result["structuredContent"]
    import json
    return json.loads(result["content"][0]["text"])


def test_real_remote_mcp_protocol_stateless_two_owner_isolation(setup_service):
    repository,other,app = setup_service
    with TestClient(app,base_url="https://sync.example") as client:
        assert rpc(client,"invalid","initialize").status_code == 401
        initialize(client,"owner-a")
        initialize(client,"owner-b")
        tools = rpc(client,"owner-a","tools/list").json()["result"]["tools"]
        assert "create_expense" in [t["name"] for t in tools]
        first = structured(rpc(client,"owner-a","tools/call",{"name":"get_context","arguments":{}}))
        second = structured(rpc(client,"owner-b","tools/call",{"name":"get_context","arguments":{}}))
        assert first["ledgerId"] == LEDGER and second["ledgerId"] == other
        result = structured(rpc(client,"owner-a","tools/call",{"name":"create_expense","arguments":{
            "title":"Bus","amount":"2500","currency":"UZS","category_id":CATEGORY,
            "date":"2026-10-20T10:00:00Z","idempotency_key":key()}}))
        assert result["acknowledgedOperationIds"]
        assert repository.ledger(LEDGER).state_snapshot()["records"][0]
        assert len(repository.ledger(other).state_snapshot()["records"]) == 1
        assert repository.ledger(LEDGER).history(result["changes"][-1]["expenseId"])["items"][-1]["source"] == "mcp"


def test_remote_mcp_read_only_cannot_mutate(setup_service):
    repository,_,app = setup_service
    before = repository.ledger(LEDGER).state_snapshot()
    with TestClient(app,base_url="https://sync.example") as client:
        initialize(client,"read-a")
        result = rpc(client,"read-a","tools/call",{"name":"archive_expense","arguments":{
            "expense_id":EXPENSE,"expected_revision":1,"idempotency_key":key()}})
        # MCP tool authorization failures are protocol tool errors, not HTTP 403.
        assert result.status_code == 200
        assert result.json()["result"]["isError"]
    assert repository.ledger(LEDGER).state_snapshot() == before


def test_rest_categories_bootstrap_restore_history_contract(setup_service):
    repository,_,app = setup_service
    with TestClient(app,base_url="https://sync.example") as client:
        response = client.post("/v1/sync/bootstrap",headers=headers("owner-a"),json=snapshot(expenses=[]))
        assert response.status_code == 409
        new_category = {"id":key(),"name":"Transport"}
        catalog = client.post("/v1/sync/categories",headers=headers("owner-a"),json={
            "ledgerId":LEDGER,"currency":"UZS","expectedRevision":1,"categories":[new_category]})
        assert catalog.status_code == 200
        assert len(catalog.json()["categories"]) == 2
        assert client.post("/v1/sync/categories",headers=headers("owner-a"),json={
            "ledgerId":LEDGER,"currency":"UZS","expectedRevision":1,"categories":[]}).status_code == 409
        op = {"id":key(),"kind":"update","expenseId":EXPENSE,"baseRevision":1,"expense":item(title="Edited")}
        assert client.post("/v1/sync/exchange",headers=headers("owner-a"),json=exchange(op)).status_code == 200
        restore = {"expenseId":EXPENSE,"historySequence":1,"expectedRevision":2,"operationId":key()}
        result = client.post("/v1/sync/restore",headers=headers("owner-a"),json=restore)
        assert result.status_code == 200
        assert result.json()["current"]["expense"]["title"] == "Lunch"
        assert client.post("/v1/sync/restore",headers=headers("read-a"),json=restore).status_code == 403
        assert client.get(f"/v1/sync/history/{EXPENSE}?limit=0",headers=headers("owner-a")).status_code == 400
    assert repository.ledger(LEDGER).state_snapshot()["nextSequence"] == 3


def test_remote_mcp_cannot_address_foreign_expense_uuid(setup_service):
    repository,other,app = setup_service
    foreign_id = key()
    op = {"id":key(),"kind":"create","expenseId":foreign_id,"baseRevision":0,
          "expense":item(id=foreign_id,title="Foreign private expense")}
    repository.ledger(other).exchange(exchange(op,ledgerId=other))
    before = repository.ledger(other).state_snapshot()
    with TestClient(app,base_url="https://sync.example") as client:
        initialize(client,"owner-a")
        result = rpc(client,"owner-a","tools/call",{"name":"get_expense","arguments":{"expense_id":foreign_id}})
        assert result.json()["result"]["isError"]
        assert "Foreign private expense" not in result.text
        edit = rpc(client,"owner-a","tools/call",{"name":"archive_expense","arguments":{
            "expense_id":foreign_id,"expected_revision":1,"idempotency_key":key()}})
        assert structured(edit)["conflicts"][0]["reason"] == "not_found"
    assert repository.ledger(other).state_snapshot() == before

from __future__ import annotations

import json
from copy import deepcopy

import httpx
import pytest

from smartspend_mcp import ai_cli
from smartspend_mcp.ai_config import AIConfig, BASE_URL, MODEL
from smartspend_mcp.interpreter import MAX_RESPONSE_BYTES, interpret, make_payload, validate_drafts
from smartspend_mcp.validation import LedgerError

from conftest import CATEGORY

# Synthetic credential, never a live token. No test contacts a provider.
FAKE_KEY = "sk-or-v1-" + "synthetic_test_only_" * 3
CONFIG = AIConfig(api_key=FAKE_KEY)
CATEGORIES = [{"id": CATEGORY, "name": "Transport", "iconSystemName": "car"}]
TEXT = "Вчера потратил пятнадцать тысяч восемьсот сум на такси"


def transaction(**changes):
    return {
        "kind": "expense", "amount_decimal": "15800", "amount_source": "пятнадцать тысяч восемьсот",
        "currency": "UZS", "title": "Такси", "category_id": CATEGORY,
        "date_expression": "2026-10-19", "account_reference": None, "counterparty": None,
        "ambiguous_fields": [], **changes,
    }


def document(*items, **changes):
    return {"transactions": list(items or [transaction()]), "unresolved_fields": [], **changes}


def envelope(content=None, **changes):
    return {"model": MODEL, "choices": [{"finish_reason": "stop", "message": {"content": json.dumps(content or document())}}], **changes}


def run(handler, text=TEXT, **changes):
    return interpret(text, config=CONFIG, categories=CATEGORIES, currency="UZS", reference_date="2026-10-20", time_zone="Asia/Tashkent", transport=httpx.MockTransport(handler), **changes)


def test_exact_luna_route_schema_no_history_or_key_in_prompt():
    seen = []

    def handler(request):
        seen.append(request)
        assert str(request.url) == BASE_URL + "/chat/completions"
        assert request.headers["authorization"] == "Bearer " + FAKE_KEY
        payload = json.loads(request.content)
        assert FAKE_KEY not in request.content.decode()
        assert payload["model"] == MODEL
        assert payload["reasoning"] == {"effort": "none"}
        assert payload["provider"] == {"require_parameters": True, "data_collection": "deny"}
        assert payload["response_format"]["json_schema"]["strict"] is True
        assert "tools" not in payload and payload["max_tokens"] == 2200
        context = json.loads(payload["messages"][1]["content"])
        assert set(context) == {"transcript", "categories", "default_currency", "reference_date", "time_zone"}
        assert context["categories"] == [{"id": CATEGORY, "name": "Transport"}]
        schema = payload["response_format"]["json_schema"]["schema"]
        assert schema["$defs"]["DraftTransaction"]["properties"]["category_id"]["enum"] == [CATEGORY, None]
        return httpx.Response(200, json=envelope())

    result = run(handler)
    assert len(seen) == 1
    assert result["requires_review"] is True and result["saved"] is False
    assert result["transactions"][0]["amount_decimal"] == "15800"
    assert result["transactions"][0]["date_expression"] == "2026-10-19"


def test_each_person_gets_dynamic_multilingual_system_options_and_schema():
    other_id = "33333333-3333-4333-8333-333333333333"
    first = [{"id": CATEGORY, "name": "Ovqat"}, {"id": other_id, "name": "Moshna"}]
    second = [{"id": other_id, "name": "Продукты"}]
    def payload(categories):
        return make_payload("I bought 2 apples for 6000 today", config=CONFIG, categories=categories,
                            currency="UZS", reference_date="2026-10-20", time_zone="Asia/Tashkent")[0]
    a, b = payload(first), payload(second)
    assert "Ovqat" in a["messages"][0]["content"] and "Moshna" in a["messages"][0]["content"]
    assert "Продукты" in b["messages"][0]["content"]
    assert "Ovqat" not in b["messages"][0]["content"] and "Moshna" not in b["messages"][0]["content"]
    allowed = b["response_format"]["json_schema"]["schema"]["$defs"]["DraftTransaction"]["properties"]["category_id"]["enum"]
    assert allowed == [other_id, None]
    assert json.loads(a["messages"][1]["content"])["categories"] == first


def test_date_resolution_uses_request_calendar_context_not_server_clock():
    payload, _ = make_payload("i spend 15000 for bus like 3 days ago", config=CONFIG,
        categories=CATEGORIES, currency="UZS", reference_date="2026-10-20", time_zone="Asia/Tashkent")
    assert "YYYY-MM-DD" in payload["messages"][0]["content"]
    context = json.loads(payload["messages"][1]["content"])
    assert context["reference_date"] == "2026-10-20"
    assert context["time_zone"] == "Asia/Tashkent"
    result = validate_drafts(document(transaction(amount_decimal="15000", amount_source="15000", date_expression="2026-10-17")),
        transcript=context["transcript"], category_ids={CATEGORY}, currency="UZS")
    assert result["transactions"][0]["date_expression"] == "2026-10-17"


def test_multiple_expenses_corrections_and_missing_amount_are_preserved():
    text = "Taxi 50, no 15 dollars; coffee, don't remember price"
    result = run(lambda _: httpx.Response(200, json=envelope(document(
        transaction(amount_decimal="15", amount_source="50, no 15", currency="USD"),
        transaction(amount_decimal=None, amount_source=None, title="Coffee", category_id=None, date_expression=None, ambiguous_fields=["amount"]),
    ))), text=text)
    assert len(result["transactions"]) == 2
    assert result["transactions"][0]["amount_decimal"] == "15"
    assert "currency_requires_review_no_conversion" in result["transactions"][0]["validation_flags"]
    assert "missing_amount_decimal" in result["transactions"][1]["validation_flags"]


def test_loans_income_and_accounts_are_not_silently_saved_as_expenses():
    result = run(lambda _: httpx.Response(200, json=envelope(document(transaction(kind="loan_received", account_reference="Visa", counterparty="Alice")))))
    flags = result["transactions"][0]["validation_flags"]
    assert "transaction_type_not_supported_in_current_app" in flags
    assert "account_or_counterparty_not_supported_in_current_app" in flags
    assert result["saved"] is False


@pytest.mark.parametrize("changes", [
    {"amount_decimal": 15800}, {"amount_decimal": "0"}, {"amount_decimal": "-12"},
    {"amount_decimal": "1e4"}, {"amount_decimal": "15,800"},
    {"amount_decimal": "1000000000000"}, {"amount_decimal": "1.0000001"},
    {"category_id": "not-an-existing-id"}, {"currency": "BTC"},
    {"amount_source": "not in transcript"}, {"amount_source": None}, {"title": " "},
    {"date_expression": "3 days ago"}, {"date_expression": "2026-02-30"},
])
def test_invalid_model_fields_fail_closed(changes):
    with pytest.raises(LedgerError):
        run(lambda _: httpx.Response(200, json=envelope(document(transaction(**changes)))))


def test_schema_extras_and_too_many_transactions_are_rejected():
    for data in [document(extra="bad"), document(transaction(extra="bad")), document(*[transaction() for _ in range(11)])]:
        with pytest.raises(LedgerError):
            run(lambda _: httpx.Response(200, json=envelope(data)))


@pytest.mark.parametrize("status", [301, 302, 401, 402, 429, 500, 503])
def test_http_errors_are_sanitized_and_never_retried_or_redirected(status):
    calls = []

    def handler(request):
        calls.append(request)
        return httpx.Response(status, text=FAKE_KEY + TEXT, headers={"Location": "https://elsewhere.invalid"})

    with pytest.raises(LedgerError) as error:
        run(handler)
    assert str(status) in str(error.value)
    assert FAKE_KEY not in str(error.value) and TEXT not in str(error.value)
    assert len(calls) == 1


@pytest.mark.parametrize("bad", [
    {"model": "openai/gpt-4o-mini"}, {"choices": []},
    {"choices": [{"finish_reason": "length", "message": {"content": "{}"}}]},
    {"choices": [{"finish_reason": "stop", "message": {"refusal": "no", "content": "{}"}}]},
    {"choices": [{"finish_reason": "stop", "message": {"tool_calls": [{}], "content": "{}"}}]},
    {"choices": [{"finish_reason": "stop", "message": {"content": "not JSON"}}]},
])
def test_incomplete_refused_wrong_model_and_malformed_responses_fail(bad):
    with pytest.raises(LedgerError):
        run(lambda _: httpx.Response(200, json=envelope(**bad)))


def test_timeout_is_sanitized():
    def handler(request):
        raise httpx.ReadTimeout(FAKE_KEY + TEXT, request=request)
    with pytest.raises(LedgerError) as error:
        run(handler)
    assert "timed out" in str(error.value)
    assert FAKE_KEY not in str(error.value) and TEXT not in str(error.value)


def test_oversized_response_fails_before_parsing():
    with pytest.raises(LedgerError, match="safety limit"):
        run(lambda _: httpx.Response(200, content=b"x" * (MAX_RESPONSE_BYTES + 1)))


@pytest.mark.parametrize("changes", [
    {"transcript": ""}, {"transcript": "x" * 4001}, {"currency": "BTC"},
    {"reference_date": "yesterday"}, {"reference_date": "20261020"},
    {"reference_date": "2026-02-30"}, {"time_zone": "Not/AZone"},
    {"categories": CATEGORIES * 101}, {"categories": CATEGORIES * 2},
])
def test_invalid_input_makes_no_request(changes):
    params = {"transcript": TEXT, "config": CONFIG, "categories": CATEGORIES, "currency": "UZS", "reference_date": "2026-10-20", "time_zone": "Asia/Tashkent", **changes}
    calls = []
    with pytest.raises(LedgerError):
        interpret(**params, transport=httpx.MockTransport(lambda request: calls.append(request)))
    assert not calls


def test_key_is_redacted_and_untrusted_hosts_models_or_missing_keys_rejected():
    assert FAKE_KEY not in repr(CONFIG)
    for params in [{"api_key": ""}, {"api_key": FAKE_KEY, "base_url": "https://elsewhere.invalid"}, {"api_key": FAKE_KEY, "model": "openai/gpt-4o-mini"}]:
        with pytest.raises(LedgerError) as error:
            AIConfig(**params)
        assert FAKE_KEY not in str(error.value)
    assert AIConfig.from_environment({"OPENROUTER_API_KEY": FAKE_KEY}) == CONFIG


def test_private_key_file_permissions_exclusive_create_and_no_symlinks(tmp_path):
    path = tmp_path / "config.json"
    CONFIG.save_new(path)
    assert path.stat().st_mode & 0o777 == 0o600
    assert AIConfig.from_private_file(path) == CONFIG
    with pytest.raises(LedgerError):
        CONFIG.save_new(path)
    link = tmp_path / "link.json"
    link.symlink_to(path)
    with pytest.raises(LedgerError):
        AIConfig.from_private_file(link)
    path.chmod(0o644)
    with pytest.raises(LedgerError, match="600"):
        AIConfig.from_private_file(path)


def test_cli_status_never_calls_network_or_prints_key(monkeypatch, capsys):
    monkeypatch.setenv("OPENAI_API_KEY", FAKE_KEY)
    monkeypatch.setattr("sys.argv", ["smartspend-ai", "status"])
    monkeypatch.setattr(ai_cli, "interpret", lambda *args, **kwargs: pytest.fail("Network not permitted"))
    ai_cli.main()
    output = capsys.readouterr().out
    assert MODEL in output and FAKE_KEY not in output
    assert json.loads(output)["network_checked"] is False


def test_cli_requires_explicit_upload_consent_and_does_not_mutate_ledger(store, monkeypatch, capsys):
    before = deepcopy(store.context())
    monkeypatch.setenv("OPENAI_API_KEY", FAKE_KEY)
    monkeypatch.setattr("sys.argv", ["smartspend-ai", "interpret", "--db", str(store.path), "--reference-date", "2026-10-20", "--time-zone", "UTC"])
    monkeypatch.setattr(ai_cli, "interpret", lambda *args, **kwargs: pytest.fail("Must not call provider"))
    with pytest.raises(SystemExit) as error:
        ai_cli.main()
    assert error.value.code == 1 and store.context() == before
    assert FAKE_KEY not in capsys.readouterr().err


def test_empty_categories_allow_only_null_category():
    payload, ids = make_payload(TEXT, config=CONFIG, categories=[], currency="UZS", reference_date="2026-10-20", time_zone="UTC")
    assert ids == set()
    assert payload["response_format"]["json_schema"]["schema"]["$defs"]["DraftTransaction"]["properties"]["category_id"]["enum"] == [None]
    result = validate_drafts(document(transaction(category_id=None)), transcript=TEXT, category_ids=ids, currency="UZS")
    assert result["saved"] is False


def test_configure_rejects_piped_keys_without_echoing_them(tmp_path, monkeypatch, capsys):
    from io import StringIO

    monkeypatch.setattr("sys.stdin", StringIO(FAKE_KEY))
    path = tmp_path / "config.json"
    monkeypatch.setattr("sys.argv", ["smartspend-ai", "--config", str(path), "configure"])
    monkeypatch.setattr(ai_cli.getpass, "getpass", lambda *args: pytest.fail("Piped input is not allowed"))
    with pytest.raises(SystemExit):
        ai_cli.main()
    assert not path.exists()
    output = capsys.readouterr()
    assert FAKE_KEY not in output.out + output.err


def test_configure_hidden_input_creates_only_private_file(tmp_path, monkeypatch, capsys):
    from io import StringIO

    class Terminal(StringIO):
        def isatty(self):
            return True

    monkeypatch.setattr("sys.stdin", Terminal())
    path = tmp_path / "config.json"
    monkeypatch.setattr("sys.argv", ["smartspend-ai", "--config", str(path), "configure"])
    monkeypatch.setattr(ai_cli.getpass, "getpass", lambda *args: FAKE_KEY)
    ai_cli.main()
    assert AIConfig.from_private_file(path) == CONFIG
    output = capsys.readouterr()
    assert FAKE_KEY not in output.out + output.err


def test_configure_aborts_if_hidden_input_unavailable(tmp_path, monkeypatch, capsys):
    import warnings
    from io import StringIO

    class Terminal(StringIO):
        def isatty(self):
            return True

    def unavailable(*args):
        warnings.warn("Cannot hide input", ai_cli.getpass.GetPassWarning)
        pytest.fail("Must not fall back to reading visible input")

    monkeypatch.setattr("sys.stdin", Terminal())
    path = tmp_path / "config.json"
    monkeypatch.setattr("sys.argv", ["smartspend-ai", "--config", str(path), "configure"])
    monkeypatch.setattr(ai_cli.getpass, "getpass", unavailable)
    with pytest.raises(SystemExit):
        ai_cli.main()
    assert not path.exists()


def test_successful_cli_uses_categories_only_and_never_writes_ledger(store, monkeypatch, capsys):
    from io import StringIO

    before = deepcopy(store.context())
    monkeypatch.setenv("OPENAI_API_KEY", FAKE_KEY)
    monkeypatch.setattr("sys.stdin", StringIO(TEXT))
    monkeypatch.setattr("sys.argv", ["smartspend-ai", "interpret", "--db", str(store.path), "--reference-date", "2026-10-20", "--time-zone", "Asia/Tashkent", "--send-to-ai"])

    def provider(text, **kwargs):
        assert text == TEXT and "expenses" not in kwargs
        assert kwargs["currency"] == "UZS"
        assert kwargs["categories"][0]["id"] == CATEGORY
        return {"requires_review": True, "saved": False}

    monkeypatch.setattr(ai_cli, "interpret", provider)
    ai_cli.main()
    assert store.context() == before
    assert json.loads(capsys.readouterr().out)["saved"] is False

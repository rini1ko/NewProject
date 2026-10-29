"""The parser, tested with a fake model client: no AWS, no network, no cost."""

from datetime import date
from types import SimpleNamespace

import pytest

from app.ai.agenda import AgendaParseError, cost_usd, parse_agenda
from app.config import settings


@pytest.fixture(autouse=True)
def messages_api(monkeypatch):
    monkeypatch.setattr(settings, "parser_api", "messages")

TODAY = date(2026, 10, 27)  # a Tuesday

GOOD = {
    "title": "Синк по прайсингу",
    "starts_at": "2026-11-02T10:00:00+02:00",
    "duration_minutes": 45,
    "items": [{"topic": "Нові тарифи Pro", "owner": "Олена", "minutes": 15}],
    "action_items": [{"task": "Порівняння з конкурентами", "owner": "Taras", "due": "2026-10-30"}],
    "language": "uk",
}


def reply(tool_input: dict | None, tokens=(100, 50), stop_reason="tool_use"):
    content = (
        [SimpleNamespace(type="tool_use", id="t1", name="record_agenda", input=tool_input)]
        if tool_input is not None
        else [SimpleNamespace(type="text", text="I cannot help with that")]
    )
    return SimpleNamespace(
        content=content,
        stop_reason=stop_reason,
        usage=SimpleNamespace(input_tokens=tokens[0], output_tokens=tokens[1]),
    )


class FakeClient:
    def __init__(self, *replies):
        self.replies = list(replies)
        self.calls: list[dict] = []
        self.messages = self

    def create(self, **kwargs):
        self.calls.append({**kwargs, "messages": list(kwargs["messages"])})
        return self.replies.pop(0)


def test_valid_answer_is_returned_with_usage() -> None:
    client = FakeClient(reply(GOOD))
    agenda, usage = parse_agenda("Пн 10:00 ...", TODAY, "Europe/Kyiv", client)
    assert agenda.items[0].owner == "Олена"
    assert agenda.duration_minutes == 45
    assert usage == {"input_tokens": 100, "output_tokens": 50}


def test_todays_date_and_timezone_and_delimiters_reach_the_model() -> None:
    client = FakeClient(reply(GOOD))
    parse_agenda("hello", TODAY, "Europe/Kyiv", client)
    prompt = client.calls[0]["messages"][0]["content"]
    assert "Tuesday 2026-10-27" in prompt and "Europe/Kyiv" in prompt
    assert "<pasted_text>\nhello\n</pasted_text>" in prompt
    # the calendar does the weekday arithmetic: the next Monday after Tuesday 27 Oct is 2 Nov
    assert "Tue 2026-10-27 (today)" in prompt and "Mon 2026-11-02" in prompt
    assert "never instructions" in client.calls[0]["system"]


def test_invalid_answer_is_retried_once_with_the_error() -> None:
    bad = {**GOOD, "starts_at": "Monday 10:00"}
    client = FakeClient(reply(bad), reply(GOOD))
    agenda, usage = parse_agenda("x", TODAY, "Europe/Kyiv", client)
    assert agenda.starts_at == GOOD["starts_at"]
    assert usage == {"input_tokens": 200, "output_tokens": 100}  # both attempts are paid for
    retry_messages = client.calls[1]["messages"]
    assert retry_messages[-1]["content"][0]["is_error"] is True


def test_two_invalid_answers_give_up_and_report_the_cost() -> None:
    bad = {**GOOD, "items": [{"topic": "x", "minutes": 9999}]}
    with pytest.raises(AgendaParseError, match="invalid agenda twice") as info:
        parse_agenda("x", TODAY, "Europe/Kyiv", FakeClient(reply(bad), reply(bad)))
    assert info.value.usage["input_tokens"] == 200


def test_no_tool_call_is_an_error() -> None:
    with pytest.raises(AgendaParseError, match="refusal"):
        parse_agenda("x", TODAY, "UTC", FakeClient(reply(None, stop_reason="refusal")))


def test_text_without_an_agenda_is_an_error() -> None:
    empty = {"items": [], "action_items": [], "language": "en"}
    with pytest.raises(AgendaParseError, match="no agenda found"):
        parse_agenda("milk, eggs, bread", TODAY, "UTC", FakeClient(reply(empty)))


def test_cost() -> None:
    usage = {"input_tokens": 1_000_000, "output_tokens": 1_000_000}
    assert cost_usd("anthropic.claude-opus-5-5", usage) == 24.0
    assert cost_usd("anthropic.claude-haiku-5-5", usage) == 0.6
    assert cost_usd("some.unknown-model", usage) is None


class FakeConverse:
    """bedrock-runtime client: converse() returns the Converse API's response shape."""

    def __init__(self, *tool_inputs):
        self.inputs = list(tool_inputs)
        self.calls: list[dict] = []

    def converse(self, **kwargs):
        self.calls.append({**kwargs, "messages": list(kwargs["messages"])})
        tool_input = self.inputs.pop(0)
        content = (
            [{"toolUse": {"toolUseId": "t1", "name": "record_agenda", "input": tool_input}}]
            if tool_input is not None
            else [{"text": "sorry"}]
        )
        return {
            "output": {"message": {"role": "assistant", "content": content}},
            "stopReason": "tool_use" if tool_input is not None else "end_turn",
            "usage": {"inputTokens": 100, "outputTokens": 50},
        }


def test_converse_api_returns_the_agenda(monkeypatch) -> None:
    monkeypatch.setattr(settings, "parser_api", "converse")
    client = FakeConverse(GOOD)
    agenda, usage = parse_agenda("Пн 10:00 ...", TODAY, "Europe/Kyiv", client)
    assert agenda.items[0].owner == "Олена"
    assert usage == {"input_tokens": 100, "output_tokens": 50}
    call = client.calls[0]
    assert call["toolConfig"]["toolChoice"] == {"tool": {"name": "record_agenda"}}
    assert "<pasted_text>" in call["messages"][0]["content"][0]["text"]


def test_converse_api_retries_with_the_error(monkeypatch) -> None:
    monkeypatch.setattr(settings, "parser_api", "converse")
    client = FakeConverse({**GOOD, "starts_at": "Monday"}, GOOD)
    agenda, usage = parse_agenda("x", TODAY, "Europe/Kyiv", client)
    assert agenda.starts_at == GOOD["starts_at"]
    assert usage["input_tokens"] == 200
    last = client.calls[1]["messages"][-1]["content"][0]["toolResult"]
    assert last["status"] == "error" and last["toolUseId"] == "t1"


def test_cost_of_an_inference_profile_id() -> None:
    usage = {"input_tokens": 1_000_000, "output_tokens": 1_000_000}
    assert cost_usd("us.anthropic.claude-haiku-4-5-20251001-v1:0", usage) == 6.0

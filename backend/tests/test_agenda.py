from httpx import AsyncClient

from tests.conftest import make_token
from tests.test_api import meeting_payload

AGENDA = {
    "items": [
        {"topic": "Нові тарифи Pro", "owner": "Олена", "minutes": 15},
        {"topic": "Фідбек від клієнтів", "owner": "Taras", "minutes": None},
    ],
    "action_items": [
        {"task": "Зібрати порівняння з конкурентами", "owner": "Taras", "due": "2026-10-30"}
    ],
}
SUGGESTION = {
    "model": "anthropic.claude-opus-5-5",
    "prompt_version": "agenda-v1",
    "agenda": {"items": []},
}


async def make_meeting(client: AsyncClient) -> str:
    response = await client.post("/api/meetings", json=meeting_payload())
    assert response.status_code == 201, response.text
    return response.json()["id"]


async def test_empty_agenda_by_default(client: AsyncClient) -> None:
    meeting_id = await make_meeting(client)
    response = await client.get(f"/api/meetings/{meeting_id}/agenda")
    assert response.status_code == 200
    assert response.json() == {
        "items": [],
        "action_items": [],
        "ai_suggestion": None,
        "updated_at": None,
    }


async def test_save_agenda_keeps_the_ai_suggestion(client: AsyncClient) -> None:
    meeting_id = await make_meeting(client)
    url = f"/api/meetings/{meeting_id}/agenda"

    saved = await client.put(url, json={**AGENDA, "ai_suggestion": SUGGESTION})
    assert saved.status_code == 200, saved.text
    assert saved.json()["items"][0]["topic"] == "Нові тарифи Pro"
    assert saved.json()["ai_suggestion"]["prompt_version"] == "agenda-v1"

    again = await client.get(url)
    assert again.json()["action_items"][0]["due"] == "2026-10-30"
    assert again.json()["updated_at"].endswith("Z")


async def test_save_agenda_replaces_the_previous_one(client: AsyncClient) -> None:
    meeting_id = await make_meeting(client)
    url = f"/api/meetings/{meeting_id}/agenda"
    await client.put(url, json={**AGENDA, "ai_suggestion": SUGGESTION})

    response = await client.put(url, json={"items": [{"topic": "Only this"}]})

    assert response.status_code == 200
    assert [i["topic"] for i in response.json()["items"]] == ["Only this"]
    assert response.json()["action_items"] == []
    assert response.json()["ai_suggestion"] is None


async def test_agenda_validation(client: AsyncClient) -> None:
    url = f"/api/meetings/{await make_meeting(client)}/agenda"
    for bad in (
        {"items": [{"topic": "   "}]},
        {"items": [{"topic": "x", "minutes": 0}]},
        {"items": [{"topic": "x", "minutes": 481}]},
        {"items": [], "action_items": [{"task": "x", "due": "not-a-date"}]},
    ):
        assert (await client.put(url, json=bad)).status_code == 422, bad


async def test_agenda_of_someone_elses_meeting_is_not_found(client: AsyncClient) -> None:
    meeting_id = await make_meeting(client)  # alice's
    bob = {"Authorization": f"Bearer {make_token('bob')}"}
    url = f"/api/meetings/{meeting_id}/agenda"

    assert (await client.get(url, headers=bob)).status_code == 404
    assert (await client.put(url, json=AGENDA, headers=bob)).status_code == 404


async def test_agenda_needs_a_token(client: AsyncClient) -> None:
    meeting_id = await make_meeting(client)
    response = await client.get(f"/api/meetings/{meeting_id}/agenda", headers={"Authorization": ""})
    assert response.status_code == 401


async def test_agenda_is_deleted_with_its_meeting(client: AsyncClient) -> None:
    meeting_id = await make_meeting(client)
    await client.put(f"/api/meetings/{meeting_id}/agenda", json=AGENDA)
    assert (await client.delete(f"/api/meetings/{meeting_id}")).status_code == 204
    assert (await client.get(f"/api/meetings/{meeting_id}/agenda")).status_code == 404


import pytest
from fastapi.testclient import TestClient

import main as api


class FakeProvider:
    def __init__(self, response=None, error=None):
        self.response = (
            response
            if response is not None
            else {
                "text": "Hello from Idrici",
                "provider": "fake",
            }
        )
        self.error = error
        self.received_messages = None

    async def generate(self, messages, tools=None):
        self.received_messages = messages

        if self.error:
            raise self.error

        return self.response


@pytest.fixture
def client():
    return TestClient(api.app)


def test_root_endpoint(client):
    response = client.get("/")

    assert response.status_code == 200
    assert response.json() == {
        "status": "ok",
        "app": "Idrici AI",
    }


def test_chat_returns_provider_response(client, monkeypatch):
    fake = FakeProvider()

    monkeypatch.setattr(
        api,
        "provider_factory",
        lambda: fake,
    )

    response = client.post(
        "/chat",
        json={"message": "Hello"},
    )

    assert response.status_code == 200
    assert response.json() == {
        "reply": "Hello from Idrici",
        "provider": "fake",
    }


def test_chat_passes_history_and_current_message(
    client,
    monkeypatch,
):
    fake = FakeProvider()

    monkeypatch.setattr(
        api,
        "provider_factory",
        lambda: fake,
    )

    response = client.post(
        "/chat",
        json={
            "message": "My corrected question",
            "history": [
                {
                    "role": "user",
                    "content": "First question",
                },
                {
                    "role": "assistant",
                    "content": "First answer",
                },
                {
                    "role": "user",
                    "content": "Correction",
                },
            ],
        },
    )

    assert response.status_code == 200

    assert fake.received_messages == [
        {
            "role": "user",
            "content": "First question",
        },
        {
            "role": "assistant",
            "content": "First answer",
        },
        {
            "role": "user",
            "content": "Correction",
        },
        {
            "role": "user",
            "content": "My corrected question",
        },
    ]


def test_chat_does_not_duplicate_current_message(
    client,
    monkeypatch,
):
    fake = FakeProvider()

    monkeypatch.setattr(
        api,
        "provider_factory",
        lambda: fake,
    )

    response = client.post(
        "/chat",
        json={"message": "Only once"},
    )

    assert response.status_code == 200
    assert fake.received_messages == [
        {
            "role": "user",
            "content": "Only once",
        }
    ]


def test_chat_rejects_empty_message(client):
    response = client.post(
        "/chat",
        json={"message": "   "},
    )

    assert response.status_code == 422


def test_chat_rejects_more_than_12_history_messages(client):
    response = client.post(
        "/chat",
        json={
            "message": "Hello",
            "history": [
                {
                    "role": "user",
                    "content": f"Message {index}",
                }
                for index in range(13)
            ],
        },
    )

    assert response.status_code == 422


def test_chat_handles_provider_failure(client, monkeypatch):
    fake = FakeProvider(error=RuntimeError("Test failure"))

    monkeypatch.setattr(
        api,
        "provider_factory",
        lambda: fake,
    )

    response = client.post(
        "/chat",
        json={"message": "Hello"},
    )

    assert response.status_code == 500
    assert response.json()["detail"] == (
        "AI request failed. Check server logs."
    )


def test_chat_rejects_empty_provider_response(
    client,
    monkeypatch,
):
    fake = FakeProvider(
        response={
            "text": "   ",
            "provider": "fake",
        }
    )

    monkeypatch.setattr(
        api,
        "provider_factory",
        lambda: fake,
    )

    response = client.post(
        "/chat",
        json={"message": "Hello"},
    )

    assert response.status_code == 500


def test_chat_rejects_invalid_provider_response(
    client,
    monkeypatch,
):
    fake = FakeProvider(response=None)
    fake.response = "invalid"

    monkeypatch.setattr(
        api,
        "provider_factory",
        lambda: fake,
    )

    response = client.post(
        "/chat",
        json={"message": "Hello"},
    )

    assert response.status_code == 500

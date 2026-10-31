from fastapi.testclient import TestClient

import main
from app.models.model_provider import MockModelProvider

client = TestClient(main.app)


class RecordingProvider(MockModelProvider):
    """Mock provider that remembers the messages it received."""

    last_messages: list[dict[str, str]] = []

    async def generate(self, messages, tools=None):
        RecordingProvider.last_messages = messages
        return await super().generate(messages, tools)


def test_root_reports_ok():
    response = client.get("/")

    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_chat_rejects_empty_message():
    response = client.post("/chat", json={"message": "   "})

    assert response.status_code == 400


def test_chat_passes_history_to_provider(monkeypatch):
    monkeypatch.setattr(main, "GroqModelProvider", RecordingProvider)

    response = client.post(
        "/chat",
        json={
            "message": "And what is my name?",
            "history": [
                {"role": "user", "content": "My name is Idrici"},
                {"role": "assistant", "content": "Nice to meet you"},
            ],
        },
    )

    assert response.status_code == 200
    assert response.json()["reply"] == "Idrici mock response: And what is my name?"
    assert RecordingProvider.last_messages == [
        {"role": "user", "content": "My name is Idrici"},
        {"role": "assistant", "content": "Nice to meet you"},
        {"role": "user", "content": "And what is my name?"},
    ]


def test_chat_works_without_history(monkeypatch):
    monkeypatch.setattr(main, "GroqModelProvider", RecordingProvider)

    response = client.post("/chat", json={"message": "Hello"})

    assert response.status_code == 200
    assert RecordingProvider.last_messages == [
        {"role": "user", "content": "Hello"},
    ]

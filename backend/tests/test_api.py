import base64

import pytest
from fastapi.testclient import TestClient

import main
from app.agent.memory import MemoryStore
from app.models.model_provider import MockModelProvider


client = TestClient(main.app)


class RecordingProvider(MockModelProvider):
    """Mock provider that remembers the messages it received."""

    last_messages: list[dict] = []

    async def generate(self, messages, tools=None):
        RecordingProvider.last_messages = messages
        return await super().generate(messages, tools)


@pytest.fixture
def isolated_store(tmp_path, monkeypatch):
    """Give every test its own temporary SQLite database."""
    store = MemoryStore(tmp_path / "test_idrici.db")
    monkeypatch.setattr(main, "get_store", lambda: store)
    return store


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
    assert response.json()["reply"] == (
        "Idrici mock response: And what is my name?"
    )

    assert RecordingProvider.last_messages == [
        {"role": "user", "content": "My name is Idrici"},
        {"role": "assistant", "content": "Nice to meet you"},
        {"role": "user", "content": "And what is my name?"},
    ]


def test_chat_works_without_history(monkeypatch):
    monkeypatch.setattr(main, "GroqModelProvider", RecordingProvider)

    response = client.post(
        "/chat",
        json={"message": "Hello"},
    )

    assert response.status_code == 200
    assert RecordingProvider.last_messages == [
        {"role": "user", "content": "Hello"},
    ]


# A tiny but valid-looking JPEG.
FAKE_JPEG_B64 = base64.b64encode(
    b"\xff\xd8\xff\xe0" + b"0" * 16
).decode()


def test_chat_passes_camera_frame_to_provider(monkeypatch):
    monkeypatch.setattr(main, "GroqModelProvider", RecordingProvider)

    response = client.post(
        "/chat",
        json={
            "message": "What am I holding?",
            "image": FAKE_JPEG_B64,
        },
    )

    assert response.status_code == 200
    assert response.json()["reply"] == (
        "Idrici mock response: What am I holding? [image received]"
    )

    assert RecordingProvider.last_messages == [
        {
            "role": "user",
            "content": [
                {"type": "text", "text": "What am I holding?"},
                {
                    "type": "image_url",
                    "image_url": {
                        "url": f"data:image/jpeg;base64,{FAKE_JPEG_B64}"
                    },
                },
            ],
        },
    ]


def test_chat_accepts_data_url_prefix(monkeypatch):
    monkeypatch.setattr(main, "GroqModelProvider", RecordingProvider)

    response = client.post(
        "/chat",
        json={
            "message": "Hi",
            "image": f"data:image/jpeg;base64,{FAKE_JPEG_B64}",
        },
    )

    assert response.status_code == 200

    content = RecordingProvider.last_messages[-1]["content"]
    assert content[1]["image_url"]["url"].endswith(FAKE_JPEG_B64)


def test_chat_rejects_invalid_base64_image():
    response = client.post(
        "/chat",
        json={
            "message": "Hi",
            "image": "not base64 !!!",
        },
    )

    assert response.status_code == 400


def test_chat_rejects_non_jpeg_image():
    png = base64.b64encode(
        b"\x89PNG\r\n\x1a\n" + b"0" * 16
    ).decode()

    response = client.post(
        "/chat",
        json={
            "message": "Hi",
            "image": png,
        },
    )

    assert response.status_code == 400


def test_chat_rejects_oversized_image():
    response = client.post(
        "/chat",
        json={
            "message": "Hi",
            "image": "A" * (main.MAX_IMAGE_CHARS + 1),
        },
    )

    assert response.status_code == 422


# ---------------------------------------------------------
# Conversation tests
# ---------------------------------------------------------

def test_create_conversation(isolated_store):
    response = client.post(
        "/conversations",
        json={"title": "My first conversation"},
    )

    assert response.status_code == 200

    data = response.json()

    assert data["id"]
    assert data["title"] == "My first conversation"


def test_list_conversations(isolated_store):
    created = client.post(
        "/conversations",
        json={"title": "Conversation one"},
    )

    assert created.status_code == 200

    response = client.get("/conversations")

    assert response.status_code == 200

    conversations = response.json()["conversations"]

    assert len(conversations) == 1
    assert conversations[0]["title"] == "Conversation one"


def test_get_conversation_and_messages(isolated_store):
    created = client.post(
        "/conversations",
        json={"title": "Test conversation"},
    )

    conversation_id = created.json()["id"]

    isolated_store.add_conversation_message(
        "default",
        conversation_id,
        "user",
        "Hello",
    )

    isolated_store.add_conversation_message(
        "default",
        conversation_id,
        "assistant",
        "Welcome",
    )

    response = client.get(
        f"/conversations/{conversation_id}"
    )

    assert response.status_code == 200

    data = response.json()

    assert data["conversation"]["id"] == conversation_id
    assert len(data["messages"]) == 2
    assert data["messages"][0]["content"] == "Hello"
    assert data["messages"][1]["content"] == "Welcome"


def test_delete_conversation(isolated_store):
    created = client.post(
        "/conversations",
        json={"title": "Delete me"},
    )

    conversation_id = created.json()["id"]

    response = client.delete(
        f"/conversations/{conversation_id}"
    )

    assert response.status_code == 200
    assert response.json()["deleted"] == conversation_id

    missing = client.get(
        f"/conversations/{conversation_id}"
    )

    assert missing.status_code == 404


def test_conversation_isolation_by_owner(isolated_store):
    created = client.post(
        "/conversations",
        json={"title": "Private conversation"},
        headers={"X-Owner-ID": "user-one"},
    )

    conversation_id = created.json()["id"]

    response = client.get(
        f"/conversations/{conversation_id}",
        headers={"X-Owner-ID": "user-two"},
    )

    assert response.status_code == 404


def test_chat_saves_conversation_messages(
    isolated_store,
    monkeypatch,
):
    monkeypatch.setattr(
        main,
        "GroqModelProvider",
        RecordingProvider,
    )

    created = client.post(
        "/conversations",
        json={"title": "Chat test"},
    )

    assert created.status_code == 200

    conversation_id = created.json()["id"]

    response = client.post(
        "/chat",
        json={
            "message": "Hello Idrici",
            "conversation_id": conversation_id,
        },
    )

    assert response.status_code == 200

    assert response.json()["conversation_id"] == conversation_id

    saved = client.get(
        f"/conversations/{conversation_id}"
    )

    assert saved.status_code == 200

    messages = saved.json()["messages"]

    assert len(messages) == 2
    assert messages[0]["role"] == "user"
    assert messages[0]["content"] == "Hello Idrici"
    assert messages[1]["role"] == "assistant"


def test_chat_uses_saved_conversation_history(
    isolated_store,
    monkeypatch,
):
    monkeypatch.setattr(
        main,
        "GroqModelProvider",
        RecordingProvider,
    )

    created = client.post(
        "/conversations",
        json={"title": "History test"},
    )

    conversation_id = created.json()["id"]

    first = client.post(
        "/chat",
        json={
            "message": "My name is Idrici",
            "conversation_id": conversation_id,
        },
    )

    assert first.status_code == 200

    second = client.post(
        "/chat",
        json={
            "message": "What is my name?",
            "conversation_id": conversation_id,
        },
    )

    assert second.status_code == 200

    messages = RecordingProvider.last_messages

    assert messages[0] == {
        "role": "user",
        "content": "My name is Idrici",
    }

    assert messages[1]["role"] == "assistant"

    assert messages[-1] == {
        "role": "user",
        "content": "What is my name?",
    }


def test_chat_rejects_unknown_conversation():
    response = client.post(
        "/chat",
        json={
            "message": "Hello",
            "conversation_id": "unknown-conversation-id",
        },
    )

    assert response.status_code == 404


def test_chat_saves_memory_command_in_conversation(isolated_store):
    created = client.post(
        "/conversations",
        json={"title": "Memory command test"},
    )

    conversation_id = created.json()["id"]

    response = client.post(
        "/chat",
        json={
            "message": "لا تحفظ هذا",
            "conversation_id": conversation_id,
        },
    )

    assert response.status_code == 200
    assert response.json()["provider"] == "memory"

    saved = client.get(
        f"/conversations/{conversation_id}"
    )

    assert saved.status_code == 200

    messages = saved.json()["messages"]

    assert len(messages) == 2
    assert messages[0]["role"] == "user"
    assert messages[1]["role"] == "assistant"

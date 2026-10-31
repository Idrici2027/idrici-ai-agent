import base64

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


# A tiny but valid-looking JPEG: the SOI marker followed by padding.
FAKE_JPEG_B64 = base64.b64encode(b"\xff\xd8\xff\xe0" + b"0" * 16).decode()


def test_chat_passes_camera_frame_to_provider(monkeypatch):
    monkeypatch.setattr(main, "GroqModelProvider", RecordingProvider)

    response = client.post(
        "/chat",
        json={"message": "What am I holding?", "image": FAKE_JPEG_B64},
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
        "/chat", json={"message": "Hi", "image": "not base64 !!!"}
    )

    assert response.status_code == 400


def test_chat_rejects_non_jpeg_image():
    png = base64.b64encode(b"\x89PNG\r\n\x1a\n" + b"0" * 16).decode()

    response = client.post("/chat", json={"message": "Hi", "image": png})

    assert response.status_code == 400


def test_chat_rejects_oversized_image():
    response = client.post(
        "/chat",
        json={"message": "Hi", "image": "A" * (main.MAX_IMAGE_CHARS + 1)},
    )

    assert response.status_code == 422

from fastapi.testclient import TestClient

import main
from test_api import RecordingProvider

client = TestClient(main.app)


def _chat(conversation_id, message):
    return client.post(
        "/chat", json={"message": message, "conversation_id": conversation_id}
    )


def test_backup_then_restore_after_losing_the_conversation(monkeypatch):
    monkeypatch.setenv("IDRICI_PROVIDER", "mock")
    conv = client.post("/conversations", json={}).json()
    assert _chat(conv["id"], "خطة مشروع التطبيق").status_code == 200

    backup = client.get("/backup").json()
    assert len(backup["conversations"]) == 1
    assert len(backup["conversations"][0]["messages"]) == 2

    # simulate the server losing its data
    assert client.delete(f"/conversations/{conv['id']}").status_code == 200
    assert client.get("/conversations").json()["conversations"] == []
    assert _chat(conv["id"], "x").status_code == 404

    out = client.post("/restore", json=backup).json()
    assert out["conversations"] == 1
    listed = client.get("/conversations").json()["conversations"]
    assert [c["id"] for c in listed] == [conv["id"]]
    assert _chat(conv["id"], "نكمل").status_code == 200


def test_new_chat_is_given_earlier_conversations(monkeypatch):
    monkeypatch.setattr(main, "GroqModelProvider", RecordingProvider)
    old = client.post("/conversations", json={}).json()
    _chat(old["id"], "أريد تعلم الطبخ الإيطالي")

    new = client.post("/conversations", json={}).json()
    _chat(new["id"], "ماذا تحدثنا في المحادثات السابقة؟")

    system = " ".join(
        m["content"] for m in RecordingProvider.last_messages
        if m["role"] == "system"
    )
    assert "الطبخ الإيطالي" in system


def test_restore_requires_api_key(monkeypatch):
    monkeypatch.setenv("IDRICI_API_KEY", "s3cret")
    assert client.get("/backup").status_code == 401
    assert client.post("/restore", json={}).status_code == 401

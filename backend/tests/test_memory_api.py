from fastapi.testclient import TestClient

import main
from test_api import RecordingProvider

client = TestClient(main.app)


def test_remember_then_recall_in_next_chat(monkeypatch):
    monkeypatch.setattr(main, "GroqModelProvider", RecordingProvider)
    r = client.post("/chat", json={"message": "تذكر أن اسمي إدريس"})
    assert r.json()["provider"] == "memory"
    client.post("/chat", json={"message": "ما اسمي؟"})
    system = [m for m in RecordingProvider.last_messages
              if m["role"] == "system"]
    assert system and "اسمي إدريس" in system[0]["content"]


def test_dont_remember_stores_nothing():
    client.post("/chat", json={"message": "لا تتذكر هذا"})
    assert client.get("/memories").json()["memories"] == []


def test_secret_not_stored_via_chat():
    r = client.post("/chat", json={"message": "remember my password is abc"})
    assert "can't store" in r.json()["reply"]
    assert client.get("/memories").json()["memories"] == []


def test_memory_crud():
    item = client.post("/memories", json={"content": "fact"}).json()
    assert client.put(f"/memories/{item['id']}",
                      json={"content": "new"}).json()["content"] == "new"
    assert client.delete(f"/memories/{item['id']}").status_code == 200
    assert client.delete(f"/memories/{item['id']}").status_code == 404


def test_api_key_enforced(monkeypatch):
    monkeypatch.setenv("IDRICI_API_KEY", "s3cret")
    assert client.post("/chat", json={"message": "hi"}).status_code == 401
    assert client.get("/memories").status_code == 401
    assert client.get("/memories",
                      headers={"X-API-Key": "s3cret"}).status_code == 200
    assert client.get("/").status_code == 200


def test_provider_selection(monkeypatch):
    monkeypatch.setenv("IDRICI_PROVIDER", "mock")
    r = client.post("/chat", json={"message": "hello"})
    assert r.json()["provider"] == "mock"


def test_voice_mode_adds_note_but_text_does_not(monkeypatch):
    monkeypatch.setattr(main, "GroqModelProvider", RecordingProvider)
    client.post("/chat", json={"message": "hi"})
    assert all(m["role"] != "system" for m in RecordingProvider.last_messages)
    client.post("/chat", json={"message": "hi", "input_mode": "voice"})
    assert any(m["role"] == "system" for m in RecordingProvider.last_messages)


def test_agent_endpoints_require_key_and_report_status(monkeypatch):
    monkeypatch.setenv("IDRICI_API_KEY", "k")
    monkeypatch.setenv("IDRICI_PROVIDER", "mock")
    assert client.post("/agent", json={"goal": "x"}).status_code == 401
    h = {"X-API-Key": "k"}
    assert client.get("/integrations", headers=h).status_code == 200
    r = client.post("/agent", json={"goal": "hello"}, headers=h)
    assert r.status_code == 200 and r.json()["status"] == "done"

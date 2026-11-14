import pytest

from app.agent.memory import MemoryStore


def test_memory_persists_across_instances(tmp_path):
    path = tmp_path / "m.db"
    MemoryStore(path).add("اسمي إدريس وأعمل على مشروع Idrici")
    assert "إدريس" in MemoryStore(path).list()[0]["content"]


def test_search_arabic_normalisation(tmp_path):
    store = MemoryStore(tmp_path / "m.db")
    store.add("أحب القهوة صباحاً")
    store.add("موعد الاجتماع يوم الخميس")
    assert store.search("احب القهوه")[0]["content"].startswith("أحب")
    assert store.search("شيء غير موجود") == []


def test_update_delete_and_dedupe(tmp_path):
    store = MemoryStore(tmp_path / "m.db")
    first = store.add("I use Android")
    assert store.add("i use android")["id"] == first["id"]
    assert len(store.list()) == 1
    assert store.update(first["id"], "I use iPhone")["content"] == "I use iPhone"
    assert store.delete(first["id"]) is True
    assert store.delete(first["id"]) is False
    assert store.list() == []


@pytest.mark.parametrize("bad", [
    "my password is hunter2", "كلمة المرور 1234", "key gsk_abcdef",
    "token ghp_xxx", "", "   ", "x" * 1001,
])
def test_rejects_secrets_and_invalid(tmp_path, bad):
    with pytest.raises(ValueError):
        MemoryStore(tmp_path / "m.db").add(bad)

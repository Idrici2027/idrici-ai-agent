import pytest


@pytest.fixture(autouse=True)
def isolated_db(tmp_path, monkeypatch):
    """Every test gets its own memory database and no API key."""
    monkeypatch.setenv("IDRICI_DB_PATH", str(tmp_path / "test.db"))
    monkeypatch.delenv("IDRICI_API_KEY", raising=False)

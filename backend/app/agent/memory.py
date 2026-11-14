"""Persistent memory for Idrici AI (SQLite, standard library only).

Only information the user explicitly asked to remember is stored. Secrets
(passwords, API keys, tokens) are rejected. Search is keyword based with
Arabic normalisation; it is NOT semantic (no embeddings).
"""
from __future__ import annotations

import os
import re
import sqlite3
import time
from pathlib import Path

MAX_MEMORY_CHARS = 1000

_DIACRITICS = re.compile("[\u064b-\u0652\u0640]")
_TOKEN = re.compile(r"\w+", re.UNICODE)
_SECRET_WORDS = re.compile(
    r"(password|passwd|passcode|api[\s_-]?key|secret|token|private[\s_-]?key"
    r"|كلمة\s*(?:ال)?(?:مرور|سر)|رمز\s*(?:ال)?(?:دخول|مرور)|مفتاح)",
    re.IGNORECASE,
)
_SECRET_VALUES = re.compile(
    r"(gsk_|sk-|ghp_|github_pat_|AIza|xox[bp]-|\b[A-Za-z0-9_\-]{32,}\b)"
)


def normalize(text: str) -> str:
    text = _DIACRITICS.sub("", text.lower())
    for src in "إأآ":
        text = text.replace(src, "ا")
    return text.replace("ى", "ي").replace("ة", "ه")


def tokens(text: str) -> set[str]:
    return {t for t in _TOKEN.findall(normalize(text)) if len(t) >= 2}


def looks_secret(text: str) -> bool:
    return bool(_SECRET_WORDS.search(text) or _SECRET_VALUES.search(text))


def default_db_path() -> Path:
    env = os.getenv("IDRICI_DB_PATH")
    if env:
        return Path(env)
    return Path(__file__).resolve().parents[2] / "data" / "idrici.db"


class MemoryStore:
    def __init__(self, path: Path | str | None = None) -> None:
        self.path = Path(path) if path else default_db_path()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self._conn() as conn:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS memories ("
                "id INTEGER PRIMARY KEY AUTOINCREMENT,"
                "content TEXT NOT NULL,"
                "norm TEXT NOT NULL,"
                "category TEXT NOT NULL DEFAULT 'note',"
                "created REAL NOT NULL,"
                "updated REAL NOT NULL)"
            )

    def _conn(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.path)
        conn.row_factory = sqlite3.Row
        return conn

    @staticmethod
    def _validate(content: str) -> str:
        content = (content or "").strip()
        if not content:
            raise ValueError("Memory cannot be empty")
        if len(content) > MAX_MEMORY_CHARS:
            raise ValueError("Memory is too long")
        if looks_secret(content):
            raise ValueError("Secrets are never stored in memory")
        return content

    def add(self, content: str, category: str = "note") -> dict:
        content = self._validate(content)
        norm = normalize(content)
        now = time.time()
        conn = self._conn()
        try:
            with conn:
                row = conn.execute(
                    "SELECT id FROM memories WHERE norm = ?", (norm,)
                ).fetchone()
                if row:  # same fact again: refresh instead of duplicating
                    conn.execute(
                        "UPDATE memories SET updated = ? WHERE id = ?",
                        (now, row["id"]),
                    )
                    new_id = row["id"]
                else:
                    new_id = conn.execute(
                        "INSERT INTO memories (content, norm, category,"
                        " created, updated) VALUES (?,?,?,?,?)",
                        (content, norm, category[:40], now, now),
                    ).lastrowid
        finally:
            conn.close()
        return self.get(new_id)

    def get(self, memory_id: int) -> dict | None:
        conn = self._conn()
        try:
            row = conn.execute(
                "SELECT id, content, category, created, updated"
                " FROM memories WHERE id = ?", (memory_id,)
            ).fetchone()
        finally:
            conn.close()
        return dict(row) if row else None

    def list(self) -> list[dict]:
        conn = self._conn()
        try:
            rows = conn.execute(
                "SELECT id, content, category, created, updated"
                " FROM memories ORDER BY updated DESC"
            ).fetchall()
        finally:
            conn.close()
        return [dict(r) for r in rows]

    def update(self, memory_id: int, content: str) -> dict | None:
        content = self._validate(content)
        conn = self._conn()
        try:
            with conn:
                cur = conn.execute(
                    "UPDATE memories SET content=?, norm=?, updated=?"
                    " WHERE id=?",
                    (content, normalize(content), time.time(), memory_id),
                )
        finally:
            conn.close()
        return self.get(memory_id) if cur.rowcount else None

    def delete(self, memory_id: int) -> bool:
        conn = self._conn()
        try:
            with conn:
                cur = conn.execute(
                    "DELETE FROM memories WHERE id=?", (memory_id,)
                )
        finally:
            conn.close()
        return cur.rowcount > 0

    def search(self, query: str, limit: int = 5) -> list[dict]:
        wanted = tokens(query)
        if not wanted:
            return []
        scored = []
        for item in self.list():
            have = tokens(item["content"])
            score = sum(
                1
                for w in wanted
                if any(
                    w == h or (len(w) >= 4 and len(h) >= 4
                               and (h.startswith(w) or w.startswith(h)))
                    for h in have
                )
            )
            if score:
                scored.append((score, item["updated"], item))
        scored.sort(key=lambda s: (s[0], s[1]), reverse=True)
        return [s[2] for s in scored[:limit]]

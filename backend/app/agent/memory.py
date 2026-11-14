"""Persistent memory and conversation storage for Idrici AI."""
from __future__ import annotations

import os
import re
import sqlite3
import time
import uuid
from pathlib import Path

MAX_MEMORY_CHARS = 1000
MAX_CONVERSATION_TITLE_CHARS = 80
MAX_CONVERSATION_MESSAGE_CHARS = 8000

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
            conn.execute(
                "CREATE TABLE IF NOT EXISTS conversations ("
                "id TEXT PRIMARY KEY,"
                "owner_id TEXT NOT NULL,"
                "title TEXT NOT NULL,"
                "created REAL NOT NULL,"
                "updated REAL NOT NULL)"
            )
            conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_conversations_owner_updated "
                "ON conversations(owner_id, updated DESC)"
            )
            conn.execute(
                "CREATE TABLE IF NOT EXISTS conversation_messages ("
                "id INTEGER PRIMARY KEY AUTOINCREMENT,"
                "conversation_id TEXT NOT NULL,"
                "role TEXT NOT NULL CHECK(role IN ('user', 'assistant')),"
                "content TEXT NOT NULL,"
                "created REAL NOT NULL,"
                "FOREIGN KEY(conversation_id) REFERENCES conversations(id) "
                "ON DELETE CASCADE)"
            )
            conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_conversation_messages_chat "
                "ON conversation_messages(conversation_id, id)"
            )

    def _conn(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.path)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON")
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
                if row:
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

    # ------------------------------------------------ conversations

    @staticmethod
    def _validate_owner_id(owner_id: str) -> str:
        owner_id = (owner_id or "").strip()
        if not owner_id or len(owner_id) > 128:
            raise ValueError("Invalid conversation owner")
        return owner_id

    @staticmethod
    def _validate_conversation_message(
        role: str, content: str
    ) -> tuple[str, str]:
        role = (role or "").strip().lower()
        content = (content or "").strip()
        if role not in {"user", "assistant"}:
            raise ValueError("Invalid conversation message role")
        if not content:
            raise ValueError("Conversation message cannot be empty")
        if len(content) > MAX_CONVERSATION_MESSAGE_CHARS:
            raise ValueError("Conversation message is too long")
        return role, content

    def create_conversation(
        self, owner_id: str, title: str = "محادثة جديدة"
    ) -> dict:
        owner_id = self._validate_owner_id(owner_id)
        title = (title or "محادثة جديدة").strip()[:MAX_CONVERSATION_TITLE_CHARS]
        if not title:
            title = "محادثة جديدة"
        conversation_id = uuid.uuid4().hex
        now = time.time()
        conn = self._conn()
        try:
            with conn:
                conn.execute(
                    "INSERT INTO conversations(id, owner_id, title, created, updated) "
                    "VALUES (?, ?, ?, ?, ?)",
                    (conversation_id, owner_id, title, now, now),
                )
        finally:
            conn.close()
        return self.get_conversation(owner_id, conversation_id)

    def list_conversations(self, owner_id: str, limit: int = 100) -> list[dict]:
        owner_id = self._validate_owner_id(owner_id)
        limit = max(1, min(int(limit), 200))
        conn = self._conn()
        try:
            rows = conn.execute(
                "SELECT c.id, c.title, c.created, c.updated, "
                "COUNT(m.id) AS message_count "
                "FROM conversations c LEFT JOIN conversation_messages m "
                "ON m.conversation_id = c.id "
                "WHERE c.owner_id = ? GROUP BY c.id "
                "ORDER BY c.updated DESC LIMIT ?",
                (owner_id, limit),
            ).fetchall()
        finally:
            conn.close()
        return [dict(row) for row in rows]

    def get_conversation(self, owner_id: str, conversation_id: str) -> dict | None:
        owner_id = self._validate_owner_id(owner_id)
        conn = self._conn()
        try:
            row = conn.execute(
                "SELECT id, title, created, updated FROM conversations "
                "WHERE id = ? AND owner_id = ?",
                (conversation_id, owner_id),
            ).fetchone()
        finally:
            conn.close()
        return dict(row) if row else None

    def list_conversation_messages(
        self, owner_id: str, conversation_id: str
    ) -> list[dict] | None:
        if self.get_conversation(owner_id, conversation_id) is None:
            return None
        conn = self._conn()
        try:
            rows = conn.execute(
                "SELECT id, role, content, created FROM conversation_messages "
                "WHERE conversation_id = ? ORDER BY id ASC",
                (conversation_id,),
            ).fetchall()
        finally:
            conn.close()
        return [dict(row) for row in rows]

    def add_conversation_message(
        self, owner_id: str, conversation_id: str, role: str, content: str
    ) -> dict | None:
        owner_id = self._validate_owner_id(owner_id)
        role, content = self._validate_conversation_message(role, content)
        now = time.time()
        conn = self._conn()
        try:
            with conn:
                conversation = conn.execute(
                    "SELECT title FROM conversations WHERE id = ? AND owner_id = ?",
                    (conversation_id, owner_id),
                ).fetchone()
                if conversation is None:
                    return None
                cur = conn.execute(
                    "INSERT INTO conversation_messages "
                    "(conversation_id, role, content, created) VALUES (?, ?, ?, ?)",
                    (conversation_id, role, content, now),
                )
                title = conversation["title"]
                if role == "user" and title == "محادثة جديدة":
                    clean_title = " ".join(content.split())[:MAX_CONVERSATION_TITLE_CHARS]
                    conn.execute(
                        "UPDATE conversations SET title = ?, updated = ? WHERE id = ?",
                        (clean_title or title, now, conversation_id),
                    )
                else:
                    conn.execute(
                        "UPDATE conversations SET updated = ? WHERE id = ?",
                        (now, conversation_id),
                    )
                message_id = cur.lastrowid
                row = conn.execute(
                    "SELECT id, role, content, created FROM conversation_messages "
                    "WHERE id = ?", (message_id,),
                ).fetchone()
        finally:
            conn.close()
        return dict(row)

    def delete_conversation(self, owner_id: str, conversation_id: str) -> bool:
        owner_id = self._validate_owner_id(owner_id)
        conn = self._conn()
        try:
            with conn:
                cur = conn.execute(
                    "DELETE FROM conversations WHERE id = ? AND owner_id = ?",
                    (conversation_id, owner_id),
                )
        finally:
            conn.close()
        return cur.rowcount > 0

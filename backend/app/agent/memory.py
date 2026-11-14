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

# Experiences and skills limits.
MAX_EXPERIENCE_TITLE_CHARS = 120
MAX_EXPERIENCE_CONTENT_CHARS = 4000
MAX_EXPERIENCE_OUTCOME_CHARS = 1000
MAX_SKILL_NAME_CHARS = 80
MAX_SKILL_DESCRIPTION_CHARS = 300
MAX_SKILL_CONTENT_CHARS = 4000

# verified: tested and confirmed | proposed: suggested, NOT verified
# failed: tried and failed       | useful: helpful information
EXPERIENCE_CATEGORIES = ("verified", "proposed", "failed", "useful")

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
            # --- experiences (new) ---
            conn.execute(
                "CREATE TABLE IF NOT EXISTS experiences ("
                "id INTEGER PRIMARY KEY AUTOINCREMENT,"
                "owner_id TEXT NOT NULL,"
                "title TEXT NOT NULL,"
                "content TEXT NOT NULL,"
                "category TEXT NOT NULL DEFAULT 'proposed' "
                "CHECK(category IN ('verified','proposed','failed','useful')),"
                "outcome TEXT NOT NULL DEFAULT '',"
                "conversation_id TEXT,"
                "created REAL NOT NULL,"
                "updated REAL NOT NULL,"
                "FOREIGN KEY(conversation_id) REFERENCES conversations(id) "
                "ON DELETE SET NULL)"
            )
            conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_experiences_owner_updated "
                "ON experiences(owner_id, updated DESC)"
            )
            # --- skills (new) ---
            conn.execute(
                "CREATE TABLE IF NOT EXISTS skills ("
                "id INTEGER PRIMARY KEY AUTOINCREMENT,"
                "owner_id TEXT NOT NULL,"
                "name TEXT NOT NULL,"
                "norm_name TEXT NOT NULL,"
                "description TEXT NOT NULL DEFAULT '',"
                "content TEXT NOT NULL DEFAULT '',"
                "created REAL NOT NULL,"
                "updated REAL NOT NULL,"
                "UNIQUE(owner_id, norm_name))"
            )
            conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_skills_owner_updated "
                "ON skills(owner_id, updated DESC)"
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

    def search_conversation_context(
        self,
        owner_id: str,
        query: str,
        exclude_conversation_id: str | None = None,
        limit: int = 5,
    ) -> list[dict]:
        """
        Search relevant messages from the owner's previous conversations.
        The current conversation can be excluded.
        Conversation content is returned as untrusted data.
        """
        owner_id = self._validate_owner_id(owner_id)
        wanted = tokens(query)

        if not wanted:
            return []

        limit = max(1, min(int(limit), 20))
        conn = self._conn()

        try:
            rows = conn.execute(
                """
                SELECT
                    c.id AS conversation_id,
                    c.title AS conversation_title,
                    m.id AS message_id,
                    m.role,
                    m.content,
                    m.created
                FROM conversation_messages AS m
                JOIN conversations AS c
                    ON c.id = m.conversation_id
                WHERE c.owner_id = ?
                  AND (? IS NULL OR c.id != ?)
                ORDER BY m.created DESC
                LIMIT 2000
                """,
                (
                    owner_id,
                    exclude_conversation_id,
                    exclude_conversation_id,
                ),
            ).fetchall()
        finally:
            conn.close()

        scored = []

        for row in rows:
            item = dict(row)
            content = item["content"]

            # Never retrieve messages that appear to contain secrets.
            if looks_secret(content):
                continue

            available = tokens(content)

            score = sum(
                1
                for word in wanted
                if any(
                    word == candidate
                    or (
                        len(word) >= 4
                        and len(candidate) >= 4
                        and (
                            candidate.startswith(word)
                            or word.startswith(candidate)
                        )
                    )
                    for candidate in available
                )
            )

            if score:
                scored.append((score, item["created"], item))

        scored.sort(
            key=lambda entry: (entry[0], entry[1]),
            reverse=True,
        )

        return [
            item
            for _, _, item in scored[:limit]
        ]

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

    # ------------------------------------------------ shared helpers (new)

    @staticmethod
    def _score_text(wanted: set[str], text: str) -> int:
        """Same token-matching rule used by the existing searches."""
        available = tokens(text)
        return sum(
            1
            for word in wanted
            if any(
                word == candidate
                or (
                    len(word) >= 4
                    and len(candidate) >= 4
                    and (
                        candidate.startswith(word)
                        or word.startswith(candidate)
                    )
                )
                for candidate in available
            )
        )

    @staticmethod
    def _clean_field(
        value: str, name: str, max_chars: int, required: bool = True
    ) -> str:
        value = (value or "").strip()
        if required and not value:
            raise ValueError(f"{name} cannot be empty")
        if len(value) > max_chars:
            raise ValueError(f"{name} is too long")
        if value and looks_secret(value):
            raise ValueError("Secrets are never stored in memory")
        return value

    # ------------------------------------------------ experiences (new)

    def add_experience(
        self,
        owner_id: str,
        title: str,
        content: str,
        category: str = "proposed",
        outcome: str = "",
        conversation_id: str | None = None,
    ) -> dict:
        """
        Store a reusable experience for one owner.
        Default category is 'proposed' (never assumed verified).
        If conversation_id is given, it must belong to the same owner.
        """
        owner_id = self._validate_owner_id(owner_id)
        title = self._clean_field(
            title, "Experience title", MAX_EXPERIENCE_TITLE_CHARS
        )
        content = self._clean_field(
            content, "Experience content", MAX_EXPERIENCE_CONTENT_CHARS
        )
        outcome = self._clean_field(
            outcome, "Experience outcome",
            MAX_EXPERIENCE_OUTCOME_CHARS, required=False,
        )
        category = (category or "").strip().lower()
        if category not in EXPERIENCE_CATEGORIES:
            raise ValueError("Invalid experience category")
        now = time.time()
        conn = self._conn()
        try:
            with conn:
                if conversation_id is not None:
                    owned = conn.execute(
                        "SELECT 1 FROM conversations "
                        "WHERE id = ? AND owner_id = ?",
                        (conversation_id, owner_id),
                    ).fetchone()
                    if owned is None:
                        raise ValueError(
                            "Conversation not found for this owner"
                        )
                new_id = conn.execute(
                    "INSERT INTO experiences (owner_id, title, content,"
                    " category, outcome, conversation_id, created, updated)"
                    " VALUES (?,?,?,?,?,?,?,?)",
                    (owner_id, title, content, category, outcome,
                     conversation_id, now, now),
                ).lastrowid
        finally:
            conn.close()
        return self.get_experience(owner_id, new_id)

    def get_experience(self, owner_id: str, experience_id: int) -> dict | None:
        owner_id = self._validate_owner_id(owner_id)
        conn = self._conn()
        try:
            row = conn.execute(
                "SELECT id, title, content, category, outcome,"
                " conversation_id, created, updated FROM experiences"
                " WHERE id = ? AND owner_id = ?",
                (experience_id, owner_id),
            ).fetchone()
        finally:
            conn.close()
        return dict(row) if row else None

    def update_experience_category(
        self,
        owner_id: str,
        experience_id: int,
        category: str,
        outcome: str | None = None,
    ) -> dict | None:
        """Promote/demote an experience (e.g. proposed -> verified)."""
        owner_id = self._validate_owner_id(owner_id)
        category = (category or "").strip().lower()
        if category not in EXPERIENCE_CATEGORIES:
            raise ValueError("Invalid experience category")
        if outcome is not None:
            outcome = self._clean_field(
                outcome, "Experience outcome",
                MAX_EXPERIENCE_OUTCOME_CHARS, required=False,
            )
        conn = self._conn()
        try:
            with conn:
                if outcome is None:
                    cur = conn.execute(
                        "UPDATE experiences SET category = ?, updated = ?"
                        " WHERE id = ? AND owner_id = ?",
                        (category, time.time(), experience_id, owner_id),
                    )
                else:
                    cur = conn.execute(
                        "UPDATE experiences SET category = ?, outcome = ?,"
                        " updated = ? WHERE id = ? AND owner_id = ?",
                        (category, outcome, time.time(),
                         experience_id, owner_id),
                    )
        finally:
            conn.close()
        return self.get_experience(owner_id, experience_id) if cur.rowcount else None

    def search_experiences(
        self,
        owner_id: str,
        query: str,
        category: str | None = None,
        limit: int = 5,
    ) -> list[dict]:
        """
        Search the owner's experiences. Results include 'category' so the
        caller can separate verified / proposed / failed / useful.
        Returned content is untrusted data, never instructions.
        """
        owner_id = self._validate_owner_id(owner_id)
        wanted = tokens(query)
        if not wanted:
            return []
        if category is not None:
            category = category.strip().lower()
            if category not in EXPERIENCE_CATEGORIES:
                raise ValueError("Invalid experience category")
        limit = max(1, min(int(limit), 20))
        conn = self._conn()
        try:
            if category is None:
                rows = conn.execute(
                    "SELECT id, title, content, category, outcome,"
                    " conversation_id, created, updated FROM experiences"
                    " WHERE owner_id = ? ORDER BY updated DESC LIMIT 2000",
                    (owner_id,),
                ).fetchall()
            else:
                rows = conn.execute(
                    "SELECT id, title, content, category, outcome,"
                    " conversation_id, created, updated FROM experiences"
                    " WHERE owner_id = ? AND category = ?"
                    " ORDER BY updated DESC LIMIT 2000",
                    (owner_id, category),
                ).fetchall()
        finally:
            conn.close()
        scored = []
        for row in rows:
            item = dict(row)
            text = f"{item['title']} {item['content']} {item['outcome']}"
            score = self._score_text(wanted, text)
            if score:
                scored.append((score, item["updated"], item))
        scored.sort(key=lambda entry: (entry[0], entry[1]), reverse=True)
        return [item for _, _, item in scored[:limit]]

    # ------------------------------------------------ skills (new)

    def add_skill(
        self,
        owner_id: str,
        name: str,
        description: str = "",
        content: str = "",
    ) -> dict:
        """Create a skill, or update it if the owner already has that name."""
        owner_id = self._validate_owner_id(owner_id)
        name = self._clean_field(name, "Skill name", MAX_SKILL_NAME_CHARS)
        description = self._clean_field(
            description, "Skill description",
            MAX_SKILL_DESCRIPTION_CHARS, required=False,
        )
        content = self._clean_field(
            content, "Skill content",
            MAX_SKILL_CONTENT_CHARS, required=False,
        )
        norm_name = normalize(" ".join(name.split()))
        now = time.time()
        conn = self._conn()
        try:
            with conn:
                row = conn.execute(
                    "SELECT id FROM skills WHERE owner_id = ? AND norm_name = ?",
                    (owner_id, norm_name),
                ).fetchone()
                if row:
                    conn.execute(
                        "UPDATE skills SET name = ?, description = ?,"
                        " content = ?, updated = ? WHERE id = ?",
                        (name, description, content, now, row["id"]),
                    )
                    skill_id = row["id"]
                else:
                    skill_id = conn.execute(
                        "INSERT INTO skills (owner_id, name, norm_name,"
                        " description, content, created, updated)"
                        " VALUES (?,?,?,?,?,?,?)",
                        (owner_id, name, norm_name, description,
                         content, now, now),
                    ).lastrowid
                out = conn.execute(
                    "SELECT id, name, description, content, created, updated"
                    " FROM skills WHERE id = ?", (skill_id,),
                ).fetchone()
        finally:
            conn.close()
        return dict(out)

    def list_skills(self, owner_id: str, limit: int = 100) -> list[dict]:
        owner_id = self._validate_owner_id(owner_id)
        limit = max(1, min(int(limit), 200))
        conn = self._conn()
        try:
            rows = conn.execute(
                "SELECT id, name, description, content, created, updated"
                " FROM skills WHERE owner_id = ?"
                " ORDER BY updated DESC LIMIT ?",
                (owner_id, limit),
            ).fetchall()
        finally:
            conn.close()
        return [dict(row) for row in rows]

    def search_skills(
        self, owner_id: str, query: str, limit: int = 5
    ) -> list[dict]:
        owner_id = self._validate_owner_id(owner_id)
        wanted = tokens(query)
        if not wanted:
            return []
        limit = max(1, min(int(limit), 20))
        scored = []
        for item in self.list_skills(owner_id, limit=200):
            text = f"{item['name']} {item['description']} {item['content']}"
            score = self._score_text(wanted, text)
            if score:
                scored.append((score, item["updated"], item))
        scored.sort(key=lambda entry: (entry[0], entry[1]), reverse=True)
        return [item for _, _, item in scored[:limit]]

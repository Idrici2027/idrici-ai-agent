"""Automatic learning: after a chat turn, keep what is worth remembering.

The model is asked to extract durable facts, preferences and lessons from
the exchange. Everything it returns is validated by MemoryStore (secrets are
rejected, sizes are limited). Auto-learned experiences are always stored as
'proposed' - never 'verified' - until the user promotes them.
"""
from __future__ import annotations

import json
import os

from app.agent.memory import MemoryStore, looks_secret
from app.models.model_provider import MockModelProvider

LEARN_PROMPT = """You are the memory curator of a personal AI assistant.
Read the exchange below and extract ONLY information worth keeping for
future conversations:
- "memories": durable facts the USER stated about themselves, their work,
  projects, preferences, or corrections they gave you. One short sentence
  each, in the user's language.
- "experiences": a concrete lesson from solving a problem (what was tried,
  what worked or failed). Use only when the exchange really contains one.

Rules:
- Use only what the user said. Never store claims the assistant made.
- Never store passwords, API keys, tokens or any secret.
- Do not store small talk, one-off questions or things that will go stale.
- If nothing is worth keeping, return empty lists.

Reply with exactly one JSON object and nothing else:
{"memories": ["..."],
 "experiences": [{"title": "...", "content": "...", "outcome": "..."}]}

EXCHANGE
User: <<<
%s
>>>
Assistant: <<<
%s
>>>"""

MAX_NEW_MEMORIES = 3
MAX_NEW_EXPERIENCES = 2
MIN_USER_CHARS = 12


def auto_learn_enabled() -> bool:
    return os.getenv("IDRICI_AUTO_LEARN", "1").strip().lower() not in {
        "0", "false", "off", "no",
    }


def parse_learning(text: str) -> dict:
    """Extract the first JSON object from a model reply; never raises."""
    start = (text or "").find("{")
    if start < 0:
        return {}
    try:
        obj, _ = json.JSONDecoder().raw_decode(text[start:])
    except ValueError:
        return {}
    return obj if isinstance(obj, dict) else {}


def apply_learning(
    store: MemoryStore,
    owner_id: str,
    data: dict,
    conversation_id: str | None = None,
) -> dict:
    """Validate and store extracted items. Returns what was saved."""
    saved = {"memories": 0, "experiences": 0}

    memories = data.get("memories")
    for item in (memories if isinstance(memories, list) else [])[:MAX_NEW_MEMORIES]:
        if not isinstance(item, str) or looks_secret(item):
            continue
        try:
            store.add(item, category="learned")
            saved["memories"] += 1
        except ValueError:
            continue

    experiences = data.get("experiences")
    for item in (experiences if isinstance(experiences, list) else [])[:MAX_NEW_EXPERIENCES]:
        if not isinstance(item, dict):
            continue
        try:
            store.add_experience(
                owner_id,
                str(item.get("title", "")),
                str(item.get("content", "")),
                category="proposed",  # never auto-verified
                outcome=str(item.get("outcome", "") or ""),
                conversation_id=conversation_id,
            )
            saved["experiences"] += 1
        except ValueError:
            continue
    return saved


async def learn_from_turn(
    provider,
    store: MemoryStore,
    owner_id: str,
    conversation_id: str | None,
    user_message: str,
    reply: str,
) -> dict:
    """Run after the reply was sent. Failures are swallowed on purpose:
    learning must never break a conversation."""
    if not auto_learn_enabled() or isinstance(provider, MockModelProvider):
        return {"memories": 0, "experiences": 0}
    if len((user_message or "").strip()) < MIN_USER_CHARS:
        return {"memories": 0, "experiences": 0}
    try:
        out = await provider.generate(messages=[{
            "role": "user",
            "content": LEARN_PROMPT % (user_message[:3000], reply[:3000]),
        }])
        return apply_learning(
            store, owner_id, parse_learning(out.get("text", "")),
            conversation_id,
        )
    except Exception as exc:  # noqa: BLE001
        print(f"AUTO-LEARN skipped: {type(exc).__name__}", flush=True)
        return {"memories": 0, "experiences": 0}

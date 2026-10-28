
import asyncio
import os
from typing import Any, Protocol

from google import genai


class ModelProvider(Protocol):
    """Common interface for interchangeable AI model providers."""

    async def generate(
        self,
        messages: list[dict[str, str]],
        tools: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any]:
        ...


class MockModelProvider:
    """Deterministic provider for development and tests."""

    async def generate(
        self,
        messages: list[dict[str, str]],
        tools: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any]:
        last_message = messages[-1]["content"] if messages else ""
        return {
            "text": f"Idrici mock response: {last_message}",
            "tool_calls": [],
            "provider": "mock",
        }


class GeminiModelProvider:
    """Google Gemini model provider."""

    def __init__(self) -> None:
        api_key = os.getenv("GEMINI_API_KEY")
        if not api_key:
            raise RuntimeError("GEMINI_API_KEY is not configured")

        self.client = genai.Client(api_key=api_key)
        self.model = os.getenv("GEMINI_MODEL", "gemini-3.8-flash")

    async def generate(
        self,
        messages: list[dict[str, str]],
        tools: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any]:
        identity_instruction = (
            "You are Idrici AI, an AI assistant created for the Idrici AI project. "
            "Your name is Idrici AI. "
            "If asked your name, clearly say: I am Idrici AI. "
            "If asked who you are, introduce yourself as Idrici AI. "
            "Answer in the user's language whenever possible. "
            "Be helpful, accurate, and clear. "
            "Never claim to have completed real-world actions unless you actually have."
        )

        conversation = "\n\n".join(
            f"{message.get('role', 'user')}: {message.get('content', '')}"
            for message in messages
        )

        prompt = f"{identity_instruction}\n\nConversation:\n{conversation}"

        response = await asyncio.to_thread(
            self.client.models.generate_content,
            model=self.model,
            contents=prompt,
        )

        return {
            "text": response.text or "I am Idrici AI, but I could not generate a response.",
            "tool_calls": [],
            "provider": "gemini",
        }

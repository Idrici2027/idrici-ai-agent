 
import asyncio
import json
import os
from typing import Any, Protocol
from urllib.error import HTTPError
from urllib.request import Request, urlopen

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


class GroqModelProvider:
    """Groq chat-completions provider."""

    def __init__(self) -> None:
        self.api_key = os.getenv("GROQ_API_KEY")
        if not self.api_key:
            raise RuntimeError("GROQ_API_KEY is not configured")

        self.model = os.getenv("GROQ_MODEL", "openai/gpt-oss-20b")
        self.api_url = "https://api.groq.com/openai/v1/chat/completions"

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

        api_messages = [
            {"role": "system", "content": identity_instruction}
        ]

        for message in messages:
            role = message.get("role", "user")
            if role not in {"system", "user", "assistant"}:
                role = "user"

            api_messages.append({
                "role": role,
                "content": message.get("content", ""),
            })

        payload = json.dumps({
            "model": self.model,
            "messages": api_messages,
            "temperature": 0.7,
        }).encode("utf-8")

        request = Request(
            self.api_url,
            data=payload,
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
                "User-Agent": "IdriciAI/1.0",
            },
            method="POST",
        )

        def send_request() -> dict[str, Any]:
            try:
                with urlopen(request, timeout=60) as response:
                    return json.loads(response.read().decode("utf-8"))
            except HTTPError as exc:
                error_body = exc.read().decode("utf-8", errors="replace")
                print(
                    f"Groq API error: HTTP {exc.code}: {error_body[:2000]}",
                    flush=True,
                )
                raise RuntimeError(
                    f"Groq API returned HTTP {exc.code}: {error_body[:2000]}"
                ) from exc

        response_data = await asyncio.to_thread(send_request)
        choices = response_data.get("choices", [])

        if not choices:
            raise RuntimeError("Groq returned no response choices")

        reply = choices[0].get("message", {}).get("content", "")

        return {
            "text": reply or "I am Idrici AI, but I could not generate a response.",
            "tool_calls": [],
            "provider": "groq",
        }


class GeminiModelProvider:
    """Google Gemini model provider retained as an alternative."""

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

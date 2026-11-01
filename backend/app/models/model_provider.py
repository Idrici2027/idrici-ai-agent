
import asyncio
import json
import os
from typing import Any, Protocol
from urllib.error import HTTPError
from urllib.request import Request, urlopen

IDENTITY_INSTRUCTION = (
    "You are Idrici AI, an AI assistant created for the Idrici AI project. "
    "Your name is Idrici AI. "
    "If asked your name, clearly say: I am Idrici AI. "
    "If asked who you are, introduce yourself as Idrici AI. "
    "Answer in the user's language whenever possible. "
    "Be helpful, accurate, and clear. "
    "Never claim to have completed real-world actions unless you actually have."
)

VISION_INSTRUCTION = (
    "The user attached a live photo taken just now by their phone's "
    "front camera, so you can see them. Use it naturally when it is "
    "relevant to their message (for example: what they are holding, "
    "pointing at, wearing, or doing). Describe only what is actually "
    "visible, never identify anyone from their face, and say so if the "
    "image is too dark or unclear."
)

FALLBACK_REPLY = "I am Idrici AI, but I could not generate a response."

# A message's content is either plain text or, when a camera frame is
# attached, an OpenAI-style list of parts:
#   [{"type": "text", "text": "..."},
#    {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,..."}}]
Content = str | list[dict[str, Any]]


def split_content(content: Any) -> tuple[str, str | None]:
    """Returns (text, base64 image or None) for a message's content."""
    if isinstance(content, str):
        return content, None

    texts: list[str] = []
    image: str | None = None

    for part in content or []:
        if part.get("type") == "text":
            texts.append(part.get("text", ""))

        elif part.get("type") == "image_url":
            url = (part.get("image_url") or {}).get("url", "")

            if url.startswith("data:") and "," in url:
                image = url.split(",", 1)[1]

    return "\n".join(texts), image


def has_image(messages: list[dict[str, Any]]) -> bool:
    return any(
        split_content(message.get("content", ""))[1] is not None
        for message in messages
    )


class ModelProvider(Protocol):
    """Common interface for interchangeable AI model providers."""

    async def generate(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any]:
        ...


class MockModelProvider:
    """Deterministic provider for development and tests."""

    async def generate(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any]:

        last_text, image = split_content(
            messages[-1]["content"] if messages else ""
        )

        suffix = " [image received]" if image else ""

        return {
            "text": f"Idrici mock response: {last_text}{suffix}",
            "tool_calls": [],
            "provider": "mock",
        }


class GroqModelProvider:
    """Groq chat-completions provider."""

    def __init__(self) -> None:
        self.api_key = os.getenv("GROQ_API_KEY")

        if not self.api_key:
            raise RuntimeError("GROQ_API_KEY is not configured")

        self.model = os.getenv(
            "GROQ_MODEL",
            "openai/gpt-oss-20b"
        )

        # Vision model supporting text and image inputs.
        # Can be overridden using GROQ_VISION_MODEL in Render.
        self.vision_model = os.getenv(
            "GROQ_VISION_MODEL",
            "qwen/qwen3.8-27b"
        )

        self.api_url = (
            "https://api.groq.com/openai/v1/chat/completions"
        )

    async def generate(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any]:

        with_image = has_image(messages)

        system_prompt = IDENTITY_INSTRUCTION

        if with_image:
            system_prompt = (
                f"{IDENTITY_INSTRUCTION} {VISION_INSTRUCTION}"
            )

        api_messages = [
            {
                "role": "system",
                "content": system_prompt
            }
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
            "model": (
                self.vision_model if with_image else self.model
            ),
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
                    return json.loads(
                        response.read().decode("utf-8")
                    )

            except HTTPError as exc:
                error_body = exc.read().decode(
                    "utf-8",
                    errors="replace"
                )

                print(
                    f"Groq API error: HTTP {exc.code}: "
                    f"{error_body[:2000]}",
                    flush=True,
                )

                raise RuntimeError(
                    f"Groq API returned HTTP {exc.code}: "
                    f"{error_body[:2000]}"
                ) from exc

        response_data = await asyncio.to_thread(send_request)

        choices = response_data.get("choices", [])

        if not choices:
            raise RuntimeError(
                "Groq returned no response choices"
            )

        reply = (
            choices[0].get("message", {}).get("content") or ""
        )

        return {
            "text": reply or FALLBACK_REPLY,
            "tool_calls": [],
            "provider": "groq",
        }


class GeminiModelProvider:
    """Google Gemini model provider retained as an alternative.

    The google-genai package is imported only when this provider is
    created, so the Groq provider keeps working even if the package
    is not installed.
    """

    def __init__(self) -> None:
        api_key = os.getenv("GEMINI_API_KEY")

        if not api_key:
            raise RuntimeError(
                "GEMINI_API_KEY is not configured"
            )

        try:
            from google import genai

        except ImportError as exc:
            raise RuntimeError(
                "google-genai is not installed. "
                "Run: pip install google-genai"
            ) from exc

        self.client = genai.Client(api_key=api_key)

        self.model = os.getenv(
            "GEMINI_MODEL",
            "gemini-3.8-flash"
        )

    async def generate(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any]:

        lines: list[str] = []
        image_b64: str | None = None

        for message in messages:
            text, image = split_content(
                message.get("content", "")
            )

            image_b64 = image or image_b64

            lines.append(
                f"{message.get('role', 'user')}: {text}"
            )

        instruction = IDENTITY_INSTRUCTION

        if image_b64:
            instruction = (
                f"{IDENTITY_INSTRUCTION} {VISION_INSTRUCTION}"
            )

        prompt = (
            f"{instruction}\n\nConversation:\n"
            + "\n\n".join(lines)
        )

        contents: Any = prompt

        if image_b64:
            import base64

            from google.genai import types

            contents = [
                prompt,
                types.Part.from_bytes(
                    data=base64.b64decode(image_b64),
                    mime_type="image/jpeg",
                ),
            ]

        response = await asyncio.to_thread(
            self.client.models.generate_content,
            model=self.model,
            contents=contents,
        )

        return {
            "text": response.text or FALLBACK_REPLY,
            "tool_calls": [],
            "provider": "gemini",
        }

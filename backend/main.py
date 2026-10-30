
import importlib.util
from pathlib import Path
from typing import Any, Callable, Literal

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field, field_validator

app = FastAPI(title="Idrici AI API")

provider_path = (
    Path(__file__).parent
    / "app"
    / "models"
    / "model_provider.py"
)

spec = importlib.util.spec_from_file_location(
    "idrici_model_provider",
    provider_path,
)

if spec is None or spec.loader is None:
    raise RuntimeError("Could not load the AI provider module")

provider_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provider_module)

GroqModelProvider = provider_module.GroqModelProvider

# يسمح باستبدال Groq بمزوّد تجريبي أثناء الاختبارات.
provider_factory: Callable[[], Any] = GroqModelProvider


class ChatMessage(BaseModel):
    role: Literal["user", "assistant"]
    content: str = Field(min_length=1, max_length=4000)

    @field_validator("content")
    @classmethod
    def validate_content(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("Message content cannot be empty")
        return value


class ChatRequest(BaseModel):
    message: str = Field(min_length=1, max_length=4000)
    history: list[ChatMessage] = Field(
        default_factory=list,
        max_length=12,
    )

    @field_validator("message")
    @classmethod
    def validate_message(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("Message cannot be empty")
        return value


@app.get("/")
async def root():
    return {
        "status": "ok",
        "app": "Idrici AI",
    }


@app.post("/chat")
async def chat(request: ChatRequest):
    try:
        provider = provider_factory()

        messages = [
            {
                "role": item.role,
                "content": item.content,
            }
            for item in request.history
        ]

        # يضاف السؤال الحالي مرة واحدة فقط.
        messages.append({
            "role": "user",
            "content": request.message,
        })

        result = await provider.generate(messages=messages)

        if not isinstance(result, dict):
            raise RuntimeError("Invalid AI provider response")

        reply = result.get("text", "")

        if not isinstance(reply, str) or not reply.strip():
            raise RuntimeError(
                "The AI provider returned an empty response"
            )

        return {
            "reply": reply.strip(),
            "provider": result.get("provider", "unknown"),
        }

    except Exception as exc:
        print(
            f"AI REQUEST ERROR: {type(exc).__name__}: {exc}",
            flush=True,
        )

        raise HTTPException(
            status_code=500,
            detail="AI request failed. Check server logs.",
        ) from None

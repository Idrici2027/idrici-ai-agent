import sys
from pathlib import Path
from typing import Literal

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

# Make the `app` package importable no matter where the server is started
# from (e.g. `uvicorn main:app` inside backend/, or `backend.main:app`).
sys.path.insert(0, str(Path(__file__).resolve().parent))

from app.models.model_provider import GroqModelProvider  # noqa: E402

MAX_MESSAGE_CHARS = 8000
MAX_HISTORY_MESSAGES = 20

app = FastAPI(title="Idrici AI API")


class HistoryMessage(BaseModel):
    role: Literal["user", "assistant"]
    content: str = Field(max_length=MAX_MESSAGE_CHARS)


class ChatRequest(BaseModel):
    message: str = Field(max_length=MAX_MESSAGE_CHARS)
    # Previous turns of the conversation, oldest first. Optional, so older
    # app versions that send only `message` keep working.
    history: list[HistoryMessage] = Field(default_factory=list)


@app.get("/")
async def root():
    return {
        "status": "ok",
        "app": "Idrici AI",
    }


@app.post("/chat")
async def chat(request: ChatRequest):
    if not request.message.strip():
        raise HTTPException(
            status_code=400,
            detail="Message cannot be empty",
        )

    messages = [
        {"role": item.role, "content": item.content}
        for item in request.history[-MAX_HISTORY_MESSAGES:]
    ]
    messages.append({"role": "user", "content": request.message})

    try:
        provider = GroqModelProvider()
        result = await provider.generate(messages=messages)

        return {
            "reply": result["text"],
            "provider": result["provider"],
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

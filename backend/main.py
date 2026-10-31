import base64
import binascii
import sys
from pathlib import Path
from typing import Any, Literal

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

# Make the `app` package importable no matter where the server is started
# from (e.g. `uvicorn main:app` inside backend/, or `backend.main:app`).
sys.path.insert(0, str(Path(__file__).resolve().parent))

from app.models.model_provider import GroqModelProvider  # noqa: E402

MAX_MESSAGE_CHARS = 8000
MAX_HISTORY_MESSAGES = 20
# Base64 characters. The app sends a ~512 px JPEG (about 100 KB), so this
# leaves plenty of room while still rejecting abuse.
MAX_IMAGE_CHARS = 1_500_000

app = FastAPI(title="Idrici AI API")


class HistoryMessage(BaseModel):
    role: Literal["user", "assistant"]
    content: str = Field(max_length=MAX_MESSAGE_CHARS)


class ChatRequest(BaseModel):
    message: str = Field(max_length=MAX_MESSAGE_CHARS)
    # Previous turns of the conversation, oldest first. Optional, so older
    # app versions that send only `message` keep working.
    history: list[HistoryMessage] = Field(default_factory=list)
    # Optional still frame from the phone's front camera: a base64 JPEG
    # (with or without a "data:image/jpeg;base64," prefix). Only the
    # current turn carries an image; it is never stored.
    image: str | None = Field(default=None, max_length=MAX_IMAGE_CHARS)


def clean_image(raw: str | None) -> str | None:
    """Validates the camera frame and returns bare base64, or None."""
    if not raw or not raw.strip():
        return None

    image = raw.strip()
    if image.startswith("data:"):
        image = image.split(",", 1)[-1]

    try:
        data = base64.b64decode(image, validate=True)
    except (binascii.Error, ValueError):
        raise HTTPException(
            status_code=400,
            detail="Image is not valid base64",
        ) from None

    if not data.startswith(b"\xff\xd8"):
        raise HTTPException(
            status_code=400,
            detail="Image must be a JPEG",
        )

    return image


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

    image = clean_image(request.image)

    messages: list[dict[str, Any]] = [
        {"role": item.role, "content": item.content}
        for item in request.history[-MAX_HISTORY_MESSAGES:]
    ]

    if image:
        user_content: Any = [
            {"type": "text", "text": request.message},
            {
                "type": "image_url",
                "image_url": {"url": f"data:image/jpeg;base64,{image}"},
            },
        ]
    else:
        user_content = request.message

    messages.append({"role": "user", "content": user_content})

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

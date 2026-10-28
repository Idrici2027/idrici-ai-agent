
import importlib.util
from pathlib import Path

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI(title="Idrici AI API")

provider_path = (
    Path(__file__).parent
    / "app"
    / "Models"
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

GeminiModelProvider = provider_module.GeminiModelProvider


class ChatRequest(BaseModel):
    message: str


@app.get("/")
async def root():
    return {"status": "ok", "app": "Idrici AI"}


@app.post("/chat")
async def chat(request: ChatRequest):
    if not request.message.strip():
        raise HTTPException(
            status_code=400,
            detail="Message cannot be empty",
        )

    try:
        provider = GeminiModelProvider()
        result = await provider.generate(
            messages=[
                {"role": "user", "content": request.message}
            ]
        )
        return {
            "reply": result["text"],
            "provider": result["provider"],
        }
    except Exception:
        raise HTTPException(
            status_code=500,
            detail="AI request failed. Check server configuration.",
        )

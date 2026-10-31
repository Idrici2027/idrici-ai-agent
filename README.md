# Idrici AI

Independent AI agent for software engineering, with a voice-enabled
holographic avatar.

## Vision
A modular, extensible AI agent with an independent core.

## Principles
- Provider-independent model interface
- Explicit tool permissions
- Automated tests
- Security by design
- Low-cost development

## Structure

```
backend/                 FastAPI server (POST /chat, keeps conversation history)
  app/models/            model providers (Groq, Gemini, Mock)
  app/agent/             agent core
android_app/
  assets/avatar/         avatar.html - 3D hologram (Three.js) shown in a WebView
  lib/main.dart          app entry
  lib/home_screen.dart   screen + conversation loop (idle/listening/thinking/speaking)
  lib/voice_service.dart speech to text + text to speech
  lib/avatar_view.dart   Flutter <-> avatar page bridge
  lib/chat_api.dart      HTTP client for the backend
```

## Avatar API (avatar.html)

| Call | Effect |
| --- | --- |
| `avatar.setState('idle' \| 'listening' \| 'thinking' \| 'speaking')` | ears, eyes, mouth, colour |
| `avatar.setLevel(0..1)` | microphone loudness (ears react while listening) |
| `avatar.lookAt(x, y)` | head follows a point, -1..1 (touch today, hand tracking next) |

## Roadmap

1. Text chat with memory - done
2. Voice in/out + 3D avatar with states - done (needs testing on a phone)
3. Camera + hand tracking so the head follows the hand - next
4. Personality and richer expressions

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
  assets/avatar/         avatar.html - 3D luminous humanoid (Three.js) shown in a WebView
  lib/main.dart          app entry
  lib/home_screen.dart   screen + conversation loop (idle/listening/thinking/speaking)
  lib/voice_service.dart speech to text + text to speech
  lib/avatar_view.dart   Flutter <-> avatar page bridge
  lib/chat_api.dart      HTTP client for the backend
```

## Avatar API (avatar.html)

| Call | Effect |
| --- | --- |
| `avatar.setState('idle' \| 'listening' \| 'thinking' \| 'speaking')` | eyes, mouth, hair light, colour |
| `avatar.setLevel(0..1)` | microphone loudness (the figure glows with your voice while listening) |
| `avatar.lookAt(x, y)` | head follows a point, -1..1 (touch today, hand tracking next) |

## Roadmap

1. Text chat with memory - done
2. Voice in/out + 3D avatar with states - done (needs testing on a phone)
3. Camera + hand tracking so the head follows the hand - next
4. Personality and richer expressions

## Backend capabilities (honest status)

| Feature | Status |
| --- | --- |
| Persistent memory (SQLite, explicit "تذكر/remember", inspect/edit/delete, secrets rejected) | IMPLEMENTED AND TESTED (store); endpoints IMPLEMENTED BUT NOT VERIFIED |
| Agent executor (plan/act/observe, approval for every write, retry, loop guard, redaction) | IMPLEMENTED AND TESTED with mocks |
| GitHub tools (list/read/search/branch/commit/PR/run tests) | IMPLEMENTED BUT NOT VERIFIED against the real API |
| Render tools (services/deploys/logs/health/deploy) | IMPLEMENTED BUT NOT VERIFIED against the real API |
| API key, provider choice, voice vs typed input | IMPLEMENTED BUT NOT VERIFIED (no FastAPI in the build sandbox) |
| OAuth flows, Google/email/calendar/cloud/design integrations | NOT IMPLEMENTED |
| Semantic (embedding) memory search | NOT IMPLEMENTED (keyword search only) |
| Document creation, file organisation, web research tools | NOT IMPLEMENTED |
| Avatar animation/lip-sync upgrades | NOT IMPLEMENTED |
| Android 8.1 install test, Flutter build | NOT VERIFIED |

## Environment variables

`IDRICI_API_KEY` (shared secret, header `X-API-Key`), `IDRICI_PROVIDER`
(groq|gemini|mock), `GROQ_API_KEY`, `GEMINI_API_KEY`, `GITHUB_TOKEN`,
`RENDER_API_KEY`, `IDRICI_DB_PATH`, `IDRICI_GITHUB_WRITE_REPOS`
(default `Idrici2027/idrici-ai-agent`), `IDRICI_PROTECTED_BRANCHES`
(`main` and `master` are always protected).

## Endpoints

`POST /chat` · `GET/POST /memories`, `PUT/DELETE /memories/{id}` ·
`GET /integrations` · `POST /agent` (starts a task) ·
`POST /agent/{id}/confirm` `{"approve": true|false}` · `GET /agent/{id}`.
Every write (commit, branch, PR, deploy, tests) is only prepared and runs
after `confirm`.

## Deploy

1. Render: set the variables above, start command `uvicorn main:app --host 0.0.0.0 --port $PORT` inside `backend/`.
2. Add a Render persistent disk and set `IDRICI_DB_PATH` to a path on it, otherwise memory is lost on redeploy.
3. GitHub: add secret `IDRICI_API_KEY`; the `Build Android` workflow builds the APK artifact.
4. Run tests: `pip install -e .[dev] && python -m pytest`.

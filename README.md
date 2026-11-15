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
| Long-term recall in /chat (memories + earlier conversations + experiences + skills injected as untrusted data) | IMPLEMENTED AND TESTED (store level); /chat wiring NOT VERIFIED (no FastAPI in the build sandbox) |
| Auto-learning after each reply (facts -> memories 'learned', lessons -> experiences 'proposed', secrets rejected, set `IDRICI_AUTO_LEARN=0` to disable) | IMPLEMENTED AND TESTED with a fake model; NOT VERIFIED with the real model |
| Side panel with all conversations (rename/delete) + agent-memory sheet in the app | IMPLEMENTED, NOT COMPILED (no Flutter SDK in the build sandbox) |
| Conversations survive a server wipe: the app keeps a copy on the phone and restores it to the server (`GET /backup`, `POST /restore`) | IMPLEMENTED; store logic TESTED, endpoints and app NOT VERIFIED here |
| New chats know about earlier chats (index of titles always; excerpts when the user asks about them) | IMPLEMENTED AND TESTED (store level) |
| Semantic (embedding) memory search | NOT IMPLEMENTED (keyword search only, Arabic "ال" aware) |
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

`POST /chat` · `GET/POST/PATCH/DELETE /conversations` · `GET/DELETE /experiences` · `GET/POST/DELETE /skills` · `GET/POST /memories`, `PUT/DELETE /memories/{id}` ·
`GET /integrations` · `POST /agent` (starts a task) ·
`POST /agent/{id}/confirm` `{"approve": true|false}` · `GET /agent/{id}`.
Every write (commit, branch, PR, deploy, tests) is only prepared and runs
after `confirm`.

## Deploy

1. Render: set the variables above, start command `uvicorn main:app --host 0.0.0.0 --port $PORT` inside `backend/`.
2. Render's disk is erased on every restart/deploy (and when a free service sleeps). The app now restores your data from the phone's copy, but for a server that keeps its own data add a Render persistent disk (paid) and set `IDRICI_DB_PATH` to a path on it, e.g. `/var/data/idrici.db`. The startup log prints `STORAGE: <path> holds N conversations`.
3. GitHub: add secret `IDRICI_API_KEY`; the `Build Android` workflow builds the APK artifact.
4. Run tests: `pip install -e .[dev] && python -m pytest`.

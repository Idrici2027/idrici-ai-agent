"""External service clients (GitHub, Render) using only the standard library.

Credentials come from environment variables (GITHUB_TOKEN, RENDER_API_KEY),
i.e. the hosting platform's secret store. They are never written to the
database, to memory, or to logs. OAuth flows are NOT implemented.
"""
from __future__ import annotations

import asyncio
import base64
import json
import os
import re
from typing import Any, Awaitable, Callable
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen

SECRET_ENV_VARS = ("GITHUB_TOKEN", "RENDER_API_KEY", "GROQ_API_KEY",
                   "GEMINI_API_KEY", "IDRICI_API_KEY")
_TOKEN_PATTERN = re.compile(
    r"(gsk_\w+|ghp_\w+|github_pat_\w+|rnd_\w+|sk-\w+|AIza[\w-]+"
    r"|Bearer\s+[\w.\-]+)")
MAX_TEXT = 20000


def redact(text: str) -> str:
    """Removes configured secrets and token-looking strings from text."""
    text = str(text)
    for name in SECRET_ENV_VARS:
        value = os.getenv(name)
        if value and len(value) >= 6:
            text = text.replace(value, "[REDACTED]")
    return _TOKEN_PATTERN.sub("[REDACTED]", text)


class IntegrationError(Exception):
    def __init__(self, message: str, status: int | None = None) -> None:
        super().__init__(redact(message))
        self.status = status

    @property
    def transient(self) -> bool:
        return self.status is None or self.status >= 500 or self.status == 429


HttpFn = Callable[..., Awaitable[Any]]


async def http_json(method: str, url: str, headers: dict | None = None,
                    body: Any = None, timeout: int = 30) -> Any:
    data = json.dumps(body).encode() if body is not None else None
    req = Request(url, data=data, method=method, headers={
        "User-Agent": "IdriciAI/1.0", "Content-Type": "application/json",
        **(headers or {})})

    def send() -> Any:
        try:
            with urlopen(req, timeout=timeout) as resp:
                raw = resp.read().decode("utf-8", errors="replace")
                try:
                    return json.loads(raw) if raw else {}
                except ValueError:
                    return raw
        except HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")[:500]
            raise IntegrationError(f"HTTP {exc.code}: {detail}", exc.code)
        except (URLError, TimeoutError, OSError) as exc:
            raise IntegrationError(f"Network error: {exc}") from None

    return await asyncio.to_thread(send)


_REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
_BRANCH = re.compile(r"^[A-Za-z0-9._/-]{1,100}$")


def _csv_env(name: str, default: str) -> set[str]:
    return {x.strip() for x in os.getenv(name, default).split(",") if x.strip()}


def _check_repo(repo: str) -> str:
    if not _REPO.match(repo or ""):
        raise IntegrationError("Repository must look like owner/name")
    return repo


def _check_branch(branch: str) -> str:
    if (not _BRANCH.match(branch or "") or ".." in branch
            or branch.startswith("/") or branch.endswith("/")):
        raise IntegrationError("Invalid branch name")
    return branch


def _check_path(path: str) -> str:
    path = (path or "").strip("/")
    if ".." in path.split("/") or "\\" in path:
        raise IntegrationError("Invalid file path")
    return path


class GitHubClient:
    API = "https://api.github.com"

    def __init__(self, token: str | None = None, http: HttpFn = http_json):
        self.token = token if token is not None else os.getenv("GITHUB_TOKEN")
        self.http = http

    @property
    def configured(self) -> bool:
        return bool(self.token)

    @staticmethod
    def protected_branches() -> set[str]:
        return {"main", "master"} | _csv_env("IDRICI_PROTECTED_BRANCHES", "")

    @staticmethod
    def writable_repos() -> set[str]:
        return _csv_env("IDRICI_GITHUB_WRITE_REPOS",
                        "Idrici2027/idrici-ai-agent")

    def _write_guard(self, repo: str, branch: str) -> None:
        if repo not in self.writable_repos():
            raise IntegrationError(f"Writes to {repo} are not allowed")
        if branch in self.protected_branches():
            raise IntegrationError(
                f"Branch '{branch}' is protected; use a development branch")

    async def _call(self, method: str, path: str, body: Any = None) -> Any:
        if not self.token:
            raise IntegrationError("GitHub is not connected (GITHUB_TOKEN)")
        return await self.http(method, f"{self.API}{path}", headers={
            "Authorization": f"Bearer {self.token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"}, body=body)

    async def list_repos(self) -> list[dict]:
        data = await self._call("GET", "/user/repos?per_page=30&sort=updated")
        return [{"full_name": r["full_name"], "private": r["private"],
                 "default_branch": r["default_branch"]} for r in data]

    async def list_branches(self, repo: str) -> list[str]:
        data = await self._call(
            "GET", f"/repos/{_check_repo(repo)}/branches?per_page=100")
        return [b["name"] for b in data]

    async def list_files(self, repo: str, path: str = "",
                         ref: str | None = None) -> list[dict]:
        q = f"?ref={quote(_check_branch(ref))}" if ref else ""
        data = await self._call(
            "GET", f"/repos/{_check_repo(repo)}/contents/"
                   f"{quote(_check_path(path))}{q}")
        if isinstance(data, dict):
            data = [data]
        return [{"name": f["name"], "path": f["path"], "type": f["type"],
                 "size": f.get("size", 0)} for f in data]

    async def read_file(self, repo: str, path: str,
                        ref: str | None = None) -> str:
        q = f"?ref={quote(_check_branch(ref))}" if ref else ""
        data = await self._call(
            "GET", f"/repos/{_check_repo(repo)}/contents/"
                   f"{quote(_check_path(path))}{q}")
        if not isinstance(data, dict) or data.get("type") != "file":
            raise IntegrationError("Path is not a file")
        text = base64.b64decode(data.get("content", "")).decode(
            "utf-8", errors="replace")
        return text[:MAX_TEXT]

    async def search_code(self, repo: str, query: str) -> list[dict]:
        q = urlencode({"q": f"{query} repo:{_check_repo(repo)}"})
        data = await self._call("GET", f"/search/code?{q}&per_page=15")
        return [{"path": i["path"]} for i in data.get("items", [])]

    async def create_branch(self, repo: str, name: str,
                            from_branch: str) -> dict:
        repo, name = _check_repo(repo), _check_branch(name)
        self._write_guard(repo, name)
        ref = await self._call(
            "GET", f"/repos/{repo}/git/ref/heads/"
                   f"{quote(_check_branch(from_branch), safe='/')}")
        await self._call("POST", f"/repos/{repo}/git/refs", {
            "ref": f"refs/heads/{name}", "sha": ref["object"]["sha"]})
        return {"branch": name, "from": from_branch}

    async def commit_file(self, repo: str, branch: str, path: str,
                          content: str, message: str) -> dict:
        repo, branch = _check_repo(repo), _check_branch(branch)
        path = _check_path(path)
        self._write_guard(repo, branch)
        body: dict[str, Any] = {
            "message": message[:200], "branch": branch,
            "content": base64.b64encode(content.encode()).decode()}
        try:
            current = await self._call(
                "GET", f"/repos/{repo}/contents/{quote(path)}"
                       f"?ref={quote(branch, safe='/')}")
            body["sha"] = current["sha"]
        except IntegrationError as exc:
            if exc.status != 404:
                raise
        res = await self._call(
            "PUT", f"/repos/{repo}/contents/{quote(path)}", body)
        return {"path": path, "branch": branch,
                "commit": res.get("commit", {}).get("sha")}

    async def create_pull_request(self, repo: str, head: str, base: str,
                                  title: str, body: str = "") -> dict:
        repo = _check_repo(repo)
        self._write_guard(repo, _check_branch(head))
        res = await self._call("POST", f"/repos/{repo}/pulls", {
            "head": head, "base": _check_branch(base),
            "title": title[:200], "body": body[:5000]})
        return {"number": res.get("number"), "url": res.get("html_url")}

    async def run_tests(self, repo: str, branch: str,
                        workflow: str = "tests.yml") -> dict:
        repo, branch = _check_repo(repo), _check_branch(branch)
        self._write_guard(repo, branch)
        await self._call(
            "POST", f"/repos/{repo}/actions/workflows/"
                    f"{quote(workflow)}/dispatches", {"ref": branch})
        return {"dispatched": workflow, "branch": branch}

    async def workflow_runs(self, repo: str, branch: str) -> list[dict]:
        data = await self._call(
            "GET", f"/repos/{_check_repo(repo)}/actions/runs?branch="
                   f"{quote(_check_branch(branch), safe='/')}&per_page=5")
        return [{"name": r["name"], "status": r["status"],
                 "conclusion": r["conclusion"], "sha": r["head_sha"][:7]}
                for r in data.get("workflow_runs", [])]


class RenderClient:
    API = "https://api.render.com/v1"

    def __init__(self, key: str | None = None, http: HttpFn = http_json):
        self.key = key if key is not None else os.getenv("RENDER_API_KEY")
        self.http = http

    @property
    def configured(self) -> bool:
        return bool(self.key)

    async def _call(self, method: str, path: str, body: Any = None) -> Any:
        if not self.key:
            raise IntegrationError("Render is not connected (RENDER_API_KEY)")
        return await self.http(method, f"{self.API}{path}", headers={
            "Authorization": f"Bearer {self.key}",
            "Accept": "application/json"}, body=body)

    @staticmethod
    def _id(service_id: str) -> str:
        if not re.match(r"^[A-Za-z0-9_-]{3,60}$", service_id or ""):
            raise IntegrationError("Invalid service id")
        return service_id

    async def list_services(self) -> list[dict]:
        data = await self._call("GET", "/services?limit=20")
        out = []
        for item in data:
            s = item.get("service", item)
            out.append({"id": s.get("id"), "name": s.get("name"),
                        "type": s.get("type"),
                        "url": (s.get("serviceDetails") or {}).get("url")})
        return out

    async def deploys(self, service_id: str) -> list[dict]:
        data = await self._call(
            "GET", f"/services/{self._id(service_id)}/deploys?limit=5")
        out = []
        for item in data:
            d = item.get("deploy", item)
            out.append({"id": d.get("id"), "status": d.get("status"),
                        "commit": (d.get("commit") or {}).get("id", "")[:7],
                        "finishedAt": d.get("finishedAt")})
        return out

    async def deploy(self, service_id: str) -> dict:
        d = await self._call(
            "POST", f"/services/{self._id(service_id)}/deploys",
            {"clearCache": "do_not_clear"})
        return {"deploy_id": d.get("id"), "status": d.get("status"),
                "note": "Submitted only; check deploy status to verify."}

    async def logs(self, service_id: str, kind: str = "app") -> list[str]:
        svc = await self._call("GET", f"/services/{self._id(service_id)}")
        owner = svc.get("ownerId")
        if kind not in ("app", "build"):
            raise IntegrationError("kind must be 'app' or 'build'")
        q = urlencode({"ownerId": owner, "resource": service_id,
                       "type": kind, "limit": 100})
        data = await self._call("GET", f"/logs?{q}")
        return [redact(l.get("message", ""))[:300]
                for l in data.get("logs", [])][-60:]

    async def verify_health(self, service_id: str) -> dict:
        svc = await self._call("GET", f"/services/{self._id(service_id)}")
        url = (svc.get("serviceDetails") or {}).get("url")
        if not url:
            raise IntegrationError("Service has no public URL")
        try:
            body = await self.http("GET", url)
        except IntegrationError as exc:
            return {"url": url, "healthy": False, "error": str(exc)}
        return {"url": url, "healthy": True, "response": str(body)[:200]}

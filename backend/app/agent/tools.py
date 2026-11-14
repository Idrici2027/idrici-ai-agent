"""Tool registry: every capability the agent can use is declared here.

Levels: "read" runs immediately; "execute" changes something outside the
app, so it is only prepared and waits for the user's explicit approval.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Awaitable, Callable

from app.agent.integrations import GitHubClient, RenderClient
from app.agent.memory import MemoryStore

READ = "read"
EXECUTE = "execute"


@dataclass
class Tool:
    name: str
    description: str
    params: dict[str, str]
    level: str
    handler: Callable[..., Awaitable[Any]]

    @property
    def needs_confirmation(self) -> bool:
        return self.level != READ


class ToolRegistry:
    def __init__(self) -> None:
        self._tools: dict[str, Tool] = {}

    def register(self, tool: Tool) -> None:
        self._tools[tool.name] = tool

    def get(self, name: str) -> Tool | None:
        return self._tools.get(name)

    def names(self) -> list[str]:
        return list(self._tools)

    def describe(self) -> str:
        lines = []
        for t in self._tools.values():
            tag = " [needs user approval]" if t.needs_confirmation else ""
            lines.append(f"- {t.name}({', '.join(t.params)}): "
                         f"{t.description}{tag}")
        return "\n".join(lines)


def build_registry(github: GitHubClient | None = None,
                   render: RenderClient | None = None,
                   store: MemoryStore | None = None) -> ToolRegistry:
    """Registers tools only for integrations that are actually connected."""
    github = github or GitHubClient()
    render = render or RenderClient()
    reg = ToolRegistry()

    def add(name, desc, params, level, fn):
        reg.register(Tool(name, desc, params, level, fn))

    if store is not None:
        async def mem_search(query: str):
            return store.search(query)
        add("memory_search", "Search the user's saved memories.",
            {"query": "text"}, READ, mem_search)

    if github.configured:
        add("github_list_repos", "List repositories the token can see.",
            {}, READ, lambda: github.list_repos())
        add("github_list_branches", "List branches.",
            {"repo": "owner/name"}, READ, github.list_branches)
        add("github_list_files", "List files in a directory.",
            {"repo": "owner/name", "path": "dir or empty", "ref": "branch"},
            READ, github.list_files)
        add("github_read_file", "Read a text file.",
            {"repo": "owner/name", "path": "file", "ref": "branch"},
            READ, github.read_file)
        add("github_search_code", "Search code in a repo.",
            {"repo": "owner/name", "query": "text"}, READ,
            github.search_code)
        add("github_workflow_runs", "Show recent CI runs for a branch.",
            {"repo": "owner/name", "branch": "branch"}, READ,
            github.workflow_runs)
        add("github_create_branch", "Create a development branch.",
            {"repo": "owner/name", "name": "new branch",
             "from_branch": "source branch"}, EXECUTE, github.create_branch)
        add("github_commit_file",
            "Create or replace ONE file with a commit on a non-protected "
            "branch.", {"repo": "owner/name", "branch": "branch",
                        "path": "file", "content": "full new text",
                        "message": "commit message"},
            EXECUTE, github.commit_file)
        add("github_create_pr", "Open a pull request.",
            {"repo": "owner/name", "head": "branch", "base": "branch",
             "title": "text", "body": "text"}, EXECUTE,
            github.create_pull_request)
        add("github_run_tests", "Trigger the tests workflow on a branch.",
            {"repo": "owner/name", "branch": "branch"}, EXECUTE,
            github.run_tests)

    if render.configured:
        add("render_list_services", "List Render services.", {}, READ,
            lambda: render.list_services())
        add("render_deploy_status", "Recent deploys of a service.",
            {"service_id": "srv-..."}, READ, render.deploys)
        add("render_logs", "Recent logs (kind: app or build).",
            {"service_id": "srv-...", "kind": "app|build"}, READ,
            render.logs)
        add("render_verify_health", "Request the service URL and report.",
            {"service_id": "srv-..."}, READ, render.verify_health)
        add("render_deploy", "Start a new deploy of a service.",
            {"service_id": "srv-..."}, EXECUTE, render.deploy)

    return reg


def integration_status(github: GitHubClient | None = None,
                       render: RenderClient | None = None) -> dict:
    github = github or GitHubClient()
    render = render or RenderClient()
    return {"github": {"connected": github.configured,
                       "needs": "GITHUB_TOKEN"},
            "render": {"connected": render.configured,
                       "needs": "RENDER_API_KEY"}}

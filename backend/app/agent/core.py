from dataclasses import dataclass, field
from typing import Any


@dataclass
class AgentResult:
    request: str
    status: str
    steps: list[str] = field(default_factory=list)
    output: Any = None


class AgentCore:
    """Coordinates requests handled by the Idrici AI agent."""

    def run(self, request: str) -> AgentResult:
        cleaned_request = request.strip()

        if not cleaned_request:
            return AgentResult(
                request="",
                status="error",
                steps=["Request validation failed"],
                output="Request cannot be empty.",
            )

        steps = [
            "Request received",
            "Request validated",
            "Ready for planning",
        ]

        return AgentResult(
            request=cleaned_request,
            status="ready",
            steps=steps,
            output=None,
        )

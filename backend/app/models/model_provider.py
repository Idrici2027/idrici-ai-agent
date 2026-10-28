from typing import Any, Protocol


class ModelProvider(Protocol):
    """Common interface for interchangeable AI model providers."""

    async def generate(
        self,
        messages: list[dict[str, str]],
        tools: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any]:
        """Generate a response using the selected model provider."""
        ...


class MockModelProvider:
    """Deterministic provider for development and tests."""

    async def generate(
        self,
        messages: list[dict[str, str]],
        tools: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any]:
        last_message = messages[-1]["content"] if messages else ""

        return {
            "text": f"Idrici mock response: {last_message}",
            "tool_calls": [],
            "provider": "mock",
        }

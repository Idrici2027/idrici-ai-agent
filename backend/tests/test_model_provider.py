import pytest

from app.models.model_provider import MockModelProvider


@pytest.mark.asyncio
async def test_mock_provider_returns_expected_response():
    provider = MockModelProvider()

    result = await provider.generate(
        [{"role": "user", "content": "Hello Idrici"}]
    )

    assert result["text"] == "Idrici mock response: Hello Idrici"
    assert result["tool_calls"] == []
    assert result["provider"] == "mock"


@pytest.mark.asyncio
async def test_mock_provider_handles_empty_messages():
    provider = MockModelProvider()

    result = await provider.generate([])

    assert result["text"] == "Idrici mock response: "
    assert result["tool_calls"] == []

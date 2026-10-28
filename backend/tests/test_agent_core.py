from app.agent.core import AgentCore


def test_agent_accepts_valid_request():
    agent = AgentCore()

    result = agent.run("  Build a Python API  ")

    assert result.request == "Build a Python API"
    assert result.status == "ready"
    assert result.steps == [
        "Request received",
        "Request validated",
        "Ready for planning",
    ]


def test_agent_rejects_empty_request():
    agent = AgentCore()

    result = agent.run("   ")

    assert result.status == "error"
    assert result.output == "Request cannot be empty."

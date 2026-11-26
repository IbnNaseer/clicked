"""Weaviate connection settings come from the environment (issue #710)."""

from unittest.mock import MagicMock, patch

import pytest
from fastapi.testclient import TestClient

import main

client = TestClient(main.app)


def test_helper_uses_defaults(monkeypatch: pytest.MonkeyPatch):
    for var in ("WEAVIATE_HOST", "WEAVIATE_HTTP_PORT", "WEAVIATE_GRPC_PORT"):
        monkeypatch.delenv(var, raising=False)

    with patch("main.weaviate.connect_to_local") as connect:
        main._weaviate_client()

    connect.assert_called_once_with(host="localhost", port=8080, grpc_port=50051)


def test_helper_passes_configured_values(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("WEAVIATE_HOST", "weaviate")
    monkeypatch.setenv("WEAVIATE_HTTP_PORT", "9090")
    monkeypatch.setenv("WEAVIATE_GRPC_PORT", "50052")

    with patch("main.weaviate.connect_to_local") as connect:
        main._weaviate_client()

    connect.assert_called_once_with(host="weaviate", port=9090, grpc_port=50052)


@pytest.mark.parametrize(
    ("method", "path", "kwargs"),
    [
        (
            "post",
            "/index/message",
            {
                "json": {
                    "messageId": "msg-1",
                    "conversationId": "conv-1",
                    "senderId": "user-1",
                    "content": "hello",
                }
            },
        ),
        ("get", "/search", {"params": {"q": "hello", "conversationId": "conv-1"}}),
    ],
)
def test_endpoints_use_helper(method, path, kwargs):
    mock_wv = MagicMock()
    mock_wv.collections.exists.return_value = False

    with (
        patch("main._weaviate_client", return_value=mock_wv) as helper,
        patch("main._openai_client"),
    ):
        getattr(client, method)(path, **kwargs)

    helper.assert_called_once_with()
    mock_wv.close.assert_called_once()

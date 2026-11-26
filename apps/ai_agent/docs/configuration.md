# AI agent configuration & environment reference

Every setting the `ai_agent` service reads, what happens when one is missing, and
which settings are not configurable at all.

The service reads `OPENAI_API_KEY` per request and captures `OPENAI_CHAT_MODEL`
and `OPENAI_EMBEDDING_MODEL` once at startup. Model changes require a process
restart. The Weaviate host and ports are read from the environment each time a
connection is opened. The direct-execution bind host and port remain hardcoded
in [`apps/ai_agent/main.py`](../main.py).

---

## 1. Environment variables

| Variable         | Required | Default | Read at                                                                | Effect when unset                                                                                                                                       |
| ---------------- | -------- | ------- | ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `OPENAI_API_KEY` | Yes\*    | _none_  | Per request, inside `_openai_client()` — not at import and not at boot | The process still starts and `/health` still returns 200; every OpenAI-backed endpoint returns 500. See [§3](#3-startup-and-missing-api-key-behaviour). |
| `OPENAI_CHAT_MODEL` | No | `gpt-4o-mini` | Module import at startup | Uses the default for all three chat-completion endpoints. |
| `OPENAI_EMBEDDING_MODEL` | No | `text-embedding-3-small` | Module import at startup | Uses the default for indexing and search. |
| `WEAVIATE_HOST` | No | `localhost` | Per request, inside `_weaviate_client()` | Connects to Weaviate on the loopback host. |
| `WEAVIATE_HTTP_PORT` | No | `8080` | Per request, inside `_weaviate_client()` | Uses the default Weaviate HTTP port. |
| `WEAVIATE_GRPC_PORT` | No | `50051` | Per request, inside `_weaviate_client()` | Uses the default Weaviate gRPC port. |

\* Required for the service to do anything useful. It is _not_ required for the
process to start, and that distinction is the single most important thing in this
document.

It is the same key the backend uses — it is declared once in the repo-root
[`.env.example`](../../../.env.example) under `# AI Service`:

```bash
# AI Service
OPENAI_API_KEY=
OPENAI_CHAT_MODEL=gpt-4o-mini
OPENAI_EMBEDDING_MODEL=text-embedding-3-small
```

There is no `.env` loading in `main.py` — no `python-dotenv`, no
`pydantic-settings`. The variable must be present in the process environment. In
local development that is whatever your shell or process manager exports; in
Docker or Kubernetes it is the container environment.

### Variables the service does **not** read

Worth stating explicitly, because their absence is easy to mistake for a bug:

| Variable                                           | Status                                                                                                                                          |
| -------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `OPENAI_MODEL` | Not read. Use `OPENAI_CHAT_MODEL` and `OPENAI_EMBEDDING_MODEL` instead. |
| `WEAVIATE_URL` / `WEAVIATE_PORT` | Not read. Use `WEAVIATE_HOST`, `WEAVIATE_HTTP_PORT` and `WEAVIATE_GRPC_PORT` — see [§4](#4-weaviate-connection). |
| `WEAVIATE_API_KEY`                                 | Not read. The client connects unauthenticated.                                                                                                  |
| `HOST` / `PORT`                                    | Not read. See [§2](#2-hardcoded-settings).                                                                                                      |
| `OPENAI_BASE_URL`                                  | Not read. `OpenAI(api_key=...)` is constructed with no base URL override, so the SDK's own environment handling is the only way to redirect it. |

Setting any of these has no effect on this service.

---

## 2. Hardcoded settings

| Setting              | Value                                                  | Where                                                |
| -------------------- | ------------------------------------------------------ | ---------------------------------------------------- |
| Bind host            | `0.0.0.0`                                              | `uvicorn.run(...)` under `if __name__ == "__main__"` |
| Bind port            | `8000`                                                 | same                                                 |
| Weaviate collection  | `Message`                                              | `index_message`, `search_messages`                   |
| Search result limit  | `5`                                                    | `search_messages`                                    |
| High-value threshold | `10_000.0` XLM                                         | `_HIGH_VALUE_THRESHOLD`, used by `analyse_transfer`  |
| Request timeouts     | 30 s for `/chat`, 10 s for the two JSON-mode endpoints | passed per call as `timeout=`                        |
| System prompt        | `_SYSTEM_PROMPT`                                       | module level                                         |

- **The host and port literals only apply to `python main.py`.** Running the
  module directly executes the `__main__` block and binds `0.0.0.0:8000`. Under
  any ASGI server invoked against the app object — which is how the repo README
  runs it (`uv run fastapi dev main.py`) and how a container normally runs it —
  the `__main__` block never executes and the host/port come from that command:

  ```bash
  # __main__ block runs: binds 0.0.0.0:8000
  python main.py

  # __main__ block does NOT run: fastapi/uvicorn decides the bind address
  uv run fastapi dev main.py                        # defaults to 127.0.0.1:8000
  uv run uvicorn main:app --host 0.0.0.0 --port 9000
  ```

  So the port is effectively set by the launch command, and the `8000` in
  `main.py` is a default only for the direct-execution path. A deployment that
  needs a different port sets it on the server command line.

---

## 3. Startup and missing-API-key behaviour

`OPENAI_API_KEY` is read **per request**, inside the `_openai_client()` helper:

```python
def _openai_client():
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        raise HTTPException(status_code=500, detail="OPENAI_API_KEY is not configured")
    if OpenAI is None:
        raise HTTPException(status_code=500, detail="openai package is not installed")

    return OpenAI(api_key=api_key)
```

Nothing validates it at import time or at startup. The service therefore **starts
successfully with no API key at all** and fails only when an OpenAI-backed
endpoint is called.

### The exact behaviour, endpoint by endpoint

| Endpoint                    | With no `OPENAI_API_KEY`                                                                                                                                                                                                                    |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GET /health`               | **200** `{"status": "ok"}`                                                                                                                                                                                                                  |
| `POST /chat`                | **500** `{"detail": "OPENAI_API_KEY is not configured"}`                                                                                                                                                                                    |
| `POST /transfers/analyse`   | **500** — unless `amount > 10000`, which is answered by the rule-based branch **before** any OpenAI client is constructed, and still returns **200**                                                                                        |
| `POST /proposals/summarise` | **500**                                                                                                                                                                                                                                     |
| `POST /index/message`       | **500** if Weaviate is reachable (the embedding call needs the key); **503** if Weaviate is unreachable, because the connection is attempted first                                                                                          |
| `GET /search`               | Same as above — **503** on a Weaviate failure, **500** on the missing key when Weaviate is up, and **200** with `{"results": []}` when the `Message` collection does not exist, because that path returns before any embedding is requested |

### This is deliberate, and it is load-balancer-visible

`/health` is a liveness probe: it answers whether the process is up and serving,
not whether every downstream dependency is configured. Because it does not touch
`_openai_client()`, a misconfigured deployment presents as:

- **healthy** to any load balancer, orchestrator probe, or uptime monitor
  pointed at `/health`, and
- **completely broken** to every real caller, with a 500 on each request.

That combination is the failure mode to watch for. An instance rolled out with a
missing or misspelled key will pass its health check, be added to the pool, and
serve nothing but 500s. Kubernetes will not restart it; a load balancer will not
drain it.

The test suite pins this behaviour rather than leaving it incidental —
`apps/ai_agent/tests/test_health.py::test_health_works_without_api_key` asserts
the 200, and `apps/ai_agent/tests/test_chat.py::test_missing_api_key_returns_500`
asserts the 500. Changing either is a deliberate contract change.

**Operational recommendation.** Do not rely on `/health` to catch a
misconfiguration. Either:

- assert the key is present at deploy time (a startup check in your orchestration,
  or a required secret rather than an optional env var), or
- monitor the 5xx rate on `/chat` separately from the liveness probe, or
- add a readiness endpoint that checks configuration — deliberately distinct from
  `/health`, which should keep its current semantics.

### Related failure: the `openai` package missing

`main.py` imports `openai` inside a `try/except ImportError` and sets
`OpenAI = None` when it is absent, so an environment without the dependency also
starts cleanly and fails per-request with **500**
`{"detail": "openai package is not installed"}`. Same shape of problem, same
`/health`-still-green consequence.

---

## 4. Weaviate connection

### How it connects

```python
def _weaviate_client():
    return weaviate.connect_to_local(
        host=os.environ.get("WEAVIATE_HOST", "localhost"),
        port=int(os.environ.get("WEAVIATE_HTTP_PORT", "8080")),
        grpc_port=int(os.environ.get("WEAVIATE_GRPC_PORT", "50051")),
    )
```

Both endpoints build their client through this one helper. The defaults match
`connect_to_local()` from `weaviate-client` (pinned at 4.22.0 in
[`uv.lock`](../uv.lock), declared as `>=4.0.0` in
[`pyproject.toml`](../pyproject.toml)): HTTP on `localhost:8080` and gRPC on
`localhost:50051`. There is still no API key support.

A connection is opened **per request** on `POST /index/message` and `GET /search`,
and closed in a `finally` block. There is no pooled or long-lived client, and no
connection is attempted at startup.

**There is no Weaviate service in [`infra/docker-compose.yml`](../../../infra/docker-compose.yml).**
That file brings up Postgres, Redis, and MinIO only. A Weaviate instance must be
run separately. A containerised `ai_agent` talking to a Weaviate in another
container should set `WEAVIATE_HOST` to that service's name, since `localhost`
inside the container is the container itself.

### Failure mode when Weaviate is unreachable

Both Weaviate-backed endpoints log unexpected connection and operation failures
and return fixed **503** responses. They preserve existing `HTTPException` responses.

| Condition                                 | Response                                                                                                                         |
| ----------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Weaviate down / unreachable               | **503** `{"detail": "Weaviate connection failed"}`                                                                               |
| Weaviate up, later operation fails        | **503** `{"detail": "Search backend unavailable"}` for unexpected exceptions                                         |
| Weaviate up, `Message` collection missing | `GET /search` → **200** `{"results": []}`; `POST /index/message` creates the collection and proceeds                             |
| Weaviate up, `OPENAI_API_KEY` missing     | **500** `{"detail": "OPENAI_API_KEY is not configured"}`                                                           |

`/health` reports process liveness. Check the service logs for connection,
operation, and cleanup failures. `apps/ai_agent/tests/test_error_details.py`
covers error responses for both endpoints.

### Collection schema

The collection is created on demand by `POST /index/message` with
`client.collections.create(name="Message")` — no property schema and no
vectoriser, because vectors are supplied explicitly from OpenAI embeddings.
Properties written per object are `conversationId`, `messageId`, `senderId`, and
`content`; searches filter on `conversationId` and return the top 5 by vector
similarity. See
[`contracts-weaviate-schema.md`](./contracts-weaviate-schema.md) for the full
shape and [`concepts-rag-search-architecture.md`](./concepts-rag-search-architecture.md)
for how it is used.

---

## 5. Running the service

From the repo root, as documented in the [main README](../../../README.md):

```bash
cd apps/ai_agent && uv run fastapi dev main.py
```

With the API key set for the process:

```bash
OPENAI_API_KEY=sk-... uv run fastapi dev main.py
```

Tests (Python 3.12+, per `requires-python` in `pyproject.toml`):

```bash
cd apps/ai_agent
uv sync --group dev
uv run pytest
```

The suite sets `OPENAI_API_KEY=test-key` for every test through an autouse
fixture in [`tests/conftest.py`](../tests/conftest.py) and mocks both `OpenAI`
and `weaviate.connect_to_local`, so **no network access and no real key are
needed** — and, as a corollary, a real misconfiguration will never be caught by
running the tests.

CI runs ruff, ruff format, mypy, and pytest with coverage via
[`.github/workflows/ai-agent-ci.yml`](../../../.github/workflows/ai-agent-ci.yml).

---

## 6. Configuration checklist for a deployment

- [ ] `OPENAI_API_KEY` is present in the process environment — verified by something other than `/health`.
- [ ] The `openai` package is installed in the runtime image (`uv sync`), or every request 500s.
- [ ] If `/search` or `/index/message` are used: a Weaviate instance is running and reachable at the client's local defaults **from the ai_agent process's own network namespace**.
- [ ] Bind host and port set on the server command line, not expected from env.
- [ ] Monitoring watches the 5xx rate on `/chat` and the 503 rate on `/search`, not just liveness.
- [ ] Model variables are set before startup; restart after changes and reindex existing messages if the embedding model changes.

---

## 7. Related documents

- [Repo-wide environment reference](../../../.env.example) — the single place every service's variables are declared, including the `OPENAI_API_KEY` this service shares with the backend. There is no separate env-reference document; `.env.example` is it.
- [Main README](../../../README.md) — how the AI service is started alongside the web and backend apps
- [`POST /chat`](./api-chat.md), [`POST /transfers/analyse`](./api-transfers-analyse.md), [`POST /proposals/summarise`](./api-proposals-summarise.md), [`/index` & `/search`](./api-index-search.md) — per-endpoint request/response contracts
- [Weaviate schema contract](./contracts-weaviate-schema.md) — the `Message` collection this service creates and queries
- [RAG search architecture](./concepts-rag-search-architecture.md) — how indexing and search fit together
- [Pydantic model contracts](./contracts-pydantic-models.md) — request/response models referenced above

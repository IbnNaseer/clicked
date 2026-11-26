# AI Agent

## OpenAI configuration

Set these environment variables before starting the service:

| Variable | Default | Used by |
| --- | --- | --- |
| `OPENAI_API_KEY` | Required | All OpenAI requests |
| `OPENAI_CHAT_MODEL` | `gpt-4o-mini` | `/chat`, `/transfers/analyse`, `/proposals/summarise` |
| `OPENAI_EMBEDDING_MODEL` | `text-embedding-3-small` | `/index/message`, `/search` |

Model settings are read once when the application module loads at startup.
Restart the service after changing either model variable. When changing the
embedding model, ensure existing indexed vectors are compatible or reindex the
messages with the new model before searching them.

## Weaviate configuration

`/index/message` and `/search` connect to Weaviate with these variables, so the
agent can reach a Weaviate service running in a separate container:

| Variable | Default | Used by |
| --- | --- | --- |
| `WEAVIATE_HOST` | `localhost` | `/index/message`, `/search` |
| `WEAVIATE_HTTP_PORT` | `8080` | `/index/message`, `/search` |
| `WEAVIATE_GRPC_PORT` | `50051` | `/index/message`, `/search` |

They are read each time a connection is opened, so no restart is needed for
changes made in the process environment.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A multi-stack voting application composed of five services that communicate through Redis and PostgreSQL. The pipeline is: **vote → Redis → worker → PostgreSQL → result**.

- **vote** (Python/Flask): Accepts votes via HTTP, pushes JSON to a Redis list called `votes`
- **redis**: Acts as the message queue between vote and worker
- **worker** (.NET 8 / C#): Polls the `votes` Redis list, upserts rows into PostgreSQL `votes` table
- **db** (PostgreSQL 15): Stores one row per voter (keyed by `voter_id`); the worker creates the table on startup
- **result** (Node.js/Express): Queries PostgreSQL every second and pushes totals to the browser via Socket.IO

## Running the Full Stack

```bash
# Use prebuilt images (default in docker-compose.yml)
docker compose up

# Vote UI:   http://localhost:8080
# Results:   http://localhost:8081
```

The `docker-compose.yml` defaults to `pokfinner/*` prebuilt images. To use your own builds, uncomment the `build:` lines and comment out the `image:` lines for each service.

## Running Services Locally (Without Docker)

**vote (Python 3.10+):**
```bash
cd vote
pip install -r requirements.txt
python app.py          # listens on port 80 by default; set PORT env var to override
```

**worker (.NET 8 SDK):**
```bash
cd worker
dotnet restore
dotnet run
```

**result (Node.js 18+):**
```bash
cd result
npm install
node server.js         # listens on port 4000 by default
```

Redis and PostgreSQL must be reachable at their configured hostnames (defaults: `redis:6379`, `db:5432`).

## Building Individual Docker Images

```bash
docker build -t myorg/vote:latest ./vote
docker build -t myorg/worker:latest ./worker
docker build -t myorg/result:latest ./result

# For arm64 → amd64 cross-build:
docker buildx build --platform linux/amd64 -t myorg/worker:latest ./worker
```

## Environment Variables

Each service reads its dependencies from environment variables — all have sensible Docker Compose defaults:

| Service | Variable | Default |
|---------|----------|---------|
| vote | `OPTION_A`, `OPTION_B` | `Cats`, `Dogs` |
| vote | `REDIS_HOST`, `REDIS_PORT` | `redis`, `6379` |
| worker | `REDIS_HOST` | `redis` |
| worker | `DB_HOST`, `DB_USERNAME`, `DB_PASSWORD`, `DB_NAME` | `db`, `postgres`, `postgres`, `postgres` |
| result | `PG_HOST`, `PG_PORT`, `PG_USER`, `PG_PASSWORD`, `PG_DATABASE` | `db`, `5432`, `postgres`, `postgres`, `postgres` |
| result | `PORT` | `4000` (local), `80` (container) |

## Architecture Notes

- **Vote deduplication**: Each browser gets a `voter_id` cookie. The worker stores one row per `voter_id` — it attempts an INSERT and falls back to UPDATE on conflict, so each voter's choice is overwritten, not accumulated.
- **Result real-time updates**: `result/server.js` polls PostgreSQL every 1 s and broadcasts score updates via Socket.IO on two namespaces (`/` and `/result`). The frontend in `views/app.js` subscribes via AngularJS.
- **Worker reconnection logic**: The worker resolves the Redis hostname to an IP address at startup (workaround for a StackExchange.Redis DNS issue) and retries both Redis and PostgreSQL connections indefinitely on failure.
- **Health checks**: `docker-compose.yml` waits for Redis (`redis-cli ping`) and PostgreSQL (`SELECT 1` via psql) to be healthy before starting dependent services. Scripts live in `healthchecks/`.
- **No test suites** exist in any service currently.

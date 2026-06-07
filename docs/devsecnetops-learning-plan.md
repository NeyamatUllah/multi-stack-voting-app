# DevSecNetOps Learning Plan

This document summarizes the structured learning roadmap for this multi-stack voting app, covering containerization, CI/CD, security, Kubernetes, observability, and cloud infrastructure.

---

## Application Architecture

The voting app is a 3-tier distributed system with five services:

```
Browser
  └─► vote (Python/Flask :8080)
        └─► Redis (queue)
              └─► worker (.NET 8)
                    └─► PostgreSQL (db)
                          └─► result (Node.js :8081)
                                └─► Browser (via Socket.IO)
```

- **vote** — accepts votes, pushes JSON to a Redis list named `votes`
- **redis** — in-memory queue buffering votes between vote and worker
- **worker** — polls Redis every 100ms, upserts one row per `voter_id` into PostgreSQL
- **db** — stores final vote state; one row per voter, overwritten on vote change
- **result** — queries DB every second, pushes live counts to the browser via WebSocket

---

## Phase 1 — Containerization Hardening

**Goal:** Stop using external prebuilt images, lock down your own Dockerfiles, and scan for vulnerabilities.

| Task | Tool |
|------|------|
| Lint Dockerfiles | **Hadolint** |
| Scan images for CVEs | **Trivy** |
| Analyze image layers/size | **Dive** |

### Step 1 — Add `.dockerignore` to `vote/` *(MEDIUM risk — currently missing)*

Prevents Python cache files, `.env`, and local configs from leaking into the image.

Create `vote/.dockerignore` with at minimum:
```
__pycache__
*.pyc
*.pyo
.env
.git
*.md
```

### Step 2 — Pin base image versions to exact tags *(HIGH risk — currently unpinned)*

Unpinned tags like `python:3.11-slim` silently pull a different image on each build, making builds non-reproducible and potentially pulling in new CVEs.

| Dockerfile | Current (unpinned) | Pin to (example) |
|------------|--------------------|-----------------|
| `vote/` | `python:3.11-slim` | `python:3.11.12-slim-bookworm` |
| `result/` | `node:18-slim` | `node:18.20.8-slim` |
| `worker/` | `mcr.microsoft.com/dotnet/sdk:8.0` | `mcr.microsoft.com/dotnet/sdk:8.0.408` |
| `worker/` | `mcr.microsoft.com/dotnet/runtime:8.0` | `mcr.microsoft.com/dotnet/runtime:8.0.15` |

### Step 3 — Add non-root `USER` to all three Dockerfiles *(MEDIUM risk — currently root)*

A container running as root means a container escape = root on the host. Add a dedicated user in each Dockerfile before the `CMD`/`ENTRYPOINT`:

```dockerfile
# Example for vote (Python)
RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser
USER appuser
```

```dockerfile
# Example for result (Node.js) — node image ships with a 'node' user already
USER node
```

```dockerfile
# Example for worker (.NET)
RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser
USER appuser
```

### Step 4 — Run Hadolint and fix all warnings

Hadolint checks your Dockerfiles against Docker best practices and the official style guide.

```bash
hadolint vote/Dockerfile
hadolint result/Dockerfile
hadolint worker/Dockerfile
```

Fix every warning before moving on. Common findings: missing `--no-install-recommends`, not pinning `apt` package versions, `COPY . .` before installing dependencies.

### Step 5 — Switch docker-compose.yml to build your own images

In `docker-compose.yml`, for each of `vote`, `result`, `worker`:
- Uncomment the `build:` line
- Comment out the `image: pokfinner/*` line

This ensures you run your own hardened images, not external prebuilt ones.

### Step 6 — Build your images

```bash
docker compose build
```

Verify all three build successfully with no errors before proceeding.

### Step 7 — Run Trivy against all three built images *(HIGH risk — no CVE scanning currently)*

```bash
trivy image multi-stack-voting-app-vote
trivy image multi-stack-voting-app-result
trivy image multi-stack-voting-app-worker
```

Triage findings:
- **CRITICAL / HIGH** — must fix before shipping (upgrade base image or specific package)
- **MEDIUM** — fix if straightforward
- **LOW / NEGLIGIBLE** — document and accept

### Step 8 — Run Dive to check for image bloat

```bash
dive multi-stack-voting-app-vote
dive multi-stack-voting-app-result
dive multi-stack-voting-app-worker
```

Look for:
- Large files baked into layers unnecessarily (e.g. build tools in the final image)
- Files added then deleted in a later layer (they still exist in the earlier layer and bloat the image)
- A good image efficiency score is **>85%**

### Definition of Done for Phase 1

- [x] `vote/.dockerignore` exists
- [x] All base image tags are pinned to exact versions
- [x] All three Dockerfiles pass Hadolint with zero warnings
- [x] All three Dockerfiles run as a non-root user
- [x] `docker-compose.yml` uses `build:` with `ghcr.io/neyamatullah/*` tags
- [x] `docker compose build` completes successfully
- [x] Trivy reports zero CRITICAL/HIGH CVEs across all three images
- [x] Dive efficiency score is above 85% for all three images (with `.dive-ci.yml` threshold)

### Phase 1 — Actual Results (2026-05-31)

| Image | Base | Efficiency | CVEs before | CVEs after |
|-------|------|-----------|-------------|------------|
| vote | python:3.11.15-slim-bookworm | 89.7% | 26 (6C/20H) | 0 |
| result | node:18.20.8-slim | 82.9% | 34 (4C/30H) | 0 |
| worker | dotnet/runtime:8.0.27-bookworm-slim | 97.2% | 15 (6C/9H) | 0 |

**Key fixes applied:**
- `apt-get upgrade -y` in all images — patched libgnutls30 (CRITICAL), libcap2, libpam, nghttp2
- `System.Drawing.Common` pinned to 8.0.0 in worker — traced transitive chain from StackExchange.Redis
- npm overrides in result — path-to-regexp 0.1.13, ws 8.17.1, socket.io-parser 4.2.6
- `COPY --chown` in all Dockerfiles — eliminated post-copy chown layers (saved 9 MB in worker)
- Accepted risks documented in `.trivyignore` — zlib1g (will_not_fix), curl, ncurses, perl, npm internals
- `.dive-ci.yml` — result image at 82.9% accepted; caused by apt-get upgrade over debian 12.11 base; resolve when upgrading to Node 20 LTS

**Branch/PR:** `feature/phase1-container-hardening` → PR #2 → merged to `dev` → promoting to `staging` → `main`

---

## Phase 2 — Docker Compose: Networking & Secrets

**Goal:** Enforce least-privilege network isolation between services and remove all hardcoded credentials from version control.

| Task | Tool |
|------|------|
| Network segmentation | Docker Compose named networks |
| Secrets management | `.env` file + `${VAR}` substitution |
| Validate compose | `docker compose config` |
| Secret scanning | **Gitleaks** |
| Security hardening | `security_opt`, `read_only`, resource limits |

---

### Current State Gaps

| Gap | Risk |
|-----|------|
| Single flat `back-tier` network — all 5 services can reach each other | HIGH — compromised vote container can talk directly to db |
| `POSTGRES_PASSWORD: "postgres"` hardcoded in docker-compose.yml | CRITICAL — committed to git history |
| No resource limits on any service | MEDIUM — one runaway container can starve the host |
| No `no-new-privileges` flag | MEDIUM — SUID binaries could be exploited inside containers |

---

### Network Design

Three networks named to mirror the Azure VNet subnet model you will deploy to later:

```
Internet
    │
 [frontend]  ──  vote, result          (public-facing, port-exposed)
    │
 [backend]   ──  vote, result,         (private app tier)
                 worker, redis
    │
 [data]      ──  result, worker, db    (most private, persistent storage only)
```

**Why redis sits in `backend` (Tier 2), not `data` (Tier 3):**
Redis is a message queue — application-layer middleware, ephemeral by nature. If Redis goes down, in-flight votes are lost; it is not the system of record. PostgreSQL is. In Azure this maps to: Azure Cache for Redis in the backend subnet, Azure Database for PostgreSQL in the data subnet.

| Network | Members | `internal`? | Why |
|---------|---------|-------------|-----|
| `frontend` | vote, result | No | Port-exposed; will become the public subnet in Azure. In a later phase nginx/AGFW will be the only member here and vote/result will move to backend-only. |
| `backend` | vote, result, worker, redis | Yes | Private app tier. vote reaches redis here. worker processes from redis here. |
| `data` | result, worker, db | Yes | Most private. Only services that read/write PostgreSQL join this network. vote cannot reach db — no shared network. |

**Key isolation achieved:**

| Path | Result | Why |
|------|--------|-----|
| vote → redis | ✅ Allowed | Both on backend |
| vote → db | ✅ **Blocked** | vote has no path to data network |
| worker → redis | ✅ Allowed | Both on backend |
| worker → db | ✅ Allowed | Both on data |
| result → db | ✅ Allowed | Both on data |
| result → redis | ⚠ Allowed | Both on backend — acceptable; redis is app-tier |

**Future alignment:**
- Phase 3/Azure: add nginx in `frontend`, move vote+result to `backend` only
- Phase 5/K8s: enforce with `NetworkPolicy`
- Phase 8/IaC: enforce with NSGs on Azure VNet subnets

---

### Step 1 — Redesign networks in docker-compose.yml

Replace the single `back-tier` with three named networks:

```yaml
networks:
  frontend:
    driver: bridge
  backend:
    driver: bridge
    internal: true    # no outbound internet — app tier is private
  data:
    driver: bridge
    internal: true    # most private — only db lives here
```

Assign services:

```yaml
vote:
  networks: [frontend, backend]

result:
  networks: [frontend, backend, data]

worker:
  networks: [backend, data]

redis:
  networks: [backend]

db:
  networks: [data]
```

> `internal: true` on `backend` and `data` prevents containers from making outbound internet calls. `frontend` is not internal because vote and result need to respond to browser requests (Docker port-maps work regardless, but internal: false keeps it explicit).

---

### Step 2 — Create `.env`

Create `.env` at the repo root (already gitignored from Phase 1):

```env
# PostgreSQL
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
POSTGRES_DB=postgres

# Vote options (override to change the ballot)
OPTION_A=Cats
OPTION_B=Dogs
```

> For a real production deployment, replace `postgres/postgres` with strong random credentials before deploying.

---

### Step 3 — Create `.env.example`

Commit a safe template so collaborators know what variables are required:

```env
# PostgreSQL — replace all values before running
POSTGRES_USER=changeme
POSTGRES_PASSWORD=changeme_secure_password_here
POSTGRES_DB=votes

# Vote ballot options
OPTION_A=Cats
OPTION_B=Dogs
```

---

### Step 4 — Update docker-compose.yml to use variables

Replace every hardcoded secret with `${VAR}` references:

```yaml
db:
  image: postgres:15-alpine
  environment:
    POSTGRES_USER: "${POSTGRES_USER}"
    POSTGRES_PASSWORD: "${POSTGRES_PASSWORD}"
    POSTGRES_DB: "${POSTGRES_DB}"

worker:
  environment:
    DB_HOST: db
    DB_USERNAME: "${POSTGRES_USER}"
    DB_PASSWORD: "${POSTGRES_PASSWORD}"
    DB_NAME: "${POSTGRES_DB}"

result:
  environment:
    PG_USER: "${POSTGRES_USER}"
    PG_PASSWORD: "${POSTGRES_PASSWORD}"
    PG_DATABASE: "${POSTGRES_DB}"

vote:
  environment:
    OPTION_A: "${OPTION_A}"
    OPTION_B: "${OPTION_B}"
```

Validate substitution works before running:

```bash
docker compose config
```

All `${VAR}` references should be replaced with values from `.env` in the output.

---

### Step 5 — Add resource limits

Prevent any single container from exhausting host CPU or memory. Add to each service:

```yaml
vote:
  deploy:
    resources:
      limits:
        cpus: '0.50'
        memory: 128M
      reservations:
        cpus: '0.10'
        memory: 64M

result:
  deploy:
    resources:
      limits:
        cpus: '0.50'
        memory: 128M

worker:
  deploy:
    resources:
      limits:
        cpus: '0.50'
        memory: 256M   # .NET runtime needs a bit more headroom

redis:
  deploy:
    resources:
      limits:
        cpus: '0.25'
        memory: 64M

db:
  deploy:
    resources:
      limits:
        cpus: '0.50'
        memory: 256M
```

---

### Step 6 — Add security hardening options

Add to every service in docker-compose.yml:

```yaml
security_opt:
  - no-new-privileges:true
```

This prevents any process inside the container from gaining elevated privileges via SUID/SGID binaries — closes a common container escape vector.

For `vote` and `result` (stateless services), also add a read-only filesystem with a tmpfs mount for `/tmp`:

```yaml
vote:
  read_only: true
  tmpfs:
    - /tmp

result:
  read_only: true
  tmpfs:
    - /tmp
```

> Do not add `read_only` to `db` — PostgreSQL writes to its data directory.

---

### Step 7 — Scan for committed secrets with Gitleaks

Install Gitleaks:

```bash
curl -sSfL https://github.com/gitleaks/gitleaks/releases/latest/download/gitleaks_$(uname -s)_amd64.tar.gz | tar -xz -C ~/.local/bin gitleaks
```

Scan the full git history:

```bash
gitleaks detect --source . --log-opts HEAD
```

**Expected finding:** The original upstream commit (`ad98dee`) hardcoded `postgres/postgres` in `docker-compose.yml`. Gitleaks will flag this.

Since these are non-production placeholder credentials (not real secrets), the correct action is:
- Document the finding
- Accept the risk for this learning repo (password was never a real secret)
- Add a `.gitleaks.toml` allowlist entry for that specific commit

For a real project with actual leaked credentials: rotate the credentials immediately, then use `git filter-repo` to scrub history.

Create `.gitleaks.toml`:

```toml
title = "Gitleaks config"

[allowlist]
  description = "Accepted historical findings"
  commits = [
    "ad98dee",  # original upstream repo commit — postgres/postgres placeholder, not real credentials
  ]
```

Re-run — scan should pass:

```bash
gitleaks detect --source . --log-opts HEAD
```

---

### Step 8 — Test and verify isolation

Start the stack:

```bash
docker compose up -d
```

**Functional test:**
- Vote UI loads at `http://localhost:8080`
- Results update in real time at `http://localhost:8081`

**Network isolation test:**

```bash
# vote should NOT be able to reach db (different network)
docker compose exec vote ping -c 2 db
# Expected: ping: bad address 'db' — or no route to host

# vote SHOULD be able to reach redis
docker compose exec vote ping -c 2 redis
# Expected: 64 bytes from ... (success)

# result should NOT be able to reach redis
docker compose exec result ping -c 2 redis
# Expected: ping: bad address 'redis'

# result SHOULD be able to reach db
docker compose exec result ping -c 2 db
# Expected: success
```

**Secret hygiene check:**

```bash
# Confirm .env is not tracked
git status
# .env should NOT appear — it is gitignored

# Confirm no secrets in docker-compose.yml
grep -i "password\|secret\|postgres" docker-compose.yml
# Should only show ${VAR} references, no literal values
```

---

### Definition of Done for Phase 2

- [ ] Three networks defined: `vote-redis`, `result-db`, `worker-net` — all `internal: true`
- [ ] vote cannot ping db (verified by exec test)
- [ ] result cannot ping redis (verified by exec test)
- [ ] All hardcoded credentials removed from docker-compose.yml — only `${VAR}` references
- [ ] `.env` exists locally and is gitignored
- [ ] `.env.example` committed with placeholder values
- [ ] `docker compose config` resolves all variables cleanly
- [ ] Resource limits set on all five services
- [ ] `no-new-privileges:true` on all services
- [ ] `read_only: true` + tmpfs on vote and result
- [ ] Gitleaks scan passes (with `.gitleaks.toml` allowlist for upstream commit)
- [ ] `docker compose up` — full stack functional

---

## Phase 3 — CI/CD Pipeline

**Goal:** Automate build, lint, scan, and push on every commit.

| Task | Tool |
|------|------|
| CI platform | **GitHub Actions** |
| Python linting | **Flake8**, **Ruff** |
| JS linting | **ESLint** |
| .NET formatting | `dotnet format` |
| Image CVE gate | **Trivy Action** (`aquasecurity/trivy-action`) |
| Container registry | **Docker Hub** or **GHCR** |

Pipeline stages: lint → build → scan → push (on `staging` push)

### Definition of Done for Phase 3

- [x] `lint-python` passes (Flake8 + Ruff on `vote/`)
- [x] `lint-js` passes (ESLint on `result/`)
- [x] `lint-dotnet` passes (`dotnet format` on `worker/`)
- [x] `build-and-scan` builds all 3 images, Trivy finds 0 HIGH/CRITICAL CVEs
- [x] `push` job runs on staging merge and images appear in GHCR
- [x] CI trigger scoped to `staging` branch only (not every feature branch push)

### Phase 3 — Actual Results (2026-06-02)

**Workflow:** `.github/workflows/ci.yml` — 5 jobs, triggers on push to `staging`

| Job | Runs on | Result |
|-----|---------|--------|
| lint-python | every staging push | Flake8 + Ruff pass |
| lint-js | every staging push | ESLint pass |
| lint-dotnet | every staging push | dotnet format pass |
| build-and-scan | after all lint jobs (matrix: vote/result/worker) | 0 HIGH/CRITICAL CVEs |
| push | after build-and-scan | images pushed to GHCR with `:latest` + `:<sha>` |

**Pre-existing issues cleaned up to pass linters:**

| File | Issue | Fix |
|------|-------|-----|
| `vote/app.py` | E302 (1 blank line before functions) | Added 2nd blank line; E231 (missing space after `,` in route methods) |
| `result/server.js` | `no-redeclare` — `Pool` declared twice | Removed unused declaration from top var chain |
| `result/views/app.js` | `no-unused-vars` — `data` param unused | Renamed to `_data` |
| `result/server.js` | `no-unused-vars` — `done` param unused | Renamed to `_done` |
| `worker/Program.cs` | Trailing whitespace on blank line | Stripped spaces |

**Config files added:**

| File | Purpose |
|------|---------|
| `vote/pyproject.toml` | Ruff: E/F rules, 120-char line limit |
| `result/.eslintrc.json` | ESLint 8: Node env, browser overrides for `views/`, `_`-prefixed unused args allowed |
| `result/package.json` | eslint devDependency + `npm run lint` script |

**Lesson learned:** Pinned `aquasecurity/trivy-action@0.28.0` — tag did not exist. Corrected to `v0.36.0` (actual latest release).

**Branch/PRs:** `feature/phase3-ci-cd` → PR #11 → `dev`; fix trivy → PR #14; simplify trigger → PR #17; promoted via PRs #12/#13/#15/#16/#18/#19 → `staging` → `main`

---

## Phase 4 — SAST & Dependency Scanning

**Goal:** Find vulnerabilities in code and dependencies before they ship.

| Task | Tool |
|------|------|
| Dependency auto-updates | **Dependabot** |
| Static analysis (semantic) | **CodeQL** (GitHub native) |
| Static analysis (pattern) | **Semgrep** |
| Secret detection in CI | **Gitleaks** (CI job) |

### Definition of Done for Phase 4

- [x] `.github/dependabot.yml` configured for pip, npm, nuget, and GitHub Actions (weekly)
- [x] `codeql.yml` workflow analyses Python, JS, and C# — triggers on staging push, PRs, and weekly cron
- [x] CodeQL results surface in GitHub Security → Code scanning tab
- [x] `semgrep.yml` workflow runs OWASP Top-10 rules — SARIF uploaded to Security tab
- [x] Gitleaks `secret-scan` job added to `ci.yml` as the first job
- [x] `build-and-scan` blocked on `secret-scan` passing

### Phase 4 — Actual Results (2026-06-03)

**Files added:**

| File | Purpose |
|------|---------|
| `.github/dependabot.yml` | Weekly PRs for pip (`vote/`), npm (`result/`), nuget (`worker/`), and GitHub Actions |
| `.github/workflows/codeql.yml` | Semantic SAST — Python (`none` build mode), JS (`none`), C# (`autobuild`); `security-and-quality` query suite |
| `.github/workflows/semgrep.yml` | Pattern SAST — `p/python`, `p/javascript`, `p/owasp-top-ten`; SARIF upload to Security tab |

**CI pipeline change (`ci.yml`):**

Added `secret-scan` as the first job (runs `gitleaks/gitleaks-action@v2` with `fetch-depth: 0` for full history). Updated `build-and-scan.needs` to `[secret-scan, lint-python, lint-js, lint-dotnet]` so a secret finding blocks all downstream work.

Updated pipeline:

```
secret-scan ─┐
lint-python  ├─► build-and-scan (matrix: vote/result/worker) ─► push to GHCR
lint-js      │
lint-dotnet  ┘
```

**Trigger design:**

| Workflow | Push trigger | PR trigger | Schedule |
|----------|-------------|------------|----------|
| `ci.yml` (Gitleaks + build) | `staging` only | — | — |
| `codeql.yml` | `staging` | PRs → staging, main | Monday 03:00 UTC |
| `semgrep.yml` | `staging` | PRs → staging, main | — |

**Branch/PRs:** `feature/phase4-sast-dependency-scanning` → PR #23 → `dev`; promoted via PRs #24/#25 → `staging` → `main`

---

## Phase 5 — Kubernetes Migration

**Goal:** Move from Docker Compose to a production-grade K8s setup that can scale, self-heal, and run anywhere.

| Task | Tool |
|------|------|
| Local K8s cluster | **Minikube** |
| CLI management | **kubectl** |
| Manifest linting | **kube-linter** |
| Health probes | Native K8s `readinessProbe` / `livenessProbe` |
| Ingress | **ingress-nginx** |
| Network policies | Native K8s `NetworkPolicy` |
| Packaging | **Helm** |
| Cluster terminal UI | **k9s** |

---

### Kubernetes vocabulary — Docker Compose mapping

Before writing any YAML, map what you already know to the Kubernetes equivalent:

| Docker Compose | Kubernetes | Purpose |
|---------------|------------|---------|
| `service:` block | `Deployment` + `Service` | Runs the container and exposes it internally |
| `image:` | Pod spec `image:` | Same |
| `environment:` (non-secret) | `ConfigMap` | Config injection |
| `environment:` (passwords) | `Secret` | Credential injection |
| `ports:` | `Service` (ClusterIP) + `Ingress` | Network exposure |
| `networks:` | `NetworkPolicy` | Traffic control |
| `depends_on: condition: healthy` | `readinessProbe` | Wait until pod is ready |
| `healthcheck:` | `livenessProbe` | Restart unresponsive pod |
| `volumes:` (persistent) | `PersistentVolumeClaim` | Persistent storage |
| `deploy.resources.limits:` | `resources.limits:` in pod spec | CPU / memory caps |

---

### Step 1 — Spin up a local cluster (Minikube)

```bash
minikube start --driver=docker
minikube addons enable ingress   # needed for Step 5
kubectl get nodes                # should show 1 node Ready
```

Install k9s for a terminal UI:
```bash
# macOS / Linux
brew install k9s
# or download binary from https://github.com/derailed/k9s/releases
k9s
```

---

### Step 2 — Write raw manifests (one service at a time)

Work from the bottom of the dependency chain upward:

```
db → redis → worker → vote → result
```

**File layout:**

```
k8s/
  configmap.yaml        # OPTION_A, OPTION_B, hostnames
  secret.yaml           # POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB
  db/
    pvc.yaml
    deployment.yaml
    service.yaml
  redis/
    deployment.yaml
    service.yaml
  worker/
    deployment.yaml
  vote/
    deployment.yaml
    service.yaml
  result/
    deployment.yaml
    service.yaml
  ingress.yaml
  networkpolicy.yaml
```

**ConfigMap** (non-secret config):
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  OPTION_A: "Cats"
  OPTION_B: "Dogs"
  REDIS_HOST: "redis"
  DB_HOST: "db"
```

**Secret** (credentials):
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
type: Opaque
stringData:
  POSTGRES_USER: postgres
  POSTGRES_PASSWORD: postgres
  POSTGRES_DB: postgres
```

**PVC for PostgreSQL** (db only — stateful):
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
```

**Deployment template** (vote example):
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vote
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vote
  template:
    metadata:
      labels:
        app: vote
    spec:
      containers:
        - name: vote
          image: ghcr.io/neyamatullah/vote:latest
          ports:
            - containerPort: 80
          env:
            - name: REDIS_HOST
              valueFrom:
                configMapKeyRef:
                  name: app-config
                  key: REDIS_HOST
            - name: OPTION_A
              valueFrom:
                configMapKeyRef:
                  name: app-config
                  key: OPTION_A
            - name: OPTION_B
              valueFrom:
                configMapKeyRef:
                  name: app-config
                  key: OPTION_B
          resources:
            limits:
              cpu: "500m"
              memory: "128Mi"
            requests:
              cpu: "100m"
              memory: "64Mi"
```

**Service template** (ClusterIP — internal only):
```yaml
apiVersion: v1
kind: Service
metadata:
  name: vote
spec:
  selector:
    app: vote
  ports:
    - port: 80
      targetPort: 80
```

Apply and verify each service before moving to the next:
```bash
kubectl apply -f k8s/db/
kubectl get pods -w          # wait for Running
kubectl apply -f k8s/redis/
kubectl apply -f k8s/worker/
kubectl apply -f k8s/vote/
kubectl apply -f k8s/result/
```

---

### Step 3 — Add health probes to all five services

Without probes, Kubernetes sends traffic to pods the instant they start — before the app is ready. Worker crashes trying to reach a db that has not finished initialising.

**Three probe types by service:**

| Service | Probe type | Command / path |
|---------|-----------|----------------|
| vote | `httpGet` | `GET /` on port 80 |
| result | `httpGet` | `GET /` on port 80 |
| redis | `tcpSocket` | port 6379 |
| db | `exec` | `pg_isready -U postgres` |
| worker | `exec` | check process alive (no HTTP port) |

**HTTP probe** (vote / result):
```yaml
readinessProbe:
  httpGet:
    path: /
    port: 80
  initialDelaySeconds: 5
  periodSeconds: 10
livenessProbe:
  httpGet:
    path: /
    port: 80
  initialDelaySeconds: 15
  periodSeconds: 20
```

**TCP probe** (redis):
```yaml
readinessProbe:
  tcpSocket:
    port: 6379
  initialDelaySeconds: 5
  periodSeconds: 10
livenessProbe:
  tcpSocket:
    port: 6379
  initialDelaySeconds: 10
  periodSeconds: 15
```

**Exec probe** (db):
```yaml
readinessProbe:
  exec:
    command: ["pg_isready", "-U", "postgres"]
  initialDelaySeconds: 10
  periodSeconds: 5
livenessProbe:
  exec:
    command: ["pg_isready", "-U", "postgres"]
  initialDelaySeconds: 20
  periodSeconds: 10
```

---

### Step 4 — Add Ingress

In Docker Compose, ports were mapped directly (`8080:80`). In Kubernetes the correct pattern is:

```
Browser → Ingress (nginx) → Service (ClusterIP) → Pod
```

Minikube addon was enabled in Step 1. Write the Ingress resource:

```yaml
# k8s/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: voting-app
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
    - host: voting.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: vote
                port:
                  number: 80
          - path: /result
            pathType: Prefix
            backend:
              service:
                name: result
                port:
                  number: 80
```

Add the hostname to `/etc/hosts`:
```bash
echo "$(minikube ip) voting.local" | sudo tee -a /etc/hosts
```

Test:
```bash
curl http://voting.local        # vote UI
curl http://voting.local/result # result UI
```

---

### Step 5 — Apply NetworkPolicy

Replicates the Phase 2 Docker network isolation in Kubernetes. The same rule applies: **vote must not be able to reach db**.

Default Kubernetes allows all pod-to-pod traffic. NetworkPolicy adds a firewall:

```yaml
# k8s/networkpolicy.yaml
# Allow db ingress only from worker and result — vote is implicitly denied
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: db-ingress-policy
spec:
  podSelector:
    matchLabels:
      app: db
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: worker
        - podSelector:
            matchLabels:
              app: result
---
# Deny all egress from vote except to redis
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: vote-egress-policy
spec:
  podSelector:
    matchLabels:
      app: vote
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: redis
    - ports:
        - port: 53          # allow DNS resolution
          protocol: UDP
```

Verify isolation:
```bash
# vote should NOT reach db
kubectl exec deploy/vote -- nc -zv db 5432
# Expected: connection refused / timed out

# vote SHOULD reach redis
kubectl exec deploy/vote -- nc -zv redis 6379
# Expected: open
```

---

### Step 6 — Package as a Helm chart

Helm turns your collection of YAML files into a parameterised, versioned, installable package.

**Initialise chart:**
```bash
helm create helm/voting-app
# then replace the generated templates with your k8s/ manifests
```

**Chart structure:**
```
helm/voting-app/
  Chart.yaml
  values.yaml
  templates/
    configmap.yaml
    secret.yaml
    db/deployment.yaml
    db/service.yaml
    db/pvc.yaml
    redis/deployment.yaml
    redis/service.yaml
    worker/deployment.yaml
    vote/deployment.yaml
    vote/service.yaml
    result/deployment.yaml
    result/service.yaml
    ingress.yaml
    networkpolicy.yaml
```

**`values.yaml`** — all tuneable defaults in one place:
```yaml
vote:
  image: ghcr.io/neyamatullah/vote
  tag: latest
  replicas: 1
  optionA: Cats
  optionB: Dogs

result:
  image: ghcr.io/neyamatullah/result
  tag: latest
  replicas: 1

worker:
  image: ghcr.io/neyamatullah/worker
  tag: latest

db:
  image: postgres
  tag: "15-alpine"
  user: postgres
  password: postgres
  name: postgres

redis:
  image: redis
  tag: "7-alpine"

ingress:
  host: voting.local
```

Templates use `{{ .Values.vote.optionA }}` to inject values, so the same chart deploys to dev, staging, and production with different `values.yaml` overrides.

**Install and upgrade:**
```bash
helm install voting-app ./helm/voting-app
helm upgrade voting-app ./helm/voting-app --set vote.optionA=Tea --set vote.optionB=Coffee
helm uninstall voting-app
```

**Lint before every PR:**
```bash
helm lint ./helm/voting-app
```

---

### Definition of Done for Phase 5

- [x] Minikube cluster running locally (`--cni=calico` required for NetworkPolicy enforcement)
- [x] All 5 services deployed as Deployments with ClusterIP Services
- [x] ConfigMap and Secret used — no hardcoded values in manifests
- [x] PVC provisioned for PostgreSQL; data survives pod restart
- [x] All 5 pods show `Running` and `READY 1/1`
- [x] readinessProbe and livenessProbe on every pod
- [x] Ingress routes `voting.local/` → vote and `voting.local/result` → result
- [x] NetworkPolicy blocks vote → db (verified by exec test)
- [x] NetworkPolicy allows vote → redis (verified by exec test)
- [x] Full stack functional end-to-end — HTTP 200 on both routes
- [x] Helm chart installs and upgrades cleanly (`helm lint` passes, install/upgrade/rollback verified)

### Phase 5 — Actual Results (2026-06-03)

**Files added:** `k8s/` directory — 14 manifests across 6 subdirectories

| File | Purpose |
|------|---------|
| `k8s/configmap.yaml` | OPTION_A/B, REDIS_HOST, DB_HOST — injected via `configMapKeyRef` |
| `k8s/secret.yaml` | POSTGRES_USER/PASSWORD/DB — injected via `secretKeyRef` |
| `k8s/db/pvc.yaml` | 1Gi ReadWriteOnce PVC for PostgreSQL data |
| `k8s/db/deployment.yaml` | postgres:15-alpine; exec probe (`pg_isready`) |
| `k8s/db/service.yaml` | ClusterIP on port 5432 |
| `k8s/redis/deployment.yaml` | redis:7-alpine; tcpSocket probe on 6379 |
| `k8s/redis/service.yaml` | ClusterIP on port 6379 |
| `k8s/worker/deployment.yaml` | GHCR image; exec probe (`kill -0 1` — minimal runtime has no pgrep) |
| `k8s/vote/deployment.yaml` | GHCR image; httpGet probe on `/` |
| `k8s/vote/service.yaml` | ClusterIP on port 80 |
| `k8s/result/deployment.yaml` | GHCR image; httpGet probe on `/` |
| `k8s/result/service.yaml` | ClusterIP on port 80 |
| `k8s/ingress.yaml` | ingress-nginx routing `voting.local/` → vote, `/result` → result |
| `k8s/networkpolicy.yaml` | db-ingress-policy (allow worker+result only); vote-egress-policy (allow redis+DNS only) |

**Lessons learned:**

| Issue | Root cause | Fix |
|-------|-----------|-----|
| NetworkPolicy not enforced | Default Minikube bridge CNI ignores policies | Restart with `--cni=calico` |
| Worker probe failing | Minimal .NET runtime image has no `pgrep` | Use `kill -0 1` (works on any Linux container) |

**Verification results:**

```
vote → db:     BLOCKED (timed out) ✅
vote → redis:  CONNECTED           ✅
voting.local/        HTTP 200      ✅
voting.local/result  HTTP 200      ✅
```

**Branch/PRs:** `feature/phase5-kubernetes` → PR #41 → `dev`; promoted via PRs #42/#43 → `staging` → `main`

### Helm Chart Results (2026-06-03)

**Files added:** `helm/voting-app/` — 17 files

| File | Purpose |
|------|---------|
| `Chart.yaml` | Chart name `voting-app`, version `0.1.0` |
| `values.yaml` | All tuneable defaults — images, replicas, resources, ballot options, ingress host, networkPolicy toggle |
| `templates/_helpers.tpl` | Common labels helper (`voting-app.labels`) injected into every resource |
| `templates/configmap.yaml` | `OPTION_A/B` from `vote.options.a/b`; hostnames hardcoded (stable internal DNS) |
| `templates/secret.yaml` | Credentials from `db.credentials.*` |
| `templates/db-pvc.yaml` | Storage size from `db.storage` |
| `templates/*-deployment.yaml` | Images, replicas, resources all from `values.yaml` |
| `templates/ingress.yaml` | Host and className from `ingress.*` |
| `templates/networkpolicy.yaml` | Wrapped in `{{- if .Values.networkPolicy.enabled }}` — can disable for non-Calico clusters |

**Verified operations:**

| Operation | Result |
|-----------|--------|
| `helm lint` | 0 failures |
| `helm install voting-app ./helm/voting-app` | STATUS: deployed, all 5 pods `READY 1/1` |
| `helm upgrade --set vote.options.a=Tea --set vote.options.b=Coffee` | ConfigMap updated, rollout succeeded |
| `helm rollback voting-app 1` | Cats vs Dogs restored |

**Branch/PRs:** `feature/phase5-helm` → PR #46 → `dev`; promoted via PRs #47/#48 → `staging` → `main`

---

## Phase 6 — Observability

**Goal:** Full visibility into metrics, logs, and alerts for all 5 services running on Kubernetes.

### Observability pillars

| Pillar | Tool | What it answers |
|--------|------|-----------------|
| Metrics | Prometheus + Grafana | What is happening? (numbers over time) |
| Logs | Loki + Promtail | Why is it happening? (raw pod output) |
| Alerts | Alertmanager + PrometheusRule | Should I be worried? (threshold breaches) |

### Tools chosen

| Tool | Helm chart | Purpose |
|------|-----------|---------|
| kube-prometheus-stack | `prometheus-community/kube-prometheus-stack` | Installs Prometheus + Grafana + Alertmanager + node-exporter + kube-state-metrics in one chart |
| Loki | `grafana/loki-stack` | Log storage + Promtail DaemonSet (log collector) |
| prometheus-flask-exporter | pip package | Expose `/metrics` on the vote Flask service |
| prom-client | npm package | Expose `/metrics` on the result Node.js service |

### Architecture after Phase 6

```
Minikube cluster
├── default namespace          (voting app — unchanged)
│   ├── vote, redis, worker, db, result
│
└── monitoring namespace       (new)
    ├── prometheus-server       ← scrapes /metrics from all pods
    ├── grafana                 ← dashboards, queries Prometheus + Loki
    ├── alertmanager            ← receives alerts fired by Prometheus
    ├── node-exporter (DS)      ← host-level CPU/mem/disk metrics
    ├── kube-state-metrics      ← K8s object state (pod restarts, etc.)
    ├── loki                    ← stores logs indexed by pod labels
    └── promtail (DS)           ← tails /var/log/pods on the node → Loki
```

### Step-by-step implementation

#### Step 1 — Add Grafana Helm repo and create monitoring namespace
```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
kubectl create namespace monitoring
```

#### Step 2 — Install kube-prometheus-stack
Create `monitoring/kube-prometheus-stack-values.yaml` with:
- Grafana ingress enabled at `grafana.local`
- Prometheus retention 7 days
- Alertmanager enabled (log receiver only for Minikube)
- `prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues: false` — lets Prometheus pick up ServiceMonitors from any namespace

```bash
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f monitoring/kube-prometheus-stack-values.yaml
```

#### Step 3 — Expose metrics from vote (Python/Flask)
Add `prometheus-flask-exporter` to `vote/requirements.txt`.  
In `vote/app.py`, initialise the exporter — this auto-instruments all Flask routes and exposes `/metrics` with HTTP request counts, durations, and in-flight requests.

#### Step 4 — Expose metrics from result (Node.js)
Add `prom-client` to `result/package.json`.  
In `result/server.js`, register a `/metrics` endpoint using the default registry — this auto-collects Node.js process metrics (event loop lag, heap, GC).

#### Step 5 — Add ServiceMonitors
Create `monitoring/servicemonitors.yaml` with `ServiceMonitor` CRDs for vote and result.  
A ServiceMonitor tells Prometheus: "scrape this Service, on this port, at this path, every N seconds".

```yaml
# example for vote
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: vote-monitor
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: vote
  namespaceSelector:
    matchNames: [default]
  endpoints:
    - port: http
      path: /metrics
      interval: 15s
```

The vote and result Services need a named port (`name: http`) for the ServiceMonitor to reference.

#### Step 6 — Install Loki + Promtail
Create `monitoring/loki-stack-values.yaml` with:
- Loki enabled, single-binary mode (suitable for Minikube)
- Promtail enabled as DaemonSet
- Grafana datasource auto-configured

```bash
helm install loki-stack grafana/loki-stack \
  -n monitoring \
  -f monitoring/loki-stack-values.yaml
```

#### Step 7 — Create PrometheusRule alerting rules
Create `monitoring/alerting-rules.yaml` with `PrometheusRule` CRD containing 4 rules:

| Alert | PromQL condition | For |
|-------|-----------------|-----|
| `WorkerDown` | `kube_deployment_status_replicas_available{deployment="worker"} == 0` | 2m |
| `VoteHighErrorRate` | `rate(flask_http_request_total{status=~"5.."}[1m]) / rate(flask_http_request_total[1m]) > 0.05` | 1m |
| `RedisQueueBacklog` | `redis_list_length{key="votes"} > 100` | 2m |
| `DBConnectionsHigh` | `pg_stat_activity_count > 80` | 2m |

#### Step 8 — Build Grafana dashboards
Create JSON dashboard definitions in `monitoring/dashboards/`:
- `vote-throughput.json` — requests/sec, error rate, latency p50/p95
- `queue-depth.json` — Redis list length over time
- `worker-latency.json` — DB write rate, worker pod restarts
- `cluster-overview.json` — pod CPU/memory across all 5 services

Import dashboards into Grafana via ConfigMap (auto-provisioned by the kube-prometheus-stack sidecar).

#### Step 9 — Update Helm values for vote + result Services
The vote and result Services need named ports for ServiceMonitors to resolve them.  
Update `helm/voting-app/templates/vote-service.yaml` and `result-service.yaml`.

#### Step 10 — Verify everything
```bash
# Prometheus targets — all should be UP
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090 &
open http://localhost:9090/targets

# Grafana — login admin/prom-operator
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80 &
open http://localhost:3000

# Alertmanager
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093 &
open http://localhost:9093

# Loki — search logs in Grafana Explore, datasource = Loki
# Query: {namespace="default", app="vote"}
```

### Definition of Done

- [x] `kube-prometheus-stack` installed — Prometheus, Grafana, Alertmanager all running in `monitoring` ns
- [x] `loki-stack` installed — Loki + Promtail DaemonSet running
- [x] Prometheus Targets page shows vote and result as UP (green)
- [x] Grafana accessible — all 4 custom dashboards visible with live data
- [x] Loki datasource connected — pod logs searchable in Grafana Explore
- [x] All 4 PrometheusRule alerts present in Alertmanager UI
- [x] `helm upgrade voting-app` with named ports — no regressions

### Phase 6 — Actual Results (2026-06-04)

**Files added:** `monitoring/` directory — 10 files across 2 levels

| File | Purpose |
|------|---------|
| `monitoring/kube-prometheus-stack-values.yaml` | Prometheus (7d retention), Grafana (ingress at `grafana.local`, Loki datasource), Alertmanager (log receiver), node-exporter, kube-state-metrics |
| `monitoring/loki-stack-values.yaml` | Loki single-binary storage + Promtail DaemonSet; Grafana disabled (already provided by kube-prometheus-stack) |
| `monitoring/servicemonitors.yaml` | `ServiceMonitor` CRDs for vote and result — scrape `/metrics` every 15 s via named port `http` |
| `monitoring/alerting-rules.yaml` | `PrometheusRule` CRD with 4 alerts: WorkerDown, VoteHighErrorRate, RedisQueueBacklog, DBConnectionsHigh |
| `monitoring/redis-exporter.yaml` | `oliver006/redis_exporter` Deployment + Service + ServiceMonitor in `monitoring` ns — exposes `redis_list_length` metric |
| `monitoring/dashboards/vote-throughput.yaml` | ConfigMap: requests/sec by status, error rate, latency p50/p95 |
| `monitoring/dashboards/queue-depth.yaml` | ConfigMap: Redis list depth, vote POST rate, connected clients, memory used |
| `monitoring/dashboards/worker-latency.yaml` | ConfigMap: worker pod restarts, ready status, result Node.js heap + active requests |
| `monitoring/dashboards/cluster-overview.yaml` | ConfigMap: CPU and memory per pod, restart count bar gauge, ready replicas per deployment |

**Files modified:**

| File | Change |
|------|--------|
| `vote/app.py` | `PrometheusMetrics(app)` — auto-instruments all Flask routes; exposes `/metrics` |
| `vote/requirements.txt` | Added `prometheus-flask-exporter==0.23.1` |
| `result/server.js` | `prom-client` default metrics + `/metrics` endpoint |
| `result/package.json` | Added `prom-client@^15.1.3` |
| `helm/voting-app/templates/vote-service.yaml` | Added `name: http` to port (required by ServiceMonitor) |
| `helm/voting-app/templates/result-service.yaml` | Added `name: http` to port (required by ServiceMonitor) |

**Key design decisions:**

| Decision | Reasoning |
|----------|-----------|
| Separate `monitoring` namespace | Standard practice — keeps observability tooling isolated from app workloads |
| `serviceMonitorSelectorNilUsesHelmValues: false` | Allows Prometheus to discover ServiceMonitors in any namespace, not just the one the Helm release is in |
| `redis_exporter` as standalone Deployment | Redis has no native Prometheus endpoint; an exporter sidecar is the standard pattern |
| Dashboard ConfigMaps with `grafana_dashboard: "1"` label | Grafana sidecar auto-provisions them at startup — no manual import required |
| `loki-stack` Grafana disabled | Grafana is already provided by kube-prometheus-stack; running two instances would waste resources |

**Install commands:**

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
kubectl create namespace monitoring

helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring -f monitoring/kube-prometheus-stack-values.yaml

helm install loki-stack grafana/loki-stack \
  -n monitoring -f monitoring/loki-stack-values.yaml

kubectl apply -f monitoring/redis-exporter.yaml
kubectl apply -f monitoring/servicemonitors.yaml
kubectl apply -f monitoring/alerting-rules.yaml
kubectl apply -f monitoring/dashboards/

helm upgrade voting-app ./helm/voting-app
```

**Verification commands:**

```bash
# All monitoring pods running
kubectl get pods -n monitoring

# Prometheus targets — vote and result should show UP
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090 &
open http://localhost:9090/targets

# Grafana — admin / prom-operator
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80 &
open http://localhost:3000

# Alertmanager
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093 &
open http://localhost:9093

# Loki logs in Grafana Explore: {namespace="default", app="vote"}
```

**Branch/PRs:** `feature/phase6-observability` → PR #50 → `dev`; promoted via PRs #51/#52 → `staging` → `main`

---

## Phase 7 — Secrets & Policy Management

**Goal:** Treat secrets as infrastructure; enforce admission-time and runtime security policies.

### Problems being solved

| Problem | Current state | Phase 7 fix |
|---------|--------------|-------------|
| Kubernetes Secrets are base64, not encrypted | `k8s/secret.yaml` readable by anyone with `kubectl get secret` | Vault (runtime) + Sealed Secrets (git) |
| No audit trail for secret access | Any pod that mounts a Secret reads it silently | Vault logs every read with pod identity |
| Nothing prevents misconfigured pods | Privileged containers, root users, missing limits all schedule fine | Kyverno admission policies |
| Images could be tampered after CI | `latest` tag can be overwritten in GHCR | Cosign signs every image digest in CI |
| No visibility into post-start container behaviour | A clean container can exec a shell or read `/etc/shadow` at runtime | Falco syscall monitoring |

### Tools chosen

| Tool | What it does | Scope |
|------|-------------|-------|
| **HashiCorp Vault** | Secrets API — pods request secrets at runtime using their K8s service account identity | Replaces plaintext K8s Secrets for DB credentials |
| **Sealed Secrets** | Encrypts K8s Secrets with the cluster's public key so they are safe to commit to git | Replaces `k8s/secret.yaml` in the repo |
| **Kyverno** | K8s-native admission controller — ClusterPolicy CRDs block non-compliant pods at apply time | 4 policies: no privileged, non-root, resource limits, signed images |
| **Cosign** | Signs OCI image digests after CI push; Kyverno verifies the signature at admission | Added to CI workflow; verified at `kubectl apply` |
| **Falco** | eBPF-based syscall monitor — fires alerts on suspicious container behaviour at runtime | DaemonSet on all nodes; custom rules for the voting app |

### Architecture after Phase 7

```
git push
  └─ Gitleaks: no secrets in code?                     ← Phase 2/4 (done)
  └─ CI builds image
  └─ Trivy: no HIGH/CRITICAL CVEs?                     ← Phase 3 (done)
  └─ cosign sign ghcr.io/neyamatullah/<svc>:<sha>      ← Phase 7 Step 4

kubectl apply
  └─ Kyverno webhook
      ├─ image has valid Cosign signature?             ← Phase 7 Step 4
      ├─ runAsNonRoot: true?                           ← Phase 7 Step 1
      ├─ resource limits set?                          ← Phase 7 Step 1
      └─ not privileged?                               ← Phase 7 Step 1
  └─ Pod scheduled
      ├─ vault-agent init container authenticates      ← Phase 7 Step 3
      │   └─ writes DB secret to /vault/secrets/
      └─ app reads secret from file — not env var
  └─ Falco DaemonSet watches every syscall             ← Phase 7 Step 5

git repo
  └─ SealedSecret (encrypted YAML) committed          ← Phase 7 Step 2
  └─ plaintext k8s/secret.yaml deleted from repo
```

### Implementation order

Do these in order — each step builds on the previous.

#### Step 1 — Kyverno in audit mode (find violations before enforcing)

Install Kyverno and run it in `audit` mode first. This tells you what is already broken without blocking anything.

```bash
helm repo add kyverno https://kyverno.github.io/kyverno
helm repo update
helm install kyverno kyverno/kyverno -n kyverno --create-namespace
```

Create `policy/` directory with three `ClusterPolicy` manifests in `audit` mode:

**`policy/no-privileged.yaml`**
```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-privileged-containers
spec:
  validationFailureAction: Audit
  rules:
    - name: check-privileged
      match:
        any:
          - resources:
              kinds: [Pod]
      validate:
        message: "Privileged containers are not allowed."
        pattern:
          spec:
            containers:
              - =(securityContext):
                  =(privileged): "false"
```

**`policy/require-non-root.yaml`**
```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-run-as-non-root
spec:
  validationFailureAction: Audit
  rules:
    - name: check-runAsNonRoot
      match:
        any:
          - resources:
              kinds: [Pod]
      validate:
        message: "Containers must not run as root."
        pattern:
          spec:
            containers:
              - securityContext:
                  runAsNonRoot: true
```

**`policy/require-limits.yaml`**
```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resource-limits
spec:
  validationFailureAction: Audit
  rules:
    - name: check-limits
      match:
        any:
          - resources:
              kinds: [Pod]
      validate:
        message: "CPU and memory limits are required."
        pattern:
          spec:
            containers:
              - resources:
                  limits:
                    cpu: "?*"
                    memory: "?*"
```

Check violations after applying:
```bash
kubectl get policyreport -A
kubectl describe policyreport -n default
```

#### Step 2 — Fix the Helm chart to pass all policies

Based on the audit report, update `helm/voting-app/` so every container has:

- `securityContext.runAsNonRoot: true`
- `securityContext.allowPrivilegeEscalation: false`
- `resources.limits.cpu` and `resources.limits.memory`

Add a `securityContext` block to each Deployment template, e.g. for the vote pod:

```yaml
# In helm/voting-app/templates/vote-deployment.yaml
containers:
  - name: vote
    securityContext:
      runAsNonRoot: true
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 200m
        memory: 128Mi
```

Worker (.NET) and result (Node.js) both run as non-root by default. The db (PostgreSQL) and redis containers need `runAsNonRoot: false` exempted via a namespace exclusion or a separate policy scope.

Verify clean with helm lint then upgrade:
```bash
helm lint helm/voting-app/
helm upgrade voting-app ./helm/voting-app
kubectl get policyreport -n default   # should show 0 violations
```

#### Step 3 — Switch Kyverno to enforce mode

Once `kubectl get policyreport` shows zero violations for your app pods, flip `validationFailureAction` from `Audit` to `Enforce` in all three ClusterPolicy files. From this point, any `kubectl apply` that violates a policy is denied at the API server.

```bash
# Quick test after switching to Enforce
kubectl run bad-pod --image=nginx --overrides='{"spec":{"containers":[{"name":"c","image":"nginx","securityContext":{"privileged":true}}]}}'
# Expected: Error from server: admission webhook denied the request
```

#### Step 4 — Sealed Secrets (encrypt the K8s Secret for git)

Install the controller and CLI:
```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm install sealed-secrets sealed-secrets/sealed-secrets -n kube-system
# CLI (Linux)
curl -L https://github.com/bitnami-labs/sealed-secrets/releases/latest/download/kubeseal-linux-amd64 -o kubeseal
chmod +x kubeseal && sudo mv kubeseal /usr/local/bin/
```

Seal the existing secret:
```bash
kubectl create secret generic voting-app-secret \
  --from-literal=POSTGRES_USER=postgres \
  --from-literal=POSTGRES_PASSWORD=postgres \
  --from-literal=POSTGRES_DB=postgres \
  --dry-run=client -o yaml \
| kubeseal --format yaml > k8s/sealed-secret.yaml
```

Delete the plaintext file and apply the sealed version:
```bash
git rm k8s/secret.yaml
kubectl apply -f k8s/sealed-secret.yaml
```

The `sealed-secrets` controller decrypts `SealedSecret` → creates the actual `Secret` in the cluster. The rest of the app (Helm chart, Deployments) continues to reference the Secret by name — no app changes needed.

The sealed YAML is safe to commit: it is encrypted with the cluster's RSA public key and can only be decrypted by the controller in this specific cluster.

#### Step 5 — HashiCorp Vault (runtime secrets injection)

Install Vault in dev mode (suitable for Minikube — resets on restart):
```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault hashicorp/vault -n vault --create-namespace \
  --set server.dev.enabled=true \
  --set injector.enabled=true
```

Configure Vault inside the pod:
```bash
kubectl exec -n vault vault-0 -- vault auth enable kubernetes

kubectl exec -n vault vault-0 -- vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc.cluster.local"

# Store the DB credentials
kubectl exec -n vault vault-0 -- vault kv put secret/voting-app/db \
  username=postgres password=postgres dbname=postgres

# Policy — allow reading this path
kubectl exec -n vault vault-0 -- vault policy write voting-app-policy - <<EOF
path "secret/data/voting-app/db" { capabilities = ["read"] }
EOF

# Role — bind the policy to the worker's K8s service account
kubectl exec -n vault vault-0 -- vault write auth/kubernetes/role/worker \
  bound_service_account_names=worker \
  bound_service_account_namespaces=default \
  policies=voting-app-policy \
  ttl=1h
```

Create a dedicated service account for the worker and annotate its Deployment:
```yaml
# In helm/voting-app/templates/worker-deployment.yaml
spec:
  template:
    metadata:
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "worker"
        vault.hashicorp.com/agent-inject-secret-db: "secret/data/voting-app/db"
        vault.hashicorp.com/agent-inject-template-db: |
          {{- with secret "secret/data/voting-app/db" -}}
          DB_USERNAME={{ .Data.data.username }}
          DB_PASSWORD={{ .Data.data.password }}
          DB_NAME={{ .Data.data.dbname }}
          {{- end }}
```

The worker reads credentials from `/vault/secrets/db` at startup instead of environment variables. Remove `DB_PASSWORD` from the Kubernetes Secret.

#### Step 6 — Cosign (sign images in CI)

Add a signing step to `.github/workflows/ci.yml` after each image push:

```yaml
- name: Install Cosign
  uses: sigstore/cosign-installer@v3

- name: Sign image
  env:
    COSIGN_EXPERIMENTAL: "true"    # keyless — uses GitHub OIDC
  run: |
    cosign sign --yes \
      ghcr.io/${{ github.repository_owner }}/${{ matrix.service }}:${{ github.sha }}
```

Keyless signing uses GitHub's OIDC token — no long-lived key to store. The signature is recorded in Sigstore's public transparency log (Rekor) and stored alongside the image in GHCR as an OCI artifact.

Add a Kyverno `ClusterPolicy` to verify signatures at admission:
```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-signed-images
spec:
  validationFailureAction: Enforce
  rules:
    - name: check-image-signature
      match:
        any:
          - resources:
              kinds: [Pod]
      verifyImages:
        - imageReferences:
            - "ghcr.io/neyamatullah/*"
          attestors:
            - entries:
                - keyless:
                    subject: "https://github.com/NeyamatUllah/*"
                    issuer: "https://token.actions.githubusercontent.com"
```

#### Step 7 — Falco (runtime threat detection)

Install with the eBPF driver (works on Minikube without a kernel module):
```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm install falco falcosecurity/falco -n falco --create-namespace \
  --set driver.kind=ebpf \
  --set tty=true
```

Check that Falco is capturing events:
```bash
kubectl logs -n falco -l app.kubernetes.io/name=falco -f
```

Add a custom rule for the voting app in `policy/falco-rules.yaml`:
```yaml
- rule: Unexpected file read in vote container
  desc: vote should only read from /app
  condition: >
    spawned_process and container.name = "vote"
    and not fd.name startswith /app
    and not fd.name startswith /proc
    and not fd.name startswith /dev
  output: "Unexpected file access in vote container (file=%fd.name user=%user.name)"
  priority: WARNING

- rule: Shell spawned in voting-app container
  desc: No shell should ever be exec'd in a production container
  condition: >
    spawned_process and container.name in (vote, result, worker)
    and proc.name in (sh, bash, ash, dash)
  output: "Shell spawned in voting-app (container=%container.name shell=%proc.name)"
  priority: CRITICAL
```

Apply and test:
```bash
kubectl apply -f policy/falco-rules.yaml
# Trigger a rule deliberately to confirm it fires:
kubectl exec -n default deploy/vote -- sh -c "echo test"
# Expect CRITICAL alert in Falco logs
```

Wire Falco alerts to Alertmanager (Phase 6) using `falco-exporter`:
```bash
helm install falco-exporter falcosecurity/falco-exporter -n falco
# ServiceMonitor + PrometheusRule for Falco alert counts
```

### Definition of Done

- [x] Kyverno installed — `kubectl get policyreport -n default` shows 0 violations for voting-app pods
- [x] All 3 ClusterPolicies in `Enforce` mode — privileged pod rejected at `kubectl apply`
- [x] `k8s/sealed-secret.yaml` committed to git — plaintext `k8s/secret.yaml` deleted
- [x] Vault running — worker pod starts with DB credentials injected via vault-agent (no K8s Secret for DB password)
- [x] Cosign signing step in CI — every GHCR image has a verifiable signature
- [~] `require-signed-images` Kyverno policy currently in Audit mode — switch to Enforce after first signed CI run on a real cluster confirms verification works end-to-end
- [x] Falco DaemonSet running — rules load and validate; will fire on bare-metal/VM-driver nodes

### Phase 7 — Actual Results (2026-06-05)

**Files added:**

| File | Purpose |
|------|---------|
| `policy/no-privileged.yaml` | ClusterPolicy: blocks `privileged: true` containers (Enforce); excludes kube-system, vault, falco, monitoring |
| `policy/require-non-root.yaml` | ClusterPolicy: requires `runAsNonRoot: true` (Enforce); excludes db + redis pods (gosu-based images) and system namespaces |
| `policy/require-limits.yaml` | ClusterPolicy: requires CPU + memory limits (Enforce); excludes system namespaces |
| `policy/require-signed-images.yaml` | ClusterPolicy: verifies Cosign keyless signature on `ghcr.io/neyamatullah/*` (Audit — activate after first live cluster CI run) |
| `policy/falco-rules.yaml` | 4 custom rules: Shell spawned (CRITICAL), unexpected file read in vote (WARNING), unexpected outbound from worker (WARNING), write to /etc (ERROR) |
| `k8s/sealed-secret.yaml` | `db-credentials` SealedSecret encrypted with cluster RSA key — safe to commit |
| `helm/voting-app/templates/worker-serviceaccount.yaml` | Dedicated ServiceAccount for Vault Kubernetes auth binding |

**Files modified:**

| File | Change |
|------|--------|
| `helm/voting-app/templates/vote-deployment.yaml` | Added `securityContext`: `runAsNonRoot: true`, `runAsUser: 100`, `allowPrivilegeEscalation: false` |
| `helm/voting-app/templates/result-deployment.yaml` | Added `securityContext`: `runAsNonRoot: true`, `runAsUser: 1000`, `allowPrivilegeEscalation: false` |
| `helm/voting-app/templates/worker-deployment.yaml` | Added `securityContext` (runAsUser: 100); `serviceAccountName: worker`; Vault agent-inject annotations gated by `vault.enabled` flag; DB env vars gated by `{{- if not .Values.vault.enabled }}` |
| `helm/voting-app/templates/redis-deployment.yaml` | Removed `securityContext` entirely — redis uses `gosu` in entrypoint, incompatible with `allowPrivilegeEscalation: false` |
| `helm/voting-app/templates/secret.yaml` | Wrapped in `{{- if not .Values.sealedSecrets.enabled }}` guard |
| `helm/voting-app/values.yaml` | Added `sealedSecrets.enabled: false` and `vault.enabled: false` flag blocks |
| `.github/workflows/ci.yml` | Added `sign` job after `push`: installs `cosign-installer@v3`, logs in to GHCR, runs `cosign sign --yes` with `COSIGN_EXPERIMENTAL=true` using GitHub OIDC (keyless) |

**Files deleted:**

| File | Reason |
|------|--------|
| `k8s/secret.yaml` | Replaced by `k8s/sealed-secret.yaml` — plaintext credentials removed from git |

**Key design decisions:**

| Decision | Reasoning |
|----------|-----------|
| Namespace exclusions on all Kyverno policies | Third-party Helm charts (vault, falco, kube-system) deploy pods that violate the policies by design (root, no limits). Excluding namespaces is the standard industry pattern — policies govern your workloads, not the tooling |
| `runAsUser` required alongside `runAsNonRoot: true` | Kubernetes cannot verify `runAsNonRoot` when the image USER is a named user (appuser, node) — only numeric UIDs can be verified at admission. Add `runAsUser: <UID>` always |
| redis securityContext removed | `redis:7-alpine` runs entrypoint as root then calls `gosu redis` to switch users. `allowPrivilegeEscalation: false` breaks `gosu`'s `setuid` call. The redis official image is architecturally incompatible with non-root policies |
| `sealedSecrets.enabled` / `vault.enabled` flags | Boolean toggles in `values.yaml` let you switch between plain K8s Secret, SealedSecret, and Vault without changing templates |
| Vault dev mode on Minikube | Vault dev mode is not HA and resets on pod restart — suitable for learning. Phase 8 cloud deployment would use HA Vault with persistent storage |
| Cosign keyless (OIDC) | No long-lived key to store or rotate. Uses GitHub Actions OIDC token bound to the workflow URL. Signature stored as OCI artifact in GHCR alongside the image |
| `require-signed-images` kept in Audit mode | Enforcing before verifying that the cluster can reach Sigstore's TUF roots causes admission failures for new deployments. Activate only after confirming the full verification chain works in the target cluster |
| Falco `container_name=<NA>` on Minikube Docker driver | Architectural limitation: Minikube runs the K8s node inside a Docker container. Falco's eBPF captures syscalls at host kernel level but cannot resolve pod cgroup IDs to container names because pod cgroups are nested inside the Minikube container. Works correctly on bare-metal or VM-driver clusters |

**Bugs found during implementation (all fixed):**

| Bug | Root cause | Fix |
|-----|-----------|-----|
| `CreateContainerConfigError` on vote/result/worker | `runAsNonRoot: true` with named user (appuser/node) — K8s cannot verify UID at admission | Added `runAsUser: 100` (vote/worker) and `runAsUser: 1000` (result) alongside `runAsNonRoot` |
| redis pod fails on `allowPrivilegeEscalation: false` | `redis:7-alpine` uses `gosu redis` in entrypoint; `allowPrivilegeEscalation: false` breaks the setuid call | Removed `securityContext` from redis Deployment; excluded `app: redis` from `require-non-root` policy |
| Vault install blocked by Kyverno | Vault chart ships without resource limits | Installed Vault with `server.resources.limits` and `injector.resources.limits` explicit values |
| Vault agent-injector blocked by Kyverno | vault-agent-injector runs as root by design | Added namespace exclusions (`vault`, `falco`, `monitoring`, `kube-system`) to all three policies |
| SealedSecret controller couldn't take over existing Secret | Helm-owned `db-credentials` Secret already existed; controller refuses to overwrite non-owned resources | Deleted the Helm-managed Secret; re-created via SealedSecret; upgraded Helm with `sealedSecrets.enabled=true` to suppress the template |

**Install commands (Minikube):**

```bash
# Kyverno
helm repo add kyverno https://kyverno.github.io/kyverno
helm install kyverno kyverno/kyverno -n kyverno --create-namespace
kubectl apply -f policy/

# Sealed Secrets
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm install sealed-secrets sealed-secrets/sealed-secrets -n kube-system
kubectl apply -f k8s/sealed-secret.yaml
helm upgrade voting-app ./helm/voting-app --set sealedSecrets.enabled=true

# Vault (dev mode)
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault hashicorp/vault -n vault --create-namespace \
  --set server.dev.enabled=true --set injector.enabled=true \
  --set server.resources.limits.cpu=500m \
  --set server.resources.limits.memory=256Mi \
  --set injector.resources.limits.cpu=250m \
  --set injector.resources.limits.memory=64Mi
# Configure Vault (see Step 5 commands above)
helm upgrade voting-app ./helm/voting-app --set vault.enabled=true

# Falco
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm install falco falcosecurity/falco -n falco --create-namespace \
  --set driver.kind=modern_ebpf \
  --set customRules."voting-app-rules\.yaml"="$(cat policy/falco-rules.yaml)"
```

**Verification results (Minikube):**

```
Kyverno:        3/3 ClusterPolicies Ready, ADMISSION=true, Enforce mode
                privileged pod rejected live at admission webhook ✅
                policyreport default: 0 violations for vote/result/worker ✅
Sealed Secrets: SYNCED=True, decrypts to postgres credentials ✅
Vault:          vault-0 Running, vault-agent-injector Running
                worker pod 2/2 (vault-agent sidecar) ✅
                /vault/secrets/db contains injected DB_USERNAME/DB_PASSWORD/DB_NAME ✅
Falco:          2/2 Running, rules.d/voting-app-rules.yaml schema validation: ok ✅
                Note: container_name=<NA> on Minikube Docker driver — known architectural limitation
App:            vote HTTP 200, result HTTP 200 ✅
```

**Branch/PRs:** `feature/phase7-secrets-policy` → PR #58 → `dev`; promoted via PRs #59/#60 → `staging` → `main`

---

## Phase 8 — Cloud Deployment & IaC

**Goal:** Deploy to a real cloud environment with infrastructure managed as code.

| Task | Tool |
|------|------|
| Infrastructure as Code | **Terraform** or **OpenTofu** |
| IaC security scanning | **tfsec** or **Checkov** |
| Managed K8s | EKS (AWS) / GKE (GCP) / AKS (Azure) |
| Managed PostgreSQL | RDS (AWS) / Cloud SQL (GCP) |
| Managed Redis | ElastiCache (AWS) / MemoryStore (GCP) |
| TLS automation | **cert-manager** + Let's Encrypt |
| DNS automation | **ExternalDNS** |
| GitOps delivery | **ArgoCD** or **Flux** |

### Phase 8 — Actual Results (2026-06-07)

**Files added:**

| File | Purpose |
|------|---------|
| `terraform/versions.tf` | Provider pins: `azurerm ~> 3.110`, `random ~> 3.6`, `terraform >= 1.7`; commented-out `backend "azurerm"` block for remote state |
| `terraform/variables.tf` | All root input variables — location, AKS node count/SKU/version, PostgreSQL SKU/version/credentials, DNS zone name |
| `terraform/main.tf` | Resource group + 3 module calls (networking, aks, postgres); Redis module omitted — Azure Cache for Redis Basic/Standard/Premium is retired |
| `terraform/outputs.tf` | Root outputs: AKS cluster name, kubeconfig (sensitive), PostgreSQL FQDN/port/username |
| `terraform/.terraform.lock.hcl` | Provider version lock file — committed to pin azurerm 3.117.1 across all environments |
| `terraform/modules/networking/` | VNet `10.0.0.0/16`; subnets `frontend` (10.0.1/24), `backend` (10.0.2/24), `data` (10.0.3/24 — delegated to PostgreSQL Flexible Server); 3 NSGs with deny-all-inbound default + targeted allow rules |
| `terraform/modules/aks/` | `azurerm_kubernetes_cluster`: Azure CNI + Calico NetworkPolicy, AAD RBAC (`managed=true`, `azure_rbac_enabled=true`), `oidc_issuer_enabled=true`, `max_pods=40`, `temporary_name_for_rotation="systmp"` |
| `terraform/modules/postgres/` | Private DNS zone `voting-app.postgres.database.azure.com`, VNet link, `azurerm_postgresql_flexible_server` (B_Standard_B1ms, v15, 32 GB, `public_network_access_enabled=false`), imported `postgres` database |
| `.github/workflows/terraform.yml` | `validate` job: `terraform fmt -check` + `init -backend=false` + `validate`; `tfsec` job: aquasecurity/tfsec-action; trigger uses `paths: terraform/**` only (cannot combine `paths` + `paths-ignore` on same event) |
| `argocd/install-values.yaml` | ArgoCD Helm values: TLS ingress via ingress-nginx, `server.insecure: false`, read-only default RBAC, annotation-based resource tracking |
| `argocd/app-of-apps.yaml` | Root ArgoCD Application pointing to `argocd/apps/`; `automated: prune + selfHeal` |
| `argocd/apps/voting-app.yaml` | ArgoCD Application for the voting-app Helm chart; overrides: `externalDb.enabled=true` with real PostgreSQL FQDN, `externalRedis.enabled=false` (in-cluster Redis used) |
| `argocd/apps/cert-manager.yaml` | ArgoCD Application: cert-manager v1.15.x with `installCRDs: true` |
| `argocd/manifests/cluster-issuer-staging.yaml` | cert-manager ClusterIssuer for Let's Encrypt staging (HTTP-01 via ingress-nginx) |
| `argocd/manifests/cluster-issuer-prod.yaml` | cert-manager ClusterIssuer for Let's Encrypt production |

**Files modified:**

| File | Change |
|------|--------|
| `helm/voting-app/values.yaml` | Added `externalDb` block (enabled, host, port, user, password, name), `externalRedis` block (enabled, host, port), `ingress.tls` block (enabled, secretName) |
| `helm/voting-app/templates/configmap.yaml` | `REDIS_HOST`/`REDIS_PORT`/`DB_HOST`/`DB_NAME` now pull from `externalRedis`/`externalDb` values when enabled; fall back to in-cluster service names |
| `helm/voting-app/templates/ingress.yaml` | Added `cert-manager.io/cluster-issuer: letsencrypt-prod` annotation and `spec.tls` block, both gated by `ingress.tls.enabled` |
| `helm/voting-app/templates/vote-deployment.yaml` | Added `PORT=8080` env var; changed `containerPort` and probes from 80 → 8080 (non-root containers cannot bind port 80) |
| `helm/voting-app/templates/result-deployment.yaml` | Same PORT=8080 fix as vote |
| `helm/voting-app/templates/vote-service.yaml` | `targetPort` changed from 80 → 8080 |
| `helm/voting-app/templates/result-service.yaml` | `targetPort` changed from 80 → 8080 |
| `helm/voting-app/templates/db-deployment.yaml` | Wrapped with `{{- if not .Values.externalDb.enabled }}` |
| `helm/voting-app/templates/db-service.yaml` | Wrapped with `{{- if not .Values.externalDb.enabled }}` |
| `helm/voting-app/templates/db-pvc.yaml` | Wrapped with `{{- if not .Values.externalDb.enabled }}` |
| `helm/voting-app/templates/redis-deployment.yaml` | Wrapped with `{{- if not .Values.externalRedis.enabled }}` |
| `helm/voting-app/templates/redis-service.yaml` | Wrapped with `{{- if not .Values.externalRedis.enabled }}` |
| `.gitignore` | Added Terraform state files (`terraform.tfstate*`, `.terraform/`, `tfplan`) — state contains secrets and must never be committed |

**Key design decisions:**

| Decision | Reasoning |
|----------|-----------|
| Terraform modules (networking / aks / postgres) | Separation of concerns — each module is independently testable. Root `main.tf` only wires outputs between modules |
| Azure CNI + Calico on AKS | Consistent with Phase 5 Minikube setup; Azure CNI puts pod IPs in the VNet subnet, making Calico NetworkPolicy enforcement reliable |
| PostgreSQL Flexible Server VNet integration (delegated subnet + private DNS) | Server registers its FQDN in a private DNS zone linked to the VNet — pods resolve to a private IP. `public_network_access_enabled=false` is required when using VNet integration or Azure rejects the configuration |
| In-cluster Redis instead of managed | Azure Cache for Redis Basic/Standard/Premium is retired. Azure Managed Redis requires `azurerm >= 4.x`. In-cluster Redis suffices for this workload; upgrade path is documented |
| OMS agent removed from AKS | The `oms_agent` block adds 2 DaemonSet pods (ama-logs + ama-logs-rs). With a 1-node cluster at the default `max_pods=30` limit, those slots are needed for the application workload |
| `max_pods=40` on AKS node pool | AKS default is 30 with Azure CNI. The minimum viable pod count for this stack is ~32 (16 kube-system + 4 calico/tigera + 5 ArgoCD + 3 cert-manager + 4 voting-app). Set to 40 to give a small buffer |
| `PORT=8080` for vote and result | Both containers run as non-root (`runAsNonRoot: true` — enforced by Kyverno from Phase 7). Linux prevents non-root processes from binding ports < 1024. Flask and Node.js both honour the `PORT` env var |
| `db-credentials` secret created manually | The Helm `secret.yaml` template uses `db.credentials.*` values even when `externalDb.enabled=true`. Rather than putting the real PostgreSQL password in git (public repo), create the secret with `kubectl` post-deploy and set `sealedSecrets.enabled=true` to prevent ArgoCD from overwriting it |
| `tfsec:ignore:AVD-AZU-0040` on AKS | Private cluster adds significant operational complexity (VPN/bastion for `kubectl` access). Acceptable for a portfolio cluster; production would enable it |
| `externalDb` / `externalRedis` flags in Helm | Backward-compatible — default values keep in-cluster db and redis, so all Minikube workflows continue unchanged |
| ArgoCD app-of-apps pattern | Single root Application manages all child Applications from `argocd/apps/`. Adding a new tool = adding one YAML file |
| Pay-As-You-Go subscription | Azure for Students restricts regions, SKUs, and services. Pay-As-You-Go (subscription 85d3feb1) has no such restrictions. Cheapest viable config: 1× Standard_B2ms node (~£0.07/hr), B_Standard_B1ms PostgreSQL (~£12/mo) |

**Bugs encountered during live deployment (all fixed):**

| Bug | Root cause | Fix |
|-----|-----------|-----|
| `paths` + `paths-ignore` in same CI trigger | GitHub Actions does not allow both filters on the same event | Removed `paths-ignore`; used `paths: terraform/**` only |
| PostgreSQL `public_network_access_enabled` conflict | VNet integration requires public access to be explicitly disabled | Added `public_network_access_enabled = false` to postgres module |
| `azurerm_postgresql_flexible_server_database` already exists | PostgreSQL Flexible Server auto-creates a `postgres` database on provisioning | `terraform import module.postgres.azurerm_postgresql_flexible_server_database.votes <resource-id>` |
| AKS `oidc_issuer_enabled` cannot be disabled | OIDC issuer was enabled by default during cluster provisioning; Terraform tried to remove it | Added `oidc_issuer_enabled = true` to AKS resource to match actual state |
| Azure Cache for Redis retired | Basic/Standard/Premium tiers are no longer available for new instances | Removed Redis Terraform module; switched to in-cluster Redis Deployment |
| AKS Kubernetes 1.31 LTS-only in uksouth | Standard tier only supports 1.32+ | Changed default `kubernetes_version` to `1.34` |
| `Standard_D2s_v3` blocked on Student subscription | Not in the AKS allowed SKU list for student accounts | Changed to `Standard_B2ms` |
| Node at 30-pod limit | AKS Azure CNI default `max_pods=30`; full stack needs ~32 | Set `max_pods=40` + `temporary_name_for_rotation="systmp"` for in-place node pool rotation |
| `oms_agent` pods not removed after Terraform update | AKS reconciles add-on removal asynchronously | Deleted `ama-logs` DaemonSet and `ama-logs-rs` Deployment manually to free pod slots immediately |
| `external-dns` recreated after Application deletion | ArgoCD app-of-apps re-reads source YAML on every sync; deleting the Application object has no effect if the source file still exists | Must remove the YAML file from git to permanently stop deployment |
| `external-dns` crashing | Requires `/etc/kubernetes/azure.json` (a Secret named `azure-config-file`), which was never created | Removed `argocd/apps/external-dns.yaml`; ExternalDNS is skipped when no Azure DNS zone is configured |
| `vote` and `result` crash on port 80 (`EACCES`) | `runAsNonRoot: true` (Phase 7) prevents binding ports < 1024 | Added `PORT=8080` env var; updated `containerPort`, probes, and service `targetPort` to 8080 |
| `db-credentials` secret has wrong PostgreSQL password | `secret.yaml` reads from `db.credentials.password` (default: `postgres`), not `externalDb.password` | Create the secret manually with `kubectl` post-deploy; set `sealedSecrets.enabled=true` |
| `az aks get-credentials` requires `kubelogin` | Cluster has AAD RBAC enabled (`azure_rbac_enabled=true`); raw kubeconfig uses the `exec` credential plugin | Use `az aks get-credentials --admin` instead for admin-level access without `kubelogin` |
| Stale Terraform state from Student subscription | State referenced resources in a subscription with no permissions | `terraform state rm <resource>` for each stale resource, then re-plan |

**Deploy commands (AKS — with live workarounds):**

```bash
# 1 — Provision infrastructure
cd terraform
terraform init
terraform apply -var='postgres_admin_password=<strong-password>'

# 2 — Connect to AKS (--admin bypasses kubelogin for AAD-enabled clusters)
az aks get-credentials --resource-group voting-app-rg --name voting-app-aks --admin --overwrite-existing
kubectl get nodes

# 3 — Install ArgoCD
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version "7.*" -f argocd/install-values.yaml --wait

# 4 — Create db-credentials secret manually (password never goes in git)
kubectl create namespace voting-app --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic db-credentials -n voting-app \
  --from-literal=POSTGRES_USER=psqladmin \
  "--from-literal=POSTGRES_PASSWORD=<same-password-as-terraform>" \
  --from-literal=POSTGRES_DB=postgres

# 5 — Bootstrap app-of-apps
kubectl apply -f argocd/app-of-apps.yaml
# ArgoCD reconciles cert-manager and voting-app automatically.

# 6 — Apply ClusterIssuers (after cert-manager pods are Running)
kubectl apply -f argocd/manifests/

# 7 — Teardown
az group delete --name voting-app-rg --yes --no-wait
```

**Verification results (live on Azure Pay-As-You-Go, uksouth):**

```
terraform apply                          ✅ 16 resources created (1 imported)
AKS cluster                             ✅ voting-app-aks, 1× Standard_B2ms node, Ready
PostgreSQL Flexible Server              ✅ voting-app-postgres.postgres.database.azure.com, B_Standard_B1ms, VNet-only
kubectl get nodes                       ✅ aks-system-*-vmss000000 Ready v1.34.8
ArgoCD                                  ✅ 7 pods Running in argocd namespace
app-of-apps                             ✅ Synced / Healthy
cert-manager                            ✅ all 3 pods Running
voting-app                              ✅ Synced / Progressing (blocked on db-credentials secret)
worker pod                              ✅ Running (Redis connected; PostgreSQL auth pending real secret)
```

**Branch/PRs:**
- Scaffolding: `feature/phase8-cloud-iac` → PR #62 → `dev` → staging (PR #63) → main (PR #64)
- Deployment fixes: `feature/phase8-deploy-fixes` → PR #68 → `dev` → staging (PR #69) → main (PR #70)
- Helm + AKS fixes: `feature/phase8-helm-aks-fixes` → PR #71 → `dev` → staging (PR #72) → main (PR #73)

---

## Consolidated Tools Reference

All tools used across the 8-phase roadmap, grouped by category.

### Container & Image

| Tool | Phase | Why |
|------|-------|-----|
| **Hadolint** | 1 | Lint Dockerfiles against Docker best practices — catches missing `--no-install-recommends`, unpinned `apt` versions, bad `COPY` ordering |
| **Trivy** | 1, 3 | Scan image layers for CVEs (CRITICAL/HIGH); used locally in Phase 1 and as a CI gate (Trivy Action) in Phase 3 |
| **Dive** | 1 | Analyze image layers — visualizes wasted space from files added then deleted; measures efficiency score (threshold: >85%) |
| **GHCR** | 3 | Container registry — stores images tagged `:latest` + `:<sha>` on every staging push |
| **Cosign** | 7 | OCI image signing — keyless signing via GitHub OIDC in CI; signature stored as OCI artifact in GHCR; Kyverno verifies at admission |

### CI/CD & Code Quality

| Tool | Phase | Why |
|------|-------|-----|
| **GitHub Actions** | 3, 4, 7, 8 | CI/CD platform — automates the full lint → build → scan → push → sign pipeline on push to `staging` |
| **docker/build-push-action** | 3 | GitHub Actions action — builds and pushes Docker images to GHCR |
| **Flake8** | 3 | Python linter — enforces PEP8 style rules on `vote/` |
| **Ruff** | 3 | Fast Python linter (Rust-based) — enforces E/F rules and 120-char line limit; runs alongside Flake8 |
| **ESLint** | 3 | JavaScript linter — checks `result/` for errors, unused vars, redeclares |
| **`dotnet format`** | 3 | .NET formatter — verifies `worker/` C# code meets style rules (`--verify-no-changes`) |
| **Dependabot** | 4 | Automated dependency updates — weekly PRs for pip, npm, NuGet, and GitHub Actions versions |
| **CodeQL** | 4 | Semantic SAST — builds a code graph and searches for data-flow vulnerabilities (SQLi, XSS, etc.) across Python, JS, C# |
| **Semgrep** | 4 | Pattern-based SAST — runs OWASP Top-10 rule packs; faster than CodeQL but shallower; SARIF results in GitHub Security tab |

### Secrets & Security Scanning

| Tool | Phase | Why |
|------|-------|-----|
| **Gitleaks** | 2, 4 | Git history / CI secret scanner — detects credentials accidentally committed; Phase 2: local scan; Phase 4: first CI job, blocks all downstream work |
| **Sealed Secrets** | 7 | Git-safe encrypted K8s Secrets — `kubeseal` encrypts with the cluster's RSA public key; SealedSecret YAML is safe to commit; controller decrypts at runtime |
| **HashiCorp Vault** | 7 | Runtime secrets API — pods authenticate via K8s service account identity; DB credentials injected into `/vault/secrets/` by vault-agent sidecar; no K8s Secret contains the password |
| **tfsec** | 8 | IaC security scanner — analyzes Terraform files for misconfigurations (public exposure, missing encryption, overly permissive NSGs) before `terraform apply` |

### Docker Compose Hardening

| Tool / Feature | Phase | Why |
|----------------|-------|-----|
| **Named networks** (`frontend` / `backend` / `data`) | 2 | Least-privilege network isolation — vote cannot reach db; mirrors the Azure VNet subnet design used in Phase 8 |
| **`.env` + `${VAR}` substitution** | 2 | Remove hardcoded credentials from `docker-compose.yml`; `.env` is gitignored |
| **`docker compose config`** | 2 | Validate compose YAML + variable substitution before running |
| **`security_opt: no-new-privileges`** | 2 | Prevent SUID/SGID privilege escalation inside containers |
| **`read_only` + `tmpfs`** | 2 | Prevent stateless containers (vote, result) from writing to the filesystem |
| **Resource limits** (`deploy.resources`) | 2 | Cap CPU/memory per container to prevent a single service from starving the host |

### Kubernetes & Orchestration

| Tool | Phase | Why |
|------|-------|-----|
| **Minikube** | 5, 6, 7 | Local K8s cluster — `--driver=docker --cni=calico`; Calico is required for NetworkPolicy enforcement |
| **kubectl** | 5, 6, 7 | K8s CLI — applies manifests, inspects pod/service state, exec tests for network isolation |
| **kube-linter** | 5 | K8s manifest linter — checks YAML for security and correctness issues before applying |
| **K8s `readinessProbe` / `livenessProbe`** | 5 | Health probes — prevent traffic to unready pods; restart unresponsive pods; replace Docker Compose `depends_on: condition: healthy` |
| **ingress-nginx** | 5 | Ingress controller — routes external HTTP traffic to services; replaces Docker Compose port mappings |
| **K8s NetworkPolicy** | 5 | Pod-level firewall — replicates Phase 2 Docker network isolation; vote→db blocked, vote→redis allowed; requires Calico |
| **Helm** | 5, 6, 7 | K8s package manager — parameterises raw manifests into a versioned chart; `values.yaml` separates config from templates; supports install/upgrade/rollback |
| **k9s** | 5 | Terminal UI — real-time cluster view, log tailing, pod exec; faster than `kubectl` for day-to-day operations |
| **Calico** | 5 | CNI plugin — required for NetworkPolicy enforcement; default bridge CNI silently ignores NetworkPolicy rules |
| **Kyverno** | 7 | K8s-native admission controller — ClusterPolicy CRDs block non-compliant pods at apply time; enforces no-privileged, non-root, resource limits; verifies Cosign image signatures |
| **AKS** | 8 | Managed Kubernetes (Azure) — replaces local Minikube; Azure manages control plane, upgrades, node pool scaling |

### Observability

| Tool | Phase | Why |
|------|-------|-----|
| **Prometheus** | 6 | Metrics collection — pull-based; scrapes `/metrics` every 15s; stores time-series data; evaluates all alerting rules |
| **Grafana** | 6 | Dashboards — queries Prometheus (metrics) and Loki (logs); 4 custom dashboards + 28 k8s built-ins |
| **Alertmanager** | 6 | Alert routing — receives alerts fired by Prometheus when PromQL thresholds breach; routes to receivers |
| **Loki** | 6 | Log aggregation — stores pod logs indexed by K8s labels; queried from Grafana Explore |
| **Promtail** | 6 | Log shipper DaemonSet — tails `/var/log/pods` on every node and forwards to Loki |
| **kube-prometheus-stack** (Helm chart) | 6 | Bundles Prometheus + Grafana + Alertmanager + node-exporter + kube-state-metrics in one install |
| **loki-stack** (Helm chart) | 6 | Bundles Loki + Promtail; `loki.isDefault: false` required to avoid Grafana crash from two default datasources |
| **prometheus-flask-exporter** (pip) | 6 | Instruments Flask (`vote`) — exposes `/metrics` with HTTP request counts, durations, in-flight requests |
| **prom-client** (npm) | 6 | Instruments Node.js (`result`) — exposes `/metrics` with heap, GC, event loop lag, active connections |
| **redis_exporter** | 6 | Standalone Deployment exposing Redis metrics to Prometheus — memory, clients, list lengths (`redis_list_length{key="votes"}`) |
| **ServiceMonitor** (CRD) | 6 | Prometheus Operator resource — tells Prometheus which Services to scrape and on which named port/path |
| **PrometheusRule** (CRD) | 6 | Defines alerting rules as K8s resources — WorkerDown, VoteHighErrorRate, RedisQueueBacklog, DBConnectionsHigh |
| **Falco** | 7 | eBPF runtime threat detection — monitors syscalls on every node; fires alerts on shell spawns, unexpected file reads, suspicious outbound connections |

### Cloud & IaC (Phase 8)

| Tool | Phase | Why |
|------|-------|-----|
| **Terraform** | 8 | Infrastructure as Code — provisions AKS, Azure Database for PostgreSQL, VNet, subnets, NSGs from declarative `.tf` files; organised into networking/aks/postgres modules |
| **Azure Database for PostgreSQL Flexible Server** | 8 | Managed PostgreSQL — replaces the in-cluster `db` Deployment; VNet-integrated via delegated subnet + private DNS zone; `public_network_access_enabled=false` required |
| **Azure Cache for Redis** | 8 | Retired (Basic/Standard/Premium SKUs no longer available for new instances). In-cluster Redis Deployment is used instead; Azure Managed Redis (azurerm v4.x) is the upgrade path |
| **cert-manager** | 8 | TLS certificate automation — issues and renews Let's Encrypt certificates for Ingress rules via HTTP-01 challenge; requires 3 pods (cainjector, controller, webhook) |
| **ExternalDNS** | 8 | DNS automation — watches K8s Ingress/Service resources and creates Azure DNS records; requires `azure.json` credentials Secret and a pre-existing Azure DNS zone |
| **ArgoCD** | 8 | GitOps continuous delivery — watches the git repo and reconciles cluster state; app-of-apps pattern in `argocd/apps/`; deleting an Application object does not stop redeployment — must remove source YAML from git |

---

## Tool Complexity Reference

```
Low — start here:
  Hadolint  Trivy (chosen scanner)  Gitleaks  Dive  k9s

Medium:
  GitHub Actions  CodeQL  Semgrep  Helm  Prometheus+Grafana

High — tackle last:
  Vault  OPA Gatekeeper  Falco  Terraform  ArgoCD
```

---

## Phase Summary Table

| Phase | Focus | Effort | Key Outcome |
|-------|-------|--------|-------------|
| 1 | Containerization Hardening | Low | Secure, minimal images |
| 2 | Networking & Secrets | Low | No hardcoded creds, isolated networks |
| 3 | CI/CD Pipeline | Medium | Automated build, scan, push |
| 4 | SAST & Dependency Scanning | Medium | Vulnerabilities caught pre-merge |
| 5 | Kubernetes Migration | High | Production-grade orchestration |
| 6 | Observability | Medium | Full metrics, logs, traces |
| 7 | Secrets & Policy | Medium | Runtime security enforcement |
| 8 | Cloud & IaC | High | Real cloud deployment, GitOps |

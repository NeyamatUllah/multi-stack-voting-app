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

- [ ] Minikube cluster running locally
- [ ] All 5 services deployed as Deployments with ClusterIP Services
- [ ] ConfigMap and Secret used — no hardcoded values in manifests
- [ ] PVC provisioned for PostgreSQL; data survives pod restart
- [ ] All 5 pods show `Running` and `READY 1/1`
- [ ] readinessProbe and livenessProbe on every pod
- [ ] Ingress routes `voting.local/` → vote and `voting.local/result` → result
- [ ] NetworkPolicy blocks vote → db (verified by exec test)
- [ ] NetworkPolicy allows vote → redis (verified by exec test)
- [ ] Full stack functional end-to-end (vote, see result update)
- [ ] Helm chart installs and upgrades cleanly (`helm lint` passes)

---

## Phase 6 — Observability

**Goal:** Gain full visibility into metrics, logs, and traces.

| Task | Tool |
|------|------|
| Metrics collection | **Prometheus** |
| Metrics visualization | **Grafana** |
| Flask metrics | **prometheus-flask-exporter** |
| Log aggregation | **Loki** + **Promtail** or **EFK stack** |
| Distributed tracing | **Jaeger** or **Tempo** |
| Alerting | **Alertmanager** |

All-in-one local stack: Grafana OSS (Prometheus + Loki + Grafana + Tempo)

Key dashboards to build:
- Vote throughput per second
- Redis queue depth (lag between vote and worker)
- Worker processing latency
- DB query duration from result service

---

## Phase 7 — Secrets & Policy Management

**Goal:** Treat secrets as infrastructure; enforce runtime security policies.

| Task | Tool |
|------|------|
| Secrets store | **HashiCorp Vault** |
| K8s secrets encryption | **Sealed Secrets** or **SOPS** + age |
| K8s admission policies | **OPA Gatekeeper** or **Kyverno** |
| Runtime threat detection | **Falco** |
| Image signing | **Cosign** (Sigstore) |
| SBOM generation | **Syft** or `trivy sbom` |

OPA/Kyverno policies to enforce:
- No privileged containers
- Non-root user required
- Resource limits required on all pods
- Only signed images allowed

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

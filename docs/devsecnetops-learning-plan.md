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

- [ ] `vote/.dockerignore` exists
- [ ] All base image tags are pinned to exact versions
- [ ] All three Dockerfiles pass Hadolint with zero warnings
- [ ] All three Dockerfiles run as a non-root user
- [ ] `docker-compose.yml` uses `build:` not `image: pokfinner/*`
- [ ] `docker compose build` completes successfully
- [ ] Trivy reports zero CRITICAL/HIGH CVEs across all three images
- [ ] Dive efficiency score is above 85% for all three images

---

## Phase 2 — Docker Compose: Networking & Secrets

**Goal:** Enforce network isolation and remove hardcoded secrets.

| Task | Tool |
|------|------|
| Secrets via env file | Docker Compose `.env` |
| Validate compose config | `docker compose config` |
| Local secret management | **direnv** or **dotenv-vault** |

Key actions:
- Split single `back-tier` network into `front-tier` (vote, result) and `back-tier` (redis, db, worker)
- Move all credentials out of `docker-compose.yml` into `.env` (gitignored)
- Add resource limits (`mem_limit`, `cpus`) per service
- Add `read_only: true` + `tmpfs` where applicable

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

Pipeline stages: lint → build → scan → push (on `main` merge only)

---

## Phase 4 — SAST & Dependency Scanning

**Goal:** Find vulnerabilities in code and dependencies before they ship.

| Task | Tool |
|------|------|
| Dependency auto-updates | **Dependabot** |
| Static analysis | **CodeQL** (GitHub native) |
| Rules-based SAST | **Semgrep** |
| Dependency CVE scan | **OWASP Dependency-Check** |
| Secret detection in commits | **Gitleaks**, **TruffleHog** |
| License compliance | **FOSSA** or `trivy --scanners license` |

---

## Phase 5 — Kubernetes Migration

**Goal:** Move from Docker Compose to a production-grade K8s setup.

| Task | Tool |
|------|------|
| Local K8s cluster | **Minikube** or **kind** |
| CLI management | **kubectl** |
| Compose → K8s conversion | **Kompose** (starting point) |
| Manifest linting | **kube-linter**, **kubeval** |
| Packaging | **Helm** |
| Ingress | **ingress-nginx** |
| Network policies | Native K8s `NetworkPolicy` + **Calico** |
| Cluster UI | **Lens** (desktop) or **k9s** (terminal) |

Migration order:
1. Raw manifests: `Deployment`, `Service`, `ConfigMap`, `Secret`
2. Add `readinessProbe` + `livenessProbe` to each pod
3. Add `Ingress` to route `/` → vote, `/result` → result
4. Apply `NetworkPolicy` to replicate front/back-tier isolation
5. Package as a Helm chart

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

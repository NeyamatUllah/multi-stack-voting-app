# Solution Architecture Document
# Multi-Stack Voting Application

| Field | Detail |
|-------|--------|
| **Project** | Multi-Stack Voting Application |
| **Author** | NeyamatUllah |
| **Version** | 1.0 |
| **Date** | 2026-05-31 |
| **Status** | In Progress |

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Business Context](#2-business-context)
3. [System Overview](#3-system-overview)
4. [Architecture Principles](#4-architecture-principles)
5. [Current State Architecture (As-Is)](#5-current-state-architecture-as-is)
6. [Target State Architecture (To-Be)](#6-target-state-architecture-to-be)
7. [Architecture Diagrams](#7-architecture-diagrams)
8. [Technology Stack](#8-technology-stack)
9. [Data Architecture](#9-data-architecture)
10. [Security Architecture](#10-security-architecture)
11. [Infrastructure Architecture](#11-infrastructure-architecture)
12. [DevSecOps Architecture](#12-devsecops-architecture)
13. [Observability Architecture](#13-observability-architecture)
14. [Non-Functional Requirements](#14-non-functional-requirements)
15. [Risk Register](#15-risk-register)
16. [Architecture Decision Records](#16-architecture-decision-records)
17. [Dependencies and Integrations](#17-dependencies-and-integrations)

---

## 1. Executive Summary

This document describes the architecture of a multi-stack voting application used as a hands-on learning platform for DevSecNetOps practices. The application allows users to vote between two options and view live results.

The system is intentionally built using multiple languages and frameworks — Python, .NET, and Node.js — to simulate the diversity found in real-world distributed systems. The primary goal is not production readiness out of the box, but to provide a realistic, multi-service environment for progressively applying containerisation, CI/CD, security hardening, Kubernetes orchestration, observability, and cloud deployment practices across eight structured phases.

**Current state:** A functional but unhardened Docker Compose application running on a single host using prebuilt external images with hardcoded credentials and no security controls.

**Target state:** A fully containerised, security-scanned, policy-enforced, observable system deployed to Kubernetes on a cloud provider, managed entirely through Infrastructure as Code and GitOps.

---

## 2. Business Context

### 2.1 Purpose

This project serves as a structured learning environment for developing end-to-end DevSecNetOps skills using a realistic multi-service application. It replaces theoretical study with hands-on implementation across real tools and real problems.

### 2.2 Stakeholder

| Stakeholder | Role | Interest |
|-------------|------|---------|
| NeyamatUllah | Developer / Learner | Build practical DevSecNetOps skills progressively |

### 2.3 Constraints

| Constraint | Detail |
|------------|--------|
| Environment | Local machine + cloud (Phase 8) |
| Languages | Fixed — Python, .NET 8, Node.js (multi-stack by design) |
| Approach | Phases must be followed chronologically |
| Budget | Minimal — prefer open-source and free-tier tools |

### 2.4 Assumptions

- Docker and Docker Compose are available on the development machine
- A GitHub account is available for CI/CD pipelines
- Cloud credentials will be obtained when Phase 8 begins
- The voting options (Cats vs Dogs) are fixed for simplicity

---

## 3. System Overview

### 3.1 What the System Does

A browser-based voting application where:
- Users visit a web page and vote for one of two options
- Each user's vote is stored and can be changed (one vote per browser)
- A separate results page shows live vote counts updating in real time

### 3.2 User Personas

| Persona | Interaction |
|---------|------------|
| Voter | Visits vote UI at `:8080`, submits a vote via form |
| Observer | Visits result UI at `:8081`, watches live counts via WebSocket |

### 3.3 Scope

**In scope:**
- Vote submission and storage
- Real-time result display
- Full DevSecNetOps toolchain implementation across 8 phases

**Out of scope:**
- User authentication and login
- Multiple voting topics
- Admin interface
- Mobile application

---

## 4. Architecture Principles

| Principle | Description |
|-----------|-------------|
| **Security by default** | Every layer is hardened — images, networks, secrets, runtime |
| **Everything containerised** | No service runs directly on the host in production |
| **Least privilege** | Services and containers get only the access they need |
| **Immutable infrastructure** | Images are built once, scanned, and promoted — never patched in place |
| **Shift security left** | Security checks happen at code commit, not at deployment |
| **Observable by design** | Metrics, logs, and traces are built in, not added later |
| **Infrastructure as Code** | All infrastructure is defined in version-controlled files |
| **GitOps** | The Git repository is the single source of truth for deployments |
| **Fail fast** | Services retry and reconnect rather than silently fail |
| **Loose coupling** | Services communicate through queues and APIs, not direct calls |

---

## 5. Current State Architecture (As-Is)

### 5.1 Overview

The current system runs as five Docker containers orchestrated by a single `docker-compose.yml` on a local host machine. All services use prebuilt external images and share a single flat internal network.

### 5.2 Current Data Flow

```
Browser
  │
  │  HTTP POST /vote
  ▼
vote (Python/Flask)
  │  pushes JSON: {"voter_id": "abc", "vote": "a"}
  │  RPUSH "votes"
  ▼
redis (in-memory queue)
  │  list: "votes"
  │  BLPOP every 100ms
  ▼
worker (.NET 8)
  │  deserialises JSON
  │  INSERT or UPDATE votes table
  ▼
PostgreSQL
  │  TABLE votes: id VARCHAR, vote VARCHAR
  │  SELECT COUNT(*) GROUP BY vote — every 1 second
  ▼
result (Node.js)
  │  Socket.IO emit "scores"
  ▼
Browser (live update)
```

### 5.3 Current Network Design

```
Internet
    │
    ├── :8080 ──► vote
    └── :8081 ──► result
                    │
             back-tier (single flat network)
          ┌──────────────────────────┐
          │  redis   db   worker     │
          └──────────────────────────┘
```

All five services share one network. No isolation between presentation and data services.

### 5.4 Current Security Posture

| Area | Current State | Risk |
|------|--------------|------|
| Secrets | Hardcoded in `docker-compose.yml` | CRITICAL |
| Images | Prebuilt external images (unverified) | CRITICAL |
| Image tags | Unpinned floating tags | HIGH |
| Network | Single flat network | HIGH |
| Container user | Likely running as root | HIGH |
| `.dockerignore` | Missing from `vote/` | MEDIUM |
| Resource limits | None configured | MEDIUM |
| CVE scanning | None | HIGH |
| Secret scanning | None | HIGH |

### 5.5 Current Gaps Summary

```
No security scanning          ──► Phase 1, 3, 4
Hardcoded secrets             ──► Phase 2
Flat network                  ──► Phase 2
External unverified images    ──► Phase 1
No CI/CD pipeline             ──► Phase 3
No Kubernetes                 ──► Phase 5
No observability              ──► Phase 6
No secrets management         ──► Phase 7
No cloud deployment           ──► Phase 8
```

---

## 6. Target State Architecture (To-Be)

### 6.1 Overview

The target state is a fully hardened, observable, policy-enforced system running on Kubernetes in a cloud provider, with all infrastructure managed as code and all deployments triggered through a GitOps pipeline.

### 6.2 Target Data Flow

```
Browser
  │  HTTPS (TLS via cert-manager)
  ▼
Ingress (nginx)
  ├──► /        ──► vote  (Presentation Tier)
  └──► /result  ──► result
                      │
              front-tier network
                      │
              back-tier network
  ┌───────────────────────────────┐
  │  redis          db            │
  │    ▲             ▲            │
  │    │             │            │
  │  worker ─────────┘            │
  └───────────────────────────────┘
```

### 6.3 Target Infrastructure

```
Cloud Provider (AWS / GCP / Azure)
  │
  ├── VPC / Virtual Network
  │     ├── Public Subnet   ── Ingress / Load Balancer
  │     └── Private Subnet  ── Kubernetes Node Pool
  │
  ├── Managed Kubernetes (EKS / GKE / AKS)
  │     ├── vote Deployment        (3 replicas)
  │     ├── result Deployment      (2 replicas)
  │     ├── worker Deployment      (1 replica)
  │     ├── NetworkPolicy          (front/back tier isolation)
  │     ├── OPA Gatekeeper         (admission policies)
  │     └── Falco                  (runtime threat detection)
  │
  ├── Managed PostgreSQL (RDS / Cloud SQL)
  ├── Managed Redis (ElastiCache / MemoryStore)
  └── HashiCorp Vault (secrets management)
```

### 6.4 Target CI/CD Pipeline

```
Git push
  │
  ├── Lint (Hadolint, Flake8, ESLint, dotnet format)
  ├── SAST (CodeQL, Semgrep)
  ├── Dependency scan (OWASP Dependency-Check)
  ├── Secret scan (Gitleaks)
  ├── Build Docker images
  ├── CVE scan (Trivy) ── fail on CRITICAL/HIGH
  ├── Sign images (Cosign)
  ├── Push to registry (GHCR)
  └── Deploy via GitOps (ArgoCD / Flux)
```

---

## 7. Architecture Diagrams

### 7.1 Three-Tier Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                    TIER 1 — PRESENTATION                         │
│                                                                  │
│    ┌──────────────────┐        ┌──────────────────┐             │
│    │      vote        │        │      result       │             │
│    │  Python / Flask  │        │  Node.js/Express  │             │
│    │  Gunicorn :8080  │        │  Socket.IO :8081  │             │
│    └──────────────────┘        └──────────────────┘             │
└──────────────┬─────────────────────────▲────────────────────────┘
               │ RPUSH                   │ SELECT every 1s
               │                         │
┌──────────────▼─────────────────────────┼────────────────────────┐
│                    TIER 2 — APPLICATION                          │
│                                                                  │
│              ┌──────────────────────────┐                        │
│              │          worker          │                        │
│              │       .NET 8 / C#        │                        │
│              │  polls Redis, writes DB  │                        │
│              └──────────────────────────┘                        │
└──────────────────────────┬──────────────────────────────────────┘
                           │ INSERT / UPDATE
                           │
┌──────────────────────────▼──────────────────────────────────────┐
│                      TIER 3 — DATA                               │
│                                                                  │
│    ┌──────────────────┐        ┌──────────────────┐             │
│    │      redis       │        │        db         │             │
│    │  Message Queue   │        │   PostgreSQL 15   │             │
│    │  list: "votes"   │        │   TABLE: votes    │             │
│    └──────────────────┘        └──────────────────┘             │
└──────────────────────────────────────────────────────────────────┘

Browser ──HTTP──► vote        (Tier 1)
Browser ◄──WebSocket── result (Tier 1)
```

> The draw.io file for this diagram is at `docs/architecture-3tier.drawio`

### 7.2 Network Isolation (Target State)

```
Internet
    │
    │ HTTPS :443
    ▼
┌─────────────────┐
│  Ingress/nginx  │
└────────┬────────┘
         │
┌────────▼────────────────────────────┐
│           front-tier network         │
│   ┌──────────┐    ┌──────────────┐  │
│   │   vote   │    │    result    │  │
│   └────┬─────┘    └──────▲───────┘  │
└────────┼─────────────────┼──────────┘
         │ (worker only)   │
┌────────▼─────────────────┼──────────┐
│           back-tier network          │
│   ┌──────────┐    ┌──────┴───────┐  │
│   │  redis   │    │      db      │  │
│   └────▲─────┘    └──────────────┘  │
│        │                            │
│   ┌────┴─────┐                      │
│   │  worker  │                      │
│   └──────────┘                      │
└──────────────────────────────────────┘
```

---

## 8. Technology Stack

### 8.1 Application Services

| Service | Language | Framework | Version | Role |
|---------|----------|-----------|---------|------|
| vote | Python | Flask + Gunicorn | 3.11 | Accepts votes, pushes to Redis |
| result | JavaScript | Node.js + Express + Socket.IO | 18 | Reads DB, pushes live counts to browser |
| worker | C# | .NET console app | .NET 8 | Drains Redis queue, writes to PostgreSQL |

### 8.2 Infrastructure Services

| Service | Technology | Version | Role |
|---------|-----------|---------|------|
| redis | Redis | alpine | In-memory message queue |
| db | PostgreSQL | 15-alpine | Permanent vote storage |

### 8.3 DevSecOps Toolchain (Target)

| Phase | Tool | Purpose |
|-------|------|---------|
| 1 | Hadolint | Dockerfile linting |
| 1 | Trivy | CVE scanning |
| 1 | Dive | Image layer analysis |
| 2 | Docker Compose `.env` | Local secrets |
| 3 | GitHub Actions | CI/CD pipeline |
| 3 | GHCR | Container registry |
| 4 | CodeQL | Static analysis |
| 4 | Semgrep | SAST rules engine |
| 4 | Gitleaks | Secret detection |
| 4 | Dependabot | Dependency updates |
| 5 | Kubernetes | Container orchestration |
| 5 | Helm | K8s package management |
| 5 | ingress-nginx | Ingress controller |
| 5 | Calico | Network policy enforcement |
| 6 | Prometheus | Metrics collection |
| 6 | Grafana | Metrics visualisation |
| 6 | Loki | Log aggregation |
| 6 | Alertmanager | Alerting |
| 7 | HashiCorp Vault | Secrets management |
| 7 | OPA Gatekeeper | Admission policies |
| 7 | Falco | Runtime threat detection |
| 7 | Cosign | Image signing |
| 8 | Terraform | Infrastructure as Code |
| 8 | ArgoCD | GitOps delivery |
| 8 | cert-manager | TLS automation |

---

## 9. Data Architecture

### 9.1 Data Model

```sql
TABLE votes
  id   VARCHAR(255) NOT NULL   -- voter_id cookie from browser (unique per user)
  vote VARCHAR(255) NOT NULL   -- "a" or "b"
```

One row per voter. Changing a vote overwrites the existing row.

### 9.2 Data Flow

| Stage | Storage | Type | Persistence |
|-------|---------|------|-------------|
| Vote submitted | Redis list "votes" | JSON string | Temporary — seconds |
| Vote processed | PostgreSQL TABLE votes | Relational row | Permanent |
| Vote counted | result service memory | Aggregated object | Runtime only |
| Vote displayed | Browser | WebSocket message | Not stored |

### 9.3 Redis Data Structure

```
Key:   "votes"
Type:  List
Value: JSON strings
       [
         '{"voter_id": "abc123", "vote": "a"}',
         '{"voter_id": "xyz789", "vote": "b"}'
       ]
TTL:   None (worker drains continuously)
```

### 9.4 Data Persistence

| Service | Persistence | Mechanism |
|---------|------------|-----------|
| Redis | None (current) | No volume, no AOF/RDB |
| PostgreSQL | Yes | Docker volume `db-data` mounted at `/var/lib/postgresql/data` |

### 9.5 Data Retention

- Votes in PostgreSQL persist indefinitely (no deletion policy)
- Redis data is transient — lost on container restart
- No backup strategy currently in place

---

## 10. Security Architecture

### 10.1 Current Security State

All security controls are absent in the current state. See Section 5.4 for the full gap analysis.

### 10.2 Target Security Controls by Layer

#### Image Security
- All base images pinned to exact digest (`@sha256:...`)
- All Dockerfiles pass Hadolint with zero warnings
- All images scanned by Trivy — no CRITICAL or HIGH CVEs permitted
- All images signed with Cosign before push to registry
- SBOM generated for every image build

#### Network Security
- `front-tier` network: vote, result only
- `back-tier` network: redis, db, worker only
- No service exposes ports to the host except via Ingress
- Kubernetes NetworkPolicy enforced by Calico
- All external traffic over HTTPS (TLS via cert-manager + Let's Encrypt)

#### Secrets Management
- No secrets in code, Dockerfiles, or compose files
- Development: `.env` file (gitignored)
- Production: HashiCorp Vault with short-lived dynamic credentials
- Kubernetes secrets encrypted at rest with Sealed Secrets

#### Container Security
- All containers run as non-root user
- Read-only root filesystem where possible
- No privileged containers (enforced by OPA Gatekeeper)
- Resource limits on all containers

#### Runtime Security
- Falco monitors for: shell spawned in container, unexpected network connections, privilege escalation
- OPA Gatekeeper admission policies: require non-root, require resource limits, require image signing

#### CI/CD Security
- Secret scanning on every commit (Gitleaks)
- SAST on every PR (CodeQL, Semgrep)
- Dependency CVE scanning (OWASP Dependency-Check)
- Trivy gate blocks deployment on CRITICAL/HIGH CVEs

### 10.3 Threat Model

| Threat | Vector | Mitigation |
|--------|--------|-----------|
| Compromised base image | Supply chain | Pin digests, Trivy scan, Cosign signing |
| Credential theft | Hardcoded secrets | Vault, Sealed Secrets |
| Container escape | Privileged container | OPA: deny privileged, non-root enforced |
| Lateral movement | Flat network | NetworkPolicy, front/back tier split |
| Data exfiltration | Compromised service | Network isolation, Falco detection |
| Vulnerable dependency | Outdated packages | Dependabot, OWASP Dependency-Check |
| Secret in Git history | Accidental commit | Gitleaks pre-commit hook |

---

## 11. Infrastructure Architecture

### 11.1 Current Infrastructure

```
Single host machine
  └── Docker Engine
        └── Docker Compose
              └── 5 containers on 1 network
```

### 11.2 Target Infrastructure (Phase 8)

```
Cloud Provider
  ├── VPC
  │     ├── Public Subnet
  │     │     └── Load Balancer / Ingress
  │     └── Private Subnet
  │           └── Kubernetes Node Pool (3 nodes)
  │
  ├── Managed Kubernetes Cluster
  │     ├── vote Deployment (3 replicas, HPA enabled)
  │     ├── result Deployment (2 replicas)
  │     ├── worker Deployment (1 replica)
  │     ├── cert-manager (TLS)
  │     ├── ingress-nginx (routing)
  │     ├── OPA Gatekeeper (policies)
  │     ├── Falco (runtime security)
  │     ├── Prometheus + Grafana (observability)
  │     └── ArgoCD (GitOps)
  │
  ├── Managed PostgreSQL
  │     └── Automated backups, multi-AZ
  │
  └── Managed Redis
        └── Persistence enabled
```

### 11.3 Scalability Design

| Service | Scaling Strategy | Reason |
|---------|-----------------|--------|
| vote | Horizontal (HPA) | Stateless, handles vote bursts |
| result | Horizontal | Stateless, Socket.IO broadcast |
| worker | Single replica | Sequential queue processing |
| redis | Managed cluster | Offloaded to cloud provider |
| db | Managed with read replicas | Offloaded to cloud provider |

---

## 12. DevSecOps Architecture

### 12.1 Eight-Phase Learning Roadmap

| Phase | Focus | Key Deliverable |
|-------|-------|----------------|
| 1 | Containerisation Hardening | Clean, pinned, scanned images |
| 2 | Networking & Secrets | Isolated networks, no hardcoded creds |
| 3 | CI/CD Pipeline | Automated build, scan, push |
| 4 | SAST & Dependency Scanning | Security gate on every PR |
| 5 | Kubernetes Migration | Full K8s deployment with Helm |
| 6 | Observability | Metrics, logs, traces, alerts |
| 7 | Secrets & Policy Management | Vault, OPA, Falco, Cosign |
| 8 | Cloud & IaC | Terraform, managed services, GitOps |

### 12.2 Target CI/CD Pipeline Detail

```
Trigger: git push / PR

Stage 1 — Lint & Format
  ├── Hadolint (all Dockerfiles)
  ├── Flake8 / Ruff (vote — Python)
  ├── ESLint (result — JavaScript)
  └── dotnet format (worker — C#)

Stage 2 — Security Scan (code)
  ├── CodeQL (SAST)
  ├── Semgrep (SAST rules)
  ├── Gitleaks (secret detection)
  └── OWASP Dependency-Check

Stage 3 — Build
  ├── docker build vote
  ├── docker build result
  └── docker build worker

Stage 4 — Security Scan (images)
  ├── Trivy scan vote   ── FAIL on CRITICAL/HIGH
  ├── Trivy scan result ── FAIL on CRITICAL/HIGH
  └── Trivy scan worker ── FAIL on CRITICAL/HIGH

Stage 5 — Publish (main branch only)
  ├── Cosign sign all images
  ├── Push to GHCR
  └── Generate SBOM

Stage 6 — Deploy (main branch only)
  └── ArgoCD sync ── GitOps trigger
```

---

## 13. Observability Architecture

### 13.1 Three Pillars

| Pillar | Tool | What is captured |
|--------|------|-----------------|
| Metrics | Prometheus + Grafana | Vote throughput, Redis queue depth, DB latency, worker lag |
| Logs | Loki + Promtail | Structured JSON logs from all services |
| Traces | Tempo / Jaeger | Request lifecycle from browser to DB and back |

### 13.2 Key Metrics to Monitor

| Metric | Source | Alert threshold |
|--------|--------|----------------|
| Votes per second | vote (prometheus-flask-exporter) | < 0 (service down) |
| Redis queue depth | Redis exporter | > 1000 (worker lagging) |
| Worker processing rate | worker logs | 0 for > 30s |
| DB query duration | PostgreSQL exporter | > 500ms |
| Container memory usage | Kubernetes | > 80% of limit |

### 13.3 Logging Strategy

All services to emit structured JSON logs:

```json
{
  "timestamp": "2026-05-31T10:00:00Z",
  "level": "INFO",
  "service": "vote",
  "voter_id": "abc123",
  "vote": "a",
  "message": "Vote received"
}
```

---

## 14. Non-Functional Requirements

| Requirement | Current State | Target State |
|-------------|--------------|-------------|
| Availability | No SLA | 99.9% uptime |
| Vote submission latency | < 500ms (local) | < 200ms (cloud) |
| Result update latency | ~1 second | ~1 second |
| Max concurrent voters | Unknown | 1000/second |
| Data durability | PostgreSQL only | PostgreSQL + managed backups |
| Recovery time | Manual restart | < 5 minutes (K8s self-healing) |
| Image CVE severity | Unknown | Zero CRITICAL/HIGH |
| Secrets exposure | Hardcoded | Zero secrets in code or Git |

---

## 15. Risk Register

| ID | Risk | Likelihood | Impact | Mitigation | Phase |
|----|------|-----------|--------|-----------|-------|
| R01 | Votes lost if Redis crashes with items in queue | Low | Medium | Enable Redis AOF persistence | 2 |
| R02 | Credentials exposed in Git history | High | Critical | Move to `.env`, Gitleaks scan | 2 |
| R03 | Prebuilt external images contain malware | Medium | Critical | Build own images, Trivy scan | 1 |
| R04 | CVE introduced via unpinned base image | High | High | Pin all image tags to digest | 1 |
| R05 | Compromised container reaches database directly | Medium | High | Network policy, tier isolation | 2 |
| R06 | Container runs as root, escalates on escape | Medium | High | Non-root USER in all Dockerfiles | 1 |
| R07 | Worker fails silently, votes pile up in Redis | Low | Medium | Alerting on Redis queue depth | 6 |
| R08 | Runaway container exhausts host resources | Low | Medium | Resource limits on all services | 2 |
| R09 | Sensitive file copied into image via COPY . . | High | Medium | Add `.dockerignore` to vote/ | 1 |
| R10 | Outdated dependency with known CVE | High | High | Dependabot + OWASP scan | 4 |

---

## 16. Architecture Decision Records

### ADR-001: Use Redis as Message Queue Between Vote and Worker

| Field | Detail |
|-------|--------|
| **Date** | 2026-05-31 |
| **Status** | Accepted |
| **Context** | Vote service needs to handle bursts of concurrent submissions without overwhelming PostgreSQL |
| **Decision** | Use a Redis list (`RPUSH` / `BLPOP`) as an async buffer between the vote service and the worker |
| **Consequences** | Votes may be lost if Redis crashes while items are in the queue and persistence is not enabled |
| **Alternatives considered** | Direct DB writes from vote service, RabbitMQ, Kafka |

---

### ADR-002: One Row Per Voter with Try-INSERT / Catch-UPDATE Pattern

| Field | Detail |
|-------|--------|
| **Date** | 2026-05-31 |
| **Status** | Accepted |
| **Context** | A voter should be able to change their vote; the result should reflect the latest choice only |
| **Decision** | Use `voter_id` as the primary key; attempt INSERT, fall back to UPDATE on duplicate key exception |
| **Consequences** | Simpler than a true UPSERT but relies on exception handling for control flow |
| **Alternatives considered** | PostgreSQL `INSERT ON CONFLICT DO UPDATE`, separate votes log table |

---

### ADR-003: Multi-Language Stack by Design

| Field | Detail |
|-------|--------|
| **Date** | 2026-05-31 |
| **Status** | Accepted |
| **Context** | Project is a learning platform — diversity of languages maximises breadth of DevSecOps exposure |
| **Decision** | Use Python (vote), .NET/C# (worker), Node.js (result) intentionally |
| **Consequences** | Three separate linting, scanning, and build toolchains required in CI/CD |
| **Alternatives considered** | Single language stack (simpler but fewer learning opportunities) |

---

### ADR-004: Build Own Images Instead of Using Prebuilt External Images

| Field | Detail |
|-------|--------|
| **Date** | 2026-05-31 |
| **Status** | Planned (Phase 1) |
| **Context** | Current `docker-compose.yml` uses `pokfinner/*` prebuilt images with unknown contents |
| **Decision** | Switch all services to `build:` from local Dockerfiles; scan all images with Trivy before use |
| **Consequences** | Longer initial build time; full control and visibility over image contents |
| **Alternatives considered** | Continue using prebuilt images (rejected — unacceptable security risk) |

---

### ADR-005: Chronological Phase Execution

| Field | Detail |
|-------|--------|
| **Date** | 2026-05-31 |
| **Status** | Accepted |
| **Context** | Each phase builds on the previous — clean images are required before CI/CD, CI/CD before K8s |
| **Decision** | Phases must be completed in order (1 → 8); no phase may be skipped |
| **Consequences** | Slower time to "exciting" phases like Kubernetes, but a solid security foundation |
| **Alternatives considered** | Jump directly to Kubernetes (rejected — produces insecure, poorly-built images in K8s) |

---

## 17. Dependencies and Integrations

### 17.1 Internal Service Dependencies

| Service | Depends On | Protocol | Failure Behaviour |
|---------|-----------|----------|------------------|
| vote | redis | TCP 6379 | Returns 500 error to browser |
| worker | redis | TCP 6379 | Retries indefinitely with 1s sleep |
| worker | db | TCP 5432 | Retries indefinitely with 1s sleep |
| result | db | TCP 5432 | Retries 1000 times with 1s interval |

### 17.2 Docker Compose Health Check Dependencies

```
vote    ── waits for ──► redis  (healthy)
result  ── waits for ──► db     (healthy)
worker  ── waits for ──► redis  (healthy)
worker  ── waits for ──► db     (healthy)
```

### 17.3 External Dependencies (Target State)

| Dependency | Purpose | Provider |
|------------|---------|----------|
| Container registry | Image storage | GitHub Container Registry (GHCR) |
| Kubernetes cluster | Container orchestration | EKS / GKE / AKS |
| Managed PostgreSQL | Production database | RDS / Cloud SQL |
| Managed Redis | Production queue | ElastiCache / MemoryStore |
| Certificate authority | TLS certificates | Let's Encrypt |
| Secrets backend | Secrets management | HashiCorp Vault |

---

*This document is a living artefact and will be updated as each phase is completed.*

# Project Plan: Multi-Stack DevOps Infrastructure Automation

**Duration:** 5 mandays × 8 hours = **40 hours** · **Team:** Solo · **Submission:** End of Day 5
**Scope:** Core project + **all 8 add-ons**
**Methodology:** Scrum-lite with GitHub Projects (Kanban) + conventional commits

---

## 1. Scope Reality Check

You've chosen full scope. At 40 hours solo, this is tight-but-feasible **only if** you hold the line on these principles:

1. **Design for the end state from day one.** Build the final topology (dedicated bastion, dual-AZ, ALB-ready VPC) on the first `terraform apply`. No retrofits.
2. **No yak-shaving.** If a task blocks you for more than 45 minutes, park it and move on. Come back with fresh eyes.
3. **Two add-ons are explicitly scoped down** (see section 2).
4. **Documentation in parallel, not at the end.** 30 minutes at end of each day → ADRs, README updates, journal entries.
5. **Every evening: `terraform destroy`.** Saves ~€3/day in NAT Gateway + ALB costs.

If you fall behind by end of Day 3, **cut Monitoring (Epic 11) first**, then the own-Dockerfiles exercise. Do NOT cut the Load Balancer — it's the headline add-on.

---

## 2. Scope Definition — All 8 Add-Ons

### Core (non-negotiable)
- Dockerized services on DockerHub
- Terraform: VPC, subnets, EC2, SGs, remote state (S3+DynamoDB)
- Ansible: playbooks deploying via bastion ProxyJump
- Working end-to-end vote → result flow
- README + architecture diagram + 15-min presentation

### Add-ons (all 8 in scope)

| # | Add-on | Difficulty | Scope | Epic |
|---|---|---|---|---|
| 1 | Proper Security Group Configs | 🟢 Easy | **Full** — SG-to-SG rules everywhere, audited | Built into Epic 5 |
| 2 | Postgres Volume | 🟢 Easy | **Full** — named volume, persistence verified | Epic 8 |
| 3 | DynamoDB + S3 for Terraform State | 🟢 Easy | **Full** — in separate bootstrap project | Epic 4 |
| 4 | Individual Bastion Host | 🟡 Medium | **Full** — dedicated t3.nano bastion, Ansible installed on it | Built into Epic 5 + Epic 9 |
| 5 | Own Dockerfiles + Compose from scratch | 🟡 Medium | **Scoped down** — Day 1 warm-up exercise, documented in ADR, then working versions used | Epic 3 |
| 6 | Logging & Monitoring | 🟡 Medium | **Full** — CloudWatch Agent, Logs, Metrics, Alarms, SNS email | Epic 11 |
| 7 | Running locally without Docker | 🟡 Medium | **Scoped down** — documented procedure in docs/, not a polished deliverable | Epic 13 |
| 8 | Load Balancer | 🟠 Hard | **Full** — ALB, 2-AZ, target groups, path routing | Epic 10 |

---

## 3. GitHub Repository Structure

> **Note:** Folder names reflect the actual repo on disk. `src/` (not `app/`), `infra/` (not `infrastructure/`), bootstrap lives under `infra/bootstrap/`.

```
multi-stack-voting-app/
├── .github/
│   ├── ISSUE_TEMPLATE/
│   │   ├── task.md
│   │   ├── epic.md
│   │   └── bug.md
│   ├── PULL_REQUEST_TEMPLATE.md
│   └── workflows/
│       ├── terraform-validate.yml
│       └── ansible-lint.yml
├── .gitignore
├── README.md
├── docs/
│   ├── 1_project-description.md         # Original brief
│   ├── 2_project-plan.md                # This file
│   ├── architecture.png                  # Exported diagram
│   ├── architecture.drawio               # Source
│   ├── runbook.md                        # Deploy from zero ✅ created
│   ├── local-development.md              # Add-on #7: run without Docker
│   ├── journal.md                        # Daily retro notes
│   └── decisions/                        # ADRs
│       ├── 001-end-state-topology.md
│       ├── 002-dotnet-8-upgrade.md
│       ├── 003-dedicated-bastion.md
│       ├── 004-single-nat-gateway.md
│       ├── 005-alb-path-routing.md
│       └── 006-own-dockerfiles-exercise.md
├── src/                                  # Application source code
│   ├── vote/                             # Python / Flask
│   ├── result/                           # Node.js
│   ├── worker/                           # .NET 8
│   ├── healthchecks/                     # Redis + Postgres health scripts
│   └── docker-compose.yml
├── infra/
│   ├── bootstrap/
│   │   └── terraform/                    # S3 + DynamoDB (run once)
│   └── terraform/
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       ├── versions.tf
│       ├── backend.tf
│       ├── terraform.tfvars.example
│       ├── environments/
│       │   └── dev.tfvars                # gitignored
│       └── modules/
│           ├── networking/               # VPC, subnets, NAT, IGW, routes
│           ├── security/                 # Security Groups
│           ├── compute/                  # EC2 instances
│           ├── alb/                      # Application Load Balancer
│           └── monitoring/               # CloudWatch + Alarms + SNS
├── configuration/
│   └── ansible/
│       ├── ansible.cfg
│       ├── requirements.yml              # Collections
│       ├── inventory/
│       │   └── aws_ec2.yml               # Dynamic inventory
│       ├── group_vars/
│       │   ├── all.yml
│       │   ├── bastion.yml
│       │   ├── frontend.yml
│       │   ├── backend.yml
│       │   └── db.yml
│       ├── playbooks/
│       │   ├── site.yml
│       │   ├── 00-bastion-setup.yml
│       │   ├── 01-docker-install.yml
│       │   ├── 02-deploy-db.yml
│       │   ├── 03-deploy-backend.yml
│       │   ├── 04-deploy-frontend.yml
│       │   └── 05-deploy-monitoring.yml
│       └── roles/
│           ├── common/
│           ├── docker/
│           ├── cloudwatch_agent/
│           ├── postgres/
│           ├── redis/
│           ├── worker/
│           ├── vote/
│           └── result/
├── tests/
├── scripts/
│   ├── bootstrap.sh                      # One-time state backend
│   ├── deploy.sh                         # terraform + ansible in sequence
│   └── destroy.sh                        # clean teardown
└── presentation/
    └── final-presentation.pdf
```

---

## 4. Git Workflow & Discipline

### Branching
- `main` — always deployable; protected, PR-only
- `feat/<epic-id>-<short-description>` — one per task
- `fix/<short-description>` — bug fixes
- `docs/<topic>` — doc-only changes

### PR discipline (even solo)
- Open PR per feature branch, write proper description, self-review, squash-merge
- Link PRs to issues with `Closes #N`
- Keep `main` history clean — this is visible to reviewers

### Conventional commits
```
feat(terraform): add ALB module with path-based routing
feat(ansible): add cloudwatch_agent role
fix(ansible): correct postgres volume mount syntax
docs(adr): document single-NAT cost trade-off
chore(ci): add terraform fmt pre-commit check
refactor(terraform): extract networking into module
```

### `.gitignore` essentials (Day 0)
```
# Terraform
**/.terraform/*
*.tfstate
*.tfstate.*
*.tfvars
!*.tfvars.example
!environments/*.example
.terraform.lock.hcl

# Ansible
*.retry
*.pem
*.key

# IDE / OS
.vscode/
.idea/
**/.DS_Store

# .NET build artifacts
src/worker/bin/
src/worker/obj/

# Secrets
.env
.env.*
!.env.example

# Claude Code workspace
.claude/
```

---

## 5. GitHub Projects Board

**Columns:** 📋 Backlog → 🎯 Sprint (today) → 🚧 In Progress (WIP=2) → 👀 Review → ✅ Done

**Labels:**
- Type: `epic`, `task`, `bug`, `docs`, `spike`
- Day: `day-1` through `day-5`
- Priority: `must-do`, `should-do`, `stretch`
- State: `blocker`, `waiting`, `needs-review`
- Category: `terraform`, `ansible`, `docker`, `aws`, `docs`

---

## 6. Epics & Tasks

15 epics, ~70 tasks. Each epic is a GitHub issue with checkboxes linking to task issues.

---

### EPIC 1 — Project Bootstrap & Repository Setup
**Labels:** `epic`, `day-1`, `must-do` · **Est:** 2h

- [x] **1.1** Clone upstream repo, initialize root git repo, set up remotes (15m) ✅
- [ ] **1.2** Create GitHub Project board, columns, labels (20m)
- [x] **1.3** Create folder structure (`src/`, `infra/`, `configuration/`, `tests/`, `docs/`), `.gitignore`, initial commit + push (30m) ✅
- [ ] **1.4** Write initial README skeleton with placeholder sections (15m)
- [ ] **1.5** Create first ADRs: 001 (topology), 002 (.NET 8) (30m)
- [ ] **1.6** Verify toolchain: Docker, Terraform ≥1.6, Ansible ≥2.15, AWS CLI v2, draw.io (10m)
- [ ] **1.7** Verify AWS IAM user has required permissions, set billing alert at €25 (15m)

**DoD:** Repo on GitHub, board populated with all Epic issues, local tooling verified, AWS billing alert active.

---

### EPIC 2 — Dockerize Services & Publish (Working Versions)
**Labels:** `epic`, `day-1`, `must-do` · **Est:** 2.5h

> Use the *provided* Dockerfiles first to get working images. The from-scratch exercise (Epic 3) is separate.

- [x] **2.1** Review provided Dockerfiles; worker already on .NET 8 (`mcr.microsoft.com/dotnet/sdk:8.0`, `net8.0` target) — no upgrade needed ✅
- [ ] **2.2** Build all three images locally, verify each runs standalone (30m)
- [ ] **2.3** Set up `docker buildx` multi-arch builder (amd64 + arm64) (20m)
- [ ] **2.4** Build + push to DockerHub, tag with `latest` + git short SHA (30m)
- [ ] **2.5** Update `docker-compose.yml` to use *your* DockerHub images (15m)
- [ ] **2.6** E2E local test: `docker compose up` → cast vote → see result (20m)
- [ ] **2.7** Commit + document local workflow in README (15m)

**DoD:** 3 images on DockerHub (multi-arch), `docker compose up` works from fresh clone.

---

### EPIC 3 — Own Dockerfiles & Compose Exercise (Add-on #5)
**Labels:** `epic`, `day-1`, `add-on` · **Est:** 2h

> **Scoped down:** 2-hour learning exercise. Write Dockerfiles from scratch into an `exercise/` branch, document the process in ADR-006, then discard in favor of working versions from Epic 2.

- [ ] **3.1** Create branch `exercise/own-dockerfiles`, delete all provided Dockerfiles + compose (10m)
- [ ] **3.2** Write Dockerfile for `vote` (Python/Flask/gunicorn) from memory (30m)
- [ ] **3.3** Write Dockerfile for `result` (Node.js) from memory (25m)
- [ ] **3.4** Write Dockerfile for `worker` (.NET 8 multi-stage) from memory (30m)
- [ ] **3.5** Write `docker-compose.yml` from memory — ports, networks, env vars (20m)
- [ ] **3.6** Document what you got right/wrong in ADR-006 (15m)
- [ ] **3.7** Archive the branch (do NOT merge — main uses Epic 2's working versions)

**DoD:** Exercise branch pushed to GitHub, ADR-006 documents the learning. Main branch unaffected.

> **Why a branch, not main:** your working deployment needs the tested Dockerfiles. The from-scratch exercise is a learning artifact, not a deliverable.

---

### EPIC 4 — Terraform State Backend (Add-on #3)
**Labels:** `epic`, `day-2`, `must-do`, `add-on` · **Est:** 1h

- [ ] **4.1** Write `infra/bootstrap/` — S3 bucket (versioned, encrypted, public-access-blocked), DynamoDB table with `LockID` PK (30m)
- [ ] **4.2** Apply locally (state stays local in `infra/bootstrap/terraform.tfstate` — not pushed to remote) (15m)
- [ ] **4.3** Commit bootstrap module + document in runbook the "run once" nature (15m)

**DoD:** S3 bucket `voting-app-tfstate-<your-initials>-<date>` exists, DynamoDB table `voting-app-tf-locks` exists.

---

### EPIC 5 — Core Infrastructure: Terraform
**Labels:** `epic`, `day-2`, `must-do` · **Est:** 7h

> The single biggest chunk. Build the full end-state topology including ALB-ready subnets — ALB itself comes in Epic 10.

- [ ] **5.1** `infra/terraform/versions.tf`, `backend.tf` (wired to `infra/bootstrap/` S3/DynamoDB) (20m)
- [ ] **5.2** **Networking module:** VPC, 2× public subnets, 2× private (app) subnets, 2× private (db) subnets across 2 AZs, IGW, single NAT Gateway, route tables (100m)
- [ ] **5.3** **Security module:** SGs for ALB, bastion, frontend, backend, db — all SG-to-SG references (Add-on #1) (75m)
- [ ] **5.4** **Compute module:** bastion (t3.nano, public), frontend (private), backend (private), db (private-db-subnet), SSH key pair, user_data for base setup (90m)
- [ ] **5.5** IAM role + instance profile (SSM Session Manager, CloudWatch Agent, ECR-pull if needed) (30m)
- [ ] **5.6** Outputs: all instance IPs, bastion public IP, SG IDs, subnet IDs (15m)
- [ ] **5.7** `terraform plan` review, `terraform apply`, verify in Console (45m)
- [ ] **5.8** Smoke test: SSH to bastion → ProxyJump to each private instance (15m)

**DoD:** 4 EC2 instances running, bastion SSH works, ProxyJump to private instances works, `terraform destroy`/`apply` round-trips cleanly.

> **Gotchas to avoid:**
> - Don't `count` EC2s — use explicit resources or `for_each` with a map. `count` churn replaces unrelated instances on change.
> - Tag *everything* with `Project = "voting-app"` and `ManagedBy = "terraform"` — you'll thank yourself in the console.
> - Use `aws_key_pair` with a key you generated via `ssh-keygen`; do NOT use AWS-generated keys (harder to automate).

---

### EPIC 6 — Configuration Management: Ansible Foundation
**Labels:** `epic`, `day-3`, `must-do` · **Est:** 3h

- [ ] **6.1** Update `~/.ssh/config` with bastion + ProxyJump entries for frontend/backend/db (20m)
- [ ] **6.2** `configuration/ansible/ansible.cfg` + `requirements.yml` (amazon.aws, community.docker) (20m)
- [ ] **6.3** Dynamic inventory: `configuration/ansible/inventory/aws_ec2.yml` using tags for groups (40m)
- [ ] **6.4** Verify: `ansible-inventory --graph` shows all hosts in correct groups (15m)
- [ ] **6.5** Verify: `ansible all -m ping` succeeds via bastion (20m)
- [ ] **6.6** `common` role: hostname, timezone, updates (25m)
- [ ] **6.7** `docker` role: install docker.io, enable service, add user to group (30m)

**DoD:** Ansible pings every host via bastion, Docker installed and verified on all app instances.

---

### EPIC 7 — Application Deployment via Ansible
**Labels:** `epic`, `day-3`, `must-do` · **Est:** 4h

- [ ] **7.1** `postgres` role: run postgres container with env vars (volume comes in Epic 8) (30m)
- [ ] **7.2** `redis` role: run redis container with proper network config (20m)
- [ ] **7.3** `worker` role: pull + run worker with `REDIS_HOST` and DB env vars (30m)
- [ ] **7.4** `vote` role: pull + run vote with `REDIS_HOST` (25m)
- [ ] **7.5** `result` role: pull + run result with DB connection (25m)
- [ ] **7.6** `site.yml` orchestration: db → backend → frontend, with proper tags (30m)
- [ ] **7.7** E2E run: `ansible-playbook site.yml` → cast vote → see result (60m buffer for debug)

**DoD:** Full stack working via Ansible. Cast a vote from frontend EC2's public IP, result app shows it. `docker logs` on each container is clean.

---

### EPIC 8 — Postgres Volume (Add-on #2)
**Labels:** `epic`, `day-3`, `add-on` · **Est:** 1h

- [ ] **8.1** Update `postgres` role to mount named Docker volume for `/var/lib/postgresql/data` (20m)
- [ ] **8.2** Re-run playbook, cast a vote, verify persistence (20m)
- [ ] **8.3** Test: `docker stop postgres && docker rm postgres`, re-run playbook, verify vote still there (20m)

**DoD:** Postgres data survives container destruction + recreation via playbook.

---

### EPIC 9 — Individual Bastion Host (Add-on #4)
**Labels:** `epic`, `day-3`, `add-on` · **Est:** 1.5h

> Already partially built via Epic 5 (dedicated bastion exists). This epic hardens and documents it.

- [ ] **9.1** Tighten bastion SG: inbound SSH (22) only from your public IP (set via tfvars variable) (20m)
- [ ] **9.2** Tighten app SGs: inbound SSH only from bastion SG (SG reference, not CIDR) (20m)
- [ ] **9.3** `bastion` role: install Ansible on bastion itself, clone repo via deploy key (30m)
- [ ] **9.4** Test: from bastion, run `ansible-playbook site.yml` (full deploy-from-bastion flow) (20m)

**DoD:** Bastion is SSH-hardened to your IP only; you can optionally deploy from the bastion itself (not required, but demonstrates the pattern).

---

### EPIC 10 — Application Load Balancer (Add-on #8) ⭐
**Labels:** `epic`, `day-4`, `add-on` · **Est:** 6h

> The headline add-on. Budget real time for path-routing debugging.

- [ ] **10.1** Spike: test ALB path-routing manually via AWS Console with a dummy instance, decide on path-strip vs base-path (45m)
- [ ] **10.2** ADR-005: document the path-routing approach chosen (20m)
- [ ] **10.3** `alb` Terraform module: ALB in 2× public subnets, HTTP listener :80 (40m)
- [ ] **10.4** Target groups: `vote-tg`, `result-tg` with health checks tuned to each app's path (40m)
- [ ] **10.5** Listener rules: `/` → vote (default), `/vote*` → vote, `/result*` → result (30m)
- [ ] **10.6** ALB SG (public:80), update frontend SG to accept only from ALB SG (20m)
- [ ] **10.7** If path-strip chosen: implement via target group's `path_pattern` + app config (60m)
- [ ] **10.8** Update Ansible vars / app configs to work behind ALB (30m)
- [ ] **10.9** E2E test via ALB DNS name (30m)
- [ ] **10.10** Update architecture diagram + README to reflect ALB topology (30m)

**DoD:** Public users hit ALB DNS name, `/vote` casts votes, `/result` shows results, frontend EC2 is no longer publicly accessible.

> **Pre-emptive decision:** If path-stripping for the Node.js `result` app becomes painful (it often does — the WebSocket path matters too), **fall back to subdomain-style routing in docs** and use path routing for just `/vote` vs default. Document the constraint in ADR-005. Ship something that works.

---

### EPIC 11 — Logging & Monitoring (Add-on #6)
**Labels:** `epic`, `day-4`, `add-on` · **Est:** 3.5h

- [ ] **11.1** Terraform: CloudWatch Log Groups with 7-day retention for each service (20m)
- [ ] **11.2** `cloudwatch_agent` Ansible role: install agent, configure via JSON (60m)
- [ ] **11.3** Configure agent to collect: `/var/log/syslog`, Docker container logs, metrics (CPU, mem, disk) (45m)
- [ ] **11.4** SNS topic + email subscription (Terraform) (20m)
- [ ] **11.5** Alarms: high CPU (>80% for 5 min), disk >80%, ALB unhealthy target count >0 (40m)
- [ ] **11.6** Test: trigger a CPU alarm with `stress` on one instance, confirm email (25m)
- [ ] **11.7** CloudWatch Dashboard (Terraform) with key widgets (30m)

**DoD:** Logs visible in CloudWatch, dashboard shows live metrics, test alarm fires an email.

---

### EPIC 12 — CI/CD Polish (Bonus)
**Labels:** `epic`, `day-5`, `stretch` · **Est:** 1.5h

> Not in the brief's add-on list but costs almost nothing and signals senior-level thinking.

- [ ] **12.1** GitHub Actions: `terraform fmt`, `terraform validate`, `tflint` on PR (45m)
- [ ] **12.2** GitHub Actions: `ansible-lint` + `yamllint` on PR (30m)
- [ ] **12.3** Pre-commit hooks locally: `terraform fmt`, trailing whitespace, large file check (15m)

**DoD:** PRs show green checks, commits are clean.

---

### EPIC 13 — Running Apps Locally Without Docker (Add-on #7)
**Labels:** `epic`, `day-5`, `add-on` · **Est:** 1.5h

> **Scoped down** — documented procedure, not a supported workflow. Actually run through it once to verify the docs.

- [ ] **13.1** Write `docs/local-development.md`: prerequisites (Python, Node, .NET 8), env var setup per service (45m)
- [ ] **13.2** Actually run through the doc start to finish, fix what doesn't work (40m)
- [ ] **13.3** Add sample `.env.example` files per service (5m)

**DoD:** A developer could clone the repo and run all 5 services on their laptop by following the doc.

---

### EPIC 14 — Documentation & ADRs
**Labels:** `epic`, `day-5`, `must-do` · **Est:** 3h

- [ ] **14.1** Architecture diagram in draw.io: VPC, subnets, ALB, EC2s, SGs, arrows (75m)
- [ ] **14.2** README: overview, architecture, prerequisites, quick-start (`./scripts/deploy.sh`), add-ons implemented, cost estimate, cleanup (75m)
- [x] **14.3** `docs/runbook.md`: deploy from zero in numbered steps ✅ created early
- [ ] **14.4** Finalize all 6 ADRs (30m)
- [ ] **14.5** Add badges to README: Terraform, Docker, AWS, CI status (15m)

**DoD:** A stranger can deploy the full stack in <45 min by reading the README.

---

### EPIC 15 — Presentation & Submission
**Labels:** `epic`, `day-5`, `must-do` · **Est:** 3h

- [ ] **15.1** Slides (15 min): Problem → Architecture → Demo → Add-ons → Lessons (90m)
- [ ] **15.2** Record 2-min demo GIF for README (30m)
- [ ] **15.3** **Full destroy → apply dry run** on clean state (30m)
- [ ] **15.4** Pin repo on GitHub, write LinkedIn post draft (30m)
- [ ] **15.5** Final submission checklist walkthrough (15m)

**DoD:** You can deliver the presentation confidently, repo is polished, submission handed in.

---

## 7. Day-by-Day Sprint Plan (40h total)

### 📅 Day 1 — Bootstrap + Docker *(8h)*
**Goal:** Repo live, 3 images on DockerHub, local compose working, own-Dockerfile exercise complete.

| Block | Time | Epic | Work |
|---|---|---|---|
| 09:00–11:00 | 2h | Epic 1 | Bootstrap repo, board, ADRs, toolchain |
| 11:00–13:30 | 2.5h | Epic 2 | Dockerize, multi-arch, DockerHub push, local E2E |
| 14:30–16:30 | 2h | Epic 3 | Own Dockerfiles exercise (branch) |
| 16:30–17:00 | 0.5h | — | Commit, push, update journal, close issues |
| 17:00–18:00 | 1h | — | Buffer / spillover |

**EOD checkpoint:** `docker compose up` on fresh clone works. Exercise branch pushed. Epics 1, 2, 3 closed.

---

### 📅 Day 2 — Terraform *(8h)*
**Goal:** Full VPC + 4 EC2s + remote state, bastion SSH + ProxyJump working.

| Block | Time | Epic | Work |
|---|---|---|---|
| 09:00–10:00 | 1h | Epic 4 | State backend bootstrap |
| 10:00–13:00 | 3h | Epic 5 | Networking + Security modules |
| 14:00–17:00 | 3h | Epic 5 | Compute + IAM + outputs, apply, verify |
| 17:00–18:00 | 1h | — | Debug + smoke test + documentation + `terraform destroy` |

**EOD checkpoint:** Full stack provisions cleanly; can re-apply in <5min tomorrow. **Destroy overnight.**

---

### 📅 Day 3 — Ansible + E2E + Quick Add-ons *(8h)*
**Goal:** Core project DONE + Postgres volume + hardened bastion.

| Block | Time | Epic | Work |
|---|---|---|---|
| 09:00–09:15 | 15m | — | `terraform apply` (coffee brews while waiting) |
| 09:15–12:15 | 3h | Epic 6 | Ansible foundation: SSH config, inventory, docker role |
| 13:00–17:00 | 4h | Epic 7 | All app roles + site.yml + E2E debug |
| 17:00–18:00 | 1h | Epics 8+9 | Postgres volume + bastion hardening |

**EOD checkpoint:** 🎯 **Core project submission-ready.** Take screenshots/video for backup. Everything from here is add-on polish. **Destroy overnight.**

---

### 📅 Day 4 — Load Balancer + Monitoring *(8h)*
**Goal:** Two hardest add-ons in the bag.

> ⚠️ **Time warning:** Epic 10 (6h) + Epic 11 (3.5h) = 9.5h. This day is intentionally overloaded — one of the two will be cut or compressed. The ALB wins; Monitoring loses.

| Block | Time | Epic | Work |
|---|---|---|---|
| 09:00–09:15 | 15m | — | `terraform apply` |
| 09:15–15:15 | 6h | Epic 10 | Load Balancer (spike → module → rules → debug → E2E) |
| 15:15–17:45 | 2.5h | Epic 11 | Monitoring — minimum: Log Groups + 2 alarms + SNS email. Skip dashboard if short on time. |

**Decision gate (Day 4, 15:15):** If Epic 10 is not fully done, spend the remaining time finishing it. Move Epic 11 to Day 5 morning and cut Epic 12 (CI/CD) if needed. Monitoring without a working ALB is worthless. **Destroy overnight.**

---

### 📅 Day 5 — Polish + Submit *(8h)*
**Goal:** Documentation, presentation, submission.

| Block | Time | Epic | Work |
|---|---|---|---|
| 09:00–10:30 | 1.5h | Epic 12 | CI/CD polish (GitHub Actions, pre-commit) |
| 10:30–12:00 | 1.5h | Epic 13 | Local-without-Docker doc + verify |
| 13:00–16:00 | 3h | Epic 14 | Diagram, README, runbook, ADRs |
| 16:00–17:30 | 1.5h | Epic 15 | Slides + demo GIF + destroy/apply dry run |
| 17:30–18:00 | 30m | Epic 15 | LinkedIn draft + final checklist + submit |

**EOD:** Submitted. Celebrate. Write the LinkedIn post tomorrow with a clear head.

---

## 8. Risk Register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| AWS SG misconfiguration blocks traffic | High | High | `telnet` test early, SG-to-SG refs, document SG matrix |
| Ansible ProxyJump fails on dynamic inventory | Medium | High | Test plain SSH first, then `ansible -m ping`, then playbook |
| Docker image arch mismatch (Apple Silicon → EC2 x86) | Medium | Medium | `buildx` multi-arch from Day 1 |
| Terraform state corruption | Low | Critical | Remote state + DynamoDB locking from Epic 4 |
| ALB path-routing breaks result app WebSocket | High | Medium | Spike in Epic 10.1, fallback plan in ADR-005 |
| CloudWatch Agent IAM permissions | Medium | Medium | Use AWS-managed `CloudWatchAgentServerPolicy` |
| Running out of time on Day 4 | Medium | Medium | Day 3 is the safe-stop line; Day 4/5 are add-ons |
| AWS bill surprise | Medium | Medium | Destroy nightly, billing alert at €25 |
| Secrets committed to git | Low | Critical | `.gitignore` Day 1, pre-commit hook Day 5 |
| Presentation not ready Day 5 | Medium | High | Diagram + README start Day 5 morning, not evening |

---

## 9. AWS Cost Control

Approximate cost **if running 24h/day for 5 days** (eu-central-1, Frankfurt):

| Resource | Daily | Notes |
|---|---|---|
| 4× t3.micro EC2 | ~€0.80 | Free tier if eligible |
| 1× t3.nano bastion | ~€0.10 | — |
| NAT Gateway | ~€1.20 | **Biggest single cost** |
| ALB | ~€0.70 | Only from Day 4 |
| Data transfer | ~€0.20 | — |
| S3 + DynamoDB | ~€0.05 | — |
| CloudWatch Logs | ~€0.10 | 7-day retention |
| **Total** | **~€3.15/day** | ~€15 for 5 days running 24/7 |

**Destroy nightly (21:00 → 09:00):** Saves ~€1.50/day × 5 = €7.50. **Target total spend: ~€10.**

Set AWS Budget alert at **€25** on Day 1 as insurance.

---

## 10. Daily Ritual

**Morning (15 min):**
1. Check yesterday's board — anything stuck? Why?
2. `terraform apply` to recreate infra (if destroyed overnight)
3. Pick today's tasks, move to Sprint column
4. Check AWS billing dashboard

**Evening (30 min):**
1. Commit + push all branches (even WIP)
2. Update README if anything changed
3. Write 3-line retro in `docs/journal.md`: what worked, what didn't, what's next
4. `terraform destroy` (if not actively debugging)
5. Close completed issues

---

## 11. Submission Checklist (Day 5 Final)

- [ ] GitHub repo is public
- [ ] No secrets in git history: `git log -p | grep -iE "password|secret|AKIA|BEGIN RSA"`
- [ ] README renders correctly on GitHub
- [ ] Architecture diagram in `docs/architecture.png`
- [ ] 6 ADRs showing design thinking
- [ ] Commit history is clean (no `wip`, `asdf`, `fix stuff`)
- [ ] `terraform apply` + `ansible-playbook site.yml` works from zero (proven by dry-run)
- [ ] All 8 add-ons documented in README with links to code
- [ ] Presentation slides finalized
- [ ] Demo GIF in README
- [ ] LinkedIn post draft ready
- [ ] Repo pinned on GitHub profile
- [ ] CI checks green on main

---

## 12. Definition of "Done, Professionally"

This is my rubric as your mentor:

1. **Clone-to-deploy in <45 min** following only the README — if not, docs fail.
2. **`terraform destroy` + `terraform apply` + `ansible-playbook site.yml` produces a working stack** — if not, IaC is flaky.
3. **Commit history reads as a story**, not a mess — PRs squash-merged with clear titles.
4. **ADRs exist for non-obvious decisions** — .NET 8, dedicated bastion, single-NAT, ALB routing, own-Dockerfiles exercise.
5. **Zero manual "click in console" steps anywhere** — full automation is the bar.
6. **All 8 add-ons traceable to code** — README has a table: add-on → implementation location.

Hit those six, and this is portfolio-grade work. You'll be able to point any future employer at this repo with pride.

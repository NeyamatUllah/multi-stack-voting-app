#!/usr/bin/env bash
# setup-github-project.sh
#
# One-time setup: creates all GitHub labels, a Projects v2 board, and
# all 15 epic issues (with task checklists) from the project plan.
#
# Prerequisites:
#   gh auth login
#   gh auth refresh -h github.com -s project   ← required for project board
#   sudo apt install jq -y
#
# Usage:
#   chmod +x scripts/setup-github-project.sh
#   ./scripts/setup-github-project.sh

set -euo pipefail

OWNER="NeyamatUllah"
REPO="NeyamatUllah/multi-stack-voting-app"
PROJECT_TITLE="Multi-Stack Voting App — DevOps"
BODY_DIR=$(mktemp -d)
trap 'rm -rf "$BODY_DIR"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# 0. Prerequisites
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> [0/5] Checking prerequisites..."

command -v jq &>/dev/null || { echo "ERROR: jq not found. Run: sudo apt install jq -y"; exit 1; }
gh auth status &>/dev/null  || { echo "ERROR: Not authenticated. Run: gh auth login"; exit 1; }

if ! gh auth status 2>&1 | grep -q "project"; then
    echo ""
    echo "ERROR: Token is missing 'project' scope."
    echo "       Run: gh auth refresh -h github.com -s project"
    echo "       Then re-run this script."
    exit 1
fi

echo "    OK — gh authenticated with project scope, jq available"

# ─────────────────────────────────────────────────────────────────────────────
# 1. Labels
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> [1/5] Creating labels..."

lbl() {
    gh label create "$1" --color "$2" --description "$3" \
        --repo "$REPO" --force 2>/dev/null
    echo "    $1"
}

# Type
lbl "epic"      "8B5CF6" "Large body of work containing multiple tasks"
lbl "task"      "3B82F6" "Individual unit of work"
lbl "bug"       "EF4444" "Something is not working"
lbl "docs"      "10B981" "Documentation only changes"
lbl "spike"     "F59E0B" "Time-boxed research or investigation"
lbl "add-on"    "EC4899" "Optional enhancement beyond core scope"

# Day
lbl "day-1"     "DBEAFE" "Day 1"
lbl "day-2"     "BFDBFE" "Day 2"
lbl "day-3"     "93C5FD" "Day 3"
lbl "day-4"     "60A5FA" "Day 4"
lbl "day-5"     "3B82F6" "Day 5"

# Priority
lbl "must-do"   "DC2626" "Non-negotiable for core delivery"
lbl "should-do" "F97316" "High value, do if time permits"
lbl "stretch"   "84CC16" "Nice to have — cut if pressed"

# Category
lbl "terraform" "7C3AED" "Infrastructure as Code"
lbl "ansible"   "EA580C" "Configuration management"
lbl "docker"    "0891B2" "Containerization"
lbl "aws"       "F59E0B" "Amazon Web Services"
lbl "docs-cat"  "059669" "Documentation"

echo "    Done"

# ─────────────────────────────────────────────────────────────────────────────
# 2. GitHub Project
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> [2/5] Creating GitHub Project..."

gh project create --owner "$OWNER" --title "$PROJECT_TITLE" > /dev/null

PROJECT_NUMBER=$(gh project list --owner "$OWNER" --format json \
    | jq -r --arg t "$PROJECT_TITLE" '.projects[] | select(.title == $t) | .number' \
    | head -1)

echo "    Project #${PROJECT_NUMBER}: ${PROJECT_TITLE}"

PROJ_DATA=$(gh api graphql -f query="
query {
  user(login: \"$OWNER\") {
    projectV2(number: $PROJECT_NUMBER) {
      id
      fields(first: 10) {
        nodes {
          ... on ProjectV2SingleSelectField {
            id name options { id name }
          }
        }
      }
    }
  }
}")

PROJECT_ID=$(echo "$PROJ_DATA"     | jq -r '.data.user.projectV2.id')
STATUS_FIELD_ID=$(echo "$PROJ_DATA" \
    | jq -r '.data.user.projectV2.fields.nodes[] | select(.name == "Status") | .id')

echo "    Project node ID: $PROJECT_ID"

# ─────────────────────────────────────────────────────────────────────────────
# 3. Status columns
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> [3/5] Configuring Status columns..."

add_status() {
    gh api graphql -f query="
    mutation {
      addProjectV2SingleSelectFieldOption(input: {
        projectId: \"$PROJECT_ID\"
        fieldId:   \"$STATUS_FIELD_ID\"
        name:      \"$1\"
        color:      $2
        description: \"\"
      }) { projectV2SingleSelectField { options { id name } } }
    }" > /dev/null
    echo "    $1"
}

add_status "📋 Backlog"     GRAY
add_status "🎯 Sprint"      BLUE
add_status "🚧 In Progress" YELLOW
add_status "👀 Review"      ORANGE
add_status "✅ Done"        GREEN

# Re-fetch to get the new Backlog option ID
BACKLOG_OPTION_ID=$(gh api graphql -f query="
query {
  user(login: \"$OWNER\") {
    projectV2(number: $PROJECT_NUMBER) {
      fields(first: 10) {
        nodes {
          ... on ProjectV2SingleSelectField {
            id name options { id name }
          }
        }
      }
    }
  }
}" | jq -r '.data.user.projectV2.fields.nodes[]
     | select(.name == "Status")
     | .options[]
     | select(.name == "📋 Backlog")
     | .id')

echo "    Backlog option ID: $BACKLOG_OPTION_ID"

# ─────────────────────────────────────────────────────────────────────────────
# Helper: create issue, add to project, set status to Backlog
# ─────────────────────────────────────────────────────────────────────────────
add_issue() {
    local title="$1" labels="$2" body_file="$3"
    local issue_url item_id

    issue_url=$(gh issue create \
        --repo "$REPO" \
        --title "$title" \
        --label "$labels" \
        --body-file "$body_file")

    item_id=$(gh project item-add "$PROJECT_NUMBER" \
        --owner "$OWNER" \
        --url "$issue_url" \
        --format json | jq -r '.id')

    gh api graphql -f query="
    mutation {
      updateProjectV2ItemFieldValue(input: {
        projectId: \"$PROJECT_ID\"
        itemId:    \"$item_id\"
        fieldId:   \"$STATUS_FIELD_ID\"
        value:     { singleSelectOptionId: \"$BACKLOG_OPTION_ID\" }
      }) { projectV2Item { id } }
    }" > /dev/null

    echo "    $issue_url"
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Epic issues
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> [4/5] Creating epic issues..."

# ── EPIC 1 ───────────────────────────────────────────────────────────────────
cat > "$BODY_DIR/e01.md" <<'BODY'
**Labels:** `epic` `day-1` `must-do` · **Est:** 2h

> Goal: Repo live on GitHub, board populated, local tooling verified, AWS billing alert active.

## Tasks
- [x] **1.1** Clone upstream repo, initialize root git repo at `multi-stack-voting-app/`, push to GitHub (15m) ✅
- [ ] **1.2** Create GitHub Project board, columns, labels (20m) — *this script does it*
- [x] **1.3** Create folder structure (`src/`, `infra/`, `configuration/`, `tests/`, `docs/`), `.gitignore`, initial commit (30m) ✅
- [ ] **1.4** Write initial README skeleton with placeholder sections (15m)
- [ ] **1.5** Create first ADRs: `docs/decisions/001-end-state-topology.md`, `002-dotnet-8-upgrade.md` (30m)
- [ ] **1.6** Verify toolchain: Docker ≥24, Terraform ≥1.6, Ansible ≥2.15, AWS CLI v2, draw.io (10m)
- [ ] **1.7** Verify AWS IAM user has required permissions; set billing alert at €25 (15m)

## Definition of Done
Repo on GitHub ✅, board populated ✅, local tooling verified, AWS billing alert active.
BODY
add_issue "EPIC 1 — Project Bootstrap & Repository Setup" "epic,day-1,must-do" "$BODY_DIR/e01.md"

# ── EPIC 2 ───────────────────────────────────────────────────────────────────
cat > "$BODY_DIR/e02.md" <<'BODY'
**Labels:** `epic` `day-1` `must-do` `docker` · **Est:** 2.5h

> Use the provided Dockerfiles first to get working images. The from-scratch exercise (Epic 3) is separate.

## Tasks
- [x] **2.1** Review provided Dockerfiles — worker already on .NET 8, no upgrade needed ✅
- [ ] **2.2** Build all three images locally, verify each runs standalone (30m)
- [ ] **2.3** Set up `docker buildx` multi-arch builder (amd64 + arm64) (20m)
- [ ] **2.4** Build + push to DockerHub, tag with `latest` + git short SHA (30m)
- [ ] **2.5** Update `src/docker-compose.yml` to use your DockerHub images instead of `pokfinner/*` (15m)
- [ ] **2.6** E2E local test: `docker compose up` → cast vote at :8080 → see result at :8081 (20m)
- [ ] **2.7** Commit + document local workflow in README (15m)

## Definition of Done
3 images on DockerHub (multi-arch), `docker compose up` works from a fresh clone.
BODY
add_issue "EPIC 2 — Dockerize Services & Publish to DockerHub" "epic,day-1,must-do,docker" "$BODY_DIR/e02.md"

# ── EPIC 3 ───────────────────────────────────────────────────────────────────
cat > "$BODY_DIR/e03.md" <<'BODY'
**Labels:** `epic` `day-1` `add-on` `docker` · **Est:** 2h

> **Scoped down:** 2-hour learning exercise. Write Dockerfiles from scratch in an `exercise/` branch, document what you got right/wrong in ADR-006, then discard in favour of the working versions from Epic 2.

## Tasks
- [ ] **3.1** Create branch `exercise/own-dockerfiles`, delete all provided Dockerfiles + compose (10m)
- [ ] **3.2** Write Dockerfile for `vote` (Python/Flask/gunicorn) from memory (30m)
- [ ] **3.3** Write Dockerfile for `result` (Node.js) from memory (25m)
- [ ] **3.4** Write Dockerfile for `worker` (.NET 8 multi-stage) from memory (30m)
- [ ] **3.5** Write `docker-compose.yml` from memory — ports, networks, env vars (20m)
- [ ] **3.6** Document what you got right/wrong in `docs/decisions/006-own-dockerfiles-exercise.md` (15m)
- [ ] **3.7** Archive the branch (do NOT merge — main uses Epic 2's working versions)

## Definition of Done
Exercise branch pushed to GitHub, ADR-006 documents the learning. Main branch unaffected.

> **Why a branch, not main:** the working deployment needs the tested Dockerfiles.
> The from-scratch exercise is a learning artifact, not a deliverable.
BODY
add_issue "EPIC 3 — Own Dockerfiles & Compose Exercise (Add-on #5)" "epic,day-1,add-on,docker" "$BODY_DIR/e03.md"

# ── EPIC 4 ───────────────────────────────────────────────────────────────────
cat > "$BODY_DIR/e04.md" <<'BODY'
**Labels:** `epic` `day-2` `must-do` `add-on` `terraform` `aws` · **Est:** 1h

> Must run **before** the main Terraform work. Creates the S3 bucket and DynamoDB table used as the remote backend. Its own state stays local.

## Tasks
- [ ] **4.1** Write `infra/bootstrap/` — S3 bucket (versioned, encrypted, public-access-blocked) + DynamoDB table with `LockID` PK (30m)
- [ ] **4.2** `terraform init && terraform apply` locally; state stays in `infra/bootstrap/terraform.tfstate` (not pushed to remote) (15m)
- [ ] **4.3** Commit bootstrap module + update `docs/runbook.md` Phase 2 with actual bucket/table names (15m)

## Definition of Done
- S3 bucket `voting-app-tfstate-<initials>-<date>` exists and is versioned
- DynamoDB table `voting-app-tf-locks` exists with `LockID` as PK
BODY
add_issue "EPIC 4 — Terraform State Backend S3 + DynamoDB (Add-on #3)" "epic,day-2,must-do,add-on,terraform,aws" "$BODY_DIR/e04.md"

# ── EPIC 5 ───────────────────────────────────────────────────────────────────
cat > "$BODY_DIR/e05.md" <<'BODY'
**Labels:** `epic` `day-2` `must-do` `terraform` `aws` · **Est:** 7h

> The single biggest chunk. Build the full end-state topology including ALB-ready subnets — ALB itself comes in Epic 10.

## Tasks
- [ ] **5.1** `infra/terraform/versions.tf`, `backend.tf` wired to `infra/bootstrap/` S3/DynamoDB (20m)
- [ ] **5.2** **Networking module** `infra/terraform/modules/networking/`: VPC, 2× public subnets, 2× private app subnets, 2× private DB subnets across 2 AZs, IGW, single NAT Gateway, route tables (100m)
- [ ] **5.3** **Security module** `infra/terraform/modules/security/`: SGs for ALB, bastion, frontend, backend, db — all SG-to-SG references, no open CIDRs on private instances (75m)
- [ ] **5.4** **Compute module** `infra/terraform/modules/compute/`: bastion (t3.nano, public), frontend (t3.micro, private), backend (t3.micro, private), db (t3.micro, private-db-subnet), SSH key pair, user_data (90m)
- [ ] **5.5** IAM role + instance profile: `CloudWatchAgentServerPolicy`, `AmazonSSMManagedInstanceCore` (30m)
- [ ] **5.6** `outputs.tf`: all instance private IPs, bastion public IP, SG IDs, subnet IDs, VPC ID (15m)
- [ ] **5.7** `terraform plan` review → `terraform apply` → verify instances in AWS Console (45m)
- [ ] **5.8** Smoke test: SSH to bastion → ProxyJump to each private instance (15m)

## Definition of Done
4 EC2 instances running, bastion SSH works, ProxyJump to all private instances works,
`terraform destroy` + `terraform apply` round-trips cleanly in < 5 min.

## Gotchas
- Use `for_each` not `count` for EC2 resources — count churn replaces unrelated instances
- Tag everything: `Project = "voting-app"`, `ManagedBy = "terraform"`
- Use `aws_key_pair` with a locally generated key (`ssh-keygen`), not AWS-generated
BODY
add_issue "EPIC 5 — Core Infrastructure: VPC, EC2, SGs (Terraform)" "epic,day-2,must-do,terraform,aws" "$BODY_DIR/e05.md"

# ── EPIC 6 ───────────────────────────────────────────────────────────────────
cat > "$BODY_DIR/e06.md" <<'BODY'
**Labels:** `epic` `day-3` `must-do` `ansible` `aws` · **Est:** 3h

## Tasks
- [ ] **6.1** Update `~/.ssh/config` with bastion entry + ProxyJump entries for frontend, backend, db (20m)
- [ ] **6.2** `configuration/ansible/ansible.cfg` + `requirements.yml` (collections: `amazon.aws`, `community.docker`) (20m)
- [ ] **6.3** Dynamic inventory `configuration/ansible/inventory/aws_ec2.yml` — group by EC2 tags (`Project = voting-app`) (40m)
- [ ] **6.4** Verify: `ansible-inventory --graph` shows all hosts in correct groups (15m)
- [ ] **6.5** Verify: `ansible all -m ping` succeeds via bastion ProxyJump (20m)
- [ ] **6.6** `common` role: set hostname, timezone, run `apt upgrade` (25m)
- [ ] **6.7** `docker` role: install `docker.io`, enable + start service, add `ubuntu` user to `docker` group (30m)

## Definition of Done
`ansible all -m ping` returns green for all 3 app instances via bastion.
Docker installed and `docker run hello-world` works on each instance without sudo.
BODY
add_issue "EPIC 6 — Configuration Management: Ansible Foundation" "epic,day-3,must-do,ansible,aws" "$BODY_DIR/e06.md"

# ── EPIC 7 ───────────────────────────────────────────────────────────────────
cat > "$BODY_DIR/e07.md" <<'BODY'
**Labels:** `epic` `day-3` `must-do` `ansible` `docker` · **Est:** 4h

## Tasks
- [ ] **7.1** `postgres` role: pull `postgres:15-alpine`, run with `POSTGRES_USER/PASSWORD/DB` env vars (volume added in Epic 8) (30m)
- [ ] **7.2** `redis` role: pull `redis:alpine`, run with restart policy (20m)
- [ ] **7.3** `worker` role: pull your DockerHub image, run with `REDIS_HOST` + `DB_HOST/USERNAME/PASSWORD` env vars (30m)
- [ ] **7.4** `vote` role: pull your DockerHub image, run with `REDIS_HOST` env var pointing to backend EC2 private IP (25m)
- [ ] **7.5** `result` role: pull your DockerHub image, run with `PG_HOST/USER/PASSWORD` env vars pointing to DB EC2 private IP (25m)
- [ ] **7.6** `configuration/ansible/playbooks/site.yml`: orchestrate db → backend → frontend order with proper tags (30m)
- [ ] **7.7** Full E2E run: `ansible-playbook site.yml` → cast vote → confirm count increments in result app (60m debug buffer)

## Definition of Done
Full stack working end-to-end via Ansible.
Cast a vote from `http://<frontend-public-or-alb-ip>`, result app shows the count.
`docker logs` on each container is clean (no connection errors after startup).

## Debug checklist
- `docker logs <container>` on each instance
- `telnet <backend-ip> 6379` from frontend to verify Redis reachable
- `telnet <db-ip> 5432` from backend to verify Postgres reachable
- `docker exec -it vote bash; env | grep REDIS` to verify env vars
BODY
add_issue "EPIC 7 — Application Deployment via Ansible" "epic,day-3,must-do,ansible,docker" "$BODY_DIR/e07.md"

# ── EPIC 8 ───────────────────────────────────────────────────────────────────
cat > "$BODY_DIR/e08.md" <<'BODY'
**Labels:** `epic` `day-3` `add-on` `ansible` `docker` · **Est:** 1h

## Tasks
- [ ] **8.1** Update `postgres` role to mount a named Docker volume at `/var/lib/postgresql/data` (20m)
- [ ] **8.2** Re-run `ansible-playbook site.yml --tags postgres`, cast a vote, verify data is persisted (20m)
- [ ] **8.3** Persistence test: `docker stop postgres && docker rm postgres`, re-run playbook, confirm vote count still there (20m)

## Definition of Done
PostgreSQL data survives container destruction and recreation via playbook.
BODY
add_issue "EPIC 8 — PostgreSQL Named Volume (Add-on #2)" "epic,day-3,add-on,ansible,docker" "$BODY_DIR/e08.md"

# ── EPIC 9 ───────────────────────────────────────────────────────────────────
cat > "$BODY_DIR/e09.md" <<'BODY'
**Labels:** `epic` `day-3` `add-on` `terraform` `ansible` · **Est:** 1.5h

> The dedicated bastion EC2 is already provisioned by Epic 5. This epic hardens it and optionally enables deploy-from-bastion.

## Tasks
- [ ] **9.1** Tighten bastion SG: inbound SSH (22) only from your public IP — set via `terraform.tfvars` variable, not hardcoded (20m)
- [ ] **9.2** Tighten all app SGs: inbound SSH only from `bastion-sg` (SG reference, not CIDR) — verify with `terraform plan` (20m)
- [ ] **9.3** `bastion` Ansible role: install Ansible on the bastion itself, clone repo via deploy key (30m)
- [ ] **9.4** Test: SSH to bastion → run `ansible-playbook site.yml` from bastion — full deploy-from-bastion flow (20m)

## Definition of Done
Bastion SG allows SSH only from your IP.
All app instance SGs allow SSH only from bastion SG (not `0.0.0.0/0`).
BODY
add_issue "EPIC 9 — Individual Bastion Host Hardening (Add-on #4)" "epic,day-3,add-on,terraform,ansible" "$BODY_DIR/e09.md"

# ── EPIC 10 ──────────────────────────────────────────────────────────────────
cat > "$BODY_DIR/e10.md" <<'BODY'
**Labels:** `epic` `day-4` `add-on` `terraform` `aws` · **Est:** 6h ⭐

> The headline add-on. Budget real time for path-routing and WebSocket debugging.

## Tasks
- [ ] **10.1** Spike: manually test ALB path-routing in AWS Console with a dummy instance; decide path-strip vs base-path strategy (45m)
- [ ] **10.2** Write `docs/decisions/005-alb-path-routing.md` documenting the chosen approach (20m)
- [ ] **10.3** `infra/terraform/modules/alb/`: ALB resource, placed in 2× public subnets, HTTP listener :80 (40m)
- [ ] **10.4** Target groups: `vote-tg` (health: `GET /`) and `result-tg` (health: `GET /`) with appropriate intervals (40m)
- [ ] **10.5** Listener rules: default + `/vote*` → `vote-tg`; `/result` + `/result/*` → `result-tg` (30m)
- [ ] **10.6** ALB SG (inbound 80 from internet); update frontend SG to accept 80/81 only from `alb-sg`, not `0.0.0.0/0` (20m)
- [ ] **10.7** Handle WebSocket path: ALB idle timeout ≥ 60s; verify `/socket.io/` upgrade passes through (60m)
- [ ] **10.8** Update Ansible group_vars to set correct env vars now that traffic flows via ALB (30m)
- [ ] **10.9** E2E test via ALB DNS name: cast vote, confirm result updates live (30m)
- [ ] **10.10** Update `docs/architecture.md` and README to reflect ALB topology (30m)

## Definition of Done
`http://<ALB-DNS>/` → vote app. `http://<ALB-DNS>/result` → result app with live WebSocket updates.
Frontend EC2 no longer directly accessible from internet.

## Fallback (if WebSocket path breaks)
Document the constraint in ADR-005 and use port-based routing (:80 vote, :81 result) as fallback.
Ship something that works rather than blocking.
BODY
add_issue "EPIC 10 — Application Load Balancer with Path Routing (Add-on #8)" "epic,day-4,add-on,terraform,aws" "$BODY_DIR/e10.md"

# ── EPIC 11 ──────────────────────────────────────────────────────────────────
cat > "$BODY_DIR/e11.md" <<'BODY'
**Labels:** `epic` `day-4` `add-on` `aws` `ansible` · **Est:** 3.5h (trimmed to 2.5h if ALB runs long)

## Tasks
- [ ] **11.1** Terraform: CloudWatch Log Groups for each service with 7-day retention (20m)
- [ ] **11.2** `cloudwatch_agent` Ansible role: download, install, and configure the CloudWatch Agent via JSON config (60m)
- [ ] **11.3** Agent config: collect `/var/log/syslog`, Docker container stdout logs, CPU + mem + disk metrics (45m)
- [ ] **11.4** Terraform: SNS topic + email subscription for alarms (20m)
- [ ] **11.5** Terraform: alarms — CPU > 80% for 5 min, disk > 80%, ALB unhealthy target count > 0 (40m)
- [ ] **11.6** Smoke test: trigger CPU alarm with `stress` on one instance, confirm email arrives (25m)
- [ ] **11.7** Terraform: CloudWatch Dashboard with CPU, memory, disk, and ALB request count widgets (30m)

## Definition of Done
Container logs visible in CloudWatch Logs.
Dashboard shows live metrics for all instances.
Test alarm fires and sends an email to the configured address.

## Minimum viable (if time-boxed)
Tasks 11.1 + 11.4 + 11.5 (log groups + one alarm + SNS email) = 40 min.
Skip dashboard (11.7) if pressed.
BODY
add_issue "EPIC 11 — Logging & Monitoring with CloudWatch (Add-on #6)" "epic,day-4,add-on,aws,ansible" "$BODY_DIR/e11.md"

# ── EPIC 12 ──────────────────────────────────────────────────────────────────
cat > "$BODY_DIR/e12.md" <<'BODY'
**Labels:** `epic` `day-5` `stretch` · **Est:** 1.5h

> Not in the brief's add-on list but signals senior-level thinking at zero extra cost.

## Tasks
- [ ] **12.1** GitHub Actions: `terraform fmt --check`, `terraform validate`, `tflint` on every PR (45m)
- [ ] **12.2** GitHub Actions: `ansible-lint` + `yamllint` on every PR (30m)
- [ ] **12.3** Local pre-commit hooks: `terraform fmt`, trailing whitespace, large file check (15m)

## Definition of Done
PRs show green checks. Commits are clean before push.
BODY
add_issue "EPIC 12 — CI/CD Polish: GitHub Actions + Pre-commit (Bonus)" "epic,day-5,stretch" "$BODY_DIR/e12.md"

# ── EPIC 13 ──────────────────────────────────────────────────────────────────
cat > "$BODY_DIR/e13.md" <<'BODY'
**Labels:** `epic` `day-5` `add-on` `docs-cat` · **Est:** 1.5h

> **Scoped down** — documented procedure verified end-to-end, not a supported workflow.

## Prerequisites (install locally)
- Python 3.11 + pip
- Node.js 18 + npm
- .NET SDK 8.0
- Redis and PostgreSQL running in Docker (as reference services)

## Tasks
- [ ] **13.1** Write `docs/local-development.md`: prerequisites, env var setup per service, startup order (45m)
- [ ] **13.2** Actually run through the doc start to finish; fix anything that doesn't work (40m)
- [ ] **13.3** Add `.env.example` files in `src/vote/`, `src/result/`, `src/worker/` (5m)

## Definition of Done
A developer can clone the repo and run all 5 services locally by following `docs/local-development.md`.
BODY
add_issue "EPIC 13 — Running Apps Locally Without Docker (Add-on #7)" "epic,day-5,add-on,docs-cat" "$BODY_DIR/e13.md"

# ── EPIC 14 ──────────────────────────────────────────────────────────────────
cat > "$BODY_DIR/e14.md" <<'BODY'
**Labels:** `epic` `day-5` `must-do` `docs-cat` · **Est:** 3h

## Tasks
- [ ] **14.1** Architecture diagram in draw.io (or Excalidraw): VPC, subnets, ALB, EC2s, SGs, data flow arrows — export to `docs/architecture.png` (75m)
- [ ] **14.2** README: overview, architecture diagram embed, prerequisites, quick-start (`./scripts/deploy.sh`), add-ons table with links to code, cost estimate, cleanup (75m)
- [x] **14.3** `docs/runbook.md`: deploy from zero in numbered steps ✅ created early
- [ ] **14.4** Finalize all 6 ADRs in `docs/decisions/` (30m)
- [ ] **14.5** Add badges to README: Terraform version, Docker, AWS, CI status (15m)

## Definition of Done
A stranger can deploy the full stack in < 45 min by following only the README.
BODY
add_issue "EPIC 14 — Documentation & Architecture Decision Records" "epic,day-5,must-do,docs-cat" "$BODY_DIR/e14.md"

# ── EPIC 15 ──────────────────────────────────────────────────────────────────
cat > "$BODY_DIR/e15.md" <<'BODY'
**Labels:** `epic` `day-5` `must-do` · **Est:** 3h

## Tasks
- [ ] **15.1** Presentation slides (15 min): Problem → Architecture → Demo → Add-ons → Lessons Learned (90m)
- [ ] **15.2** Record 2-min demo GIF for README (cast vote → result updates live) (30m)
- [ ] **15.3** Full destroy → apply dry run on clean state — proves IaC is not flaky (30m)
- [ ] **15.4** Pin repo on GitHub profile, write LinkedIn post draft (30m)
- [ ] **15.5** Final submission checklist walkthrough (15m)

## Submission checklist
- [ ] GitHub repo is public
- [ ] No secrets in git history: `git log -p | grep -iE "password|secret|AKIA|BEGIN RSA"`
- [ ] README renders correctly on GitHub
- [ ] `docs/architecture.png` present
- [ ] 6 ADRs in `docs/decisions/`
- [ ] Commit history is clean (no `wip`, `asdf`, `fix stuff`)
- [ ] `terraform apply` + `ansible-playbook site.yml` works from zero
- [ ] All 8 add-ons documented in README with links to code
- [ ] Demo GIF in README
- [ ] CI checks green on main

## Definition of Done
Presentation delivered. Repo is portfolio-grade. LinkedIn post ready to publish.
BODY
add_issue "EPIC 15 — Presentation & Submission" "epic,day-5,must-do" "$BODY_DIR/e15.md"

# ─────────────────────────────────────────────────────────────────────────────
# 5. Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> [5/5] Done!"
echo ""
echo "    Project board : https://github.com/users/${OWNER}/projects/${PROJECT_NUMBER}"
echo "    Issues        : https://github.com/${REPO}/issues"
echo ""
echo "    Next steps:"
echo "    1. Open the project board and delete the default 'Todo / In Progress / Done'"
echo "       options from the Status field — your custom columns are already added."
echo "    2. Move EPIC 1 tasks 1.1 + 1.3 and EPIC 2 task 2.1 to ✅ Done"
echo "       (they were completed before this script ran)."
echo "    3. Move today's epics to 🎯 Sprint."
echo ""

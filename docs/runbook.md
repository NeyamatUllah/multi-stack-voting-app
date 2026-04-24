# Runbook — Multi-Stack Voting App

Deploy the full stack from zero, in order. Each section maps to an Epic in `2_project-plan.md`.

---

## Prerequisites

| Tool | Version | Check |
|---|---|---|
| Git | any | `git --version` |
| Docker + Docker Buildx | 24+ | `docker buildx version` |
| Terraform | ≥ 1.6 | `terraform version` |
| Ansible | ≥ 2.15 | `ansible --version` |
| AWS CLI | v2 | `aws --version` |

AWS credentials must be configured:
```bash
aws configure        # or export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
aws sts get-caller-identity   # verify
```

---

## Phase 0 — Clone the Repository

```bash
git clone git@github.com:<your-username>/<repo-name>.git
cd <repo-name>
```

### Repository Layout

```
.
├── src/                    # Application source code
│   ├── vote/               # Python / Flask — voting UI
│   ├── result/             # Node.js — results display
│   ├── worker/             # .NET 8 — Redis → PostgreSQL bridge
│   ├── healthchecks/       # Shell scripts used by docker-compose healthchecks
│   └── docker-compose.yml  # Local development stack
├── infra/                  # Terraform — AWS infrastructure
├── configuration/          # Ansible — configuration management & deployment
├── tests/                  # Integration / smoke tests
└── docs/                   # Architecture diagrams, ADRs, this runbook
```

---

## Phase 1 — Local Stack (Docker Compose)

Verifies the application works before touching any cloud infrastructure.

### 1.1 — Build a Multi-Arch Builder (one-time)

```bash
docker buildx create --name multiarch --driver docker-container --use
docker buildx inspect --bootstrap
```

### 1.2 — Build and Push Images to DockerHub

Run from the repo root. Replace `<hub>` with your DockerHub username.

```bash
docker login

# Vote service (Python / Flask)
cd src/vote
docker buildx build --target final \
  --platform linux/amd64,linux/arm64 \
  -t <hub>/vote:latest --push .

# Result service (Node.js)
cd ../result
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t <hub>/result:latest --push .

# Worker service (.NET 8)
cd ../worker
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t <hub>/worker:latest --push .
```

### 1.3 — Update docker-compose.yml

In `src/docker-compose.yml`, replace the three `image:` references with your DockerHub images:

```yaml
# vote service
image: <hub>/vote:latest

# result service
image: <hub>/result:latest

# worker service
image: <hub>/worker:latest
```

### 1.4 — Run the Local Stack

```bash
cd src/
docker compose up
```

| Service | URL |
|---|---|
| Vote | http://localhost:8080 |
| Result | http://localhost:8081 |

Cast a vote. Confirm the count appears in the result app. Tear down with `docker compose down`.

---

## Phase 2 — Terraform Bootstrap (Remote State)

Run **once** before any main Terraform work. Creates the S3 bucket and DynamoDB table used as the Terraform remote backend.

```bash
cd infra/bootstrap/
terraform init
terraform apply
```

Expected outputs:
- S3 bucket: `voting-app-tfstate-<initials>-<date>`
- DynamoDB table: `voting-app-tf-locks`

> This state is stored **locally** (`infra/bootstrap/terraform.tfstate`). Keep it safe — it is not in the remote backend.

---

## Phase 3 — Provision AWS Infrastructure (Terraform)

```bash
cd infra/
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — set region, key name, your public IP for bastion SSH
terraform init
terraform plan
terraform apply
```

### What Gets Created

| Resource | Details |
|---|---|
| VPC | 1 VPC, 2 public subnets, 2 private (app) subnets, 2 private (db) subnets |
| NAT Gateway | Single NAT Gateway in AZ-1 (cost trade-off) |
| Bastion | t3.nano in public subnet — only entry point via SSH |
| Frontend EC2 | Private subnet — runs `vote` + `result` containers |
| Backend EC2 | Private subnet — runs `redis` + `worker` containers |
| DB EC2 | Private DB subnet — runs `postgres` container |
| Security Groups | SG-to-SG rules (no open CIDRs on private instances) |
| ALB | Application Load Balancer in 2 public subnets (added in Epic 10) |

### Smoke Test After Apply

```bash
# SSH to bastion
ssh bastion-instance

# From bastion — ProxyJump to private instances
ssh frontend-instance
ssh backend-instance
ssh db-instance
```

### Teardown (run every evening to control costs)

```bash
cd infra/
terraform destroy
```

---

## Phase 4 — Deploy Containers (Ansible)

```bash
cd configuration/ansible/

# Verify connectivity
ansible-inventory --graph
ansible all -m ping

# Full deployment
ansible-playbook playbooks/site.yml
```

### Deployment Order (enforced by site.yml)

1. `common` role — hostname, timezone, system updates
2. `docker` role — install Docker, enable service, add user to group
3. `postgres` role — pull + run postgres with named volume
4. `redis` role — pull + run redis
5. `worker` role — pull + run worker with `REDIS_HOST` + DB env vars
6. `vote` role — pull + run vote with `REDIS_HOST`
7. `result` role — pull + run result with DB connection env vars

### Connection Environment Variables

| Container | Variable | Points To |
|---|---|---|
| `vote` | `REDIS_HOST` | Backend EC2 private IP |
| `worker` | `REDIS_HOST` | Backend EC2 private IP |
| `worker` | `DB_HOST` | DB EC2 private IP |
| `result` | `PG_HOST` | DB EC2 private IP |

---

## Phase 5 — End-to-End Verification

```bash
# From any machine with network access to the ALB
curl http://<ALB-DNS>/        # should return vote page HTML
curl http://<ALB-DNS>/result  # should return result page HTML
```

Manual check:
1. Open `http://<ALB-DNS>/` — cast a vote
2. Open `http://<ALB-DNS>/result` — confirm the vote count increments

### Debug Commands

```bash
# Check container logs on any EC2
docker logs vote
docker logs result
docker logs worker
docker logs redis
docker logs postgres

# Hop into a container
docker exec -it vote bash
env | grep REDIS    # verify env vars

# Test port reachability between instances (install telnet first)
telnet <backend-private-ip> 6379   # redis
telnet <db-private-ip> 5432        # postgres
```

---

## Phase 6 — Teardown

```bash
# Stop containers (handled by terraform destroy, but for manual cleanup)
ansible-playbook playbooks/site.yml --tags stop

# Destroy all AWS resources
cd infra/
terraform destroy
```

> Do **not** destroy the bootstrap state backend unless you are fully done with the project.

---

## Progress Log

| Phase | Status | Date | Notes |
|---|---|---|---|
| Repo initialized, .gitignore, initial push | ✅ Done | 2026-04-24 | Root repo at `multi-stack-voting-app/` |
| src/.git removed, single repo structure | ✅ Done | 2026-04-24 | |
| Multi-arch Docker builder created | ⏳ In Progress | | |
| Vote / Result / Worker images pushed to DockerHub | ⏳ In Progress | | |
| docker-compose.yml updated to own images | ⏳ In Progress | | |
| Local docker compose E2E verified | ⏳ Pending | | |
| Terraform state backend (S3 + DynamoDB) | ⏳ Pending | | |
| Core Terraform (VPC, EC2, SGs) | ⏳ Pending | | |
| Ansible foundation (SSH, inventory, docker role) | ⏳ Pending | | |
| Application deployment via Ansible | ⏳ Pending | | |
| PostgreSQL named volume | ⏳ Pending | | |
| Bastion hardening | ⏳ Pending | | |
| ALB with path-based routing | ⏳ Pending | | |
| CloudWatch logging & alarms | ⏳ Pending | | |

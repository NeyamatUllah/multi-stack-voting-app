# Multi-Stack Voting App — DevOps

A polyglot microservices voting application deployed on AWS, demonstrating end-to-end DevOps practices: containerization, infrastructure-as-code, configuration management, and observability.

<!-- Demo GIF here -->

---

## Architecture

Five services form the voting pipeline:

| Service | Technology | Role |
|---|---|---|
| **vote** | Python / Flask | Accepts votes from browser, pushes to Redis |
| **redis** | Redis | In-memory queue between vote and worker |
| **worker** | .NET 8 | Drains Redis queue, writes to PostgreSQL |
| **result** | Node.js / Socket.IO | Streams live vote counts to browser |
| **postgres** | PostgreSQL 15 | Persistent vote store |

<!-- Architecture diagram -->
![Architecture](docs/architecture.png)

> Full architecture details: [docs/architecture.md](docs/architecture.md)

---

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| Docker + Buildx | 24+ | [docs.docker.com](https://docs.docker.com/get-docker/) |
| Terraform | ≥ 1.6 | [terraform.io](https://developer.hashicorp.com/terraform/install) |
| Ansible | ≥ 2.15 | `pip install ansible` |
| AWS CLI | v2 | [aws.amazon.com/cli](https://aws.amazon.com/cli/) |
| gh CLI | latest | `sudo apt install gh` |

AWS credentials must be configured:

```bash
aws configure
aws sts get-caller-identity   # verify
```

---

## Quick Start

```bash
# 1. Clone
git clone https://github.com/NeyamatUllah/multi-stack-voting-app.git
cd multi-stack-voting-app

# 2. Provision state backend (run once)
cd infra/bootstrap && terraform init && terraform apply && cd ../..

# 3. Provision AWS infrastructure
cd infra/terraform && terraform init && terraform apply && cd ../..

# 4. Deploy containers
cd configuration/ansible && ansible-playbook playbooks/site.yml
```

Full step-by-step instructions: [docs/runbook.md](docs/runbook.md)

---

## Local Development (Docker Compose)

```bash
cd src/
docker compose up
```

| Service | URL |
|---|---|
| Vote | http://localhost:8080 |
| Result | http://localhost:8081 |

Cast a vote and watch the result update in real time.

---

## Add-ons Implemented

| # | Add-on | Difficulty | Location |
|---|---|---|---|
| 1 | Proper Security Group Configs | 🟢 Easy | `infra/terraform/modules/security/` |
| 2 | PostgreSQL Named Volume | 🟢 Easy | `configuration/ansible/roles/postgres/` |
| 3 | S3 + DynamoDB Terraform State | 🟢 Easy | `infra/bootstrap/` |
| 4 | Individual Bastion Host | 🟡 Medium | `infra/terraform/modules/compute/` |
| 5 | Own Dockerfiles from Scratch | 🟡 Medium | branch `exercise/own-dockerfiles` |
| 6 | CloudWatch Logging & Monitoring | 🟡 Medium | `infra/terraform/modules/monitoring/` |
| 7 | Running Locally Without Docker | 🟡 Medium | [docs/local-development.md](docs/local-development.md) |
| 8 | Application Load Balancer | 🟠 Hard | `infra/terraform/modules/alb/` |

---

## AWS Cost Estimate

| Resource | Daily | Notes |
|---|---|---|
| 4× t3.micro EC2 | ~€0.80 | Free tier eligible |
| 1× t3.nano bastion | ~€0.10 | — |
| NAT Gateway | ~€1.20 | Single NAT (cost trade-off) |
| ALB | ~€0.70 | From Day 4 onwards |
| S3 + DynamoDB | ~€0.05 | — |
| CloudWatch | ~€0.10 | 7-day log retention |
| **Total** | **~€3.15/day** | Destroy nightly to save ~€1.50/day |

---

## Cleanup

```bash
cd configuration/ansible && ansible-playbook playbooks/site.yml --tags stop
cd infra/terraform && terraform destroy
```

> Do **not** destroy the bootstrap state backend (`infra/bootstrap/`) unless you are fully done with the project.

---

## Repository Structure

```
.
├── src/                    # Application source code
│   ├── vote/               # Python / Flask
│   ├── result/             # Node.js
│   ├── worker/             # .NET 8
│   └── docker-compose.yml  # Local development
├── infra/
│   ├── bootstrap/          # S3 + DynamoDB state backend (run once)
│   └── terraform/          # VPC, EC2, SGs, ALB, CloudWatch
├── configuration/
│   └── ansible/            # Playbooks and roles for container deployment
├── tests/
├── scripts/                # bootstrap.sh, deploy.sh, destroy.sh
└── docs/                   # Architecture, runbook, ADRs
```

---

## Documentation

- [Architecture](docs/architecture.md) — Network topology, data flow, security group matrix
- [Runbook](docs/runbook.md) — Deploy from zero in numbered steps
- [Local Development](docs/local-development.md) — Run all services without Docker
- [Architecture Decisions](docs/decisions/) — ADRs for non-obvious choices

---

## CI Status

<!-- Badges -->
![Terraform](https://img.shields.io/badge/Terraform-≥1.6-7B42BC?logo=terraform)
![Docker](https://img.shields.io/badge/Docker-multi--arch-2496ED?logo=docker)
![AWS](https://img.shields.io/badge/AWS-EC2%20%7C%20ALB%20%7C%20CloudWatch-FF9900?logo=amazonaws)

# Solution Architecture — Multi-Stack Voting App

## Overview

A polyglot microservices application deployed on AWS, demonstrating end-to-end DevOps practices:
containerization, infrastructure-as-code, configuration management, and observability.

| Concern | Tool |
|---|---|
| Containerization | Docker, DockerHub |
| Infrastructure | Terraform (IaC), AWS |
| Configuration & Deploy | Ansible |
| Monitoring | CloudWatch Logs, Metrics, Alarms |
| Source Control | Git / GitHub |
| State Backend | S3 + DynamoDB |

---

## 1. Application Architecture

Five services form the voting pipeline. A vote cast in the browser travels through four hops before the result is visible.

```mermaid
graph LR
    User(["🌐 Browser"])

    subgraph FE["Frontend EC2 (private subnet)"]
        Vote["vote\nPython / Flask\n:80"]
        Result["result\nNode.js / Socket.IO\n:81"]
    end

    subgraph BE["Backend EC2 (private subnet)"]
        Redis["redis\n:6379"]
        Worker["worker\n.NET 8"]
    end

    subgraph DB["DB EC2 (private DB subnet)"]
        Postgres["postgres\n:5432"]
    end

    User -->|"POST /  (cast vote)"| Vote
    User -->|"GET /result  (WebSocket)"| Result

    Vote -->|"LPUSH votes"| Redis
    Worker -->|"BLPOP votes"| Redis
    Worker -->|"INSERT / UPDATE"| Postgres
    Result -->|"SELECT votes"| Postgres
```

### Service Responsibility

| Service | Technology | Host | Role |
|---|---|---|---|
| **vote** | Python 3.11 / Flask / gunicorn | Frontend EC2 | Accepts votes from browser, pushes to Redis queue |
| **redis** | Redis Alpine | Backend EC2 | In-memory queue — buffers votes between vote and worker |
| **worker** | .NET 8 | Backend EC2 | Drains Redis queue, upserts votes into PostgreSQL |
| **result** | Node.js 18 / Socket.IO | Frontend EC2 | Reads from PostgreSQL, streams live counts to browser via WebSocket |
| **postgres** | PostgreSQL 15 | DB EC2 | Persistent vote store |

### Environment Variables (Connection Wiring)

| Container | Variable | Value |
|---|---|---|
| `vote` | `REDIS_HOST` | Backend EC2 private IP |
| `worker` | `REDIS_HOST` | Backend EC2 private IP |
| `worker` | `DB_HOST` | DB EC2 private IP |
| `worker` | `DB_USERNAME` | `postgres` |
| `worker` | `DB_PASSWORD` | (from Ansible vault or env) |
| `result` | `PG_HOST` | DB EC2 private IP |
| `result` | `PG_USER` | `postgres` |
| `result` | `PG_PASSWORD` | (from Ansible vault or env) |

---

## 2. Network Architecture

```mermaid
graph TB
    Internet(["🌐 Internet"])

    subgraph AWS["AWS (eu-central-1)"]

        subgraph VPC["VPC  10.0.0.0/16"]

            IGW["Internet Gateway"]

            subgraph PubA["Public Subnet AZ-1a  10.0.1.0/24"]
                ALB["Application\nLoad Balancer"]
                Bastion["Bastion\nt3.nano"]
                NAT["NAT Gateway"]
            end

            subgraph PubB["Public Subnet AZ-1b  10.0.2.0/24"]
                ALB
            end

            subgraph PrivAppA["Private App Subnet AZ-1a  10.0.11.0/24"]
                FrontendEC2["Frontend EC2\nvote :80\nresult :81"]
            end

            subgraph PrivBeA["Private Backend Subnet AZ-1a  10.0.21.0/24"]
                BackendEC2["Backend EC2\nredis :6379\nworker"]
            end

            subgraph PrivDBA["Private DB Subnet AZ-1a  10.0.31.0/24"]
                DBEC2["DB EC2\npostgres :5432\n(named volume)"]
            end

        end

        subgraph StateBackend["Terraform State Backend"]
            S3["S3 Bucket\nvoting-app-tfstate-*"]
            DDB["DynamoDB\nvoting-app-tf-locks"]
        end

        subgraph Observability["Observability"]
            CWLogs["CloudWatch Logs"]
            CWAlarms["CloudWatch Alarms"]
            SNS["SNS → Email"]
        end

    end

    Internet --> IGW
    IGW --> ALB
    IGW --> Bastion
    ALB -->|"/ and /vote → :80"| FrontendEC2
    ALB -->|"/result → :81"| FrontendEC2
    Bastion -->|"SSH ProxyJump"| FrontendEC2
    Bastion -->|"SSH ProxyJump"| BackendEC2
    Bastion -->|"SSH ProxyJump"| DBEC2
    FrontendEC2 -->|"6379"| BackendEC2
    FrontendEC2 -->|"5432"| DBEC2
    BackendEC2 -->|"5432"| DBEC2
    FrontendEC2 & BackendEC2 & DBEC2 --> NAT --> IGW
```

> **Single NAT Gateway** — all private subnets share one NAT in AZ-1a. This is a deliberate cost trade-off (~€1.20/day vs. ~€2.40/day for HA NAT). See `docs/decisions/004-single-nat-gateway.md`.

---

## 3. ALB Path Routing

The Application Load Balancer is the single public entry point. It routes by URL path:

```
lb-xxx.eu-central-1.elb.amazonaws.com/           →  vote  (Frontend EC2 :80)
lb-xxx.eu-central-1.elb.amazonaws.com/result      →  result (Frontend EC2 :81)
lb-xxx.eu-central-1.elb.amazonaws.com/result/*    →  result (Frontend EC2 :81)  ← WebSocket upgrade path
```

```mermaid
graph LR
    Client(["Browser"])
    ALB["ALB\n:80"]

    subgraph TGs["Target Groups"]
        VoteTG["vote-tg\nFrontend EC2 :80\nhealth: GET /"]
        ResultTG["result-tg\nFrontend EC2 :81\nhealth: GET /"]
    end

    Client --> ALB
    ALB -->|"default rule\n/ and /vote*"| VoteTG
    ALB -->|"/result and /result/*"| ResultTG
```

> **WebSocket risk:** Socket.IO (result app) requires the ALB to support WebSocket upgrades. The listener must have idle timeout ≥ 60s. If path-stripping causes issues with the `/socket.io/` path, fall back to port-based routing and document in ADR-005. See Epic 10 in the plan.

---

## 4. Security Group Matrix

All private instance SGs use **SG-to-SG references**, never open CIDRs. This is Add-on #1 (Proper Security Group Configs).

| Security Group | Inbound Rule | Source | Port |
|---|---|---|---|
| **alb-sg** | HTTP from internet | `0.0.0.0/0` | 80 |
| **bastion-sg** | SSH from operator | `<your-public-ip>/32` | 22 |
| **frontend-sg** | HTTP from ALB | `alb-sg` | 80, 81 |
| **frontend-sg** | SSH from bastion | `bastion-sg` | 22 |
| **backend-sg** | Redis from frontend | `frontend-sg` | 6379 |
| **backend-sg** | SSH from bastion | `bastion-sg` | 22 |
| **db-sg** | Postgres from backend | `backend-sg` | 5432 |
| **db-sg** | Postgres from frontend | `frontend-sg` | 5432 |
| **db-sg** | SSH from bastion | `bastion-sg` | 22 |

All outbound: unrestricted (instances need outbound to pull Docker images via NAT).

---

## 5. Infrastructure Components

| Component | Type | Size | Subnet | Purpose |
|---|---|---|---|---|
| Bastion | EC2 | t3.nano | Public | SSH entry point; Ansible runs from here |
| Frontend | EC2 | t3.micro | Private App | Hosts `vote` + `result` containers |
| Backend | EC2 | t3.micro | Private App | Hosts `redis` + `worker` containers |
| DB | EC2 | t3.micro | Private DB | Hosts `postgres` with named volume |
| ALB | Load Balancer | — | 2× Public | Path-based routing to frontend |
| NAT Gateway | Managed | — | Public AZ-1a | Outbound internet for private subnets |
| S3 Bucket | Object Storage | — | — | Terraform remote state |
| DynamoDB | NoSQL Table | On-demand | — | Terraform state locking |
| CloudWatch | Managed | — | — | Logs, metrics, alarms |

---

## 6. Deployment Flow

```mermaid
sequenceDiagram
    participant Dev as Developer (local)
    participant GH as GitHub
    participant TF as Terraform
    participant AWS as AWS
    participant AN as Ansible
    participant DH as DockerHub

    Dev->>GH: git push
    GH-->>Dev: CI: terraform validate + ansible-lint

    Dev->>TF: terraform apply (infra/bootstrap/)
    TF->>AWS: Create S3 bucket + DynamoDB table

    Dev->>TF: terraform apply (infra/terraform/)
    TF->>AWS: VPC, subnets, SGs, EC2s, ALB, IAM

    Dev->>AN: ansible-playbook site.yml
    AN->>AWS: SSH via bastion ProxyJump
    AN->>AWS: Install Docker on all instances
    AN->>DH: Pull vote, result, worker images
    AN->>AWS: Run containers with env vars
    AN->>AWS: Install + configure CloudWatch Agent
```

---

## 7. Observability

| Signal | Source | Destination | Alert Condition |
|---|---|---|---|
| Container logs | Docker via CW Agent | CloudWatch Logs | — |
| System logs | `/var/log/syslog` | CloudWatch Logs | — |
| CPU metric | CW Agent | CloudWatch Metrics | > 80% for 5 min → SNS |
| Disk metric | CW Agent | CloudWatch Metrics | > 80% used → SNS |
| ALB unhealthy hosts | ALB | CloudWatch Metrics | > 0 unhealthy → SNS |
| SNS | CloudWatch Alarm | Email | Configured at deploy |

---

## 8. Key Design Decisions

| Decision | Choice | Alternative Considered | ADR |
|---|---|---|---|
| Single vs HA NAT Gateway | Single (cost) | HA NAT (~€2.40/day extra) | ADR-004 |
| Bastion vs SSM | Dedicated bastion | AWS SSM Session Manager (no bastion) | ADR-003 |
| ALB routing strategy | Path-based | Port-based (2 listeners) | ADR-005 |
| .NET version | .NET 8 (LTS) | .NET 7 (EOL May 2024) | ADR-002 |
| EC2 placement | All in AZ-1a | Multi-AZ (higher cost) | ADR-001 |
| Terraform state | S3 + DynamoDB | Terraform Cloud | ADR-003 |

> ADRs live in `docs/decisions/`. Each documents the context, options considered, decision, and consequences.

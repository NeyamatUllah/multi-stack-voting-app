# ADR-001: End-State Topology from Day One

**Status:** Accepted  
**Date:** 2026-04-24

---

## Context

The project requires deploying five services (vote, redis, worker, postgres, result) on AWS with a Load Balancer add-on as the headline deliverable. There are two broad approaches to sequencing the infrastructure:

**Option A — Incremental:** Start with the minimum viable topology (single public EC2, no bastion, no ALB-ready subnets), then retrofit private subnets, a bastion, and ALB-ready networking later.

**Option B — End-state from day one:** Design and provision the final topology on the first `terraform apply`, even if some components (ALB, monitoring) are wired in later epics.

The risk with Option A is that retrofitting private subnets requires destroying and recreating EC2 instances, re-running Ansible, and updating security group references — compounding work that doesn't need to exist.

---

## Decision

**Build the end-state topology on the first `terraform apply` (Option B).**

The network layout on day one:
- 1 VPC (`10.0.0.0/16`)
- 2 public subnets across 2 AZs (for ALB + bastion)
- 2 private app subnets across 2 AZs (for frontend + backend EC2)
- 2 private DB subnets across 2 AZs (for postgres EC2)
- 1 Internet Gateway
- 1 NAT Gateway (single, in AZ-1a — see ADR-004)
- Dedicated bastion EC2 in a public subnet (see ADR-003)
- Security groups using SG-to-SG references throughout

EC2 instances provisioned from day one even if containers aren't deployed yet:
- Bastion (t3.nano, public subnet)
- Frontend (t3.micro, private app subnet)
- Backend (t3.micro, private app subnet)
- DB (t3.micro, private DB subnet)

---

## Consequences

**Positive:**
- No retrofitting: adding the ALB (Epic 10) only requires adding the `alb` Terraform module and pointing it at already-existing subnets and EC2s
- Ansible inventory is stable from day one — private IPs don't change between Epics
- Security groups are correct from the start; no "open everything while debugging" shortcuts needed
- `terraform destroy` + `terraform apply` always produces the same known topology

**Negative:**
- Slightly more Terraform to write on day 2 than a minimal viable approach
- NAT Gateway cost starts from day 2 even before containers are running (~€1.20/day)

**Neutral:**
- Multi-AZ subnets are provisioned even though EC2 instances currently run in AZ-1a only — this is the prerequisite for the ALB which requires 2 AZs

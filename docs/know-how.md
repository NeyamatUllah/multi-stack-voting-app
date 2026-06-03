# Know-How

Concepts and questions that came up during the DevSecNetOps learning journey.
Each entry is a real question asked during implementation, answered in context.

---

## Table of Contents

- [Is Phase 4 (SAST & Dependency Scanning) also part of CI/CD?](#is-phase-4-sast--dependency-scanning-also-part-of-cicd)
- [What is SAST?](#what-is-sast)
- [What is a Kubernetes cluster?](#what-is-a-kubernetes-cluster)
- [Is Ingress a tool for Kubernetes?](#is-ingress-a-tool-for-kubernetes)

---

## Is Phase 4 (SAST & Dependency Scanning) also part of CI/CD?

Partially. Here is the breakdown:

| Tool | Lives in CI/CD? | Why |
|------|----------------|-----|
| **Dependabot** | No | A GitHub platform feature, not a workflow. Runs on GitHub's schedule independently of the pipeline. |
| **CodeQL** | Yes — its own workflow | `.github/workflows/codeql.yml` is a GitHub Actions workflow, but runs on its own trigger (push + PR + cron), separate from `ci.yml`. |
| **Semgrep** | Yes — its own workflow | Same — a separate Actions workflow triggered on PRs or pushes. |
| **Gitleaks** | Yes — added to `ci.yml` | Extends the existing Phase 3 pipeline as a new job alongside lint and build. |

**The distinction:**

- Phase 3 CI/CD = **build, lint, scan images, push to registry** — the delivery pipeline.
- Phase 4 = **security analysis of code and dependencies** — the security gate layer.

They are both GitHub Actions, but serve different purposes. The convention is to keep them in separate workflow files so they can be triggered, maintained, and reviewed independently. CodeQL for example is often triggered on a weekly schedule in addition to push — that does not belong in the delivery pipeline.

In practice, all of them together form the **DevSecOps pipeline** — Phase 3 is the CD skeleton, Phase 4 hangs security checks onto it.

---

## What is SAST?

**SAST (Static Application Security Testing)** — analyse source code *without running it* to find security vulnerabilities.

### How it works

Source code is parsed into an AST (Abstract Syntax Tree) — a structured representation of the code's logic. The tool then searches for patterns or data flows that indicate a vulnerability.

Example — SQL injection in Python:
```python
# SAST flags this — user_input flows directly into a raw SQL string
query = "SELECT * FROM users WHERE id = " + user_input
cursor.execute(query)

# SAST is happy with this — parameterised query
cursor.execute("SELECT * FROM users WHERE id = %s", (user_input,))
```

### SAST vs other scanning types

| Type | What it scans | Needs running? | Tools used in this project |
|------|--------------|----------------|----------------------------|
| **SAST** | Your source code | No | CodeQL, Semgrep |
| **DAST** | Running app (HTTP traffic) | Yes | OWASP ZAP, Burp (not in this project) |
| **SCA** | Dependencies / packages | No | Dependabot |
| **Image scan** | Container layers | No | Trivy (Phase 3) |

### Two approaches — CodeQL vs Semgrep

**CodeQL (semantic / data-flow analysis)**
- Compiles code into a queryable database
- Traces data from *source* (user input) to *sink* (dangerous function)
- Catches multi-step, cross-function vulnerabilities
- Slower but deeper — finds things pattern matching cannot

**Semgrep (pattern / AST matching)**
- Matches code patterns against a rule library
- Fast — no compilation step
- Rules are readable YAML, easy to write custom ones
- Best for catching known bad patterns (OWASP Top-10, framework misuse)

They are **complementary** — Semgrep is the fast early gate on every PR, CodeQL is the thorough deep scan.

### What SAST finds in this project specifically

| Service | Likely findings |
|---------|----------------|
| **vote** (Python/Flask) | Debug mode on, open redirect, unsanitised input |
| **result** (Node.js) | Prototype pollution, path traversal, weak crypto |
| **worker** (.NET/C#) | SQL injection (raw string queries), insecure deserialisation |

### What SAST does NOT cover

- Vulnerabilities that only appear at runtime (business logic flaws)
- Outdated dependencies with CVEs — that is SCA (Dependabot)
- Misconfigurations in running infrastructure — that is DAST / CSPM

---

## What is a Kubernetes cluster?

A cluster is a group of machines that Kubernetes treats as a single computing platform. You deploy your app to the cluster — Kubernetes decides where and how to run it.

### The two types of nodes

```
┌─────────────────────────────────────────────────┐
│                  K8s CLUSTER                    │
│                                                 │
│  ┌──────────────┐    ┌────────┐  ┌────────┐    │
│  │ Control Plane│    │ Node 1 │  │ Node 2 │    │
│  │  (the brain) │    │(worker)│  │(worker)│    │
│  └──────────────┘    └────────┘  └────────┘    │
└─────────────────────────────────────────────────┘
```

**Control Plane — the brain.** Makes all decisions. Your app never runs here.

| Component | What it does |
|-----------|-------------|
| **API Server** | The front door — every `kubectl` command talks to this |
| **Scheduler** | Decides which node a new pod should run on |
| **Controller Manager** | Watches the cluster and fixes drift (e.g. a pod died → start a new one) |
| **etcd** | The database — stores the entire cluster state as key-value pairs |

**Worker Nodes — where your app actually runs.** Each node is a machine (VM or physical).

| Component | What it does |
|-----------|-------------|
| **kubelet** | The agent on each node — takes orders from the control plane, starts/stops containers |
| **kube-proxy** | Handles networking rules so pods can talk to each other |
| **Container runtime** | Actually runs containers (containerd under the hood) |

### How a deployment flows through the cluster

When you run `kubectl apply -f vote/deployment.yaml`:

```
You
 │
 ▼
kubectl → API Server       "I want 1 replica of vote"
               │
               ▼
            etcd           stores desired state
               │
               ▼
          Scheduler        "Node 1 has capacity — put it there"
               │
               ▼
         kubelet (Node 1)  pulls the image, starts the container
               │
               ▼
           Pod running ✅
```

If the pod crashes, the **Controller Manager** notices actual state (0 replicas) ≠ desired state (1 replica) and instructs the Scheduler to place a new one. This is **self-healing**.

### In this project (Minikube)

Minikube runs everything on your laptop in a single VM:

```
Your Laptop
└── Minikube VM
    ├── Control Plane (api-server, scheduler, etcd, controller-manager)
    └── Worker Node
        ├── vote pod
        ├── result pod
        ├── worker pod
        ├── redis pod
        └── db pod
```

In production (Phase 8, Azure/AWS/GCP), the control plane is managed for you (AKS/EKS/GKE) and you get multiple worker nodes spread across availability zones.

### Key mental model

> Docker Compose says **"run these containers on this machine."**
> Kubernetes says **"I want this app to exist — figure out where to run it."**

You describe the **desired state**. The cluster continuously reconciles reality to match it.

---
## Is Ingress a tool for Kubernetes?

Ingress is a **native Kubernetes resource**, not a third-party tool. But it has two parts that are easy to confuse:

**Ingress (the resource)** — a Kubernetes API object you write in YAML that defines routing rules:

```yaml
- path: /         → route to vote Service
- path: /result   → route to result Service
```

**Ingress Controller** — a pod running inside the cluster that reads those rules and actually enforces them. Without a controller, an Ingress resource does nothing. The most common controller is **ingress-nginx** (nginx running as a K8s pod).

### The flow

```
Browser → ingress-nginx pod (controller) → reads Ingress rules → routes to Service → Pod
```

### Analogy

| Kubernetes | Analogy |
|-----------|---------|
| `Ingress` resource | A routing table (the rules, on paper) |
| Ingress Controller | The router (the hardware that enforces the rules) |

### In this project

- `Ingress` = the `k8s/ingress.yaml` file you write
- `ingress-nginx` = installed in Minikube via `minikube addons enable ingress`; on a real cluster (AKS/EKS) you install it yourself via Helm

### Why not just use a NodePort or LoadBalancer Service?

| Approach | Problem |
|---------|---------|
| NodePort | Exposes a random high port (e.g. 32456) — not clean for HTTP |
| LoadBalancer | Provisions a cloud load balancer per Service — expensive and wasteful for multiple services |
| **Ingress** | One entry point, routes to many services by path/host — the correct production pattern |

---

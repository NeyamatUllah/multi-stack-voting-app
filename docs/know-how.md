# Know-How

Concepts and questions that came up during the DevSecNetOps learning journey.
Each entry is a real question asked during implementation, answered in context.

---

## Table of Contents

- [Is Phase 4 (SAST & Dependency Scanning) also part of CI/CD?](#is-phase-4-sast--dependency-scanning-also-part-of-cicd)
- [What is SAST?](#what-is-sast)
- [What is a Kubernetes cluster?](#what-is-a-kubernetes-cluster)
- [Is Ingress a tool for Kubernetes?](#is-ingress-a-tool-for-kubernetes)
- [Why did NetworkPolicy not block traffic in Minikube?](#why-did-networkpolicy-not-block-traffic-in-minikube)
- [Why did the worker probe fail with "pgrep not found"?](#why-did-the-worker-probe-fail-with-pgrep-not-found)
- [How do system design tiers map to Docker networks and Kubernetes?](#how-do-system-design-tiers-map-to-docker-networks-and-kubernetes)
- [What is the Prometheus pull model and why does it matter?](#what-is-the-prometheus-pull-model-and-why-does-it-matter)
- [What is a ServiceMonitor and how does Prometheus discover targets?](#what-is-a-servicemonitor-and-how-does-prometheus-discover-targets)
- [How do Loki and Prometheus differ in what they collect?](#how-do-loki-and-prometheus-differ-in-what-they-collect)
- [What is a PrometheusRule and how does alerting work in kube-prometheus-stack?](#what-is-a-prometheusrule-and-how-does-alerting-work-in-kube-prometheus-stack)
- [Why do Kubernetes Services need named ports for ServiceMonitors?](#why-do-kubernetes-services-need-named-ports-for-servicemonitors)

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

## Why did NetworkPolicy not block traffic in Minikube?

After applying a NetworkPolicy that should have blocked `vote → db`, the connection still went through. The root cause was the **CNI plugin**.

### What is a CNI plugin?

CNI (Container Network Interface) is the component responsible for pod networking in Kubernetes. Different CNI plugins have different capabilities:

| CNI | NetworkPolicy enforcement |
|-----|--------------------------|
| bridge (Minikube default) | ❌ No — policies are accepted but silently ignored |
| Flannel | ❌ No |
| **Calico** | ✅ Yes |
| **Cilium** | ✅ Yes |

Kubernetes accepts and stores NetworkPolicy objects regardless of CNI — it never warns you that they won't be enforced. You only discover the problem when you test.

### Fix

Restart Minikube with Calico as the CNI:

```bash
minikube delete
minikube start --driver=docker --cni=calico
```

### Rule of thumb

Always use `--cni=calico` (or Cilium) in Minikube whenever you need NetworkPolicy enforcement. The default bridge CNI is fine for learning basic K8s but cannot enforce network isolation.

---

## Why did the worker probe fail with "pgrep not found"?

The worker `readinessProbe` and `livenessProbe` were configured to run `pgrep -f worker` to check if the .NET process was alive. The pod entered a crash loop with:

```
exec: "pgrep": executable file not found in $PATH
```

### Root cause

The worker runs on `mcr.microsoft.com/dotnet/runtime:8.0` — a minimal Debian image stripped of non-essential tools. `pgrep` is part of the `procps` package, which is not installed.

### Fix

Use `kill -0 1` instead — it sends signal 0 to PID 1, which checks whether the process exists without actually killing it. Signal 0 is available on every Linux system with no extra tools required:

```yaml
readinessProbe:
  exec:
    command: ["/bin/sh", "-c", "kill -0 1"]
```

### When to use which probe command

| Container type | Recommended probe |
|---------------|------------------|
| Flask / Express (HTTP server) | `httpGet` on the app port |
| Redis, PostgreSQL (TCP server) | `tcpSocket` on the service port |
| PostgreSQL (more precise) | `exec: pg_isready -U postgres` |
| Minimal runtime (no shell tools) | `exec: /bin/sh -c "kill -0 1"` |

---

## How do system design tiers map to Docker networks and Kubernetes?

The tier boundary concept is identical across all three layers. Only the enforcement mechanism changes.

```
System Design Tier  →  Docker Network  →  Kubernetes Equivalent
─────────────────────────────────────────────────────────────────
Presentation Tier   →  frontend        →  Ingress + ingress-nginx (controlled external entry)
Application Tier    →  backend         →  NetworkPolicy (vote-egress-policy)
Data Tier           →  data            →  NetworkPolicy (db-ingress-policy)
```

### How each layer enforces isolation

**System Design** — a logical boundary on paper. "The web tier should not talk directly to the database." Not enforced by any technology yet.

**Docker Compose** — enforced by named networks. A container can only reach another if they share a network. `vote` has no path to `db` because they share no common network.

```yaml
vote:  networks: [frontend, backend]   # no data network → cannot reach db
db:    networks: [data]                # isolated to data tier only
```

**Kubernetes** — enforced by NetworkPolicy (requires Calico or Cilium CNI). Instead of network membership, rules are written based on pod labels:

```yaml
# db only accepts ingress from worker and result — vote implicitly denied
podSelector: app=db
ingress from: app=worker OR app=result
```

### The key difference in default behaviour

| Model | Default | You write rules to... |
|-------|---------|----------------------|
| Docker networks | Isolated unless joined | Allow traffic (by joining a network) |
| K8s NetworkPolicy | Open — all pods talk freely | Restrict traffic (by writing policies) |

Docker is **opt-in** (join a network to gain access). Kubernetes is **opt-out** (all open by default; policies add restrictions).

### This project — the full translation

| Phase 2 Docker Network | Members | K8s equivalent |
|------------------------|---------|----------------|
| `frontend` (not internal) | vote, result | Ingress resource + ingress-nginx |
| `backend` (internal) | vote, result, worker, redis | `vote-egress-policy` (vote → redis only) |
| `data` (internal) | result, worker, db | `db-ingress-policy` (db ← worker + result only) |

### Complete mental model

```
Concept           Docker Compose          Kubernetes
────────────────────────────────────────────────────
Tier boundary     Named network           NetworkPolicy
External access   ports: exposed          Ingress + Service
Internal DNS      service name            Service (ClusterIP)
No direct access  not in same network     not in policy allowlist
```

The tier boundaries never change across the stack — only the tool that enforces them does.

---

## What is the Prometheus pull model and why does it matter?

Most monitoring systems **push** metrics — the application sends data to a central collector. Prometheus inverts this: it **pulls** (scrapes) metrics by making HTTP GET requests to a `/metrics` endpoint on each target, on a schedule it controls.

```
Application pod          Prometheus server
─────────────            ─────────────────
GET /metrics  ←──────── scrape every 15 s
200 OK + text ────────→ stores in TSDB
```

**Why pull is better for Kubernetes:**

| Concern | Push | Pull |
|---------|------|------|
| Target discovery | App must know the collector address | Prometheus discovers targets from the cluster API |
| Dead-target detection | Silent — stopped app stops sending | Prometheus marks target DOWN immediately |
| Configuration ownership | Distributed — every app must be configured | Centralised — one Prometheus config rules all |
| Back-pressure | Collector can be overwhelmed | Prometheus controls the scrape rate |

**The exposition format** — what `/metrics` returns — is plain text:

```
# HELP flask_http_request_total Total HTTP requests
# TYPE flask_http_request_total counter
flask_http_request_total{method="GET",status="200"} 42
```

`prometheus-flask-exporter` generates this automatically for every Flask route. `prom-client` does the same for Node.js.

---

## What is a ServiceMonitor and how does Prometheus discover targets?

A `ServiceMonitor` is a Kubernetes CRD (Custom Resource Definition) introduced by the Prometheus Operator. It is a declarative way to tell Prometheus: "scrape these Services, on this port, at this path."

Without ServiceMonitors, you would edit Prometheus's `prometheus.yml` by hand every time a new service appeared. With the Operator pattern, you instead create a ServiceMonitor and Prometheus reconfigures itself automatically.

**How it works:**

```
ServiceMonitor (CRD)
  └─ selector: matchLabels: app=vote        ← find Services with this label
  └─ namespaceSelector: [default]           ← in this namespace
  └─ endpoints: port=http, path=/metrics    ← scrape this port/path

Prometheus Operator watches ServiceMonitors
  └─ translates them into scrape_configs
  └─ hot-reloads Prometheus — no restart needed
```

**Named port requirement:** the ServiceMonitor references ports by *name*, not number. A Service port entry must have `name: http` (or any name); a bare `port: 80` with no name cannot be referenced.

```yaml
# Service — named port
ports:
  - name: http       ← ServiceMonitor references this
    port: 80

# ServiceMonitor
endpoints:
  - port: http       ← must match the name above
    path: /metrics
```

**`serviceMonitorSelectorNilUsesHelmValues: false`** — by default kube-prometheus-stack only picks up ServiceMonitors in the same Helm release. Setting this to `false` opens it to ServiceMonitors in any namespace, which is necessary when the voting-app ServiceMonitors live in `monitoring` but the Services live in `default`.

---

## How do Loki and Prometheus differ in what they collect?

They solve different observability problems and are deliberately kept separate:

| | Prometheus | Loki |
|--|-----------|------|
| **What** | Numeric metrics (counters, gauges, histograms) | Raw log lines |
| **How collected** | Pull — scrapes `/metrics` endpoints | Push — Promtail tails pod log files and ships to Loki |
| **Storage** | Time-series database (TSDB) — optimised for numbers | Object storage — indexes only labels, not full text |
| **Query language** | PromQL — arithmetic, aggregation, rates | LogQL — label filtering + regex on log content |
| **Grafana panel** | Graph, stat, bar gauge | Logs panel, Explore |
| **Answers** | "How many requests/sec?" "Is error rate rising?" | "What did the pod actually print when it crashed?" |

**Promtail** is the log collector DaemonSet that bridges the gap: it runs on every node, tails `/var/log/pods/`, attaches Kubernetes labels (`namespace`, `pod`, `container`), and forwards structured log streams to Loki.

**In this project:**
- Prometheus answers questions like "is the worker down?" or "is the Redis queue backed up?"
- Loki answers "what was in the worker's stdout before it crashed?" or "what did the vote service log when the error rate spiked?"

---

## What is a PrometheusRule and how does alerting work in kube-prometheus-stack?

A `PrometheusRule` is another Prometheus Operator CRD. It defines alerting rules using PromQL expressions. When an expression evaluates to true for longer than the `for` duration, Prometheus fires an alert to Alertmanager.

**Alert lifecycle:**

```
PrometheusRule (CRD)
  └─ PromQL expression evaluated every eval_interval (default 1m)
      └─ condition true for >= `for` duration → FIRING
          └─ Prometheus sends alert to Alertmanager
              └─ Alertmanager groups, deduplicates, routes → receiver
```

**The four alerts in this project:**

| Alert | Expression | Severity |
|-------|-----------|----------|
| `WorkerDown` | `kube_deployment_status_replicas_available{deployment="worker"} == 0` | critical |
| `VoteHighErrorRate` | 5xx rate / total rate > 5% | warning |
| `RedisQueueBacklog` | `redis_list_length{key="votes"} > 100` | warning |
| `DBConnectionsHigh` | `pg_stat_activity_count > 80` | warning |

**Alertmanager** receives fired alerts and routes them to receivers (Slack, PagerDuty, email, etc.). For local Minikube use, the receiver is set to `log-only` (no external destination) — the alert still appears in the Alertmanager UI at `localhost:9093`.

**Label propagation:** the `release: kube-prometheus-stack` label on both ServiceMonitors and PrometheusRules is how the Operator associates them with the correct Prometheus instance. Without it, the Operator ignores the resource.

---

## Why do Kubernetes Services need named ports for ServiceMonitors?

Kubernetes port entries support an optional `name` field. ServiceMonitors reference ports by name — not number — because a Service may expose the same number on multiple protocols, or the port number may change between environments while the semantic name stays stable.

**Without a name (ServiceMonitor cannot reference it):**
```yaml
ports:
  - port: 80        # valid Service, but ServiceMonitor cannot reference this
    targetPort: 80
```

**With a name (ServiceMonitor works):**
```yaml
ports:
  - name: http      # ServiceMonitor uses this string
    port: 80
    targetPort: 80
```

**In the voting-app:** the vote and result Services originally had unnamed ports. The ServiceMonitors reference `port: http`, so the Helm templates were updated to add `name: http` to both Services. `helm lint` validated no regressions, and the change is backward-compatible — named ports are still addressable by number everywhere else.

---

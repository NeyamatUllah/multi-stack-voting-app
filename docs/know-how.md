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
- [What is Kyverno and how does it differ from OPA/Gatekeeper?](#what-is-kyverno-and-how-does-it-differ-from-opagatekeeper)
- [Why does runAsNonRoot: true fail when the image uses a named USER?](#why-does-runasnonroot-true-fail-when-the-image-uses-a-named-user)
- [Why is redis incompatible with allowPrivilegeEscalation: false?](#why-is-redis-incompatible-with-allowprivilegeescalation-false)
- [What is the difference between Sealed Secrets and Vault?](#what-is-the-difference-between-sealed-secrets-and-vault)
- [How does Vault agent injection work in Kubernetes?](#how-does-vault-agent-injection-work-in-kubernetes)
- [What is Cosign keyless signing and how does it work?](#what-is-cosign-keyless-signing-and-how-does-it-work)
- [Why does Falco show container_name=NA on Minikube with the Docker driver?](#why-does-falco-show-container_namena-on-minikube-with-the-docker-driver)

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

## What is Kyverno and how does it differ from OPA/Gatekeeper?

Both are Kubernetes admission controllers that enforce policies at the API server webhook level — they intercept every `kubectl apply` and can block or mutate resources before they are accepted.

| | Kyverno | OPA/Gatekeeper |
|--|---------|----------------|
| Policy language | YAML (ClusterPolicy CRD — native K8s style) | Rego (a purpose-built logic language) |
| Learning curve | Low — familiar YAML patterns | High — Rego requires learning a new language |
| Background scanning | Yes — scans existing resources on schedule | Partial |
| Image verification | Built-in `verifyImages` with Cosign support | Needs external tooling |
| Mutation | Yes — can add/patch fields at admission | Yes |

**Kyverno ClusterPolicy anatomy:**

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
spec:
  validationFailureAction: Enforce   # or Audit (log only)
  background: true                   # also scan existing resources
  rules:
    - name: check-privileged
      match:
        any:
          - resources:
              kinds: [Pod]
      exclude:
        any:
          - resources:
              namespaces: [kube-system, vault]   # don't apply to system namespaces
      validate:
        message: "Privileged containers are not allowed."
        pattern:
          spec:
            containers:
              - =(securityContext):
                  =(privileged): "false"
```

**`=(field):`** — the `=()` wrapper means "if this field exists, it must match the pattern." Without it, Kyverno would reject pods that don't set `securityContext` at all.

**Audit vs Enforce:** start in Audit mode to identify violations without breaking anything, then flip to Enforce once your own workloads are clean. Use `kubectl get policyreport -A` to see findings.

**In this project:** three policies in Enforce mode (`no-privileged`, `require-non-root`, `require-limits`) and one in Audit (`require-signed-images` — pending live cluster verification).

---

## Why does runAsNonRoot: true fail when the image uses a named USER?

Kubernetes evaluates `runAsNonRoot: true` at admission — before pulling the image. It checks whether the effective UID is non-zero. The problem: Kubernetes can only verify a **numeric** UID at this point; it cannot resolve a named user like `appuser` or `node` to a UID without reading the image's `/etc/passwd` — which requires pulling the image.

```
Error: container has runAsNonRoot and image has non-numeric user (appuser),
       cannot verify user is non-root
```

**Fix:** always specify `runAsUser: <UID>` alongside `runAsNonRoot: true`. Find the UID the Dockerfile sets:

```bash
docker run --rm --entrypoint id ghcr.io/neyamatullah/vote:latest
# uid=100(appuser) gid=65533(nogroup) ...
```

Then in the pod spec:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 100          # numeric UID Kubernetes can verify at admission
  allowPrivilegeEscalation: false
```

**In this project:**

| Service | Named user | Numeric UID |
|---------|-----------|-------------|
| vote | appuser | 100 |
| worker | appuser | 100 |
| result | node | 1000 |

---

## Why is redis incompatible with allowPrivilegeEscalation: false?

The `redis:7-alpine` official image has a specific startup pattern:

1. The container starts as **root** (image `USER` is empty / root)
2. The entrypoint script calls `gosu redis <cmd>` to drop to the `redis` user before starting the server

`gosu` works by calling `execve()` with the `setuid` syscall — it literally becomes the target user. `allowPrivilegeEscalation: false` is implemented via the `no_new_privs` Linux flag, which blocks `setuid` execution. With the flag set, `gosu` cannot change the UID and the container fails to start.

**Why not just add `runAsUser: 999` (the redis UID)?**
The official image expects to start as root so it can set file permissions on `/data` before dropping privileges. Forcing a non-root start breaks that initialization sequence.

**Resolution in this project:**
- Remove `securityContext` from the redis Deployment template entirely
- Exclude pods with `app: redis` label from the `require-run-as-non-root` Kyverno policy

This is a deliberate exception documented in the policy's `exclude` block. The same pattern applies to the official PostgreSQL image.

---

## What is the difference between Sealed Secrets and Vault?

They solve different parts of the secrets problem and are used together, not as alternatives.

| | Sealed Secrets | HashiCorp Vault |
|--|---------------|-----------------|
| **Problem solved** | How to store K8s Secrets safely in git | How pods access secrets at runtime without K8s Secrets at all |
| **Mechanism** | Encrypts a K8s Secret manifest with the cluster's RSA public key so the YAML is safe to commit | Runs a secrets API server; pods authenticate with their K8s service account and retrieve secrets over HTTP |
| **At rest** | Encrypted YAML in git; cluster controller decrypts on apply | Secrets stored in Vault's encrypted backend; never in etcd or git |
| **At runtime** | Becomes a normal K8s Secret in the cluster | `vault-agent` sidecar retrieves and writes secrets to a shared volume; app reads from file |
| **Audit trail** | None — K8s audit logs show Secret reads but not who | Full audit log: every secret read is logged with pod identity, timestamp, path |
| **Rotation** | Re-seal with `kubeseal` and apply the new YAML | Update the value in Vault; vault-agent refreshes the file on TTL expiry |
| **Fits when** | You need secrets committed to git safely (GitOps) | You need runtime identity-based access and auditability |

**In this project:** both are used together:
- `k8s/sealed-secret.yaml` (Sealed Secrets) keeps the encrypted credentials in git and bootstraps the cluster
- Vault injects live DB credentials into the worker pod at runtime, bypassing the K8s Secret entirely when `vault.enabled=true`

---

## How does Vault agent injection work in Kubernetes?

Vault agent injection is a **mutating admission webhook** pattern. The Vault injector intercepts pod creation and adds a sidecar container automatically based on pod annotations.

**Flow:**

```
kubectl apply (worker Deployment)
    │
    ▼
Kyverno webhook (policy check)
    │
    ▼
vault-agent-injector webhook (mutation)
    └─ reads vault.hashicorp.com/* annotations
    └─ adds vault-agent init container + sidecar to the pod spec
    │
    ▼
Pod starts
    ├─ vault-agent (init): authenticates via K8s service account token
    │     └─ Vault verifies token with K8s API, checks role binding
    │     └─ writes secrets to shared emptyDir at /vault/secrets/
    │
    ├─ vault-agent (sidecar): runs continuously, refreshes secrets on TTL expiry
    │
    └─ worker container: reads /vault/secrets/db (a rendered HCL template)
```

**Key annotation:** `vault.hashicorp.com/agent-inject-template-<name>` defines a Go template that renders the secret into any format the app needs:

```yaml
vault.hashicorp.com/agent-inject-template-db: |
  {{- with secret "secret/data/voting-app/db" -}}
  DB_USERNAME={{ .Data.data.username }}
  DB_PASSWORD={{ .Data.data.password }}
  {{- end }}
```

**Kubernetes auth method:** the worker uses its `ServiceAccount` token (projected into the pod at `/var/run/secrets/kubernetes.io/serviceaccount/token`) to authenticate. Vault verifies the token against the K8s API and checks whether the service account is bound to a Vault role:

```bash
vault write auth/kubernetes/role/worker \
  bound_service_account_names=worker \
  bound_service_account_namespaces=default \
  policies=voting-app-policy \
  ttl=1h
```

**Helm template escaping:** Vault HCL templates use `{{ }}` — the same syntax as Helm. To pass Vault directives through Helm without evaluation, escape them:

```yaml
# In a Helm template — passes raw HCL to Vault annotation
vault.hashicorp.com/agent-inject-template-db: |
  {{ "{{" }}- with secret "{{ .Values.vault.secretPath }}" -{{ "}}" }}
  DB_USERNAME={{ "{{" }} .Data.data.username {{ "}}" }}
  {{ "{{" }}- end {{ "}}" }}
```

---

## What is Cosign keyless signing and how does it work?

Cosign is a tool for signing and verifying OCI container images. Keyless signing removes the need to manage a long-lived private key — instead, it uses a short-lived certificate issued by Sigstore's certificate authority, bound to a workload identity (in CI, the GitHub Actions OIDC token).

**Signing flow (in GitHub Actions):**

```
CI workflow runs on staging push
    │
    ├─ push image to GHCR as ghcr.io/neyamatullah/vote:<sha>
    │
    └─ cosign sign --yes ghcr.io/neyamatullah/vote:<sha>
          │
          ├─ GitHub requests OIDC token for this workflow run
          │     └─ token contains: repository, workflow URL, actor
          │
          ├─ Cosign exchanges token for a short-lived certificate from Fulcio (Sigstore CA)
          │
          ├─ Signs the image digest with the ephemeral key
          │
          └─ Records signature + certificate in Rekor (public transparency log)
                └─ Stores signature as OCI artifact alongside the image in GHCR
```

**Verification flow (Kyverno `require-signed-images` policy):**

```yaml
verifyImages:
  - imageReferences:
      - "ghcr.io/neyamatullah/*"
    attestors:
      - entries:
          - keyless:
              subject: "https://github.com/NeyamatUllah/*"
              issuer: "https://token.actions.githubusercontent.com"
```

At `kubectl apply`, Kyverno fetches the signature from GHCR, looks it up in Rekor, and verifies the certificate was issued for the expected GitHub workflow subject. No private key anywhere in the system.

**`COSIGN_EXPERIMENTAL=true`** — enables keyless mode (no `--key` flag needed). The resulting signature is stored as a separate OCI tag alongside the image (e.g. `sha256-abc123.sig`).

**Why keep `require-signed-images` in Audit mode initially?** Kyverno must be able to reach Sigstore's TUF (The Update Framework) roots to verify signatures. On a fresh cluster or in a network-restricted environment this may fail, which would block all pod admissions. Verify the full chain works before switching to Enforce.

---

## Why does Falco show container_name=NA on Minikube with the Docker driver?

This is a fundamental architectural limitation of how Minikube's Docker driver works.

**Normal Falco operation (bare-metal or VM driver):**

```
Host kernel
    └─ eBPF probes capture syscalls
    └─ Falco reads cgroup IDs from /sys/fs/cgroup
    └─ Maps cgroup ID → container ID → pod name via CRI socket
    └─ Output: container.name=vote, k8s.pod.name=vote-abc123
```

**Minikube Docker driver:**

```
Host kernel
    └─ eBPF probes capture syscalls on the host kernel
    │
    └─ Minikube node runs as a Docker container ("minikube")
            └─ containerd runs inside the Minikube container
                    └─ vote pod runs inside containerd
```

Falco's eBPF probes capture at the **host kernel** level. The cgroup IDs it sees belong to the Minikube Docker container, not to individual pod containers. The CRI socket that Falco uses to resolve `container ID → name` is the one inside the Minikube container, which the host-level Falco cannot access. Result: every event shows `container.name=<NA>`.

**What still works:**
- The Falco DaemonSet runs and rules are loaded (`schema validation: ok`)
- All syscalls are captured
- Rules fire — you see the events in logs
- Only the container name enrichment is missing

**Fix:**
- Use `minikube start --driver=kvm2` or `--driver=virtualbox` — Minikube runs in a full VM, K8s pods run directly on the VM's kernel, and Falco can map cgroups correctly
- On bare-metal Kubernetes (kubeadm, k3s) the issue does not exist

---

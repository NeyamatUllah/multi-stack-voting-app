# ADR-002: Upgrade Worker Service to .NET 8

**Status:** Accepted  
**Date:** 2026-04-24

---

## Context

The upstream Docker Samples repository shipped the `worker` service targeting **.NET 7**, which reached end-of-life in **May 2024**. Running an EOL runtime in a project presented in May 2026 creates three problems:

1. **Security:** No security patches are released for EOL runtimes. Any CVE discovered after May 2024 is unpatched.
2. **Image availability:** Microsoft removes EOL SDK and runtime images from MCR over time, breaking `docker pull` for CI pipelines.
3. **Portfolio signal:** Deploying an EOL stack signals carelessness to a technical reviewer.

The available options were:

| Option | Runtime | LTS Until | Risk |
|---|---|---|---|
| Keep as-is | .NET 7 | EOL May 2024 | Security and availability risk |
| Upgrade to .NET 8 | .NET 8 | November 2026 | Minimal — no breaking changes for this app |
| Upgrade to .NET 9 | .NET 9 | May 2026 | Non-LTS; shorter support window |

---

## Decision

**Upgrade the worker to .NET 8 LTS.**

Changes required:
- `Worker.csproj`: `<TargetFramework>net8.0</TargetFramework>`
- `Dockerfile`: base images changed from `mcr.microsoft.com/dotnet/sdk:7.0` and `mcr.microsoft.com/dotnet/runtime:7.0` to their `8.0` equivalents

Both changes were already applied in the cloned source — no further action needed.

.NET 9 was rejected because it is a Standard Term Support (STS) release ending May 2026, which is the same month as project submission, leaving zero buffer for patch updates.

---

## Consequences

**Positive:**
- Runtime supported until November 2026 — well past submission
- Microsoft actively publishes security patches
- `mcr.microsoft.com/dotnet/sdk:8.0` and `runtime:8.0` images are actively maintained and available for `linux/amd64` and `linux/arm64` (required for multi-arch builds)
- No application code changes needed — the worker's C# code is fully compatible with .NET 8

**Negative:**
- None material for this application

**Neutral:**
- The `Npgsql` (7.0.7) and `StackExchange.Redis` (2.6.66) NuGet packages used by the worker are both compatible with .NET 8 without version changes

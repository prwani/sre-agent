# On-Premise VM Management with Azure SRE Agent

Manage on-premise Windows and Linux servers using **Azure Arc** and **Azure SRE Agent**. This sample deploys an SRE Agent that monitors, diagnoses, and remediates issues on Arc-enrolled servers — the same experience you get with cloud-native resources, extended to hybrid infrastructure.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  Azure SRE Agent                                              │
│  Auto-investigates incidents, runs diagnostics via Arc,       │
│  proposes and executes remediation with human approval         │
├──────────────────────────────────────────────────────────────┤
│  Azure Monitor (Alerts) ← Azure Monitor Agent (AMA)           │
│  Heartbeat loss, High CPU, High Memory alerts                 │
│  Data: Perf table, Heartbeat table in Log Analytics           │
├──────────────────────────────────────────────────────────────┤
│  Azure Arc Management Plane                                   │
│  Run Commands, Extension Management, Update Manager           │
└──────────────────────────────────────────────────────────────┘
         │
         ▼
   Arc-enrolled servers (on-prem Windows + Linux)
   ArcBox-Win2K22 | ArcBox-Win2K25 | ArcBox-SQL | ArcBox-Ubuntu-01 | ArcBox-Ubuntu-02
```

## What This Sample Demonstrates

- **Hybrid server monitoring** — SRE Agent receives Azure Monitor alerts from on-prem servers via Arc
- **OS-aware diagnostics** — Automatically detects Windows vs Linux and runs appropriate commands
- **SQL Server management** — Special handling for database servers (service health, backup verification)
- **Patch compliance** — Weekly assessment of missing patches via Azure Update Manager
- **Safety hooks** — All remediation actions require human approval before execution
- **Scheduled automation** — Proactive health scans every 6 hours, patch assessment weekly

## Prerequisites

### Required
- Active Azure subscription with **Owner** role
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.60+
- [Azure Developer CLI (azd)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) 1.9+
- [Python](https://python.org) 3.10+
- **ArcBox for IT Pros** deployed — [setup guide](https://jumpstart.azure.com/azure_jumpstart_arcbox/ITPro)

### ArcBox Server Inventory

| Server | OS | Role | Arc Status |
|---|---|---|---|
| ArcBox-Win2K22 | Windows Server 2022 | Application Server | Arc-enrolled |
| ArcBox-Win2K25 | Windows Server 2025 | File Server | Arc-enrolled |
| ArcBox-SQL | Windows Server 2022 + SQL 2022 | Database Server | Arc-enrolled |
| ArcBox-Ubuntu-01 | Ubuntu 22.04 LTS | Web Server | Arc-enrolled |
| ArcBox-Ubuntu-02 | Ubuntu 22.04 LTS | Monitoring Server | Arc-enrolled |

> **Cost:** ArcBox ~$40-60/mo + SRE Agent ~$10/mo. Shut down ArcBox-Client when not demoing.

### Register Providers
```bash
az provider register -n Microsoft.App --wait
az provider register -n Microsoft.HybridCompute --wait
```

## Quick Start

### 1. Check prerequisites
```bash
bash scripts/prereqs.sh
```

### 2. Deploy infrastructure
```bash
cd samples/onprem-vm-management
azd env new sre-onprem
azd env set ARC_RESOURCE_GROUP rg-arcbox-itpro
azd up
```

### 3. Configure SRE Agent
```bash
bash scripts/post-deploy.sh
```

### 4. Verify
Open the SRE Agent portal URL from the deployment output. Ask:
> "What Arc servers are in my environment and what's their health status?"

## Demo Scenarios

### Scenario 1: Server Health Alert (IT Ops)

Simulate high CPU on a Windows server:
```bash
bash scripts/break-cpu.sh ArcBox-Win2K22
```

**What happens:**
1. CPU spikes to ~100% on ArcBox-Win2K22 for 10 minutes
2. Azure Monitor alert fires (CPU >90% from Perf table)
3. SRE Agent receives the incident automatically
4. Agent uses `wintel-health-check` skill → queries KQL metrics
5. Runs `Get-Process | Sort CPU` via Arc Run Command
6. Identifies the top CPU process → proposes remediation
7. `arc-remediation-approval` hook fires → you approve or reject

**Clean up:** CPU stress auto-expires after 10 minutes.

### Scenario 2: Security Agent Failure (Security Ops)

Disable Defender on a Linux server:
```bash
bash scripts/break-defender.sh ArcBox-Ubuntu-01
```

**What happens:**
1. Defender real-time protection disabled on ArcBox-Ubuntu-01
2. Defender for Cloud detects unhealthy MDE agent (~15-30 min)
3. SRE Agent receives the security alert
4. Agent uses `security-agent-troubleshooting` skill
5. Detects OS=Linux → runs `mdatp health` diagnostics via Arc
6. Auto-remediates: `mdatp config real-time-protection --value enabled`
7. Verifies fix → reports success

### Scenario 3: Patch Assessment (Ops Automation)

Trigger a manual patch assessment (or wait for the weekly scheduled task):
```bash
# In the SRE Agent chat:
> Run a patch assessment on all my Arc servers
```

**What happens:**
1. Agent queries Azure Update Manager for missing patches
2. Uses `patch-validation` skill → checks each server's OS type
3. Runs pre-patch readiness checks via Arc Run Commands per OS
4. Generates patch risk report with deployment wave plan
5. Does NOT install patches — report only

## SRE Agent Configuration

This sample configures the following:

| Component | Name | Description |
|---|---|---|
| **Skills** | wintel-health-check | CPU, memory, disk, services (Windows + Linux) |
| | security-agent-troubleshooting | MDE agent diagnostics (Windows + Linux) |
| | patch-validation | Patch assessment + pre/post validation |
| **Subagents** | vm-diagnostics | Server health investigation specialist |
| | security-troubleshooter | MDE agent issue specialist |
| **Hook** | arc-remediation-approval | Approval gate for write operations on Arc servers |
| **Scheduled Tasks** | proactive-health-scan | Every 6h: health check all servers |
| | patch-assessment-scan | Weekly Monday 08:00 UTC: patch compliance |
| **Knowledge Base** | arc-vm-health-check.md | Health check runbook (Windows + Linux + SQL) |
| | defender-troubleshooting.md | MDE troubleshooting runbook |
| | patch-management-runbook.md | Patch management runbook |
| **Alerts** | alert-heartbeat-loss | Arc server unreachable (15 min) → Sev 0 |
| | alert-high-cpu | CPU >90% sustained → Sev 1 |
| | alert-high-memory | Memory >90% sustained → Sev 2 |

## Companion Repository

For advanced automation (PowerShell demo scripts, ITSM integration, Python adapters):
- [ops-automation-using-sre-agent](https://github.com/prwani/ops-automation-using-sre-agent)

## Cleanup

```bash
azd down --purge
```

> **Note:** This only removes the SRE Agent resources. ArcBox must be cleaned up separately.

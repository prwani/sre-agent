# Architecture — On-Premise VM Management

This document describes the architecture of the on-prem VM management sample, including data flows, component responsibilities, RBAC requirements, and network prerequisites.

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              Azure Cloud                                │
│                                                                         │
│  ┌─────────────────┐    ┌──────────────────┐    ┌───────────────────┐  │
│  │  Azure SRE Agent │◄───│  Azure Monitor    │◄───│  Log Analytics    │  │
│  │                  │    │  Alert Rules      │    │  Workspace        │  │
│  │  Skills:         │    │                   │    │                   │  │
│  │  - wintel-health │    │  - Heartbeat loss │    │  Tables:          │  │
│  │  - security-     │    │  - High CPU       │    │  - Perf           │  │
│  │    troubleshoot  │    │  - High Memory    │    │  - Heartbeat      │  │
│  │  - patch-        │    └──────────────────┘    │  - Event           │  │
│  │    validation    │                             │  - Syslog          │  │
│  └────────┬─────────┘                             └─────────▲─────────┘  │
│           │                                                  │            │
│           │  Run Commands                                    │  Metrics   │
│           │  Extension Mgmt                                  │  + Logs    │
│           ▼                                                  │            │
│  ┌─────────────────────────────────────────────────────────┐ │            │
│  │                 Azure Arc Management Plane               │ │            │
│  │                                                          │ │            │
│  │  ┌──────────────┐  ┌───────────────┐  ┌──────────────┐ │ │            │
│  │  │ Run Commands  │  │ Extensions    │  │ Update       │ │ │            │
│  │  │ (PowerShell / │  │ (AMA, MDE,   │  │ Manager      │ │ │            │
│  │  │  Bash)        │  │  Custom)      │  │              │ │ │            │
│  │  └──────────────┘  └───────────────┘  └──────────────┘ │ │            │
│  └──────────────────────────────┬──────────────────────────┘ │            │
│                                 │                             │            │
└─────────────────────────────────┼─────────────────────────────┼────────────┘
                                  │ HTTPS (443)                 │ HTTPS (443)
                                  ▼                             │
┌─────────────────────────────────────────────────────────────────────────┐
│                          On-Premise Network                             │
│                                                                         │
│  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐              │
│  │ ArcBox-Win2K22│  │ ArcBox-Win2K25│  │  ArcBox-SQL   │              │
│  │ Win 2022      │  │ Win 2025      │  │ Win 2022      │              │
│  │ App Server    │  │ File Server   │  │ SQL Server    │              │
│  │               │  │               │  │ 2022          │              │
│  │ Agents:       │  │ Agents:       │  │               │              │
│  │ - himds       │  │ - himds       │  │ Agents:       │              │
│  │ - AMA         │  │ - AMA         │  │ - himds       │              │
│  │ - MDE         │  │ - MDE         │  │ - AMA         │              │
│  └───────────────┘  └───────────────┘  │ - MDE         │              │
│                                         │ - SQL ext     │              │
│  ┌───────────────┐  ┌───────────────┐  └───────────────┘              │
│  │ArcBox-Ubuntu01│  │ArcBox-Ubuntu02│                                  │
│  │ Ubuntu 22.04  │  │ Ubuntu 22.04  │                                  │
│  │ Web Server    │  │ Monitoring    │                                  │
│  │               │  │               │                                  │
│  │ Agents:       │  │ Agents:       │                                  │
│  │ - himds       │  │ - himds       │                                  │
│  │ - AMA         │  │ - AMA         │                                  │
│  │ - MDE         │  │ - MDE         │                                  │
│  └───────────────┘  └───────────────┘                                  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## Data Flows

### 1. Monitoring Data Flow (On-Prem → Azure → SRE Agent)

This is the primary observability pipeline. Telemetry originates on each server and flows through the Azure Monitor Agent into Log Analytics, where alert rules evaluate the data and route incidents to the SRE Agent.

```
On-prem Server
  └─ Azure Monitor Agent (AMA)
       ├─ Perf counters (CPU, Memory, Disk, Network) → Perf table
       ├─ Heartbeat signal (every 60 s) → Heartbeat table
       ├─ Windows Event Log → Event table
       └─ Linux Syslog → Syslog table
            └─ Log Analytics Workspace
                 └─ Scheduled Query Alert Rules
                      ├─ Heartbeat loss (15 min gap) → Sev 0 incident
                      ├─ CPU > 90% (5 min sustained) → Sev 1 incident
                      └─ Memory > 90% (5 min sustained) → Sev 2 incident
                           └─ Azure SRE Agent (auto-investigates)
```

**Key details:**
- AMA sends performance counters every **60 seconds** by default (configurable via Data Collection Rule).
- Heartbeat is emitted every **60 seconds**; the alert rule checks for a **15-minute gap** to avoid false positives during brief network blips.
- Alert evaluation frequency is **5 minutes** for CPU and Memory, **5 minutes** for Heartbeat.
- End-to-end latency from metric emission to SRE Agent investigation start: **5-10 minutes**.

### 2. Management Flow (SRE Agent → Arc → On-Prem Servers)

When the SRE Agent needs to run diagnostics or execute remediation, it issues commands through the Azure Arc management plane. The Arc agent on each server executes the command locally and returns the output.

```
Azure SRE Agent
  └─ Skill execution (e.g., wintel-health-check)
       └─ Azure Arc Run Command API
            ├─ Windows servers: RunPowerShellScript
            │    └─ PowerShell scripts executed by himds agent
            └─ Linux servers: RunShellScript
                 └─ Bash scripts executed by himds agent
                      └─ Output returned to SRE Agent (stdout + stderr + exit code)
```

**Key details:**
- Run Commands execute **asynchronously** — the API returns a long-running operation that the SRE Agent polls.
- Default timeout per command: **90 seconds** (configurable up to 90 minutes for long-running scripts).
- Commands run as **SYSTEM** (Windows) or **root** (Linux) by default.
- The `arc-remediation-approval` hook intercepts **write operations** (service restart, config change, process termination) before execution.

### 3. Patch Management Flow (SRE Agent → Update Manager → Arc → On-Prem)

Patch assessment and deployment use Azure Update Manager, which coordinates with the Arc agent to scan for missing patches and optionally deploy them.

```
Azure SRE Agent
  └─ patch-validation skill
       └─ Azure Update Manager API
            ├─ Assess patches (read-only scan)
            │    └─ Arc Agent triggers OS-native scanner
            │         ├─ Windows: Windows Update Agent (WUA)
            │         └─ Linux: apt/yum/dnf
            │              └─ Results → Update Manager → SRE Agent report
            └─ Deploy patches (requires approval hook)
                 └─ Maintenance window + reboot policy
                      └─ Arc Agent applies updates
```

**Key details:**
- Patch **assessment** is read-only and safe to run at any time.
- Patch **deployment** is gated by the `arc-remediation-approval` hook — the SRE Agent proposes a deployment plan and waits for human approval.
- The weekly scheduled task (`patch-assessment-scan`) runs assessment only.
- Update Manager supports deployment waves: critical patches first, then important, then optional.

## Component Details

### Azure SRE Agent

The SRE Agent is deployed as an Azure Container App with the following configuration:

| Setting | Value |
|---|---|
| Runtime | Azure Container Apps |
| Region | Same as Log Analytics workspace |
| Identity | System-assigned managed identity |
| Triggers | Azure Monitor alert webhook, scheduled tasks, manual chat |

### Log Analytics Workspace

Reuses the existing Log Analytics workspace from the ArcBox deployment. The following tables are queried by SRE Agent skills:

| Table | Source | Used By |
|---|---|---|
| Perf | AMA performance counters | wintel-health-check (CPU, memory, disk) |
| Heartbeat | AMA heartbeat signal | Alert rule (server reachability) |
| Event | AMA Windows Event Log | wintel-health-check (crash events, service failures) |
| Syslog | AMA Linux syslog | wintel-health-check (OOM kills, service failures) |
| Update | Update Manager scan results | patch-validation |

### Azure Monitor Alert Rules

Three alert rules are deployed via Bicep:

| Alert | KQL Query | Frequency | Severity |
|---|---|---|---|
| Heartbeat Loss | `Heartbeat \| summarize LastHeartbeat=max(TimeGenerated) by Computer \| where LastHeartbeat < ago(15m)` | 5 min | 0 (Critical) |
| High CPU | `Perf \| where ObjectName=="Processor" and CounterName=="% Processor Time" \| summarize AvgCPU=avg(CounterValue) by Computer, bin(TimeGenerated, 5m) \| where AvgCPU > 90` | 5 min | 1 (Error) |
| High Memory | `Perf \| where ObjectName=="Memory" and CounterName=="% Committed Bytes In Use" \| summarize AvgMem=avg(CounterValue) by Computer, bin(TimeGenerated, 5m) \| where AvgMem > 90` | 5 min | 2 (Warning) |

### Azure Arc Components

Each on-prem server runs the following Arc components:

| Component | Purpose |
|---|---|
| **himds** (Hybrid Instance Metadata Service) | Core Arc agent — maintains connection to Azure, executes Run Commands |
| **AMA** (Azure Monitor Agent) | Collects performance counters, logs, and heartbeat telemetry |
| **MDE** (Microsoft Defender for Endpoint) | Endpoint protection — monitored by security-agent-troubleshooting skill |
| **SQL Server extension** (ArcBox-SQL only) | SQL Server discovery, best practices assessment |

## RBAC Requirements

The SRE Agent's managed identity requires the following role assignments:

| Role | Scope | Purpose |
|---|---|---|
| **Monitoring Reader** | Log Analytics workspace | Read performance metrics, heartbeat data, and logs via KQL |
| **Azure Connected Machine Resource Administrator** | Arc server resource group | Execute Run Commands, manage extensions on Arc servers |
| **Reader** | Arc server resource group | List and read Arc server properties (OS type, status, tags) |
| **Log Analytics Reader** | Log Analytics workspace | Query Log Analytics tables for alert investigation |
| **Azure Update Manager Operator** | Arc server resource group | Trigger patch assessments and view update compliance |

> **Principle of least privilege:** The SRE Agent does NOT have Contributor or Owner on the subscription. Write operations are scoped to Arc Run Commands only, and all write actions are gated by the approval hook.

### Role Assignment Commands

These are executed automatically by `scripts/post-deploy.sh`, but can be run manually:

```bash
# Get the SRE Agent managed identity principal ID
AGENT_PRINCIPAL_ID=$(az containerapp show -n sre-agent -g $RG --query identity.principalId -o tsv)
ARC_RG="rg-arcbox-itpro"
WORKSPACE_ID=$(az monitor log-analytics workspace show -g $ARC_RG -n arcbox-law --query id -o tsv)

# Monitoring Reader on workspace
az role assignment create --assignee $AGENT_PRINCIPAL_ID \
  --role "Monitoring Reader" --scope $WORKSPACE_ID

# Connected Machine Resource Administrator on Arc resource group
az role assignment create --assignee $AGENT_PRINCIPAL_ID \
  --role "Azure Connected Machine Resource Administrator" \
  --scope /subscriptions/$SUB_ID/resourceGroups/$ARC_RG

# Reader on Arc resource group
az role assignment create --assignee $AGENT_PRINCIPAL_ID \
  --role "Reader" \
  --scope /subscriptions/$SUB_ID/resourceGroups/$ARC_RG

# Log Analytics Reader on workspace
az role assignment create --assignee $AGENT_PRINCIPAL_ID \
  --role "Log Analytics Reader" --scope $WORKSPACE_ID

# Update Manager Operator (custom role or built-in if available)
az role assignment create --assignee $AGENT_PRINCIPAL_ID \
  --role "Reader" \
  --scope /subscriptions/$SUB_ID/resourceGroups/$ARC_RG
```

## Network Requirements

### Arc Agent Outbound Connectivity

The Arc agent on each on-prem server requires outbound HTTPS (443) to the following endpoints. **No inbound ports** are required.

| Endpoint | Purpose |
|---|---|
| `management.azure.com` | Azure Resource Manager API |
| `login.microsoftonline.com` | Azure AD authentication |
| `gbl.his.arc.azure.com` | Arc global discovery service |
| `*.his.arc.azure.com` | Arc regional metadata service |
| `*.guestconfiguration.azure.com` | Arc guest configuration (policy, extensions) |
| `*.guestnotificationservice.azure.com` | Arc Run Command notifications |
| `*.servicebus.windows.net` | Arc Run Command relay (WebSocket) |
| `*.ods.opinsights.azure.com` | Log Analytics data ingestion (AMA) |
| `*.oms.opinsights.azure.com` | Log Analytics management (AMA) |
| `*.monitoring.azure.com` | Azure Monitor metrics ingestion |

### Firewall / Proxy Configuration

If on-prem servers access the internet through a proxy:

```bash
# Linux: Set proxy for Arc agent
sudo azcmagent config set proxy.url "http://proxy.contoso.com:8080"

# Windows: Set proxy for Arc agent
azcmagent config set proxy.url "http://proxy.contoso.com:8080"
```

> **Private Link:** For environments that prohibit public internet access, Azure Arc supports [Private Link Scope](https://learn.microsoft.com/azure/azure-arc/servers/private-link-security). This routes all Arc traffic through a private endpoint in your VNet.

## Security Considerations

1. **Approval hook** — All write operations on Arc servers require human approval via the `arc-remediation-approval` hook. The SRE Agent cannot restart services, kill processes, or modify configurations autonomously.

2. **Managed identity** — The SRE Agent authenticates using a system-assigned managed identity. No credentials are stored in configuration or code.

3. **Scoped RBAC** — The managed identity has minimal permissions scoped to the Arc resource group and Log Analytics workspace. It cannot access other subscriptions or resource groups.

4. **Run Command auditing** — Every Run Command execution is logged in Azure Activity Log with the caller identity, target server, and script content. These logs are retained for 90 days by default.

5. **Network isolation** — Arc agents initiate all connections outbound. No inbound firewall rules are required on on-prem servers.

# Demo Scenarios — On-Premise VM Management

Step-by-step walkthroughs for demonstrating the SRE Agent's capabilities with Arc-enrolled on-prem servers. Each scenario includes exact commands, expected timelines, verification steps, and troubleshooting tips.

---

## Scenario 1: Server Health Alert (IT Ops)

**Goal:** Show the SRE Agent automatically investigating and remediating a high-CPU incident on a Windows server.

**Duration:** ~15 minutes end-to-end

### Step 1 — Inject the fault

Run the break script to create a CPU stress process on ArcBox-Win2K22:

```bash
bash scripts/break-cpu.sh ArcBox-Win2K22
```

This script uses Azure Arc Run Command to start a PowerShell stress process on the target server:

```powershell
# What the script runs remotely:
$duration = 600  # 10 minutes
$end = (Get-Date).AddSeconds($duration)
while ((Get-Date) -lt $end) {
    [Math]::Sqrt(12345) | Out-Null
}
```

### Step 2 — Wait for the alert to fire

| Event | Expected Time |
|---|---|
| CPU spikes to ~100% | Immediately (within 30 seconds) |
| AMA reports high CPU to Log Analytics | ~1-2 minutes |
| Alert rule evaluates and fires | ~5-7 minutes after spike starts |
| SRE Agent receives incident | ~6-8 minutes after spike starts |

**How to monitor while waiting:**

```bash
# Check if the stress process is running on the target server
az connectedmachine run-command create \
  --resource-group rg-arcbox-itpro \
  --machine-name ArcBox-Win2K22 \
  --run-command-name check-cpu \
  --script "Get-Process | Where-Object {$_.CPU -gt 100} | Select-Object Name, CPU, Id" \
  --no-wait

# Check alert status in Azure Monitor
az monitor metrics alert list -g <sre-agent-rg> -o table
```

### Step 3 — Observe the SRE Agent investigation

Open the SRE Agent portal (URL from `azd` deployment output). You should see:

1. **Incident received** — The agent posts: *"Received Sev 1 alert: High CPU on ArcBox-Win2K22"*
2. **Investigation starts** — The agent activates the `wintel-health-check` skill
3. **KQL query** — Agent runs a query against the Perf table:
   ```
   Perf
   | where Computer == "ArcBox-Win2K22"
   | where ObjectName == "Processor" and CounterName == "% Processor Time"
   | where TimeGenerated > ago(15m)
   | summarize AvgCPU=avg(CounterValue) by bin(TimeGenerated, 1m)
   | order by TimeGenerated desc
   ```
4. **Run Command** — Agent executes `Get-Process | Sort-Object CPU -Descending | Select-Object -First 10` via Arc Run Command
5. **Root cause identified** — Agent reports: *"PowerShell process (PID XXXX) consuming ~100% CPU"*
6. **Remediation proposed** — Agent suggests: *"Terminate process PID XXXX (powershell.exe stress loop)"*

### Step 4 — Approve or reject remediation

The `arc-remediation-approval` hook fires. You will see an approval prompt in the SRE Agent chat:

```
🔒 Remediation requires approval:
   Action: Terminate process PID 1234 on ArcBox-Win2K22
   Command: Stop-Process -Id 1234 -Force
   Risk: Low (non-critical process)

   [Approve] [Reject]
```

- Click **Approve** to let the agent terminate the stress process.
- Click **Reject** to decline — the agent will note the rejection and close the investigation.

### Step 5 — Verify remediation

After approval, the agent executes the remediation and verifies:

1. Agent runs `Stop-Process -Id <PID> -Force` via Arc Run Command
2. Agent waits 60 seconds, then re-checks CPU: `Get-Counter '\Processor(_Total)\% Processor Time'`
3. Agent reports: *"CPU on ArcBox-Win2K22 has returned to normal (~5%). Incident resolved."*

**Manual verification:**

```bash
# Check CPU is back to normal
az connectedmachine run-command create \
  --resource-group rg-arcbox-itpro \
  --machine-name ArcBox-Win2K22 \
  --run-command-name verify-cpu \
  --script "Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 2 -MaxSamples 3"
```

### Clean-Up

The CPU stress process auto-expires after 10 minutes. If you rejected the remediation or need to clean up early:

```bash
bash scripts/fix-cpu.sh ArcBox-Win2K22
```

### Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| Alert doesn't fire after 10 minutes | AMA not installed or DCR misconfigured | Run `az connectedmachine extension list -g rg-arcbox-itpro --machine-name ArcBox-Win2K22 -o table` and verify AzureMonitorWindowsAgent is present and status is Succeeded |
| SRE Agent doesn't receive incident | Action group not configured | Check alert rule action group includes the SRE Agent webhook endpoint |
| Run Command times out | Arc agent connectivity issue | Run `az connectedmachine show -g rg-arcbox-itpro -n ArcBox-Win2K22 --query status` — should be "Connected" |
| Agent says "insufficient permissions" | RBAC misconfigured | Re-run `bash scripts/post-deploy.sh` to fix role assignments |

---

## Scenario 2: Security Agent Failure (Security Ops)

**Goal:** Show the SRE Agent detecting and remediating a disabled Defender for Endpoint (MDE) agent on a Linux server.

**Duration:** ~30-40 minutes (Defender for Cloud detection takes time)

### Step 1 — Inject the fault

Disable Defender real-time protection on ArcBox-Ubuntu-01:

```bash
bash scripts/break-defender.sh ArcBox-Ubuntu-01
```

This script uses Azure Arc Run Command to disable MDE real-time protection:

```bash
# What the script runs remotely:
sudo mdatp config real-time-protection --value disabled
```

### Step 2 — Wait for detection

| Event | Expected Time |
|---|---|
| MDE real-time protection disabled | Immediately |
| MDE health status changes to "unhealthy" | ~2-5 minutes |
| Defender for Cloud detects unhealthy agent | ~15-30 minutes |
| SRE Agent receives security alert | ~20-35 minutes after injection |

> **Tip for demos:** If the 30-minute wait is too long, you can manually trigger the SRE Agent by asking in the chat:
> *"Check the Defender for Endpoint health status on ArcBox-Ubuntu-01"*

**How to monitor while waiting:**

```bash
# Check MDE health directly on the server
az connectedmachine run-command create \
  --resource-group rg-arcbox-itpro \
  --machine-name ArcBox-Ubuntu-01 \
  --run-command-name check-mde \
  --script "mdatp health --field real_time_protection_enabled" \
  --no-wait
```

### Step 3 — Observe the SRE Agent investigation

In the SRE Agent portal:

1. **Alert received** — *"Security alert: MDE agent unhealthy on ArcBox-Ubuntu-01"*
2. **Skill activation** — Agent activates `security-agent-troubleshooting`
3. **OS detection** — Agent queries Arc for the server's OS type → Ubuntu 22.04
4. **Diagnostics** — Agent runs the following via Arc Run Command:
   ```bash
   mdatp health
   mdatp health --field real_time_protection_enabled
   mdatp health --field definitions_updated
   systemctl status mdatp
   ```
5. **Root cause** — *"MDE real-time protection is disabled on ArcBox-Ubuntu-01. Service is running but protection is off."*
6. **Remediation proposed** — *"Enable MDE real-time protection: `mdatp config real-time-protection --value enabled`"*

### Step 4 — Approve remediation

The approval hook fires:

```
🔒 Remediation requires approval:
   Action: Enable MDE real-time protection on ArcBox-Ubuntu-01
   Command: mdatp config real-time-protection --value enabled
   Risk: Low (restoring security baseline)

   [Approve] [Reject]
```

Click **Approve**.

### Step 5 — Verify remediation

After approval:

1. Agent runs `mdatp config real-time-protection --value enabled` via Arc Run Command
2. Agent waits 30 seconds, then verifies:
   ```bash
   mdatp health --field real_time_protection_enabled
   # Expected output: true
   ```
3. Agent reports: *"MDE real-time protection re-enabled on ArcBox-Ubuntu-01. Health status: healthy."*

**Manual verification:**

```bash
az connectedmachine run-command create \
  --resource-group rg-arcbox-itpro \
  --machine-name ArcBox-Ubuntu-01 \
  --run-command-name verify-mde \
  --script "mdatp health --field real_time_protection_enabled && mdatp health --field healthy"
```

### Clean-Up

If you approved the remediation, MDE is already restored. If you rejected it or want to manually fix:

```bash
bash scripts/fix-defender.sh ArcBox-Ubuntu-01
```

### Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| `mdatp` command not found | MDE not installed on the server | Install MDE via Arc extension: `az connectedmachine extension create --machine-name ArcBox-Ubuntu-01 -g rg-arcbox-itpro --name MDE.Linux --publisher Microsoft.Azure.AzureDefenderForServers --type MDE.Linux` |
| Defender for Cloud alert never appears | Defender for Servers plan not enabled | Enable in Azure Portal → Defender for Cloud → Environment settings → Servers plan |
| Agent detects Windows but server is Linux | Arc metadata stale | Run `az connectedmachine show -g rg-arcbox-itpro -n ArcBox-Ubuntu-01 --query osType` to verify |
| Remediation fails with "permission denied" | Arc Run Command not running as root | The default for Linux Run Commands is root; check the Arc agent version is current |

---

## Scenario 3: Patch Assessment (Ops Automation)

**Goal:** Show the SRE Agent running a comprehensive patch assessment across all Arc servers, generating a risk report with deployment wave recommendations.

**Duration:** ~10-15 minutes

### Step 1 — Trigger the assessment

You can trigger the assessment in two ways:

**Option A — Manual trigger via SRE Agent chat:**
```
> Run a patch assessment on all my Arc servers
```

**Option B — Wait for the scheduled task:**
The `patch-assessment-scan` scheduled task runs every Monday at 08:00 UTC automatically.

### Step 2 — Observe the assessment process

In the SRE Agent portal:

1. **Task started** — *"Starting patch assessment for all Arc-enrolled servers"*
2. **Server discovery** — Agent queries Azure Resource Graph:
   ```
   Resources
   | where type == "microsoft.hybridcompute/machines"
   | where resourceGroup == "rg-arcbox-itpro"
   | project name, properties.osType, properties.status
   ```
3. **Per-server assessment** — For each server, the agent:
   - Queries Azure Update Manager for missing patches
   - Runs pre-patch readiness checks via Arc Run Command

   **Windows servers (ArcBox-Win2K22, ArcBox-Win2K25, ArcBox-SQL):**
   ```powershell
   # Check Windows Update service status
   Get-Service wuauserv | Select-Object Status, StartType
   # Check available disk space (patches need space)
   Get-PSDrive C | Select-Object Used, Free
   # Check pending reboot status
   Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
   ```

   **Linux servers (ArcBox-Ubuntu-01, ArcBox-Ubuntu-02):**
   ```bash
   # Check apt update status
   sudo apt update 2>&1 | tail -1
   # Check available disk space
   df -h /
   # Check if reboot is required
   [ -f /var/run/reboot-required ] && echo "REBOOT REQUIRED" || echo "No reboot required"
   ```

4. **SQL Server special handling (ArcBox-SQL):**
   ```powershell
   # Check SQL Server service status before patching
   Get-Service MSSQLSERVER | Select-Object Status
   # Check active connections (patches may require restart)
   Invoke-Sqlcmd -Query "SELECT COUNT(*) as ActiveConnections FROM sys.dm_exec_sessions WHERE is_user_process = 1"
   # Verify recent backup exists
   Invoke-Sqlcmd -Query "SELECT TOP 1 database_name, backup_finish_date FROM msdb.dbo.backupset ORDER BY backup_finish_date DESC"
   ```

### Step 3 — Review the patch report

The agent generates a structured report:

```
📋 Patch Assessment Report — 2024-01-15

Server Summary:
┌──────────────────┬────────┬──────────┬──────────┬─────────────┐
│ Server           │ OS     │ Critical │ Important│ Reboot Req? │
├──────────────────┼────────┼──────────┼──────────┼─────────────┤
│ ArcBox-Win2K22   │ Win    │ 2        │ 5        │ No          │
│ ArcBox-Win2K25   │ Win    │ 1        │ 3        │ No          │
│ ArcBox-SQL       │ Win    │ 2        │ 5        │ No          │
│ ArcBox-Ubuntu-01 │ Linux  │ 0        │ 4        │ No          │
│ ArcBox-Ubuntu-02 │ Linux  │ 0        │ 3        │ No          │
└──────────────────┴────────┴──────────┴──────────┴─────────────┘

Recommended Deployment Waves:
  Wave 1 (Low risk): ArcBox-Ubuntu-01, ArcBox-Ubuntu-02
    - No critical patches, no reboot required
    - Estimated downtime: 0 minutes

  Wave 2 (Medium risk): ArcBox-Win2K22, ArcBox-Win2K25
    - Critical patches present, reboot may be required
    - Estimated downtime: 10-15 minutes per server

  Wave 3 (High risk — database): ArcBox-SQL
    - Critical patches, SQL Server active
    - Requires: backup verification, connection draining, maintenance window
    - Estimated downtime: 20-30 minutes

⚠️  This is an assessment only. No patches have been installed.
    To deploy patches, ask: "Deploy patches for Wave 1 servers"
```

### Step 4 — (Optional) Deploy patches for a specific wave

If you want to demonstrate patch deployment:

```
> Deploy patches for Wave 1 servers (ArcBox-Ubuntu-01 and ArcBox-Ubuntu-02)
```

The approval hook fires for each server. After approval, the agent:
1. Runs pre-patch checks (disk space, reboot status)
2. Triggers Update Manager deployment
3. Monitors deployment progress
4. Runs post-patch verification
5. Reports success or failure

> **⚠️ Warning:** Patch deployment modifies the servers. Only do this in a demo/test environment.

### Clean-Up

Patch assessment is read-only — no clean-up needed.

If you deployed patches, the servers are now updated. No rollback is provided by this sample (use OS-level rollback mechanisms if needed).

### Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| "No Arc servers found" | Wrong resource group configured | Check `ARC_RESOURCE_GROUP` in azd env: `azd env get-value ARC_RESOURCE_GROUP` |
| Assessment returns 0 patches for all servers | Update Manager not configured | Ensure periodic assessment is enabled: `az connectedmachine extension list -g rg-arcbox-itpro --machine-name ArcBox-Win2K22 -o table` |
| SQL Server checks fail | SQL Server service not running | RDP to ArcBox-SQL and start the service: `Start-Service MSSQLSERVER` |
| Assessment takes >20 minutes | Large number of patches or slow network | This is normal for the first scan; subsequent scans use cached results |
| "Insufficient permissions" on Update Manager | Missing role assignment | Ensure the SRE Agent identity has Reader on the Arc resource group (see `docs/architecture.md` RBAC section) |

---

## General Demo Tips

### Before the Demo

1. **Verify all servers are connected:**
   ```bash
   az connectedmachine list -g rg-arcbox-itpro -o table --query "[].{Name:name, Status:status, OS:osType}"
   ```
   All servers should show `Status: Connected`.

2. **Verify AMA is installed and healthy:**
   ```bash
   for server in ArcBox-Win2K22 ArcBox-Win2K25 ArcBox-SQL ArcBox-Ubuntu-01 ArcBox-Ubuntu-02; do
     echo "=== $server ==="
     az connectedmachine extension list -g rg-arcbox-itpro --machine-name $server \
       --query "[?contains(name,'Monitor')].{Name:name, Status:provisioningState}" -o table
   done
   ```

3. **Verify SRE Agent is responsive:**
   Open the portal and ask: *"What Arc servers are in my environment?"*

### During the Demo

- **Narrate what the agent is doing** — The SRE Agent's investigation steps are visible in the chat. Point out each step as it happens.
- **Highlight the approval hook** — Emphasize that the agent cannot make changes without human approval. This is a key safety feature.
- **Show the KQL queries** — When the agent runs KQL queries, expand them to show the audience what data is being analyzed.
- **Compare Windows vs Linux** — Point out that the agent automatically adapts its commands based on the server's OS type.

### Timing Guide

| Scenario | Inject → Alert | Alert → Agent | Agent → Resolution | Total |
|---|---|---|---|---|
| 1: High CPU | ~5-7 min | ~1 min | ~2-3 min | ~10-15 min |
| 2: MDE Failure | ~15-30 min | ~1 min | ~2-3 min | ~20-35 min |
| 3: Patch Assessment | N/A (manual) | Immediate | ~5-10 min | ~5-10 min |

> **Recommended demo order:** Start with Scenario 2 (longest wait), then run Scenario 1 while waiting, then finish with Scenario 3. This parallelizes the wait times.

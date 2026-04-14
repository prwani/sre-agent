# Patch Validation

You are an SRE Agent skill specialized in validating operating system and application patches on hybrid servers managed via Azure Arc, using Azure Update Manager for orchestration.

## ArcBox Server Inventory

| Server | OS | Role | Patch Wave |
|---|---|---|---|
| ArcBox-Ubuntu-01 | Ubuntu 22.04 LTS | Web Server | Wave 1 — Dev/Test |
| ArcBox-Ubuntu-02 | Ubuntu 22.04 LTS | Monitoring Server | Wave 1 — Dev/Test |
| ArcBox-Win2K22 | Windows Server 2022 | Application Server | Wave 2 — Non-Critical |
| ArcBox-Win2K25 | Windows Server 2025 | File Server | Wave 2 — Non-Critical |
| ArcBox-SQL | Windows Server 2022 + SQL 2022 | Database Server | Wave 3 — Critical |

## When to Use This Skill

- Azure Update Manager reports pending patches
- Scheduled maintenance window — pre-patch and post-patch validation
- Post-reboot validation after patching cycle
- Patch compliance audit request
- Rollback decision needed after failed patch

## Step 1: Query Pending Patches via Azure Resource Graph

### All Pending Patches (Windows and Linux)

```kql
patchassessmentresources
| where type == "microsoft.hybridcompute/machines/patchassessmentresults/softwarepatches"
| extend machineName = tostring(split(id, "/")[8])
| extend patchName = properties.patchName
| extend classification = properties.classifications[0]
| extend severity = properties.msrcSeverity
| extend kbId = properties.kbId
| extend rebootRequired = properties.rebootBehavior
| project machineName, patchName, classification, severity, kbId, rebootRequired
| order by machineName, classification
```

### Patch Assessment Summary per Machine

```kql
patchassessmentresources
| where type == "microsoft.hybridcompute/machines/patchassessmentresults"
| extend machineName = tostring(split(id, "/")[8])
| extend criticalCount = properties.criticalAndSecurityPatchCount
| extend otherCount = properties.otherPatchCount
| extend rebootPending = properties.rebootPending
| extend lastAssessment = properties.lastModifiedDateTime
| project machineName, criticalCount, otherCount, rebootPending, lastAssessment
| order by criticalCount desc
```

### Patch Installation Results (Post-Patch)

```kql
patchinstallationresources
| where type == "microsoft.hybridcompute/machines/patchinstallationresults"
| extend machineName = tostring(split(id, "/")[8])
| extend status = properties.status
| extend installedCount = properties.installedPatchCount
| extend failedCount = properties.failedPatchCount
| extend pendingReboot = properties.rebootStatus
| extend startTime = properties.startDateTime
| project machineName, status, installedCount, failedCount, pendingReboot, startTime
| order by startTime desc
```

## Step 2: Pre-Patch Checks

Run these checks **before** the patch window opens. All commands use `az connectedmachine run-command create` via the Arc plane. Do **NOT** use `az vm run-command invoke`.

```bash
az connectedmachine run-command create \
  --resource-group "{resourceGroup}" \
  --machine-name "{machineName}" \
  --run-command-name "prepatch-$(date +%s)" \
  --location "{location}" \
  --script "{script}" \
  --async-execution false \
  --timeout-in-seconds 120
```

### Windows Pre-Patch (ArcBox-Win2K22, ArcBox-Win2K25, ArcBox-SQL)

**Disk Space Check:**

```powershell
$drives = Get-PSDrive -PSProvider FileSystem
$issues = @()
foreach ($d in $drives) {
    $totalGB = [math]::Round(($d.Used + $d.Free) / 1GB, 1)
    $freeGB = [math]::Round($d.Free / 1GB, 1)
    $pctFree = if ($totalGB -gt 0) { [math]::Round($d.Free / ($d.Used + $d.Free) * 100, 1) } else { 0 }
    Write-Output "$($d.Name): $freeGB GB free / $totalGB GB total ($pctFree% free)"
    if ($freeGB -lt 5) { $issues += "$($d.Name) drive has only $freeGB GB free" }
}
if ($issues) { Write-Output "BLOCK: $($issues -join '; ')" } else { Write-Output "PASS: Disk space OK" }
```

**Pending Reboot Check:**

```powershell
$rebootPending = $false
$paths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
    "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
)
if (Test-Path $paths[0]) { $rebootPending = $true; Write-Output "CBS RebootPending key exists" }
if (Test-Path $paths[1]) { $rebootPending = $true; Write-Output "WU RebootRequired key exists" }
$smKey = Get-ItemProperty $paths[2] -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
if ($smKey) { $rebootPending = $true; Write-Output "PendingFileRenameOperations found" }
if ($rebootPending) { Write-Output "BLOCK: Reboot already pending — resolve before patching" }
else { Write-Output "PASS: No pending reboot" }
```

**Critical Services Check:**

```powershell
$criticalServices = @("WinRM", "EventLog", "W32Time", "WinDefend", "Sense")
$stopped = @()
foreach ($svc in $criticalServices) {
    $s = Get-Service $svc -ErrorAction SilentlyContinue
    if ($s) {
        Write-Output "$($s.Name): $($s.Status)"
        if ($s.Status -ne "Running") { $stopped += $s.Name }
    }
}
if ($stopped) { Write-Output "WARNING: These critical services are not running: $($stopped -join ', ')" }
else { Write-Output "PASS: All critical services running" }
```

**Backup Status:**

```powershell
$lastBackup = Get-WinEvent -LogName "Microsoft-Windows-Backup" -MaxEvents 1 -ErrorAction SilentlyContinue
if ($lastBackup) {
    $hoursSinceBackup = [math]::Round((New-TimeSpan -Start $lastBackup.TimeCreated -End (Get-Date)).TotalHours, 1)
    Write-Output "Last backup event: $($lastBackup.TimeCreated) ($hoursSinceBackup hours ago)"
    if ($hoursSinceBackup -gt 24) { Write-Output "WARNING: Last backup > 24 hours ago" }
    else { Write-Output "PASS: Recent backup exists" }
} else {
    Write-Output "WARNING: No backup events found in Windows Backup log"
}
```

### Linux Pre-Patch (ArcBox-Ubuntu-01, ArcBox-Ubuntu-02)

**Disk Space Check:**

```bash
echo "=== Disk Space Check ==="
BLOCK=0
while IFS= read -r line; do
    pct=$(echo "$line" | awk '{print $5}' | tr -d '%')
    mount=$(echo "$line" | awk '{print $6}')
    avail=$(echo "$line" | awk '{print $4}')
    echo "${mount}: ${pct}% used, ${avail} available"
    if [ "$pct" -gt 90 ]; then
        echo "BLOCK: ${mount} is ${pct}% full"
        BLOCK=1
    fi
done < <(df -h | grep -v tmpfs | grep -v udev | tail -n +2)
[ "$BLOCK" -eq 0 ] && echo "PASS: Disk space OK"
```

**Pending Reboot Check:**

```bash
echo "=== Reboot Required Check ==="
if [ -f /var/run/reboot-required ]; then
    echo "BLOCK: Reboot required ($(cat /var/run/reboot-required.pkgs 2>/dev/null | wc -l) packages)"
    cat /var/run/reboot-required.pkgs 2>/dev/null
else
    echo "PASS: No pending reboot"
fi
```

**Critical Services Check:**

```bash
echo "=== Critical Services ==="
FAILED=0
for svc in cron ssh rsyslog; do
    status=$(systemctl is-active "$svc" 2>/dev/null)
    echo "${svc}: ${status}"
    if [ "$status" != "active" ]; then
        echo "WARNING: ${svc} is not active"
        FAILED=1
    fi
done
[ "$FAILED" -eq 0 ] && echo "PASS: All critical services running"
```

**APT Lock Check:**

```bash
echo "=== APT Lock Check ==="
if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    echo "BLOCK: dpkg lock is held by another process"
    fuser -v /var/lib/dpkg/lock-frontend 2>/dev/null
else
    echo "PASS: No APT lock contention"
fi
```

### SQL Server Pre-Patch (ArcBox-SQL only)

Run these **in addition** to the standard Windows pre-patch checks:

**SQL Service and Backup Check:**

```powershell
Write-Output "=== SQL Service Check ==="
Get-Service MSSQLSERVER, SQLSERVERAGENT -ErrorAction SilentlyContinue | Select Name, Status | Format-Table -AutoSize

Write-Output "=== Recent Backup Check ==="
try {
    Invoke-Sqlcmd -Query "
        SELECT d.name AS DatabaseName,
               MAX(b.backup_finish_date) AS LastBackup,
               DATEDIFF(HOUR, MAX(b.backup_finish_date), GETDATE()) AS HoursSinceBackup
        FROM sys.databases d
        LEFT JOIN msdb.dbo.backupset b ON d.name = b.database_name
        WHERE d.database_id > 4
        GROUP BY d.name
        ORDER BY LastBackup ASC
    " -TrustServerCertificate | Format-Table -AutoSize
} catch {
    Write-Output "SQL backup query failed: $_"
}
```

**Availability Group Health (if applicable):**

```powershell
Write-Output "=== AG Health Check ==="
try {
    $agResult = Invoke-Sqlcmd -Query "
        SELECT ag.name AS AGName,
               rs.role_desc,
               rs.synchronization_health_desc,
               rs.connected_state_desc
        FROM sys.dm_hadr_availability_replica_states rs
        JOIN sys.availability_groups ag ON rs.group_id = ag.group_id
        WHERE rs.is_local = 1
    " -TrustServerCertificate -ErrorAction Stop
    if ($agResult) { $agResult | Format-Table -AutoSize }
    else { Write-Output "No Availability Groups configured." }
} catch {
    Write-Output "No AG or query failed: $_"
}
```

## Step 3: Post-Patch Validation

Run these checks **after** the patch window closes and servers have been rebooted (if required).

### Windows Post-Patch (ArcBox-Win2K22, ArcBox-Win2K25, ArcBox-SQL)

**Verify Reboot and Uptime:**

```powershell
$os = Get-CimInstance Win32_OperatingSystem
$lastBoot = $os.LastBootUpTime
$uptime = (Get-Date) - $lastBoot
Write-Output "Last Boot: $lastBoot"
Write-Output "Uptime: $([math]::Round($uptime.TotalHours, 1)) hours"
if ($uptime.TotalHours -gt 24) {
    Write-Output "WARNING: Server may not have rebooted during patch window"
}
```

**Critical Services Restored:**

```powershell
$criticalServices = @("WinRM", "EventLog", "W32Time", "WinDefend", "Sense")
$failed = @()
foreach ($svc in $criticalServices) {
    $s = Get-Service $svc -ErrorAction SilentlyContinue
    if ($s) {
        Write-Output "$($s.Name): $($s.Status)"
        if ($s.Status -ne "Running") { $failed += $s.Name }
    } else {
        Write-Output "$svc: NOT FOUND"
        $failed += $svc
    }
}
if ($failed) { Write-Output "FAIL: Services not running: $($failed -join ', ')" }
else { Write-Output "PASS: All critical services running" }
```

**Check for Crash Dumps:**

```powershell
$dumpPath = "$env:SystemRoot\Minidump"
$fullDump = "$env:SystemRoot\MEMORY.DMP"
$issues = @()
if (Test-Path $dumpPath) {
    $dumps = Get-ChildItem $dumpPath -Filter "*.dmp" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-24) }
    if ($dumps) {
        $issues += "Found $($dumps.Count) crash dump(s) in last 24h"
        $dumps | Select-Object Name, LastWriteTime, Length | Format-Table -AutoSize
    }
}
if (Test-Path $fullDump) {
    $dumpInfo = Get-Item $fullDump
    if ($dumpInfo.LastWriteTime -gt (Get-Date).AddHours(-24)) {
        $issues += "Full memory dump found: $($dumpInfo.LastWriteTime)"
    }
}
if ($issues) { Write-Output "CRITICAL: $($issues -join '; ')" }
else { Write-Output "PASS: No recent crash dumps" }
```

**Verify Latest Installed Patch:**

```powershell
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 5 HotFixID, Description, InstalledOn | Format-Table -AutoSize
```

**Check Event Log for Post-Patch Errors:**

```powershell
$since = (Get-Date).AddHours(-4)
$errors = Get-EventLog -LogName System -EntryType Error -After $since -ErrorAction SilentlyContinue
$appErrors = Get-EventLog -LogName Application -EntryType Error -After $since -ErrorAction SilentlyContinue
Write-Output "System errors since ${since}: $($errors.Count)"
Write-Output "Application errors since ${since}: $($appErrors.Count)"
if ($errors.Count -gt 0) {
    Write-Output "--- Top System Errors ---"
    $errors | Select-Object -First 10 TimeGenerated, Source, EventID, Message | Format-Table -AutoSize
}
```

### Linux Post-Patch (ArcBox-Ubuntu-01, ArcBox-Ubuntu-02)

**Verify Reboot and Uptime:**

```bash
echo "=== Uptime ==="
uptime -s
uptime -p
UPTIME_HOURS=$(awk '{printf "%.1f", $1/3600}' /proc/uptime)
echo "Uptime hours: $UPTIME_HOURS"
if (( $(echo "$UPTIME_HOURS > 24" | bc -l) )); then
    echo "WARNING: Server may not have rebooted during patch window"
fi
```

**Critical Services Restored:**

```bash
echo "=== Critical Services ==="
FAILED=0
for svc in cron ssh rsyslog; do
    status=$(systemctl is-active "$svc" 2>/dev/null)
    echo "${svc}: ${status}"
    if [ "$status" != "active" ]; then
        echo "FAIL: ${svc} not running after patch"
        FAILED=1
    fi
done
echo "---"
systemctl list-units --state=failed --no-legend 2>/dev/null
[ "$FAILED" -eq 0 ] && echo "PASS: All critical services running"
```

**Remaining Upgradable Packages:**

```bash
echo "=== Remaining Upgradable ==="
COUNT=$(apt list --upgradable 2>/dev/null | grep -c "upgradable")
echo "Upgradable packages remaining: $COUNT"
if [ "$COUNT" -gt 0 ]; then
    apt list --upgradable 2>/dev/null | head -20
fi
```

**Check for Kernel Panic or OOM Events:**

```bash
echo "=== Kernel Panic / OOM Check ==="
dmesg 2>/dev/null | grep -i -E "panic|oom|kill" | tail -10
journalctl -k --since "4 hours ago" --no-pager 2>/dev/null | grep -i -E "panic|oom|kill" | tail -10
if [ $? -ne 0 ]; then
    echo "PASS: No kernel panic or OOM events"
fi
```

### SQL Server Post-Patch (ArcBox-SQL only)

Run in addition to Windows post-patch checks:

**SQL Service Running:**

```powershell
Write-Output "=== SQL Service Status ==="
Get-Service MSSQLSERVER, SQLSERVERAGENT -ErrorAction SilentlyContinue | Select Name, Status | Format-Table -AutoSize
$sqlSvc = Get-Service MSSQLSERVER -ErrorAction SilentlyContinue
if ($sqlSvc.Status -ne "Running") {
    Write-Output "CRITICAL: SQL Server is not running after patch!"
}
```

**DBCC CHECKDB:**

```powershell
Write-Output "=== DBCC CHECKDB ==="
try {
    $databases = Invoke-Sqlcmd -Query "SELECT name FROM sys.databases WHERE database_id > 4 AND state_desc = 'ONLINE'" -TrustServerCertificate
    foreach ($db in $databases) {
        Write-Output "Checking $($db.name)..."
        try {
            Invoke-Sqlcmd -Query "DBCC CHECKDB ([$($db.name)]) WITH NO_INFOMSGS, ALL_ERRORMSGS" -TrustServerCertificate -QueryTimeout 300
            Write-Output "$($db.name): PASS"
        } catch {
            Write-Output "$($db.name): FAIL — $_"
        }
    }
} catch {
    Write-Output "DBCC check failed: $_"
}
```

**AG Sync Status (if applicable):**

```powershell
Write-Output "=== AG Sync Status ==="
try {
    $agResult = Invoke-Sqlcmd -Query "
        SELECT ag.name AS AGName,
               db.database_name,
               rs.synchronization_state_desc,
               rs.synchronization_health_desc
        FROM sys.dm_hadr_database_replica_states rs
        JOIN sys.availability_groups ag ON rs.group_id = ag.group_id
        JOIN sys.availability_databases_cluster db ON rs.database_id = db.database_id
        WHERE rs.is_local = 1
    " -TrustServerCertificate -ErrorAction Stop
    if ($agResult) {
        $agResult | Format-Table -AutoSize
        $unhealthy = $agResult | Where-Object { $_.synchronization_health_desc -ne "HEALTHY" }
        if ($unhealthy) { Write-Output "CRITICAL: AG databases not healthy!" }
        else { Write-Output "PASS: All AG databases healthy" }
    } else {
        Write-Output "No Availability Groups configured."
    }
} catch {
    Write-Output "No AG or query failed: $_"
}
```

## Step 4: Rollback Decision Tree

After post-patch validation, evaluate results and assign a priority action:

```
START
  │
  ├─ Critical service down (SQL, WinRM, ssh, cron)?
  │   └─ YES → P1 ROLLBACK — Immediate rollback required
  │
  ├─ Crash dumps found or kernel panic detected?
  │   └─ YES → P1 ROLLBACK — System instability, rollback immediately
  │
  ├─ DBCC CHECKDB failures on SQL databases?
  │   └─ YES → P1 ROLLBACK — Data integrity at risk
  │
  ├─ AG synchronization unhealthy?
  │   └─ YES → P2 INVESTIGATE — Check secondary replica, may need rollback
  │
  ├─ Services recovered but new errors in event log?
  │   └─ YES → P3 MONITOR — Document errors, monitor for 4 hours
  │
  ├─ Non-critical service failed to restart?
  │   └─ YES → P3 MONITOR — Attempt manual restart, document
  │
  ├─ Upgradable packages still remaining (Linux)?
  │   └─ YES → P4 COMPLETE — Note for next patch window
  │
  └─ All checks pass?
      └─ YES → P4 COMPLETE — Patch validated successfully
```

### Rollback Actions by Priority

| Priority | Action | SLA |
|---|---|---|
| P1 ROLLBACK | Restore from snapshot/backup, notify stakeholders, open incident | 30 min |
| P2 INVESTIGATE | Deep investigation, prepare rollback, notify team | 2 hours |
| P3 MONITOR | Set up enhanced monitoring, recheck in 4 hours | 4 hours |
| P4 COMPLETE | Close patch ticket, update CMDB | End of window |

## Step 5: Patch Wave Strategy

Patches are deployed in waves to minimize blast radius. Each wave must complete validation before the next wave begins.

### Wave 1 — Dev/Test (ArcBox-Ubuntu-01, ArcBox-Ubuntu-02)

**Rationale**: Linux web/monitoring servers are lower risk and validate patch compatibility.

1. Run pre-patch checks (Step 2 — Linux)
2. Trigger patch deployment via Azure Update Manager
3. Wait for reboot if required
4. Run post-patch validation (Step 3 — Linux)
5. Evaluate rollback decision tree (Step 4)
6. **Gate**: All Wave 1 servers must be P4 COMPLETE before proceeding

### Wave 2 — Non-Critical Windows (ArcBox-Win2K22, ArcBox-Win2K25)

**Rationale**: Application and file servers — important but no database dependency.

1. Run pre-patch checks (Step 2 — Windows)
2. Trigger patch deployment via Azure Update Manager
3. Wait for reboot if required
4. Run post-patch validation (Step 3 — Windows)
5. Evaluate rollback decision tree (Step 4)
6. **Gate**: All Wave 2 servers must be P4 COMPLETE before proceeding

### Wave 3 — Critical (ArcBox-SQL)

**Rationale**: Database server is highest risk; patched last with full validation.

1. Run pre-patch checks (Step 2 — Windows + SQL)
2. Confirm recent SQL backup exists (< 4 hours old)
3. If AG configured, verify secondary is healthy
4. Trigger patch deployment via Azure Update Manager
5. Wait for reboot if required
6. Run post-patch validation (Step 3 — Windows + SQL)
7. Run DBCC CHECKDB on all user databases
8. Verify AG sync if applicable
9. Evaluate rollback decision tree (Step 4)

### Wave Completion Summary

| Wave | Servers | Pre-Patch | Patch | Post-Patch | Status |
|---|---|---|---|---|---|
| 1 | Ubuntu-01, Ubuntu-02 | PASS/FAIL | Installed/Failed | P1–P4 | COMPLETE/BLOCKED |
| 2 | Win2K22, Win2K25 | PASS/FAIL | Installed/Failed | P1–P4 | COMPLETE/BLOCKED |
| 3 | SQL | PASS/FAIL | Installed/Failed | P1–P4 | COMPLETE/BLOCKED |

## Safety Rules

- NEVER proceed to the next patch wave if the current wave has P1 or P2 findings
- ALWAYS run pre-patch checks before deploying patches
- ALWAYS take/verify a backup of ArcBox-SQL before Wave 3
- For P1 ROLLBACK, notify stakeholders immediately and open an incident
- Log all pre-patch, post-patch, and rollback actions for audit trail
- If a pre-patch check returns BLOCK, halt patching for that server and investigate

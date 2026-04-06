# Arc Server Health Check Investigation Runbook

## Trigger Keywords
`CPU high`, `memory pressure`, `disk full`, `service stopped`, `server unhealthy`, `heartbeat lost`, `server down`, `performance degraded`, `slow response`

## Scope
Azure Arc-enrolled servers (Windows and Linux) in the ArcBox demo environment. Metrics collected via Azure Monitor Agent (AMA) into Log Analytics Workspace.

### ArcBox Server Inventory
| Server | OS | Role |
|---|---|---|
| ArcBox-Win2K22 | Windows Server 2022 | Application Server |
| ArcBox-Win2K25 | Windows Server 2025 | File Server |
| ArcBox-SQL | Windows Server 2022 + SQL Server 2022 | Database Server |
| ArcBox-Ubuntu-01 | Ubuntu 22.04 LTS | Web Server |
| ArcBox-Ubuntu-02 | Ubuntu 22.04 LTS | Monitoring Server |

---

## Phase 1: Server Discovery and Connectivity

### 1.1 List All Arc Servers
```kql
resources
| where type == "microsoft.hybridcompute/machines"
| project name, location, resourceGroup,
    properties.osType, properties.status,
    properties.agentVersion, properties.osSku,
    properties.lastStatusChange
| order by name asc
```

**Via Azure CLI:**
```bash
az connectedmachine list --resource-group <resourceGroup> --output table
```

### 1.2 Check Heartbeat Status
```kql
Heartbeat
| where TimeGenerated > ago(30m)
| summarize LastHeartbeat = max(TimeGenerated) by Computer, OSType, Category, Version
| extend MinutesSinceHeartbeat = datetime_diff('minute', now(), LastHeartbeat)
| extend Status = case(
    MinutesSinceHeartbeat <= 5, "Healthy",
    MinutesSinceHeartbeat <= 15, "Warning",
    "Critical - Heartbeat Lost"
)
| order by MinutesSinceHeartbeat desc
```

### 1.3 Detect Stale Agents
```kql
Heartbeat
| summarize LastHeartbeat = max(TimeGenerated) by Computer, OSType
| where LastHeartbeat < ago(15m)
| extend DowntimeMinutes = datetime_diff('minute', now(), LastHeartbeat)
| order by DowntimeMinutes desc
```

### 1.4 Check Agent Extension Health
```bash
# List extensions for a specific Arc server
az connectedmachine extension list \
    --machine-name ArcBox-Win2K22 \
    --resource-group <resourceGroup> \
    --output table

# Check extension provisioning state
az connectedmachine extension list \
    --machine-name ArcBox-Ubuntu-01 \
    --resource-group <resourceGroup> \
    --query "[].{Name:name, Type:properties.type, Status:properties.provisioningState}" \
    --output table
```

---

## Phase 2: CPU Investigation

### 2.1 CPU Trends (KQL)
```kql
// Works for both Windows (Processor / % Processor Time) and Linux (Processor / % Processor Time)
Perf
| where TimeGenerated > ago(1h)
| where ObjectName == "Processor" and CounterName == "% Processor Time" and InstanceName == "_Total"
| summarize AvgCPU = avg(CounterValue), MaxCPU = max(CounterValue), MinCPU = min(CounterValue)
    by bin(TimeGenerated, 5m), Computer
| order by TimeGenerated desc, Computer asc
```

### 2.2 CPU Spike Detection
```kql
Perf
| where TimeGenerated > ago(1h)
| where ObjectName == "Processor" and CounterName == "% Processor Time" and InstanceName == "_Total"
| summarize AvgCPU = avg(CounterValue) by bin(TimeGenerated, 5m), Computer
| where AvgCPU > 85
| extend Severity = case(
    AvgCPU > 95, "CRITICAL",
    AvgCPU > 85, "WARNING",
    "OK"
)
| order by TimeGenerated desc
```

### 2.3 Top CPU Consumers — Windows
Run via Arc Run Command on ArcBox-Win2K22, ArcBox-Win2K25, or ArcBox-SQL:
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Win2K22 \
    --run-command-name "CheckTopCPU" \
    --location <location> \
    --script "Get-Process | Sort-Object CPU -Descending | Select-Object -First 15 Name, Id, CPU, @{Name='MemoryMB';Expression={[math]::Round(\$_.WorkingSet64/1MB,2)}}, @{Name='CPUSeconds';Expression={[math]::Round(\$_.TotalProcessorTime.TotalSeconds,2)}} | Format-Table -AutoSize"
```

### 2.4 Top CPU Consumers — Linux
Run via Arc Run Command on ArcBox-Ubuntu-01 or ArcBox-Ubuntu-02:
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Ubuntu-01 \
    --run-command-name "CheckTopCPU" \
    --location <location> \
    --script "ps aux --sort=-%cpu | head -15"
```

### 2.5 Per-Core CPU Usage — Windows
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Win2K22 \
    --run-command-name "PerCoreCPU" \
    --location <location> \
    --script "Get-Counter '\\Processor(*)\\% Processor Time' -SampleInterval 2 -MaxSamples 3 | ForEach-Object { \$_.CounterSamples | Where-Object { \$_.InstanceName -ne '_total' } | Sort-Object CookedValue -Descending | Format-Table -AutoSize }"
```

### 2.6 Per-Core CPU Usage — Linux
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Ubuntu-01 \
    --run-command-name "PerCoreCPU" \
    --location <location> \
    --script "mpstat -P ALL 2 3 2>/dev/null || cat /proc/stat | grep '^cpu[0-9]'"
```

---

## Phase 3: Memory Investigation

### 3.1 Memory Trends (KQL)
```kql
// Windows: Memory / % Committed Bytes In Use
// Linux: Memory / % Used Memory
Perf
| where TimeGenerated > ago(1h)
| where (ObjectName == "Memory" and CounterName == "% Committed Bytes In Use")
    or (ObjectName == "Memory" and CounterName == "% Used Memory")
| summarize AvgMemory = avg(CounterValue), MaxMemory = max(CounterValue)
    by bin(TimeGenerated, 5m), Computer, CounterName
| order by TimeGenerated desc
```

### 3.2 Available Memory (KQL)
```kql
Perf
| where TimeGenerated > ago(1h)
| where (ObjectName == "Memory" and CounterName == "Available MBytes")
    or (ObjectName == "Memory" and CounterName == "Available MBytes Memory")
| summarize AvgAvailMB = avg(CounterValue), MinAvailMB = min(CounterValue)
    by bin(TimeGenerated, 5m), Computer
| order by TimeGenerated desc
```

### 3.3 Memory Details — Windows
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Win2K22 \
    --run-command-name "MemoryDetails" \
    --location <location> \
    --script "Write-Output '=== System Memory ===' ; Get-CimInstance Win32_OperatingSystem | Select-Object @{Name='TotalGB';Expression={[math]::Round(\$_.TotalVisibleMemorySize/1MB,2)}}, @{Name='FreeGB';Expression={[math]::Round(\$_.FreePhysicalMemory/1MB,2)}}, @{Name='UsedPct';Expression={[math]::Round(((\$_.TotalVisibleMemorySize - \$_.FreePhysicalMemory)/\$_.TotalVisibleMemorySize)*100,1)}} | Format-List ; Write-Output '=== Top Memory Consumers ===' ; Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 10 Name, Id, @{Name='MemoryMB';Expression={[math]::Round(\$_.WorkingSet64/1MB,2)}} | Format-Table -AutoSize"
```

### 3.4 Memory Details — Linux
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Ubuntu-01 \
    --run-command-name "MemoryDetails" \
    --location <location> \
    --script "echo '=== Memory Summary ===' && free -h && echo '' && echo '=== /proc/meminfo highlights ===' && grep -E 'MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree' /proc/meminfo && echo '' && echo '=== Top Memory Consumers ===' && ps aux --sort=-%mem | head -10"
```

---

## Phase 4: Disk Investigation

### 4.1 Disk Space Trends (KQL)
```kql
// Windows: LogicalDisk / % Free Space
// Linux: Logical Disk / % Free Space (note the space in "Logical Disk")
Perf
| where TimeGenerated > ago(1h)
| where (ObjectName == "LogicalDisk" or ObjectName == "Logical Disk")
    and CounterName == "% Free Space"
    and InstanceName != "_Total"
| summarize AvgFreeSpace = avg(CounterValue), MinFreeSpace = min(CounterValue)
    by bin(TimeGenerated, 15m), Computer, InstanceName
| where MinFreeSpace < 20
| order by MinFreeSpace asc
```

### 4.2 Disk I/O (KQL)
```kql
Perf
| where TimeGenerated > ago(1h)
| where (ObjectName == "LogicalDisk" or ObjectName == "Logical Disk")
    and CounterName in ("Disk Reads/sec", "Disk Writes/sec", "Avg. Disk sec/Read", "Avg. Disk sec/Write")
    and InstanceName != "_Total"
| summarize AvgValue = avg(CounterValue), MaxValue = max(CounterValue)
    by bin(TimeGenerated, 5m), Computer, InstanceName, CounterName
| order by TimeGenerated desc
```

### 4.3 Disk Details — Windows
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Win2K22 \
    --run-command-name "DiskDetails" \
    --location <location> \
    --script "Write-Output '=== Drive Space ===' ; Get-PSDrive -PSProvider FileSystem | Select-Object Name, @{Name='UsedGB';Expression={[math]::Round(\$_.Used/1GB,2)}}, @{Name='FreeGB';Expression={[math]::Round(\$_.Free/1GB,2)}}, @{Name='TotalGB';Expression={[math]::Round((\$_.Used+\$_.Free)/1GB,2)}}, @{Name='PctFree';Expression={if((\$_.Used+\$_.Free) -gt 0){[math]::Round(\$_.Free/(\$_.Used+\$_.Free)*100,1)}else{'N/A'}}} | Format-Table -AutoSize ; Write-Output '=== Largest Files in C:\\Windows\\Temp ===' ; Get-ChildItem -Path C:\\Windows\\Temp -Recurse -File -ErrorAction SilentlyContinue | Sort-Object Length -Descending | Select-Object -First 10 @{Name='SizeMB';Expression={[math]::Round(\$_.Length/1MB,2)}}, FullName | Format-Table -AutoSize"
```

### 4.4 Disk Details — Linux
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Ubuntu-01 \
    --run-command-name "DiskDetails" \
    --location <location> \
    --script "echo '=== Disk Usage ===' && df -h && echo '' && echo '=== Largest directories under /var ===' && du -sh /var/*/ 2>/dev/null | sort -rh | head -10 && echo '' && echo '=== Largest log files ===' && find /var/log -type f -exec du -sh {} + 2>/dev/null | sort -rh | head -10"
```

---

## Phase 5: Services Health

### 5.1 Windows Critical Services
Run on ArcBox-Win2K22 and ArcBox-Win2K25:
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Win2K22 \
    --run-command-name "CheckServices" \
    --location <location> \
    --script "Write-Output '=== Critical Service Status ===' ; \$services = @('WinRM','EventLog','W32Time','WinDefend','Sense','himds','GCArcService','ExtensionService') ; foreach (\$svc in \$services) { \$s = Get-Service -Name \$svc -ErrorAction SilentlyContinue ; if (\$s) { Write-Output ('{0}: {1}' -f \$s.Name, \$s.Status) } else { Write-Output ('{0}: NOT FOUND' -f \$svc) } }"
```

### 5.2 Linux Critical Services
Run on ArcBox-Ubuntu-01 and ArcBox-Ubuntu-02:
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Ubuntu-01 \
    --run-command-name "CheckServices" \
    --location <location> \
    --script "echo '=== Critical Service Status ===' && for svc in cron ssh sshd rsyslog ufw mdatp himdsd gcad extd; do status=$(systemctl is-active $svc 2>/dev/null || echo 'not-found'); echo \"$svc: $status\"; done && echo '' && echo '=== Failed Services ===' && systemctl list-units --state=failed --no-pager"
```

### 5.3 SQL Server Services (ArcBox-SQL Only)
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-SQL \
    --run-command-name "CheckSQLServices" \
    --location <location> \
    --script "Write-Output '=== SQL Server Services ===' ; Get-Service -Name 'MSSQLSERVER','SQLSERVERAGENT','MSSQLFDLauncher','SQLBrowser' -ErrorAction SilentlyContinue | Select-Object Name, Status, StartType | Format-Table -AutoSize ; Write-Output '=== SQL Database Status ===' ; try { Invoke-Sqlcmd -Query \"SELECT name, state_desc, recovery_model_desc, compatibility_level FROM sys.databases ORDER BY name\" -ServerInstance '.' -TrustServerCertificate | Format-Table -AutoSize } catch { Write-Output ('SQL Query Error: {0}' -f \$_.Exception.Message) }"
```

### 5.4 SQL Server Health (ArcBox-SQL Only)
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-SQL \
    --run-command-name "SQLHealth" \
    --location <location> \
    --script "try { Write-Output '=== SQL Server Version ===' ; Invoke-Sqlcmd -Query 'SELECT @@VERSION AS SQLVersion' -ServerInstance '.' -TrustServerCertificate | Format-List ; Write-Output '=== Active Connections ===' ; Invoke-Sqlcmd -Query 'SELECT DB_NAME(dbid) AS DatabaseName, COUNT(*) AS Connections FROM sys.sysprocesses GROUP BY dbid ORDER BY Connections DESC' -ServerInstance '.' -TrustServerCertificate | Format-Table -AutoSize ; Write-Output '=== Database Sizes ===' ; Invoke-Sqlcmd -Query \"SELECT DB_NAME(database_id) AS DatabaseName, CAST(SUM(size * 8.0 / 1024) AS DECIMAL(10,2)) AS SizeMB FROM sys.master_files GROUP BY database_id ORDER BY SizeMB DESC\" -ServerInstance '.' -TrustServerCertificate | Format-Table -AutoSize } catch { Write-Output ('SQL Error: {0}' -f \$_.Exception.Message) }"
```

---

## Phase 6: Event Log Analysis

### 6.1 Windows Event Logs — Recent Errors
Run on ArcBox-Win2K22, ArcBox-Win2K25, or ArcBox-SQL:
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Win2K22 \
    --run-command-name "EventLogErrors" \
    --location <location> \
    --script "Write-Output '=== System Event Log Errors (Last 1 Hour) ===' ; Get-EventLog -LogName System -EntryType Error -After (Get-Date).AddHours(-1) -ErrorAction SilentlyContinue | Select-Object -First 20 TimeGenerated, Source, EventID, Message | Format-Table -Wrap -AutoSize ; Write-Output '=== Application Event Log Errors (Last 1 Hour) ===' ; Get-EventLog -LogName Application -EntryType Error -After (Get-Date).AddHours(-1) -ErrorAction SilentlyContinue | Select-Object -First 20 TimeGenerated, Source, EventID, Message | Format-Table -Wrap -AutoSize"
```

### 6.2 Windows Event Logs via KQL
```kql
Event
| where TimeGenerated > ago(1h)
| where EventLevelName == "Error" or EventLevelName == "Warning"
| where Computer has "ArcBox"
| summarize Count = count() by Computer, EventLog, Source, EventID, EventLevelName
| order by Count desc
| take 25
```

### 6.3 Linux Journal — Recent Errors
Run on ArcBox-Ubuntu-01 or ArcBox-Ubuntu-02:
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Ubuntu-01 \
    --run-command-name "JournalErrors" \
    --location <location> \
    --script "echo '=== Journal Errors (Last 1 Hour) ===' && journalctl -p err --since '1 hour ago' --no-pager | tail -50 && echo '' && echo '=== Kernel Errors ===' && journalctl -k -p err --since '1 hour ago' --no-pager | tail -20"
```

### 6.4 Syslog via KQL
```kql
Syslog
| where TimeGenerated > ago(1h)
| where SeverityLevel in ("err", "crit", "alert", "emerg")
| where Computer has "ArcBox"
| summarize Count = count() by Computer, Facility, SeverityLevel, ProcessName
| order by Count desc
| take 25
```

---

## Phase 7: Network Connectivity

### 7.1 Network Connectivity — Windows
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Win2K22 \
    --run-command-name "NetworkCheck" \
    --location <location> \
    --script "Write-Output '=== Network Adapters ===' ; Get-NetAdapter | Select-Object Name, Status, LinkSpeed | Format-Table -AutoSize ; Write-Output '=== IP Configuration ===' ; Get-NetIPAddress -AddressFamily IPv4 | Where-Object { \$_.InterfaceAlias -notlike 'Loopback*' } | Select-Object InterfaceAlias, IPAddress, PrefixLength | Format-Table -AutoSize ; Write-Output '=== DNS Resolution ===' ; Resolve-DnsName login.microsoftonline.com -ErrorAction SilentlyContinue | Select-Object -First 3 Name, Type, IPAddress | Format-Table -AutoSize ; Write-Output '=== Azure Arc Connectivity ===' ; Test-NetConnection -ComputerName gbl.his.arc.azure.com -Port 443 -WarningAction SilentlyContinue | Select-Object ComputerName, TcpTestSucceeded, RemotePort | Format-List"
```

### 7.2 Network Connectivity — Linux
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Ubuntu-01 \
    --run-command-name "NetworkCheck" \
    --location <location> \
    --script "echo '=== Network Interfaces ===' && ip -br addr show && echo '' && echo '=== DNS Resolution ===' && nslookup login.microsoftonline.com 2>/dev/null || dig login.microsoftonline.com +short && echo '' && echo '=== Azure Arc Connectivity ===' && curl -s -o /dev/null -w 'HTTP Status: %{http_code}\nConnect Time: %{time_connect}s\n' https://gbl.his.arc.azure.com && echo '' && echo '=== Listening Ports ===' && ss -tlnp | head -20"
```

---

## Phase 8: Summary and Thresholds

### Metric Thresholds
| Metric | OK | WARNING | CRITICAL | Action |
|---|---|---|---|---|
| CPU % | < 70% | 70–90% sustained 10+ min | > 90% sustained 5+ min | Identify top processes, consider scaling |
| Memory % | < 75% | 75–90% | > 90% | Identify consumers, check for leaks |
| Disk Free % | > 20% | 10–20% | < 10% | Clean temp/log files, extend disk |
| Heartbeat Staleness | < 5 min | 5–15 min | > 15 min | Check agent, network, VM power state |
| Service State | Running | Degraded | Stopped | Restart service, check dependencies |

### Common Root Causes
| Symptom | Likely Cause | Next Step |
|---|---|---|
| CPU > 90% on Windows | Runaway process or Windows Update | Identify with Get-Process; check WSUS |
| CPU > 90% on Linux | Stuck cron job or crypto miner | Check `top`, review crontab and /proc |
| Memory pressure + swapping | Memory leak or undersized VM | Profile top consumers, resize VM |
| Disk full on /var | Log rotation failure | Check logrotate, clean old logs |
| Disk full on C:\ | Windows Update cache | Clean Windows\Temp, SoftwareDistribution |
| Heartbeat lost | Network issue or VM powered off | Check NSG, VM status in portal |
| SQL services stopped | Crash from OOM or disk full | Check SQL error log, event log |
| WinRM unavailable | Service crash or firewall | Restart WinRM, check listener config |

### Escalation Criteria

Escalate immediately if:
- **Multiple servers** show heartbeat loss simultaneously (network/infrastructure issue)
- **SQL Server** is down and databases are in suspect state
- **Disk at 0% free** on any production server
- **CPU at 100%** with no identifiable user process (possible compromise)
- **Azure Monitor Agent** (AMA) extension in failed state across multiple servers
- **Services fail to restart** after manual intervention

---

## Phase 9: Send Analysis Email

After completing investigation, send an email summary to the incident stakeholders.

**Send to:** sre-team@contoso.com

### Email Structure

**Subject:** `[Incident {incidentID}] Arc Server Health Analysis - {serverName}`

**Body should include:**

1. **Incident Summary**
   - Server name, OS, role, incident start time (UTC)
   - Current metric values and health status

2. **Key Findings**
   - CPU/Memory/Disk status at time of incident
   - Service availability results
   - Suspected root cause
   - Timeline of when issue started

3. **Evidence**
   - Resource metrics (CPU/Memory/Disk values over time)
   - Event log error samples
   - Service status output
   - Include KQL queries used (for reproducibility)

4. **Recommended Actions**
   - Immediate: restart services, clean disk, kill process
   - Follow-up: resize VM, patch, add monitoring alert

5. **Links**
   - Azure Portal link to the Arc server resource
   - Log Analytics workspace query link
   - GitHub issue (if created)

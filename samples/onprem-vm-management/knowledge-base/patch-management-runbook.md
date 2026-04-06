# Patch Management Runbook

## Trigger Keywords
`patches`, `updates`, `security updates`, `patch Tuesday`, `missing patches`, `CVE`, `KB`, `apt upgrade`, `Windows Update`, `WSUS`, `Update Manager`, `compliance`, `vulnerability`

## Scope
Patch assessment and validation for Azure Arc-enrolled Windows and Linux servers via Azure Update Manager. Covers all ArcBox demo environment servers.

### ArcBox Server Inventory
| Server | OS | Role | Patch Notes |
|---|---|---|---|
| ArcBox-Win2K22 | Windows Server 2022 | Application Server | Standard Windows Update |
| ArcBox-Win2K25 | Windows Server 2025 | File Server | Standard Windows Update |
| ArcBox-SQL | Windows Server 2022 + SQL 2022 | Database Server | Windows + SQL CU patches |
| ArcBox-Ubuntu-01 | Ubuntu 22.04 LTS | Web Server | apt-based patching |
| ArcBox-Ubuntu-02 | Ubuntu 22.04 LTS | Monitoring Server | apt-based patching |

---

## Phase 1: Patch Assessment

### 1.1 Query Azure Update Manager — Missing Patches (Resource Graph)
```kql
patchassessmentresources
| where type == "microsoft.hybridcompute/machines/patchassessmentresults/softwarepatches"
| extend machineName = tostring(split(id, '/')[8])
| extend patchName = properties.patchName
| extend classification = properties.classifications[0]
| extend severity = properties.msrcSeverity
| extend kbId = properties.kbId
| extend rebootRequired = properties.rebootBehavior
| where properties.installationState == "Available" or properties.installationState == "Pending"
| summarize MissingPatches = count() by machineName, tostring(classification)
| order by MissingPatches desc
```

### 1.2 Patch Assessment Summary by Server
```kql
patchassessmentresources
| where type == "microsoft.hybridcompute/machines/patchassessmentresults"
| extend machineName = tostring(split(id, '/')[8])
| project machineName,
    lastAssessmentTime = properties.lastModifiedDateTime,
    status = properties.status,
    criticalCount = properties.availablePatchCountByClassification.critical,
    securityCount = properties.availablePatchCountByClassification.security,
    otherCount = properties.availablePatchCountByClassification.other,
    rebootPending = properties.rebootPending
| order by machineName asc
```

### 1.3 Critical and Security Patches Detail
```kql
patchassessmentresources
| where type == "microsoft.hybridcompute/machines/patchassessmentresults/softwarepatches"
| extend machineName = tostring(split(id, '/')[8])
| extend classification = tostring(properties.classifications[0])
| where classification in ("Critical", "Security")
| project machineName,
    patchName = properties.patchName,
    classification,
    severity = properties.msrcSeverity,
    kbId = properties.kbId,
    version = properties.version,
    reboot = properties.rebootBehavior
| order by machineName asc, classification asc
```

### 1.4 Trigger On-Demand Assessment via CLI
```bash
# Trigger patch assessment for a specific server
az connectedmachine assess-patches \
    --resource-group <resourceGroup> \
    --name ArcBox-Win2K22

az connectedmachine assess-patches \
    --resource-group <resourceGroup> \
    --name ArcBox-Ubuntu-01
```

### 1.5 Windows Patch Summary (On-Host)
Run on ArcBox-Win2K22, ArcBox-Win2K25, or ArcBox-SQL:
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Win2K22 \
    --run-command-name "PatchSummary" \
    --location <location> \
    --script "Write-Output '=== Installed Hotfixes (Last 30 Days) ===' ; Get-HotFix | Where-Object { \$_.InstalledOn -gt (Get-Date).AddDays(-30) } | Sort-Object InstalledOn -Descending | Select-Object HotFixID, Description, InstalledOn, InstalledBy | Format-Table -AutoSize ; Write-Output '' ; Write-Output '=== Windows Update History (Last 10) ===' ; \$session = New-Object -ComObject Microsoft.Update.Session ; \$searcher = \$session.CreateUpdateSearcher() ; \$history = \$searcher.QueryHistory(0, 10) ; \$history | Select-Object Date, @{Name='Result';Expression={switch(\$_.ResultCode){1{'InProgress'};2{'Succeeded'};3{'SucceededWithErrors'};4{'Failed'};5{'Aborted'}}}}, Title | Format-Table -Wrap -AutoSize ; Write-Output '' ; Write-Output '=== OS Build ===' ; [System.Environment]::OSVersion.Version"
```

### 1.6 Linux Patch Summary (On-Host)
Run on ArcBox-Ubuntu-01 or ArcBox-Ubuntu-02:
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Ubuntu-01 \
    --run-command-name "PatchSummary" \
    --location <location> \
    --script "echo '=== Upgradable Packages ===' && apt list --upgradable 2>/dev/null && echo '' && echo '=== Security Updates Available ===' && apt list --upgradable 2>/dev/null | grep -i security | wc -l && echo 'security packages available' && echo '' && echo '=== Last apt Update ===' && stat /var/cache/apt/pkgcache.bin 2>/dev/null | grep Modify && echo '' && echo '=== Kernel Version ===' && uname -r && echo '' && echo '=== Recently Installed Packages (Last 30 Days) ===' && grep 'install ' /var/log/dpkg.log 2>/dev/null | tail -20 || zcat /var/log/dpkg.log.1.gz 2>/dev/null | grep 'install ' | tail -20"
```

### 1.7 SQL Server Patch Level (ArcBox-SQL Only)
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-SQL \
    --run-command-name "SQLPatchLevel" \
    --location <location> \
    --script "Write-Output '=== SQL Server Version ===' ; try { \$result = Invoke-Sqlcmd -Query 'SELECT SERVERPROPERTY(''ProductVersion'') AS Version, SERVERPROPERTY(''ProductLevel'') AS PatchLevel, SERVERPROPERTY(''ProductUpdateLevel'') AS CumulativeUpdate, SERVERPROPERTY(''Edition'') AS Edition' -ServerInstance '.' -TrustServerCertificate ; Write-Output ('Version: {0}' -f \$result.Version) ; Write-Output ('Patch Level: {0}' -f \$result.PatchLevel) ; Write-Output ('Cumulative Update: {0}' -f \$result.CumulativeUpdate) ; Write-Output ('Edition: {0}' -f \$result.Edition) } catch { Write-Output ('SQL Query Error: {0}' -f \$_.Exception.Message) } ; Write-Output '' ; Write-Output '=== Full Version String ===' ; try { Invoke-Sqlcmd -Query 'SELECT @@VERSION AS FullVersion' -ServerInstance '.' -TrustServerCertificate | Select-Object -ExpandProperty FullVersion } catch { Write-Output 'Could not query SQL Server' }"
```

---

## Phase 2: Pre-Patch Readiness

### Windows Pre-Patch Checklist
Run on ArcBox-Win2K22, ArcBox-Win2K25, or ArcBox-SQL:
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Win2K22 \
    --run-command-name "PrePatchCheck" \
    --location <location> \
    --script "Write-Output '=== PRE-PATCH READINESS CHECK ===' ; Write-Output '' ; Write-Output '--- 1. Disk Space ---' ; Get-PSDrive -PSProvider FileSystem | Select-Object Name, @{Name='FreeGB';Expression={[math]::Round(\$_.Free/1GB,2)}}, @{Name='PctFree';Expression={if((\$_.Used+\$_.Free) -gt 0){[math]::Round(\$_.Free/(\$_.Used+\$_.Free)*100,1)}else{'N/A'}}} | Format-Table -AutoSize ; \$cFree = (Get-PSDrive C).Free/1GB ; if (\$cFree -lt 5) { Write-Output 'WARNING: Less than 5GB free on C: drive. Clean up before patching.' } else { Write-Output ('OK: C: drive has {0:N1}GB free' -f \$cFree) } ; Write-Output '' ; Write-Output '--- 2. Pending Reboot Check ---' ; \$pendingReboot = \$false ; if (Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Component Based Servicing\\RebootPending' -ErrorAction SilentlyContinue) { \$pendingReboot = \$true } ; if (Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\WindowsUpdate\\Auto Update\\RebootRequired' -ErrorAction SilentlyContinue) { \$pendingReboot = \$true } ; if (\$pendingReboot) { Write-Output 'WARNING: Server has a pending reboot. Reboot before applying new patches.' } else { Write-Output 'OK: No pending reboot' } ; Write-Output '' ; Write-Output '--- 3. Critical Services ---' ; \$critSvcs = @('WinRM','EventLog','WinDefend','Sense','himds') ; foreach (\$svc in \$critSvcs) { \$s = Get-Service -Name \$svc -ErrorAction SilentlyContinue ; if (\$s -and \$s.Status -eq 'Running') { Write-Output ('OK: {0} is Running' -f \$svc) } elseif (\$s) { Write-Output ('WARNING: {0} is {1}' -f \$svc, \$s.Status) } else { Write-Output ('INFO: {0} not installed' -f \$svc) } } ; Write-Output '' ; Write-Output '--- 4. Uptime ---' ; \$uptime = (Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime ; Write-Output ('Server uptime: {0} days, {1} hours' -f \$uptime.Days, \$uptime.Hours)"
```

### Linux Pre-Patch Checklist
Run on ArcBox-Ubuntu-01 or ArcBox-Ubuntu-02:
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Ubuntu-01 \
    --run-command-name "PrePatchCheck" \
    --location <location> \
    --script "echo '=== PRE-PATCH READINESS CHECK ===' && echo '' && echo '--- 1. Disk Space ---' && df -h / /var /boot 2>/dev/null && root_avail=$(df / --output=avail -BG | tail -1 | tr -d ' G') && if [ \"$root_avail\" -lt 5 ]; then echo 'WARNING: Less than 5GB free on /. Clean up before patching.'; else echo \"OK: / has ${root_avail}GB free\"; fi && echo '' && echo '--- 2. Pending Reboot Check ---' && if [ -f /var/run/reboot-required ]; then echo 'WARNING: Reboot required before applying new patches'; cat /var/run/reboot-required.pkgs 2>/dev/null; else echo 'OK: No pending reboot'; fi && echo '' && echo '--- 3. APT Lock Check ---' && if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then echo 'WARNING: APT lock is held by another process'; fuser -v /var/lib/dpkg/lock-frontend 2>&1; else echo 'OK: No APT lock'; fi && echo '' && echo '--- 4. Critical Services ---' && for svc in ssh cron rsyslog mdatp himdsd; do status=$(systemctl is-active $svc 2>/dev/null || echo 'not-found'); if [ \"$status\" = 'active' ]; then echo \"OK: $svc is active\"; elif [ \"$status\" = 'not-found' ]; then echo \"INFO: $svc not installed\"; else echo \"WARNING: $svc is $status\"; fi; done && echo '' && echo '--- 5. Uptime ---' && uptime"
```

### SQL Pre-Patch Checklist (ArcBox-SQL Only)
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-SQL \
    --run-command-name "SQLPrePatchCheck" \
    --location <location> \
    --script "Write-Output '=== SQL PRE-PATCH READINESS ===' ; Write-Output '' ; Write-Output '--- 1. SQL Service Status ---' ; Get-Service MSSQLSERVER, SQLSERVERAGENT -ErrorAction SilentlyContinue | Select-Object Name, Status | Format-Table -AutoSize ; Write-Output '' ; Write-Output '--- 2. Database Status ---' ; try { Invoke-Sqlcmd -Query 'SELECT name, state_desc FROM sys.databases WHERE state_desc != ''ONLINE''' -ServerInstance '.' -TrustServerCertificate | Format-Table -AutoSize ; \$offlineDBs = (Invoke-Sqlcmd -Query 'SELECT COUNT(*) AS cnt FROM sys.databases WHERE state_desc != ''ONLINE''' -ServerInstance '.' -TrustServerCertificate).cnt ; if (\$offlineDBs -gt 0) { Write-Output ('WARNING: {0} databases are not ONLINE' -f \$offlineDBs) } else { Write-Output 'OK: All databases are ONLINE' } } catch { Write-Output ('SQL Error: {0}' -f \$_.Exception.Message) } ; Write-Output '' ; Write-Output '--- 3. Recent Backup Check ---' ; try { Invoke-Sqlcmd -Query \"SELECT d.name AS DatabaseName, CASE WHEN MAX(b.backup_finish_date) IS NULL THEN 'NEVER' ELSE CONVERT(VARCHAR, MAX(b.backup_finish_date), 120) END AS LastBackup, DATEDIFF(HOUR, MAX(b.backup_finish_date), GETDATE()) AS HoursAgo FROM sys.databases d LEFT JOIN msdb.dbo.backupset b ON d.name = b.database_name WHERE d.database_id > 4 GROUP BY d.name ORDER BY d.name\" -ServerInstance '.' -TrustServerCertificate | Format-Table -AutoSize } catch { Write-Output 'Could not query backup history' } ; Write-Output '' ; Write-Output '--- 4. Active Connections ---' ; try { \$connCount = (Invoke-Sqlcmd -Query 'SELECT COUNT(*) AS cnt FROM sys.dm_exec_sessions WHERE is_user_process = 1' -ServerInstance '.' -TrustServerCertificate).cnt ; Write-Output ('Active user connections: {0}' -f \$connCount) ; if (\$connCount -gt 50) { Write-Output 'WARNING: High number of active connections. Consider scheduling patch during low-usage window.' } } catch { Write-Output 'Could not query connections' }"
```

---

## Phase 3: Patch Deployment

### 3.1 Deploy Patches via Azure Update Manager CLI
```bash
# Install all Critical and Security patches on a Windows server
az connectedmachine install-patches \
    --resource-group <resourceGroup> \
    --name ArcBox-Win2K22 \
    --maximum-duration "PT2H" \
    --reboot-setting "IfRequired" \
    --windows-parameters classificationsToInclude="Critical" classificationsToInclude="Security"

# Install all patches on a Linux server
az connectedmachine install-patches \
    --resource-group <resourceGroup> \
    --name ArcBox-Ubuntu-01 \
    --maximum-duration "PT2H" \
    --reboot-setting "IfRequired" \
    --linux-parameters classificationsToInclude="Security" classificationsToInclude="Critical"
```

### 3.2 Install Specific KB (Windows)
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Win2K22 \
    --run-command-name "InstallSpecificKB" \
    --location <location> \
    --script "\$session = New-Object -ComObject Microsoft.Update.Session ; \$searcher = \$session.CreateUpdateSearcher() ; \$searchResult = \$searcher.Search(\"IsInstalled=0 AND Type='Software'\") ; \$kbTarget = 'KB5034441' ; \$targetUpdate = \$searchResult.Updates | Where-Object { \$_.Title -match \$kbTarget } ; if (\$targetUpdate) { Write-Output ('Found: {0}' -f \$targetUpdate.Title) ; \$updatesToInstall = New-Object -ComObject Microsoft.Update.UpdateColl ; \$updatesToInstall.Add(\$targetUpdate) | Out-Null ; \$installer = \$session.CreateUpdateInstaller() ; \$installer.Updates = \$updatesToInstall ; \$result = \$installer.Install() ; Write-Output ('Result: {0}' -f \$result.ResultCode) } else { Write-Output ('KB {0} not found in available updates' -f \$kbTarget) }"
```

### 3.3 Install Specific Package (Linux)
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Ubuntu-01 \
    --run-command-name "InstallSpecificPkg" \
    --location <location> \
    --script "echo '=== Updating package list ===' && apt-get update -qq && echo '' && echo '=== Installing security updates only ===' && DEBIAN_FRONTEND=noninteractive apt-get -s upgrade | grep -i security | head -20 && echo '' && echo 'Run with apt-get upgrade (remove -s) to apply'"
```

### 3.4 Recommended Wave Strategy

| Wave | Servers | Timing | Approval |
|---|---|---|---|
| Wave 1 (Dev/Test) | ArcBox-Ubuntu-02 (Monitoring) | Patch Tuesday + 1 day | Auto-approve |
| Wave 2 (Non-Critical) | ArcBox-Ubuntu-01, ArcBox-Win2K25 | Patch Tuesday + 3 days | Auto-approve |
| Wave 3 (Critical) | ArcBox-Win2K22, ArcBox-SQL | Patch Tuesday + 7 days | Manual approval |

---

## Phase 4: Post-Patch Validation

### Windows Post-Patch Validation
Run on ArcBox-Win2K22, ArcBox-Win2K25, or ArcBox-SQL:
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Win2K22 \
    --run-command-name "PostPatchValidation" \
    --location <location> \
    --script "Write-Output '=== POST-PATCH VALIDATION ===' ; Write-Output '' ; Write-Output '--- 1. Last Boot Time ---' ; \$lastBoot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime ; Write-Output ('Last boot: {0}' -f \$lastBoot) ; Write-Output ('Uptime: {0}' -f ((Get-Date) - \$lastBoot)) ; Write-Output '' ; Write-Output '--- 2. Critical Services ---' ; \$critSvcs = @('WinRM','EventLog','W32Time','WinDefend','Sense','himds','GCArcService','ExtensionService') ; foreach (\$svc in \$critSvcs) { \$s = Get-Service -Name \$svc -ErrorAction SilentlyContinue ; if (\$s) { \$status = if (\$s.Status -eq 'Running') { 'OK' } else { 'FAIL' } ; Write-Output ('{0}: {1} - {2}' -f \$status, \$svc, \$s.Status) } } ; Write-Output '' ; Write-Output '--- 3. Latest Hotfixes ---' ; Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 5 HotFixID, Description, InstalledOn | Format-Table -AutoSize ; Write-Output '' ; Write-Output '--- 4. Crash Dumps Check ---' ; \$dumps = Get-ChildItem 'C:\\Windows\\Minidump' -ErrorAction SilentlyContinue ; if (\$dumps) { Write-Output ('WARNING: {0} crash dump(s) found' -f \$dumps.Count) ; \$dumps | Select-Object Name, LastWriteTime | Format-Table -AutoSize } else { Write-Output 'OK: No crash dumps found' } ; Write-Output '' ; Write-Output '--- 5. Pending Reboot ---' ; \$pendingReboot = \$false ; if (Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Component Based Servicing\\RebootPending' -ErrorAction SilentlyContinue) { \$pendingReboot = \$true } ; if (Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\WindowsUpdate\\Auto Update\\RebootRequired' -ErrorAction SilentlyContinue) { \$pendingReboot = \$true } ; if (\$pendingReboot) { Write-Output 'WARNING: Reboot still pending after patching' } else { Write-Output 'OK: No pending reboot' } ; Write-Output '' ; Write-Output '--- 6. Event Log Errors Since Boot ---' ; \$errorCount = (Get-EventLog -LogName System -EntryType Error -After \$lastBoot -ErrorAction SilentlyContinue | Measure-Object).Count ; Write-Output ('System errors since last boot: {0}' -f \$errorCount) ; if (\$errorCount -gt 10) { Write-Output 'WARNING: Elevated error count. Review Event Viewer.' }"
```

### Linux Post-Patch Validation
Run on ArcBox-Ubuntu-01 or ArcBox-Ubuntu-02:
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Ubuntu-01 \
    --run-command-name "PostPatchValidation" \
    --location <location> \
    --script "echo '=== POST-PATCH VALIDATION ===' && echo '' && echo '--- 1. Uptime and Kernel ---' && uptime && echo \"Kernel: $(uname -r)\" && echo '' && echo '--- 2. Critical Services ---' && for svc in ssh cron rsyslog ufw mdatp himdsd gcad extd; do status=$(systemctl is-active $svc 2>/dev/null || echo 'not-found'); if [ \"$status\" = 'active' ]; then echo \"OK: $svc is active\"; elif [ \"$status\" = 'not-found' ]; then echo \"INFO: $svc not installed\"; else echo \"FAIL: $svc is $status\"; fi; done && echo '' && echo '--- 3. Remaining Upgradable Packages ---' && upgradable=$(apt list --upgradable 2>/dev/null | grep -c upgradable) && echo \"Upgradable packages remaining: $upgradable\" && echo '' && echo '--- 4. Reboot Required ---' && if [ -f /var/run/reboot-required ]; then echo 'WARNING: Reboot required'; else echo 'OK: No reboot required'; fi && echo '' && echo '--- 5. Disk Space After Patch ---' && df -h / /var /boot 2>/dev/null && echo '' && echo '--- 6. Journal Errors Since Boot ---' && error_count=$(journalctl -b -p err --no-pager 2>/dev/null | wc -l) && echo \"Errors since boot: $error_count\" && if [ \"$error_count\" -gt 20 ]; then echo 'WARNING: Elevated error count. Review with journalctl -b -p err'; fi"
```

### SQL Post-Patch Validation (ArcBox-SQL Only)
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-SQL \
    --run-command-name "SQLPostPatchValidation" \
    --location <location> \
    --script "Write-Output '=== SQL POST-PATCH VALIDATION ===' ; Write-Output '' ; Write-Output '--- 1. SQL Service Status ---' ; Get-Service MSSQLSERVER, SQLSERVERAGENT -ErrorAction SilentlyContinue | Select-Object Name, Status | Format-Table -AutoSize ; Write-Output '' ; Write-Output '--- 2. Database Status ---' ; try { Invoke-Sqlcmd -Query 'SELECT name, state_desc, recovery_model_desc FROM sys.databases ORDER BY name' -ServerInstance '.' -TrustServerCertificate | Format-Table -AutoSize } catch { Write-Output ('SQL Error: {0}' -f \$_.Exception.Message) } ; Write-Output '' ; Write-Output '--- 3. SQL Version (Post-Patch) ---' ; try { \$ver = Invoke-Sqlcmd -Query 'SELECT SERVERPROPERTY(''ProductVersion'') AS Version, SERVERPROPERTY(''ProductUpdateLevel'') AS CU' -ServerInstance '.' -TrustServerCertificate ; Write-Output ('SQL Version: {0}, CU: {1}' -f \$ver.Version, \$ver.CU) } catch { Write-Output 'Could not query SQL version' } ; Write-Output '' ; Write-Output '--- 4. DBCC CHECKDB (user databases) ---' ; try { \$dbs = Invoke-Sqlcmd -Query 'SELECT name FROM sys.databases WHERE database_id > 4 AND state_desc = ''ONLINE''' -ServerInstance '.' -TrustServerCertificate ; foreach (\$db in \$dbs) { Write-Output ('Running DBCC CHECKDB on {0}...' -f \$db.name) ; try { Invoke-Sqlcmd -Query ('DBCC CHECKDB ([{0}]) WITH NO_INFOMSGS, ALL_ERRORMSGS' -f \$db.name) -ServerInstance '.' -TrustServerCertificate -QueryTimeout 300 ; Write-Output ('OK: {0} passed integrity check' -f \$db.name) } catch { Write-Output ('FAIL: {0} - {1}' -f \$db.name, \$_.Exception.Message) } } } catch { Write-Output 'Could not enumerate databases' } ; Write-Output '' ; Write-Output '--- 5. SQL Error Log (Last 50 entries) ---' ; try { Invoke-Sqlcmd -Query \"EXEC sp_readerrorlog 0, 1, NULL, NULL\" -ServerInstance '.' -TrustServerCertificate | Select-Object -Last 20 LogDate, ProcessInfo, Text | Format-Table -Wrap -AutoSize } catch { Write-Output 'Could not read SQL error log' }"
```

---

## Phase 5: Rollback

### 5.1 Uninstall Specific KB — Windows
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Win2K22 \
    --run-command-name "RollbackKB" \
    --location <location> \
    --script "\$kbId = 'KB5034441' ; Write-Output ('=== Uninstalling {0} ===' -f \$kbId) ; \$installed = Get-HotFix -Id \$kbId -ErrorAction SilentlyContinue ; if (\$installed) { Write-Output ('Found: {0} installed on {1}' -f \$kbId, \$installed.InstalledOn) ; \$result = Start-Process -FilePath 'wusa.exe' -ArgumentList ('/uninstall /kb:{0} /quiet /norestart' -f \$kbId.Replace('KB','')) -Wait -PassThru ; Write-Output ('Exit code: {0}' -f \$result.ExitCode) ; switch (\$result.ExitCode) { 0 { Write-Output 'Uninstall succeeded' } 3010 { Write-Output 'Uninstall succeeded - reboot required' } 2359303 { Write-Output 'Update not applicable or already removed' } default { Write-Output 'Uninstall may have failed. Check CBS log.' } } } else { Write-Output ('{0} is not installed on this server' -f \$kbId) }"
```

### 5.2 Rollback Package — Linux
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Ubuntu-01 \
    --run-command-name "RollbackPkg" \
    --location <location> \
    --script "PACKAGE='openssl' && echo \"=== Rollback $PACKAGE ===\" && echo '--- Current Version ---' && dpkg -l $PACKAGE 2>/dev/null | tail -1 && echo '' && echo '--- Available Versions ---' && apt-cache policy $PACKAGE && echo '' && echo '--- To rollback, run: ---' && echo \"apt-get install $PACKAGE=<old-version> -y --allow-downgrades\" && echo '' && echo '--- Recent Package Changes ---' && grep $PACKAGE /var/log/dpkg.log 2>/dev/null | tail -10 || echo 'No recent changes found in dpkg log'"
```

### 5.3 SQL Server CU Rollback (ArcBox-SQL Only)
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-SQL \
    --run-command-name "SQLCURollback" \
    --location <location> \
    --script "Write-Output '=== SQL Server CU Rollback Procedure ===' ; Write-Output '' ; Write-Output '--- Current SQL Version ---' ; try { Invoke-Sqlcmd -Query 'SELECT SERVERPROPERTY(''ProductVersion'') AS Version, SERVERPROPERTY(''ProductLevel'') AS Level, SERVERPROPERTY(''ProductUpdateLevel'') AS CU' -ServerInstance '.' -TrustServerCertificate | Format-List } catch { Write-Output 'Could not query SQL version' } ; Write-Output '' ; Write-Output '--- Installed SQL Updates ---' ; Get-HotFix | Where-Object { \$_.Description -match 'Update' -and \$_.HotFixID -match 'KB' } | Sort-Object InstalledOn -Descending | Select-Object HotFixID, Description, InstalledOn | Format-Table -AutoSize ; Write-Output '' ; Write-Output '--- CU Rollback Steps ---' ; Write-Output '1. Stop SQL Server: Stop-Service MSSQLSERVER -Force' ; Write-Output '2. Uninstall CU: wusa.exe /uninstall /kb:<CU_KB> /quiet /norestart' ; Write-Output '3. Restart server: Restart-Computer -Force' ; Write-Output '4. Verify SQL version after reboot' ; Write-Output '5. Run DBCC CHECKDB on all databases' ; Write-Output '' ; Write-Output 'WARNING: SQL CU rollback may require re-running recovery on databases. Ensure backups exist before proceeding.'"
```

---

## Phase 6: Compliance Reporting

### 6.1 Overall Compliance Summary (KQL)
```kql
patchassessmentresources
| where type == "microsoft.hybridcompute/machines/patchassessmentresults"
| extend machineName = tostring(split(id, '/')[8])
| extend criticalMissing = toint(properties.availablePatchCountByClassification.critical)
| extend securityMissing = toint(properties.availablePatchCountByClassification.security)
| extend totalMissing = criticalMissing + securityMissing
| extend complianceStatus = case(
    totalMissing == 0, "Compliant",
    criticalMissing > 0, "Non-Compliant (Critical)",
    "Non-Compliant (Security)"
)
| project machineName, complianceStatus, criticalMissing, securityMissing,
    lastAssessment = properties.lastModifiedDateTime,
    rebootPending = properties.rebootPending
| order by totalMissing desc
```

### 6.2 Patch History via KQL
```kql
patchinstallationresources
| where type == "microsoft.hybridcompute/machines/patchinstallationresults"
| extend machineName = tostring(split(id, '/')[8])
| project machineName,
    installationTime = properties.lastModifiedDateTime,
    status = properties.status,
    installedCount = properties.installedPatchCount,
    failedCount = properties.failedPatchCount,
    pendingCount = properties.pendingPatchCount,
    rebootStatus = properties.rebootStatus,
    maintenanceWindowExceeded = properties.maintenanceWindowExceeded
| order by installationTime desc
```

---

## Rollback Decision Tree

| Priority | Condition | Action |
|---|---|---|
| **P1 — Critical** | Server down, SQL databases in suspect state, data loss risk | Immediate rollback, restore from backup, escalate to Microsoft Support |
| **P2 — High** | Critical service not starting, application errors after patch | Rollback specific KB/package, restart services, validate |
| **P3 — Medium** | Performance degradation, non-critical service affected | Monitor for 1 hour, rollback if no improvement |
| **P4 — Low** | Cosmetic issues, minor warnings in event logs | Document and monitor, rollback in next maintenance window if needed |

### Rollback General Procedure
1. **Identify** the problematic patch (KB/package) from post-patch validation
2. **Verify backup** exists for the server (VM snapshot or system backup)
3. **Notify stakeholders** of planned rollback
4. **Execute rollback** using the appropriate method (wusa /uninstall, apt downgrade, SQL CU removal)
5. **Reboot** if required
6. **Validate** all services are running and application is functional
7. **Document** the issue and root cause for the patch vendor

---

## Phase 7: Send Analysis Email

After completing patch assessment or deployment, send a summary to stakeholders.

**Send to:** sre-team@contoso.com

### Email Structure

**Subject:** `[Patch Report] {date} - ArcBox Server Patch Status`

**Body should include:**

1. **Patch Summary**
   - Assessment date, servers assessed, overall compliance status
   - Count of critical/security/other missing patches per server

2. **Deployment Results** (if patches were applied)
   - Servers patched, success/failure count
   - Reboot status per server
   - Any failed patches with error details

3. **Post-Patch Validation**
   - Service health per server
   - Database integrity results (SQL)
   - Any new errors in event logs

4. **Action Items**
   - Servers needing manual intervention
   - Failed patches requiring investigation
   - Next patch window schedule

5. **Links**
   - Azure Update Manager dashboard link
   - Log Analytics workspace query link

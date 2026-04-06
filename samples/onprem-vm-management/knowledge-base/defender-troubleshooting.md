# Defender for Endpoint Troubleshooting Runbook

## Trigger Keywords
`Defender unhealthy`, `MDE`, `security agent`, `antivirus disabled`, `Sense service`, `mdatp`, `real-time protection`, `signature outdated`, `tamper protection`, `EDR`, `endpoint protection`

## Scope
Microsoft Defender for Endpoint (MDE) on Azure Arc-enrolled Windows and Linux servers in the ArcBox demo environment. Covers both the MDE extension health and the on-host agent state.

### ArcBox Server Inventory
| Server | OS | MDE Extension Type |
|---|---|---|
| ArcBox-Win2K22 | Windows Server 2022 | MDE.Windows |
| ArcBox-Win2K25 | Windows Server 2025 | MDE.Windows |
| ArcBox-SQL | Windows Server 2022 + SQL 2022 | MDE.Windows |
| ArcBox-Ubuntu-01 | Ubuntu 22.04 LTS | MDE.Linux |
| ArcBox-Ubuntu-02 | Ubuntu 22.04 LTS | MDE.Linux |

---

## Phase 1: Extension Health

### 1.1 Check MDE Extension Status — All Servers
```bash
# Check MDE extension for a specific Windows server
az connectedmachine extension list \
    --machine-name ArcBox-Win2K22 \
    --resource-group <resourceGroup> \
    --query "[?contains(properties.type,'MDE') || contains(properties.type,'MicrosoftDefenderForEndpoint')].{Name:name, Type:properties.type, Status:properties.provisioningState, Version:properties.typeHandlerVersion}" \
    --output table

# Check MDE extension for a specific Linux server
az connectedmachine extension list \
    --machine-name ArcBox-Ubuntu-01 \
    --resource-group <resourceGroup> \
    --query "[?contains(properties.type,'MDE') || contains(properties.type,'MicrosoftDefenderForEndpoint')].{Name:name, Type:properties.type, Status:properties.provisioningState, Version:properties.typeHandlerVersion}" \
    --output table
```

### 1.2 Extension Health via Resource Graph
```kql
resources
| where type == "microsoft.hybridcompute/machines/extensions"
| where properties.type contains "MDE" or properties.type contains "MicrosoftDefenderForEndpoint"
| extend machineName = tostring(split(id, '/')[8])
| project machineName, extensionName = name,
    provisioningState = properties.provisioningState,
    extensionType = properties.type,
    version = properties.typeHandlerVersion,
    lastModified = properties.instanceView.status.time
| order by machineName asc
```

### 1.3 Extension Instance View (Detailed Status)
```bash
az connectedmachine extension show \
    --machine-name ArcBox-Win2K22 \
    --resource-group <resourceGroup> \
    --name MDE.Windows \
    --query "{Name:name, Type:properties.type, Status:properties.provisioningState, Message:properties.instanceView.status.message}" \
    --output json
```

---

## Phase 2: Heartbeat Check

### 2.1 MDE Heartbeat via Log Analytics
```kql
Heartbeat
| where TimeGenerated > ago(30m)
| where Computer has "ArcBox"
| summarize LastHeartbeat = max(TimeGenerated) by Computer, OSType, Category
| extend MinutesSinceHeartbeat = datetime_diff('minute', now(), LastHeartbeat)
| extend AgentStatus = case(
    MinutesSinceHeartbeat <= 5, "Healthy",
    MinutesSinceHeartbeat <= 15, "Warning - Delayed",
    "Critical - Not Reporting"
)
| order by MinutesSinceHeartbeat desc
```

### 2.2 MDE Telemetry Check
```kql
// Check if Defender events are flowing
DeviceInfo
| where TimeGenerated > ago(1h)
| where DeviceName has "ArcBox"
| summarize LastSeen = max(TimeGenerated) by DeviceName, OSPlatform, OnboardingStatus, SensorHealthState
| order by DeviceName asc
```

### 2.3 Security Alert Activity
```kql
SecurityAlert
| where TimeGenerated > ago(24h)
| where CompromisedEntity has "ArcBox"
| summarize AlertCount = count() by CompromisedEntity, AlertName, AlertSeverity, ProviderName
| order by AlertCount desc
```

---

## Phase 3: Windows MDE Diagnostics

### 3.1 Service Status
Run on ArcBox-Win2K22, ArcBox-Win2K25, or ArcBox-SQL:
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Win2K22 \
    --run-command-name "MDEServiceCheck" \
    --location <location> \
    --script "Write-Output '=== Defender Services ===' ; \$services = @('WinDefend','Sense','MdCoreSvc','MpsSvc') ; foreach (\$svc in \$services) { \$s = Get-Service -Name \$svc -ErrorAction SilentlyContinue ; if (\$s) { Write-Output ('{0}: Status={1}, StartType={2}' -f \$s.Name, \$s.Status, \$s.StartType) } else { Write-Output ('{0}: NOT INSTALLED' -f \$svc) } } ; Write-Output '' ; Write-Output '=== WdFilter Driver ===' ; fltmc | Select-String -Pattern 'WdFilter'"
```

### 3.2 Protection Status
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Win2K22 \
    --run-command-name "MDEProtectionStatus" \
    --location <location> \
    --script "Write-Output '=== Defender Protection Status ===' ; try { \$status = Get-MpComputerStatus ; Write-Output ('Real-Time Protection Enabled: {0}' -f \$status.RealTimeProtectionEnabled) ; Write-Output ('Behavior Monitor Enabled: {0}' -f \$status.BehaviorMonitorEnabled) ; Write-Output ('On Access Protection Enabled: {0}' -f \$status.OnAccessProtectionEnabled) ; Write-Output ('Antivirus Enabled: {0}' -f \$status.AntivirusEnabled) ; Write-Output ('Antispyware Enabled: {0}' -f \$status.AntispywareEnabled) ; Write-Output ('Tamper Protection Source: {0}' -f \$status.TamperProtectionSource) ; Write-Output '' ; Write-Output '=== Signature Info ===' ; Write-Output ('Antivirus Signature Version: {0}' -f \$status.AntivirusSignatureVersion) ; Write-Output ('Antivirus Signature Age (days): {0}' -f \$status.AntivirusSignatureAge) ; Write-Output ('Antivirus Signature Last Updated: {0}' -f \$status.AntivirusSignatureLastUpdated) ; Write-Output ('Antispyware Signature Version: {0}' -f \$status.AntispywareSignatureVersion) ; Write-Output '' ; Write-Output '=== Last Scan ===' ; Write-Output ('Quick Scan End Time: {0}' -f \$status.QuickScanEndTime) ; Write-Output ('Full Scan End Time: {0}' -f \$status.FullScanEndTime) ; Write-Output ('Quick Scan Age (days): {0}' -f \$status.QuickScanAge) } catch { Write-Output ('Error: {0}' -f \$_.Exception.Message) }"
```

### 3.3 Connectivity Test
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Win2K22 \
    --run-command-name "MDEConnectivity" \
    --location <location> \
    --script "Write-Output '=== MDE Cloud Connectivity ===' ; \$endpoints = @('winatp-gw-cne3.microsoft.com','winatp-gw-cus3.microsoft.com','us.vortex-win.data.microsoft.com','us-v20.events.data.microsoft.com','settings-win.data.microsoft.com') ; foreach (\$ep in \$endpoints) { \$result = Test-NetConnection -ComputerName \$ep -Port 443 -WarningAction SilentlyContinue ; Write-Output ('{0}:443 - Connected={1} (Latency={2}ms)' -f \$ep, \$result.TcpTestSucceeded, \$result.PingReplyDetails.RoundtripTime) } ; Write-Output '' ; Write-Output '=== CRL Connectivity ===' ; Test-NetConnection -ComputerName crl.microsoft.com -Port 80 -WarningAction SilentlyContinue | Select-Object ComputerName, TcpTestSucceeded | Format-List"
```

### 3.4 Event Logs
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Win2K22 \
    --run-command-name "MDEEventLogs" \
    --location <location> \
    --script "Write-Output '=== Defender Operational Events (Last 1 Hour) ===' ; Get-WinEvent -LogName 'Microsoft-Windows-Windows Defender/Operational' -MaxEvents 30 -ErrorAction SilentlyContinue | Where-Object { \$_.TimeCreated -gt (Get-Date).AddHours(-1) } | Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-Table -Wrap -AutoSize ; Write-Output '=== Sense (EDR) Events ===' ; Get-WinEvent -LogName 'Microsoft-Windows-SENSE/Operational' -MaxEvents 15 -ErrorAction SilentlyContinue | Where-Object { \$_.TimeCreated -gt (Get-Date).AddHours(-1) } | Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-Table -Wrap -AutoSize"
```

### 3.5 Threat Detection History — Windows
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Win2K22 \
    --run-command-name "MDEThreatHistory" \
    --location <location> \
    --script "Write-Output '=== Recent Threat Detections ===' ; Get-MpThreatDetection | Select-Object -First 10 DetectionID, @{Name='ThreatName';Expression={(Get-MpThreat -ThreatID \$_.ThreatID -ErrorAction SilentlyContinue).ThreatName}}, InitialDetectionTime, LastThreatStatusChangeTime, ActionSuccess | Format-Table -AutoSize ; Write-Output '' ; Write-Output '=== Active Threats ===' ; Get-MpThreat -ErrorAction SilentlyContinue | Where-Object { \$_.IsActive -eq \$true } | Select-Object ThreatID, ThreatName, SeverityID | Format-Table -AutoSize"
```

---

## Phase 4: Linux MDE Diagnostics

### 4.1 Service Status
Run on ArcBox-Ubuntu-01 or ArcBox-Ubuntu-02:
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Ubuntu-01 \
    --run-command-name "MDEServiceCheck" \
    --location <location> \
    --script "echo '=== MDE Service Status ===' && systemctl status mdatp --no-pager 2>/dev/null || echo 'mdatp service not found' && echo '' && echo '=== MDE Package Info ===' && dpkg -l mdatp 2>/dev/null | tail -3 || rpm -qa mdatp 2>/dev/null || echo 'mdatp package not found'"
```

### 4.2 Health Check
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Ubuntu-01 \
    --run-command-name "MDEHealthCheck" \
    --location <location> \
    --script "echo '=== Full MDE Health ===' && mdatp health 2>/dev/null || echo 'mdatp command not found' && echo '' && echo '=== Key Health Fields ===' && echo 'Real-time protection:' && mdatp health --field real_time_protection_enabled 2>/dev/null && echo 'Definitions status:' && mdatp health --field definitions_status 2>/dev/null && echo 'Definitions updated:' && mdatp health --field definitions_updated 2>/dev/null && echo 'Engine version:' && mdatp health --field engine_version 2>/dev/null && echo 'App version:' && mdatp health --field app_version 2>/dev/null && echo 'Org ID:' && mdatp health --field org_id 2>/dev/null && echo 'EDR early preview:' && mdatp health --field edr_early_preview_enabled 2>/dev/null && echo 'Healthy:' && mdatp health --field healthy 2>/dev/null"
```

### 4.3 Connectivity Test
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Ubuntu-01 \
    --run-command-name "MDEConnectivity" \
    --location <location> \
    --script "echo '=== MDE Cloud Connectivity ===' && mdatp connectivity test 2>/dev/null || echo 'mdatp connectivity test not available' && echo '' && echo '=== Manual Endpoint Checks ===' && for ep in winatp-gw-cne3.microsoft.com winatp-gw-cus3.microsoft.com us.vortex-win.data.microsoft.com settings-win.data.microsoft.com; do result=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 https://$ep 2>/dev/null); echo \"$ep: HTTP $result\"; done && echo '' && echo '=== CRL Check ===' && curl -s -o /dev/null -w 'crl.microsoft.com: HTTP %{http_code}\n' --connect-timeout 5 http://crl.microsoft.com"
```

### 4.4 Logs
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Ubuntu-01 \
    --run-command-name "MDELogs" \
    --location <location> \
    --script "echo '=== MDE Journal Logs (Last 1 Hour) ===' && journalctl -u mdatp --since '1 hour ago' --no-pager | tail -50 && echo '' && echo '=== MDE Diagnostic Log (Errors) ===' && if [ -d /var/log/microsoft/mdatp ]; then grep -i 'error\\|fail\\|critical' /var/log/microsoft/mdatp/*.log 2>/dev/null | tail -30; else echo 'MDE log directory not found'; fi"
```

### 4.5 Threat Detection History — Linux
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Ubuntu-01 \
    --run-command-name "MDEThreatHistory" \
    --location <location> \
    --script "echo '=== Recent Threat Detections ===' && mdatp threat list 2>/dev/null || echo 'No threats found or mdatp not available' && echo '' && echo '=== Quarantined Items ===' && mdatp threat quarantine list 2>/dev/null || echo 'No quarantined items'"
```

---

## Phase 5: Remediation

### Windows Remediation

#### 5.1 Start Defender Services
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Win2K22 \
    --run-command-name "StartDefenderServices" \
    --location <location> \
    --script "Write-Output '=== Starting Defender Services ===' ; \$services = @('WinDefend','Sense','MdCoreSvc') ; foreach (\$svc in \$services) { try { Start-Service -Name \$svc -ErrorAction Stop ; Write-Output ('{0}: Started successfully' -f \$svc) } catch { Write-Output ('{0}: Failed to start - {1}' -f \$svc, \$_.Exception.Message) } } ; Start-Sleep -Seconds 5 ; Write-Output '' ; Write-Output '=== Post-Restart Status ===' ; foreach (\$svc in \$services) { \$s = Get-Service -Name \$svc -ErrorAction SilentlyContinue ; if (\$s) { Write-Output ('{0}: {1}' -f \$s.Name, \$s.Status) } }"
```

#### 5.2 Update Signatures
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Win2K22 \
    --run-command-name "UpdateSignatures" \
    --location <location> \
    --script "Write-Output '=== Updating Defender Signatures ===' ; try { Update-MpSignature -ErrorAction Stop ; Write-Output 'Signature update initiated successfully' } catch { Write-Output ('Failed to update signatures: {0}' -f \$_.Exception.Message) } ; Start-Sleep -Seconds 10 ; Write-Output '' ; Write-Output '=== Updated Signature Status ===' ; \$status = Get-MpComputerStatus ; Write-Output ('Signature Version: {0}' -f \$status.AntivirusSignatureVersion) ; Write-Output ('Signature Age (days): {0}' -f \$status.AntivirusSignatureAge) ; Write-Output ('Last Updated: {0}' -f \$status.AntivirusSignatureLastUpdated)"
```

#### 5.3 Enable Real-Time Protection
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Win2K22 \
    --run-command-name "EnableRTP" \
    --location <location> \
    --script "Write-Output '=== Enabling Real-Time Protection ===' ; try { Set-MpPreference -DisableRealtimeMonitoring \$false -ErrorAction Stop ; Write-Output 'Real-time protection enabled' } catch { Write-Output ('Failed: {0}' -f \$_.Exception.Message) } ; Set-MpPreference -DisableBehaviorMonitoring \$false -ErrorAction SilentlyContinue ; Set-MpPreference -DisableIOAVProtection \$false -ErrorAction SilentlyContinue ; Write-Output '' ; \$status = Get-MpComputerStatus ; Write-Output ('Real-Time Protection: {0}' -f \$status.RealTimeProtectionEnabled) ; Write-Output ('Behavior Monitor: {0}' -f \$status.BehaviorMonitorEnabled)"
```

#### 5.4 Run Quick Scan — Windows
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Win2K22 \
    --run-command-name "QuickScan" \
    --location <location> \
    --script "Write-Output '=== Starting Quick Scan ===' ; Start-MpScan -ScanType QuickScan -AsJob ; Write-Output 'Quick scan initiated. Check Get-MpComputerStatus for completion.'"
```

### Linux Remediation

#### 5.5 Restart MDE Service
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Ubuntu-01 \
    --run-command-name "RestartMDE" \
    --location <location> \
    --script "echo '=== Restarting MDE Service ===' && systemctl restart mdatp && sleep 5 && echo '=== Post-Restart Status ===' && systemctl is-active mdatp && echo '' && echo '=== Health After Restart ===' && mdatp health --field healthy 2>/dev/null && mdatp health --field real_time_protection_enabled 2>/dev/null"
```

#### 5.6 Update Definitions — Linux
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Ubuntu-01 \
    --run-command-name "UpdateDefinitions" \
    --location <location> \
    --script "echo '=== Updating MDE Definitions ===' && mdatp definitions update 2>/dev/null && echo 'Definitions update initiated' && sleep 10 && echo '' && echo '=== Updated Definition Status ===' && mdatp health --field definitions_status 2>/dev/null && mdatp health --field definitions_updated 2>/dev/null"
```

#### 5.7 Enable Real-Time Protection — Linux
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Ubuntu-01 \
    --run-command-name "EnableRTP" \
    --location <location> \
    --script "echo '=== Enabling Real-Time Protection ===' && mdatp config real-time-protection --value enabled 2>/dev/null && echo 'Real-time protection enabled' && echo '' && mdatp health --field real_time_protection_enabled 2>/dev/null"
```

#### 5.8 Run Quick Scan — Linux
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Ubuntu-01 \
    --run-command-name "QuickScan" \
    --location <location> \
    --script "echo '=== Starting Quick Scan ===' && mdatp scan quick 2>/dev/null &"
```

---

## Phase 6: Proxy Configuration (On-Prem Specific)

### 6.1 Check Current Proxy — Windows
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Win2K22 \
    --run-command-name "CheckProxy" \
    --location <location> \
    --script "Write-Output '=== WinHTTP Proxy ===' ; netsh winhttp show proxy ; Write-Output '' ; Write-Output '=== System Proxy (IE Settings) ===' ; Get-ItemProperty 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings' | Select-Object ProxyEnable, ProxyServer, ProxyOverride | Format-List ; Write-Output '' ; Write-Output '=== Defender Proxy ===' ; Get-MpPreference | Select-Object ProxyServer, ProxyBypass, ProxyPacUrl | Format-List"
```

### 6.2 Configure Proxy — Windows
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Win2K22 \
    --run-command-name "SetProxy" \
    --location <location> \
    --script "# Set WinHTTP proxy for MDE cloud communication\nnetsh winhttp set proxy proxy-server='http://proxy.contoso.com:8080' bypass-list='*.contoso.com;localhost;127.0.0.1'\nWrite-Output 'WinHTTP proxy configured'\nWrite-Output '' \nWrite-Output '=== Verify ===' \nnetsh winhttp show proxy"
```

### 6.3 Check Current Proxy — Linux
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Ubuntu-01 \
    --run-command-name "CheckProxy" \
    --location <location> \
    --script "echo '=== Environment Proxy ===' && echo \"http_proxy=$http_proxy\" && echo \"https_proxy=$https_proxy\" && echo \"no_proxy=$no_proxy\" && echo '' && echo '=== MDE Proxy Configuration ===' && mdatp health --field proxy 2>/dev/null && mdatp health --field proxy_address 2>/dev/null"
```

### 6.4 Configure Proxy — Linux
```bash
az connectedmachine run-command create \
    --resource-group <resourceGroup> \
    --machine-name ArcBox-Ubuntu-01 \
    --run-command-name "SetProxy" \
    --location <location> \
    --script "echo '=== Configuring MDE Proxy ===' && mdatp config proxy --value http://proxy.contoso.com:8080 2>/dev/null && echo 'Proxy configured for MDE' && echo '' && echo '=== Verify ===' && mdatp health --field proxy 2>/dev/null"
```

---

## Phase 7: Reinstall MDE Extension (Last Resort)

### 7.1 Remove and Reinstall — Windows
```bash
# Remove extension
az connectedmachine extension delete \
    --machine-name ArcBox-Win2K22 \
    --resource-group <resourceGroup> \
    --name MDE.Windows \
    --yes

# Reinstall extension
az connectedmachine extension create \
    --machine-name ArcBox-Win2K22 \
    --resource-group <resourceGroup> \
    --name MDE.Windows \
    --location <location> \
    --type MDE.Windows \
    --publisher Microsoft.Azure.AzureDefenderForServers
```

### 7.2 Remove and Reinstall — Linux
```bash
# Remove extension
az connectedmachine extension delete \
    --machine-name ArcBox-Ubuntu-01 \
    --resource-group <resourceGroup> \
    --name MDE.Linux \
    --yes

# Reinstall extension
az connectedmachine extension create \
    --machine-name ArcBox-Ubuntu-01 \
    --resource-group <resourceGroup> \
    --name MDE.Linux \
    --location <location> \
    --type MDE.Linux \
    --publisher Microsoft.Azure.AzureDefenderForServers
```

---

## Verification and Escalation

### Post-Remediation Verification Checklist
| Check | Windows Command | Linux Command | Expected Result |
|---|---|---|---|
| Service Running | `Get-Service WinDefend,Sense` | `systemctl is-active mdatp` | Running / active |
| Real-Time Protection | `(Get-MpComputerStatus).RealTimeProtectionEnabled` | `mdatp health --field real_time_protection_enabled` | True / enabled |
| Signatures Current | `(Get-MpComputerStatus).AntivirusSignatureAge` | `mdatp health --field definitions_status` | Age < 1 day / up_to_date |
| Cloud Connectivity | `Test-NetConnection winatp-gw-cne3.microsoft.com -Port 443` | `mdatp connectivity test` | Success / pass |
| Healthy Overall | `(Get-MpComputerStatus).AntivirusEnabled` | `mdatp health --field healthy` | True |

### Escalation Criteria

Escalate immediately if:
- **MDE services will not start** after multiple restart attempts
- **Real-time protection cannot be enabled** (possible Group Policy or tamper protection conflict)
- **Signatures fail to update** for more than 3 days
- **Cloud connectivity fails** from multiple servers simultaneously (network/firewall issue)
- **Active threats detected** that cannot be remediated automatically
- **Extension reinstall fails** repeatedly (provisioning error)
- **Onboarding issues** — device not appearing in Microsoft Defender portal

### Escalation Contacts
- **L1 SOC:** soc-team@contoso.com — Alert triage and initial response
- **L2 Security Engineering:** sec-eng@contoso.com — Configuration and policy issues
- **Microsoft Support:** Open a case at https://admin.microsoft.com for platform-level MDE issues

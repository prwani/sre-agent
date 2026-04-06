#!/bin/bash
# ============================================================
# Post-deployment setup script for On-Prem VM Management sample
# Run after `azd up` to configure:
#   1.  Resolve deployed resources
#   2.  Assign SRE Agent Administrator role
#   3.  Upload knowledge base files
#   4.  Upload skills (patch-validation, security-agent-troubleshooting, wintel-health-check)
#   5.  Create arc-remediation-approval hook
#   6.  Create scheduled tasks (proactive-health-scan, patch-assessment-scan)
#   7.  Create subagents (vm-diagnostics, security-troubleshooter)
#   8.  Create incident response plan (arc-server-alerts)
#   9.  Verify Arc servers are accessible
#   10. Print summary
# ============================================================

set -uo pipefail

# ---- Colors ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ---- Windows compatibility: find python ----
if command -v python3 &>/dev/null; then PYTHON=python3
elif command -v python &>/dev/null; then PYTHON=python
else echo -e "${RED}ERROR: Python not found. Install python3 and retry.${NC}"; exit 1; fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SAMPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  On-Prem VM Management — Post-Deployment Setup${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"

# ═══════════════════════════════════════════════════════════
# [1/10] Resolve deployed resources
# ═══════════════════════════════════════════════════════════
echo -e "\n${YELLOW}[1/10] Resolving deployed resources...${NC}"

RESOURCE_GROUP=$(azd env get-value RESOURCE_GROUP_NAME 2>/dev/null || echo "")
if [[ -z "$RESOURCE_GROUP" ]]; then
  ENV_NAME=$(azd env get-value AZURE_ENV_NAME 2>/dev/null || echo "onprem-vm")
  RESOURCE_GROUP="rg-${ENV_NAME}"
fi

ARC_RESOURCE_GROUP=$(azd env get-value ARC_RESOURCE_GROUP 2>/dev/null || echo "")
if [[ -z "$ARC_RESOURCE_GROUP" ]]; then
  ARC_RESOURCE_GROUP="${ARC_RESOURCE_GROUP:-rg-arcbox-itpro}"
fi

# Get SRE Agent endpoint
AGENT_NAME=$(az resource list --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.App/agents" --query "[0].name" -o tsv 2>/dev/null || echo "")
AGENT_ENDPOINT=$(az resource show \
  --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.App/agents" \
  --name "$AGENT_NAME" \
  --query "properties.agentEndpoint" -o tsv 2>/dev/null || echo "")

if [[ -z "$AGENT_ENDPOINT" ]]; then
  echo -e "${RED}ERROR: Could not find SRE Agent endpoint. Check resource group: $RESOURCE_GROUP${NC}"
  exit 1
fi

SUBSCRIPTION_ID=$(az account show --query id -o tsv 2>/dev/null)
AGENT_ID=$(az resource list --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.App/agents" --query "[0].id" -o tsv 2>/dev/null || echo "")
AGENT_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.App/agents/${AGENT_NAME}"
API_VERSION="2025-05-01-preview"

# Get Log Analytics Workspace
LAW_ID=$(az resource list --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.OperationalInsights/workspaces" \
  --query "[0].id" -o tsv 2>/dev/null | head -1)
LAW_NAME=$(az resource show --ids "$LAW_ID" --query "name" -o tsv 2>/dev/null || echo "")

echo -e "${GREEN}  Resource Group:     $RESOURCE_GROUP${NC}"
echo -e "${GREEN}  Arc Resource Group: $ARC_RESOURCE_GROUP${NC}"
echo -e "${GREEN}  Agent Endpoint:     $AGENT_ENDPOINT${NC}"
echo -e "${GREEN}  Agent ID:           $AGENT_ID${NC}"
echo -e "${GREEN}  Subscription:       $SUBSCRIPTION_ID${NC}"
echo -e "${GREEN}  LAW Name:           $LAW_NAME${NC}"

# ---- Helper: Get auth token for SRE Agent API ----
get_agent_token() {
  az account get-access-token --resource "https://azuresre.dev" --query accessToken -o tsv 2>/dev/null
}

# ---- Helper: Call ExtendedAgent API ----
agent_api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local token
  token=$(get_agent_token)

  if [[ -n "$body" ]]; then
    curl -s -X "$method" \
      "${AGENT_ENDPOINT}${path}" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d "$body"
  else
    curl -s -X "$method" \
      "${AGENT_ENDPOINT}${path}" \
      -H "Authorization: Bearer $token"
  fi
}

# ═══════════════════════════════════════════════════════════
# [2/10] Assign SRE Agent Administrator role
# ═══════════════════════════════════════════════════════════
echo -e "\n${YELLOW}[2/10] Assigning SRE Agent Administrator role...${NC}"

# Extract user OID from access token (avoids Graph API which may be blocked)
ACCESS_TOKEN=$(az account get-access-token --resource "https://azuresre.dev" --query accessToken -o tsv 2>/dev/null)
USER_OID=""
if [[ -n "$ACCESS_TOKEN" ]]; then
  USER_OID=$($PYTHON -c "
import json, base64, sys
try:
    token = sys.argv[1]
    payload = token.split('.')[1]
    payload += '=' * (4 - len(payload) % 4)
    claims = json.loads(base64.b64decode(payload))
    print(claims.get('oid', ''))
except Exception:
    print('')
" "$ACCESS_TOKEN")
fi

if [[ -n "$USER_OID" && -n "$AGENT_ID" ]]; then
  echo "   Assigning role to user OID: ${USER_OID:0:8}..."
  az role assignment create \
    --assignee-object-id "$USER_OID" \
    --assignee-principal-type User \
    --role "e79298df-d852-4c6d-84f9-5d13249d1e55" \
    --scope "$AGENT_ID" \
    --output none 2>/dev/null || true
  echo -e "${GREEN}  ✓ SRE Agent Administrator role assigned.${NC}"
else
  echo -e "${YELLOW}  Could not extract user OID. Assign SRE Agent Administrator role manually.${NC}"
fi

# ═══════════════════════════════════════════════════════════
# [3/10] Upload knowledge base files
# ═══════════════════════════════════════════════════════════
echo -e "\n${YELLOW}[3/10] Uploading knowledge base files...${NC}"
TOKEN=$(get_agent_token)

KB_DIR="$SAMPLE_DIR/knowledge-base"
if [ -d "$KB_DIR" ] && ls "$KB_DIR"/*.md &>/dev/null; then
  CURL_ARGS=(-s -o /dev/null -w "%{http_code}" \
    -X POST "${AGENT_ENDPOINT}/api/v1/AgentMemory/upload" \
    -H "Authorization: Bearer ${TOKEN}" \
    -F "triggerIndexing=true")
  KB_NAMES=""
  for f in "$KB_DIR"/*.md; do
    CURL_ARGS+=(-F "files=@${f};type=text/plain")
    KB_NAMES="${KB_NAMES} $(basename "$f")"
  done

  HTTP_CODE=$(curl "${CURL_ARGS[@]}")
  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
    echo -e "${GREEN}  ✓ Uploaded:${KB_NAMES}${NC}"
  else
    echo -e "${YELLOW}  Upload returned HTTP ${HTTP_CODE}${NC}"
  fi
else
  echo -e "${YELLOW}  No knowledge base files found in $KB_DIR${NC}"
fi

# ═══════════════════════════════════════════════════════════
# [4/10] Upload skills
# ═══════════════════════════════════════════════════════════
echo -e "\n${YELLOW}[4/10] Uploading skills...${NC}"

SKILLS_DIR="$SAMPLE_DIR/skills"
for skill_dir in "$SKILLS_DIR"/*/; do
  [ -d "$skill_dir" ] || continue
  skill_name=$(basename "$skill_dir")
  skill_file="$skill_dir/SKILL.md"

  if [ ! -f "$skill_file" ]; then
    echo -e "${YELLOW}  Skipping $skill_name (no SKILL.md)${NC}"
    continue
  fi

  echo "   Uploading skill: $skill_name"

  # Collect additional files in the skill directory (non-SKILL.md)
  SKILL_BODY=$($PYTHON -c "
import json, os, sys, glob

skill_dir = sys.argv[1]
skill_name = sys.argv[2]

skill_content = open(os.path.join(skill_dir, 'SKILL.md')).read()

# Collect additional files
additional = []
for f in sorted(glob.glob(os.path.join(skill_dir, '*.md'))):
    basename = os.path.basename(f)
    if basename == 'SKILL.md':
        continue
    additional.append({'filePath': basename, 'content': open(f).read()})

# Determine tools based on skill type
tools = ['RunAzCliReadCommands', 'RunAzCliWriteCommands', 'GetAzCliHelp']

body = {
    'name': skill_name,
    'type': 'Skill',
    'properties': {
        'description': skill_content.split(chr(10))[0].strip('# ').strip(),
        'tools': tools,
        'skillContent': skill_content,
        'additionalFiles': additional
    }
}
print(json.dumps(body))
" "$skill_dir" "$skill_name")

  RESULT=$(agent_api PUT "/api/v2/extendedAgent/skills/$skill_name" "$SKILL_BODY" || echo "FAILED")
  if echo "$RESULT" | grep -q "$skill_name" 2>/dev/null; then
    echo -e "${GREEN}  ✓ Skill '$skill_name' created.${NC}"
  else
    echo -e "${YELLOW}  Skill '$skill_name' may need manual setup. Response: ${RESULT:0:200}${NC}"
  fi
done

# ═══════════════════════════════════════════════════════════
# [5/10] Create arc-remediation-approval hook
# ═══════════════════════════════════════════════════════════
echo -e "\n${YELLOW}[5/10] Creating arc-remediation-approval hook...${NC}"

HOOK_BODY=$(cat <<'HOOKEOF'
{
  "name": "arc-remediation-approval",
  "type": "GlobalHook",
  "properties": {
    "eventType": "Stop",
    "activationMode": "onDemand",
    "description": "Requires explicit user approval before executing remediation actions on Arc-connected servers (service restarts, config changes, patch installs)",
    "hook": {
      "type": "prompt",
      "prompt": "Check if the agent is about to execute a remediation action on an Arc-connected server. This includes restarting services, modifying configurations, installing patches, or running write commands via az connectedmachine run-command. If the response includes any such action, reject and ask the user to approve first.\n\n$ARGUMENTS\n\nRespond with JSON:\n- If no remediation action: {\"ok\": true, \"reason\": \"No server-modifying action detected\"}\n- If remediation pending: {\"ok\": false, \"reason\": \"Server remediation requires approval. Reply 'yes' to approve or 'no' to cancel.\"}",
      "model": "ReasoningFast",
      "timeout": 30,
      "failMode": "Block",
      "maxRejections": 3
    }
  }
}
HOOKEOF
)

RESULT=$(agent_api PUT "/api/v2/extendedAgent/hooks/arc-remediation-approval" "$HOOK_BODY" || echo "FAILED")
if echo "$RESULT" | grep -q "arc-remediation-approval" 2>/dev/null; then
  echo -e "${GREEN}  ✓ Hook 'arc-remediation-approval' created.${NC}"
else
  echo -e "${YELLOW}  Hook may need manual setup. Response: ${RESULT:0:200}${NC}"
fi

# ═══════════════════════════════════════════════════════════
# [6/10] Create scheduled tasks
# ═══════════════════════════════════════════════════════════
echo -e "\n${YELLOW}[6/10] Creating scheduled tasks...${NC}"
TOKEN=$(get_agent_token)

# Clean up existing tasks with the same names
EXISTING_TASKS=$(curl -s "${AGENT_ENDPOINT}/api/v1/scheduledtasks" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "[]")
echo "$EXISTING_TASKS" | $PYTHON -c "
import sys, json
try:
    tasks = json.load(sys.stdin)
    for t in tasks:
        if t.get('name') in ('proactive-health-scan', 'patch-assessment-scan'):
            print(t.get('id', ''))
except: pass
" 2>/dev/null | while read -r task_id; do
  if [ -n "$task_id" ]; then
    curl -s -o /dev/null -X DELETE "${AGENT_ENDPOINT}/api/v1/scheduledtasks/${task_id}" \
      -H "Authorization: Bearer ${TOKEN}" 2>/dev/null
  fi
done

# Task 1: Proactive health scan (every 6 hours)
echo "   Creating proactive-health-scan task..."
TASK1_BODY=$($PYTHON -c "
import json
body = {
    'name': 'proactive-health-scan',
    'description': 'Proactive health scan of all Arc-connected servers every 6 hours',
    'cronExpression': '0 */6 * * *',
    'agentPrompt': 'Run a proactive health check on all Arc-connected servers in the resource group. For each server, check CPU usage, memory usage, disk space, and critical service status. Use the wintel-health-check skill for Windows servers. Report any servers with issues and recommend remediation actions. Use the arc-remediation-approval hook before executing any fixes.',
    'agent': 'vm-diagnostics'
}
print(json.dumps(body))
")

TOKEN=$(get_agent_token)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "${AGENT_ENDPOINT}/api/v1/scheduledtasks" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$TASK1_BODY")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "202" ]; then
  echo -e "${GREEN}  ✓ Scheduled task: proactive-health-scan (every 6h → vm-diagnostics)${NC}"
else
  echo -e "${YELLOW}  proactive-health-scan returned HTTP ${HTTP_CODE}${NC}"
fi

# Task 2: Patch assessment scan (daily at 02:00 UTC)
echo "   Creating patch-assessment-scan task..."
TASK2_BODY=$($PYTHON -c "
import json
body = {
    'name': 'patch-assessment-scan',
    'description': 'Daily patch compliance assessment across all Arc-connected servers',
    'cronExpression': '0 2 * * *',
    'agentPrompt': 'Assess patch compliance for all Arc-connected servers. For each server, check pending Windows Updates (Windows) or apt/yum update status (Linux). Use the patch-validation skill to verify patch levels. Generate a compliance report listing each server, its OS, pending patches (critical/security/other), and last patch date. Flag any servers more than 30 days behind on security patches.',
    'agent': 'vm-diagnostics'
}
print(json.dumps(body))
")

TOKEN=$(get_agent_token)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "${AGENT_ENDPOINT}/api/v1/scheduledtasks" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$TASK2_BODY")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "202" ]; then
  echo -e "${GREEN}  ✓ Scheduled task: patch-assessment-scan (daily 02:00 UTC → vm-diagnostics)${NC}"
else
  echo -e "${YELLOW}  patch-assessment-scan returned HTTP ${HTTP_CODE}${NC}"
fi

# ═══════════════════════════════════════════════════════════
# [7/10] Create subagents
# ═══════════════════════════════════════════════════════════
echo -e "\n${YELLOW}[7/10] Creating subagents...${NC}"

# Subagent 1: vm-diagnostics
echo "   Creating vm-diagnostics subagent..."
VM_DIAG_BODY=$($PYTHON -c "
import json
body = {
    'name': 'vm-diagnostics',
    'type': 'ExtendedAgent',
    'tags': [],
    'owner': '',
    'properties': {
        'instructions': '''You are a VM diagnostics specialist for Azure Arc-connected on-premises servers.

Your responsibilities:
- Diagnose CPU, memory, disk, and network issues on Arc servers
- Run remote commands via az connectedmachine run-command create
- Detect OS type (Windows/Linux) and dispatch appropriate diagnostic commands
- Use the wintel-health-check skill for Windows Server health diagnostics
- Use the patch-validation skill for patch compliance assessment

Server inventory (ArcBox):
- ArcBox-Win2K22: Windows Server 2022 (Application Server)
- ArcBox-Win2K25: Windows Server 2025 (File Server)
- ArcBox-SQL: Windows Server 2022 + SQL 2022 (Database Server)
- ArcBox-Ubuntu-01: Ubuntu 22.04 LTS (Web Server)
- ArcBox-Ubuntu-02: Ubuntu 22.04 LTS (Monitoring Server)

When running commands on servers:
1. Always detect the OS type first using az connectedmachine show
2. Use PowerShell for Windows, bash for Linux
3. Execute via: az connectedmachine run-command create --resource-group <rg> --machine-name <server> --name <unique-name> --location <location> --script <script>
4. Always use the arc-remediation-approval hook before executing write/remediation actions
5. Report results in a structured format with server name, status, and findings''',
        'handoffDescription': 'Specialist for diagnosing and remediating issues on Azure Arc-connected on-premises VMs. Handles CPU/memory/disk diagnostics, service health checks, and patch compliance.',
        'handoffs': [],
        'tools': ['RunAzCliReadCommands', 'RunAzCliWriteCommands', 'GetAzCliHelp'],
        'mcpTools': [],
        'allowParallelToolCalls': True,
        'enableSkills': True
    }
}
print(json.dumps(body))
")

TOKEN=$(get_agent_token)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X PUT "${AGENT_ENDPOINT}/api/v2/extendedAgent/agents/vm-diagnostics" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$VM_DIAG_BODY")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "202" ] || [ "$HTTP_CODE" = "204" ]; then
  echo -e "${GREEN}  ✓ Subagent 'vm-diagnostics' created.${NC}"
else
  echo -e "${YELLOW}  vm-diagnostics returned HTTP ${HTTP_CODE}${NC}"
fi

# Subagent 2: security-troubleshooter
echo "   Creating security-troubleshooter subagent..."
SEC_BODY=$($PYTHON -c "
import json
body = {
    'name': 'security-troubleshooter',
    'type': 'ExtendedAgent',
    'tags': [],
    'owner': '',
    'properties': {
        'instructions': '''You are a security troubleshooter for Azure Arc-connected on-premises servers.

Your responsibilities:
- Investigate and remediate security agent issues (MDE/Defender for Endpoint)
- Verify Microsoft Defender real-time protection status
- Check and fix Defender agent connectivity and health
- Audit security configurations across the server fleet
- Use the security-agent-troubleshooting skill for detailed procedures

Server inventory (ArcBox):
- ArcBox-Win2K22: Windows Server 2022 (Application Server)
- ArcBox-Win2K25: Windows Server 2025 (File Server)
- ArcBox-SQL: Windows Server 2022 + SQL 2022 (Database Server)
- ArcBox-Ubuntu-01: Ubuntu 22.04 LTS (Web Server)
- ArcBox-Ubuntu-02: Ubuntu 22.04 LTS (Monitoring Server)

Security checks by OS:
Windows:
  - Get-MpComputerStatus (Defender status)
  - Get-MpPreference (Defender configuration)
  - sc query windefend (service status)
Linux:
  - mdatp health (Defender for Endpoint status)
  - mdatp config real-time-protection (RTP status)
  - systemctl status mdatp (service status)

Always:
1. Detect OS type before running commands
2. Execute via az connectedmachine run-command create
3. Use the arc-remediation-approval hook before making changes
4. Report findings with server name, issue, severity, and recommended fix''',
        'handoffDescription': 'Specialist for security agent troubleshooting on Arc-connected servers. Handles Defender/MDE issues, security configuration audits, and compliance remediation.',
        'handoffs': [],
        'tools': ['RunAzCliReadCommands', 'RunAzCliWriteCommands', 'GetAzCliHelp'],
        'mcpTools': [],
        'allowParallelToolCalls': True,
        'enableSkills': True
    }
}
print(json.dumps(body))
")

TOKEN=$(get_agent_token)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X PUT "${AGENT_ENDPOINT}/api/v2/extendedAgent/agents/security-troubleshooter" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$SEC_BODY")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "202" ] || [ "$HTTP_CODE" = "204" ]; then
  echo -e "${GREEN}  ✓ Subagent 'security-troubleshooter' created.${NC}"
else
  echo -e "${YELLOW}  security-troubleshooter returned HTTP ${HTTP_CODE}${NC}"
fi

# ═══════════════════════════════════════════════════════════
# [8/10] Create incident response plan
# ═══════════════════════════════════════════════════════════
echo -e "\n${YELLOW}[8/10] Creating incident response plan...${NC}"

# Enable Azure Monitor as incident platform
echo "   Enabling Azure Monitor incident platform..."
if az rest --method PATCH \
  --url "https://management.azure.com${AGENT_RESOURCE_ID}?api-version=${API_VERSION}" \
  --body '{"properties":{"incidentManagementConfiguration":{"type":"AzMonitor","connectionName":"azmonitor"}}}' \
  --output none 2>&1; then
  echo -e "${GREEN}  ✓ Azure Monitor enabled as incident platform.${NC}"
else
  echo -e "${YELLOW}  Could not enable Azure Monitor (may already be set).${NC}"
fi

echo "   Waiting for Azure Monitor to initialize..."
sleep 15

TOKEN=$(get_agent_token)

# Delete existing filters
curl -s -o /dev/null -X DELETE \
  "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters/arc-server-alerts" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || true

sleep 3

# Create response plan with retry
FILTER_BODY=$($PYTHON -c "
import json
body = {
    'id': 'arc-server-alerts',
    'name': 'Arc Server Alerts',
    'priorities': ['Sev0', 'Sev1', 'Sev2', 'Sev3'],
    'titleContains': '',
    'handlingAgent': 'vm-diagnostics',
    'agentMode': 'SemiAutonomous',
    'maxAttempts': 3,
    'instructions': '''Investigate alerts from Arc-connected on-premises servers.

1. Identify the affected server and detect its OS type.
2. Use the vm-diagnostics subagent for performance issues (CPU, memory, disk).
3. Use the security-troubleshooter subagent for security/Defender issues.
4. Load the appropriate skill (wintel-health-check, patch-validation, security-agent-troubleshooting).
5. Always use the arc-remediation-approval hook before executing any remediation.
6. Report findings with server name, issue description, severity, and remediation taken.'''
}
print(json.dumps(body))
")

FILTER_CREATED=false
for attempt in 1 2 3 4 5; do
  TOKEN=$(get_agent_token)
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X PUT "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters/arc-server-alerts" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$FILTER_BODY")

  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "202" ] || [ "$HTTP_CODE" = "409" ]; then
    echo -e "${GREEN}  ✓ Response plan: arc-server-alerts → vm-diagnostics (SemiAutonomous)${NC}"
    FILTER_CREATED=true
    break
  else
    echo "   ⏳ Attempt $attempt/5: HTTP ${HTTP_CODE}, retrying in 15s..."
    sleep 15
  fi
done

if [ "$FILTER_CREATED" = "false" ]; then
  echo -e "${YELLOW}  Response plan failed after 5 attempts. Set up in portal or re-run.${NC}"
fi

# Delete default quickstart handler
TOKEN=$(get_agent_token)
curl -s -o /dev/null -X DELETE \
  "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters/quickstart_response_plan" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || true

# ═══════════════════════════════════════════════════════════
# [9/10] Verify Arc servers are accessible
# ═══════════════════════════════════════════════════════════
echo -e "\n${YELLOW}[9/10] Verifying Arc servers in $ARC_RESOURCE_GROUP...${NC}"

ARC_COUNT=$(az connectedmachine list --resource-group "$ARC_RESOURCE_GROUP" \
  --query "length(@)" -o tsv 2>/dev/null || echo "0")

if [ "$ARC_COUNT" -gt 0 ] 2>/dev/null; then
  echo -e "${GREEN}  Found $ARC_COUNT Arc-connected server(s):${NC}"
  az connectedmachine list --resource-group "$ARC_RESOURCE_GROUP" \
    --query "[].{Name:name, OS:osType, Status:status}" -o table 2>/dev/null
else
  echo -e "${YELLOW}  No Arc servers found in $ARC_RESOURCE_GROUP.${NC}"
  echo -e "${YELLOW}  Ensure ArcBox is deployed and servers are connected.${NC}"
fi

# Grant agent identity RBAC for Arc resources
echo "   Granting agent identity roles on Arc resource group..."
AGENT_MI_NAME=$(az resource list --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.ManagedIdentity/userAssignedIdentities" \
  --query "[?contains(name, 'sreagent')].name" -o tsv 2>/dev/null | head -1)
AGENT_MI_PRINCIPAL_ID=$(az identity show --name "$AGENT_MI_NAME" --resource-group "$RESOURCE_GROUP" \
  --query principalId -o tsv 2>/dev/null || echo "")

if [[ -n "$AGENT_MI_PRINCIPAL_ID" ]]; then
  # Azure Connected Machine Resource Administrator on Arc RG
  az role assignment create \
    --assignee-object-id "$AGENT_MI_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "Azure Connected Machine Resource Administrator" \
    --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${ARC_RESOURCE_GROUP}" \
    --output none 2>/dev/null || true
  echo -e "${GREEN}  ✓ Connected Machine Resource Administrator granted on $ARC_RESOURCE_GROUP${NC}"

  # Reader on the Arc resource group
  az role assignment create \
    --assignee-object-id "$AGENT_MI_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "Reader" \
    --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${ARC_RESOURCE_GROUP}" \
    --output none 2>/dev/null || true
  echo -e "${GREEN}  ✓ Reader granted on $ARC_RESOURCE_GROUP${NC}"

  # Monitoring Contributor on subscription
  az role assignment create \
    --assignee-object-id "$AGENT_MI_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "Monitoring Contributor" \
    --scope "/subscriptions/${SUBSCRIPTION_ID}" \
    --output none 2>/dev/null || true
  echo -e "${GREEN}  ✓ Monitoring Contributor granted on subscription${NC}"
else
  echo -e "${YELLOW}  Could not find agent managed identity. Assign roles manually.${NC}"
fi

# ═══════════════════════════════════════════════════════════
# [10/10] Verification & Summary
# ═══════════════════════════════════════════════════════════
echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Verifying setup...${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
sleep 10

TOKEN=$(get_agent_token)
VERIFY_PASS=0
VERIFY_FAIL=0

# Check subagents
echo -e "\n  ${YELLOW}Subagents:${NC}"
for agent_name in vm-diagnostics security-troubleshooter; do
  AGENT_CHECK=$(curl -s -o /dev/null -w "%{http_code}" \
    "${AGENT_ENDPOINT}/api/v2/extendedAgent/agents/${agent_name}" \
    -H "Authorization: Bearer ${TOKEN}" 2>/dev/null)
  if [ "$AGENT_CHECK" = "200" ]; then
    echo -e "    ${GREEN}✓ $agent_name${NC}"
    VERIFY_PASS=$((VERIFY_PASS + 1))
  else
    echo -e "    ${RED}✗ $agent_name (HTTP $AGENT_CHECK)${NC}"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
  fi
done

# Check skills
echo -e "\n  ${YELLOW}Skills:${NC}"
for skill_name in patch-validation security-agent-troubleshooting wintel-health-check; do
  SKILL_CHECK=$(curl -s "${AGENT_ENDPOINT}/api/v2/extendedAgent/skills/${skill_name}" \
    -H "Authorization: Bearer ${TOKEN}" 2>/dev/null | $PYTHON -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print('ok' if d.get('name')=='$skill_name' else 'missing')
except: print('missing')
" 2>/dev/null)
  if [ "$SKILL_CHECK" = "ok" ]; then
    echo -e "    ${GREEN}✓ $skill_name${NC}"
    VERIFY_PASS=$((VERIFY_PASS + 1))
  else
    echo -e "    ${RED}✗ $skill_name${NC}"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
  fi
done

# Check hook
echo -e "\n  ${YELLOW}Hooks:${NC}"
HOOK_CHECK=$(curl -s "${AGENT_ENDPOINT}/api/v2/extendedAgent/hooks/arc-remediation-approval" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null | $PYTHON -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print('ok' if d.get('name')=='arc-remediation-approval' else 'missing')
except: print('missing')
" 2>/dev/null)
if [ "$HOOK_CHECK" = "ok" ]; then
  echo -e "    ${GREEN}✓ arc-remediation-approval${NC}"
  VERIFY_PASS=$((VERIFY_PASS + 1))
else
  echo -e "    ${RED}✗ arc-remediation-approval${NC}"
  VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# Check response plan
echo -e "\n  ${YELLOW}Response Plans:${NC}"
FILTER_CHECK=$(curl -s "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null | $PYTHON -c "
import sys,json
try:
    data=json.load(sys.stdin)
    found = any(f.get('id')=='arc-server-alerts' for f in data)
    print('ok' if found else 'missing')
except: print('missing')
" 2>/dev/null)
if [ "$FILTER_CHECK" = "ok" ]; then
  echo -e "    ${GREEN}✓ arc-server-alerts → vm-diagnostics${NC}"
  VERIFY_PASS=$((VERIFY_PASS + 1))
else
  echo -e "    ${RED}✗ arc-server-alerts${NC}"
  VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# Check scheduled tasks
echo -e "\n  ${YELLOW}Scheduled Tasks:${NC}"
TASKS_JSON=$(curl -s "${AGENT_ENDPOINT}/api/v1/scheduledtasks" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "[]")
for task_name in proactive-health-scan patch-assessment-scan; do
  TASK_CHECK=$(echo "$TASKS_JSON" | $PYTHON -c "
import sys,json
try:
    data=json.load(sys.stdin)
    found = any(t.get('name')=='$task_name' for t in data)
    print('ok' if found else 'missing')
except: print('missing')
" 2>/dev/null)
  if [ "$TASK_CHECK" = "ok" ]; then
    echo -e "    ${GREEN}✓ $task_name${NC}"
    VERIFY_PASS=$((VERIFY_PASS + 1))
  else
    echo -e "    ${RED}✗ $task_name${NC}"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
  fi
done

# Summary
echo ""
echo -e "  ${BLUE}────────────────────────────────────────${NC}"
if [ "$VERIFY_FAIL" -eq 0 ]; then
  echo -e "  ${GREEN}✓ All ${VERIFY_PASS}/${VERIFY_PASS} checks passed — agent is fully set up!${NC}"
else
  echo -e "  ${YELLOW}⚠ ${VERIFY_PASS} passed, ${VERIFY_FAIL} failed — check items above${NC}"
fi

echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Setup complete!${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Infrastructure deployed:"
echo "    ✓ SRE Agent:    $AGENT_ENDPOINT"
echo "    ✓ Arc servers:  ${ARC_COUNT:-0} in $ARC_RESOURCE_GROUP"
echo "    ✓ Subagents:    vm-diagnostics, security-troubleshooter"
echo "    ✓ Skills:       patch-validation, security-agent-troubleshooting, wintel-health-check"
echo "    ✓ Hook:         arc-remediation-approval"
echo "    ✓ Tasks:        proactive-health-scan (6h), patch-assessment-scan (daily)"
echo "    ✓ Response plan: arc-server-alerts → vm-diagnostics (SemiAutonomous)"
echo ""
echo "  To test the VM management workflow:"
echo "    1. Break something:  ./scripts/break-cpu.sh ArcBox-Win2K22"
echo "    2. Ask the agent:    'Check health of ArcBox-Win2K22'"
echo "    3. Or trigger alert: wait for proactive-health-scan"
echo ""
echo "  Agent Portal: $AGENT_ENDPOINT"

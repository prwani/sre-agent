#!/bin/bash
# =============================================================================
# break-defender.sh — Disable Defender real-time protection on an Arc server
# Auto-detects OS type and dispatches the appropriate command.
# Uses az connectedmachine run-command create exclusively.
#
# Usage: ./break-defender.sh [server-name] [resource-group]
# Default: ArcBox-Win2K22 in $ARC_RESOURCE_GROUP (or rg-arcbox-itpro)
#
# Windows: Set-MpPreference -DisableRealtimeMonitoring $true
# Linux:   mdatp config real-time-protection --value disabled
# =============================================================================

set -uo pipefail

# ---- Colors ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SERVER="${1:-ArcBox-Win2K22}"
RG="${2:-${ARC_RESOURCE_GROUP:-rg-arcbox-itpro}}"

echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Break Defender — Disable Real-Time Protection${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Server: ${YELLOW}$SERVER${NC}"
echo -e "  Resource Group: $RG"
echo ""

# ---- Validate server exists ----
echo -e "${YELLOW}Detecting server properties...${NC}"
SERVER_INFO=$(az connectedmachine show \
  --resource-group "$RG" --name "$SERVER" \
  --query "{location:location, osType:osType, status:status}" -o json 2>/dev/null)

if [[ -z "$SERVER_INFO" || "$SERVER_INFO" == "null" ]]; then
  echo -e "${RED}ERROR: Server '$SERVER' not found in resource group '$RG'${NC}"
  echo ""
  echo "Available servers:"
  az connectedmachine list --resource-group "$RG" \
    --query "[].{Name:name, OS:osType, Status:status}" -o table 2>/dev/null || \
    echo "  (could not list servers)"
  exit 1
fi

if command -v python3 &>/dev/null; then PYCMD=python3; else PYCMD=python; fi

LOCATION=$(echo "$SERVER_INFO" | $PYCMD -c "import sys,json; print(json.load(sys.stdin)['location'])")
OS_TYPE=$(echo "$SERVER_INFO" | $PYCMD -c "import sys,json; print(json.load(sys.stdin)['osType'])")
STATUS=$(echo "$SERVER_INFO" | $PYCMD -c "import sys,json; print(json.load(sys.stdin)['status'])")

echo -e "  OS Type:  ${GREEN}$OS_TYPE${NC}"
echo -e "  Location: $LOCATION"
echo -e "  Status:   $STATUS"
echo ""

if [[ "$STATUS" != "Connected" ]]; then
  echo -e "${YELLOW}WARNING: Server status is '$STATUS' (not 'Connected'). Command may fail.${NC}"
fi

# ---- Build OS-appropriate Defender disable command ----
RUN_NAME="break-defender-$(date +%s)"

if [[ "$OS_TYPE" == "Windows" ]]; then
  echo -e "${YELLOW}Disabling Windows Defender real-time protection (PowerShell)...${NC}"
  SCRIPT='try { Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop; $status = Get-MpComputerStatus; Write-Output "Real-time protection disabled: RealTimeProtectionEnabled=$($status.RealTimeProtectionEnabled)" } catch { Write-Output "Failed to disable Defender: $_" }'
else
  echo -e "${YELLOW}Disabling MDE real-time protection (Linux)...${NC}"
  SCRIPT='if command -v mdatp &>/dev/null; then mdatp config real-time-protection --value disabled 2>&1; echo "RTP status: $(mdatp health --field real_time_protection_enabled 2>/dev/null)"; else echo "mdatp not installed on this server"; fi'
fi

# ---- Execute via run-command ----
echo ""
az connectedmachine run-command create \
  --resource-group "$RG" \
  --machine-name "$SERVER" \
  --name "$RUN_NAME" \
  --location "$LOCATION" \
  --script "$SCRIPT" \
  --no-wait \
  --output none 2>&1

RC=$?
if [ $RC -eq 0 ]; then
  echo -e "${GREEN}✓ Defender disable command dispatched successfully!${NC}"
  echo ""
  echo "  Run command name: $RUN_NAME"
  echo ""
  echo "  Check status:"
  echo "    az connectedmachine run-command show -g $RG --machine-name $SERVER --name $RUN_NAME -o table"
  echo ""
  echo "  This should trigger a security alert for the SRE Agent to investigate."
  echo ""
  echo "  To restore, ask the SRE Agent:"
  echo "    'Check Defender status on $SERVER and re-enable real-time protection'"
else
  echo -e "${RED}✗ Failed to dispatch Defender disable command (exit code: $RC)${NC}"
  echo "  Verify server is connected and you have Run Command permissions."
  exit 1
fi

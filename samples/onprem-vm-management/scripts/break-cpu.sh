#!/bin/bash
# =============================================================================
# break-cpu.sh — Spike CPU on an Arc-connected server
# Auto-detects OS type and dispatches the appropriate stress command.
# Uses az connectedmachine run-command create exclusively.
#
# Usage: ./break-cpu.sh [server-name] [resource-group]
# Default: ArcBox-Win2K22 in $ARC_RESOURCE_GROUP (or rg-arcbox-itpro)
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
echo -e "${BLUE}  Break CPU — Stress Test for Arc Server${NC}"
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

# ---- Build OS-appropriate CPU stress script ----
RUN_NAME="break-cpu-$(date +%s)"

if [[ "$OS_TYPE" == "Windows" ]]; then
  echo -e "${YELLOW}Dispatching Windows CPU stress (PowerShell, 10 minutes)...${NC}"
  SCRIPT='$duration = 10; $end = (Get-Date).AddMinutes($duration); $cores = [Environment]::ProcessorCount; 1..$cores | ForEach-Object { Start-Job -ScriptBlock { param($endTime) while ((Get-Date) -lt $endTime) { [math]::Sqrt(12345) | Out-Null } } -ArgumentList $end }; Write-Output "CPU stress started: $cores cores for $duration minutes (PID: $PID, ends at $end)"'
else
  echo -e "${YELLOW}Dispatching Linux CPU stress (bash, 10 minutes)...${NC}"
  SCRIPT='CORES=$(nproc); for i in $(seq 1 $CORES); do (yes > /dev/null &); done; PIDS=$(jobs -p | tr "\n" " "); echo "CPU stress started: $CORES cores for 10 minutes (PIDs: $PIDS)"; sleep 600; kill $PIDS 2>/dev/null; echo "CPU stress ended"'
fi

# ---- Execute via run-command ----
echo ""
az connectedmachine run-command create \
  --resource-group "$RG" \
  --machine-name "$SERVER" \
  --name "$RUN_NAME" \
  --location "$LOCATION" \
  --script "$SCRIPT" \
  --async-execution true \
  --no-wait \
  --output none 2>&1

RC=$?
if [ $RC -eq 0 ]; then
  echo -e "${GREEN}✓ CPU stress command dispatched successfully!${NC}"
  echo ""
  echo "  Run command name: $RUN_NAME"
  echo "  Duration: 10 minutes"
  echo ""
  echo "  Check status:"
  echo "    az connectedmachine run-command show -g $RG --machine-name $SERVER --name $RUN_NAME -o table"
  echo ""
  echo "  This should trigger CPU alerts for the SRE Agent to investigate."
else
  echo -e "${RED}✗ Failed to dispatch CPU stress command (exit code: $RC)${NC}"
  echo "  Verify server is connected and you have Run Command permissions."
  exit 1
fi

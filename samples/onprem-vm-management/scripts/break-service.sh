#!/bin/bash
# =============================================================================
# break-service.sh — Stop a service on an Arc-connected server
# Auto-detects OS type and dispatches the appropriate stop command.
# Uses az connectedmachine run-command create exclusively.
#
# Usage: ./break-service.sh [server-name] [resource-group]
# Default: ArcBox-Win2K22 in $ARC_RESOURCE_GROUP (or rg-arcbox-itpro)
#
# Service stopped per server role:
#   Windows (general):   W32Time (Windows Time)
#   Windows (SQL):       SQLSERVERAGENT (SQL Agent, not engine)
#   Linux:               cron
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
echo -e "${BLUE}  Break Service — Stop a Service on Arc Server${NC}"
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

# ---- Determine which service to stop ----
RUN_NAME="break-service-$(date +%s)"

if [[ "$OS_TYPE" == "Windows" ]]; then
  # SQL Server → stop SQL Agent; others → stop W32Time
  if echo "$SERVER" | grep -qi "sql"; then
    SERVICE_NAME="SQLSERVERAGENT"
    DISPLAY_NAME="SQL Server Agent"
    SCRIPT="Stop-Service -Name SQLSERVERAGENT -Force -ErrorAction SilentlyContinue; \$svc = Get-Service -Name SQLSERVERAGENT -ErrorAction SilentlyContinue; Write-Output \"Service SQLSERVERAGENT status: \$(\$svc.Status)\""
  else
    SERVICE_NAME="W32Time"
    DISPLAY_NAME="Windows Time"
    SCRIPT="Stop-Service -Name W32Time -Force -ErrorAction SilentlyContinue; \$svc = Get-Service -Name W32Time -ErrorAction SilentlyContinue; Write-Output \"Service W32Time status: \$(\$svc.Status)\""
  fi
  echo -e "${YELLOW}Stopping ${DISPLAY_NAME} (${SERVICE_NAME}) via PowerShell...${NC}"
else
  SERVICE_NAME="cron"
  DISPLAY_NAME="cron scheduler"
  SCRIPT="systemctl stop cron 2>/dev/null || systemctl stop crond 2>/dev/null; echo \"Service cron status: \$(systemctl is-active cron 2>/dev/null || systemctl is-active crond 2>/dev/null)\""
  echo -e "${YELLOW}Stopping ${DISPLAY_NAME} (${SERVICE_NAME}) via bash...${NC}"
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
  echo -e "${GREEN}✓ Service stop command dispatched successfully!${NC}"
  echo ""
  echo "  Service:          $DISPLAY_NAME ($SERVICE_NAME)"
  echo "  Run command name: $RUN_NAME"
  echo ""
  echo "  Check status:"
  echo "    az connectedmachine run-command show -g $RG --machine-name $SERVER --name $RUN_NAME -o table"
  echo ""
  echo "  To restore the service, ask the SRE Agent:"
  echo "    'Check and fix the $SERVICE_NAME service on $SERVER'"
else
  echo -e "${RED}✗ Failed to dispatch service stop command (exit code: $RC)${NC}"
  echo "  Verify server is connected and you have Run Command permissions."
  exit 1
fi

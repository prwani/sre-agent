#!/bin/bash
# =============================================================================
# prereqs.sh — Check prerequisites for On-Prem VM Management sample
# Works on macOS (brew), Linux, and Windows (winget via Git Bash)
# Run this before 'azd provision' to verify required tools and access.
# =============================================================================

set -uo pipefail

# ---- Colors ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  On-Prem VM Management — Prerequisites Check${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""

MISSING=0

# Detect OS
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "mingw"* || "$OSTYPE" == "cygwin" ]]; then
  OS="windows"
elif [[ "$OSTYPE" == "darwin"* ]]; then
  OS="mac"
else
  OS="linux"
fi

echo -e "Platform: ${BLUE}$OS${NC}"
echo ""

# ---- Check each tool ----
check_tool() {
  local name="$1"
  local cmd="$2"
  local install_mac="$3"
  local install_win="$4"
  local install_linux="${5:-}"

  if command -v "$cmd" &>/dev/null; then
    version=$($cmd --version 2>&1 | head -1)
    echo -e "  ${GREEN}✓${NC} $name: $version"
  else
    echo -e "  ${RED}✗${NC} $name: NOT FOUND"
    if [ "$OS" = "mac" ]; then
      echo "     Install: $install_mac"
    elif [ "$OS" = "windows" ]; then
      echo "     Install: $install_win"
    else
      echo "     Install: ${install_linux:-see https://learn.microsoft.com/cli/azure/install-azure-cli}"
    fi
    MISSING=$((MISSING + 1))
  fi
}

echo "Checking tools:"
check_tool "Azure CLI" "az" \
  "brew install azure-cli" \
  "winget install Microsoft.AzureCLI" \
  "curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash"
check_tool "Azure Developer CLI" "azd" \
  "brew install azd" \
  "winget install Microsoft.Azd" \
  "curl -fsSL https://aka.ms/install-azd.sh | bash"
check_tool "Python 3" "python3" \
  "brew install python3" \
  "winget install Python.Python.3.12" \
  "sudo apt install python3"

# Python fallback for Windows (python instead of python3)
if ! command -v python3 &>/dev/null && command -v python &>/dev/null; then
  version=$(python --version 2>&1)
  if echo "$version" | grep -q "Python 3"; then
    echo -e "  ${GREEN}✓${NC} Python (via 'python'): $version"
    MISSING=$((MISSING - 1))
  fi
fi

echo ""

# ---- Check Azure login ----
echo "Checking Azure auth:"
if az account show &>/dev/null 2>&1; then
  sub_name=$(az account show --query name -o tsv 2>/dev/null)
  sub_id=$(az account show --query id -o tsv 2>/dev/null)
  echo -e "  ${GREEN}✓${NC} Logged in: $sub_name ($sub_id)"
else
  echo -e "  ${RED}✗${NC} Not logged in to Azure"
  echo "     Run: az login"
  MISSING=$((MISSING + 1))
fi

echo ""

# ---- Check resource providers ----
echo "Checking resource providers:"

check_provider() {
  local ns="$1"
  local state
  state=$(az provider show -n "$ns" --query "registrationState" -o tsv 2>/dev/null || echo "Unknown")
  if [ "$state" = "Registered" ]; then
    echo -e "  ${GREEN}✓${NC} $ns: Registered"
  else
    echo -e "  ${RED}✗${NC} $ns: $state"
    echo "     Run: az provider register -n $ns --wait"
    MISSING=$((MISSING + 1))
  fi
}

check_provider "Microsoft.App"
check_provider "Microsoft.HybridCompute"

echo ""

# ---- Check Arc resource group and servers ----
echo "Checking Arc-connected servers:"

ARC_RG="${ARC_RESOURCE_GROUP:-}"
if [[ -z "$ARC_RG" ]]; then
  ARC_RG=$(azd env get-value ARC_RESOURCE_GROUP 2>/dev/null || echo "")
fi
if [[ -z "$ARC_RG" ]]; then
  ARC_RG="rg-arcbox-itpro"
fi

# Check if resource group exists
RG_EXISTS=$(az group show --name "$ARC_RG" --query name -o tsv 2>/dev/null || echo "")
if [[ -z "$RG_EXISTS" ]]; then
  echo -e "  ${RED}✗${NC} Resource group '$ARC_RG' not found"
  echo "     Set ARC_RESOURCE_GROUP env var or deploy ArcBox first"
  MISSING=$((MISSING + 1))
else
  echo -e "  ${GREEN}✓${NC} Resource group: $ARC_RG"

  # List Arc servers
  ARC_COUNT=$(az connectedmachine list --resource-group "$ARC_RG" \
    --query "length(@)" -o tsv 2>/dev/null || echo "0")

  if [ "$ARC_COUNT" -gt 0 ] 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} Found $ARC_COUNT Arc-connected server(s)"
    echo ""
    echo -e "  ${BLUE}Arc Server Inventory:${NC}"
    echo "  ┌────────────────────┬──────────┬─────────────┐"
    echo "  │ Server             │ OS       │ Status      │"
    echo "  ├────────────────────┼──────────┼─────────────┤"

    az connectedmachine list --resource-group "$ARC_RG" \
      --query "[].{name:name, os:osType, status:status}" -o json 2>/dev/null | \
    if command -v python3 &>/dev/null; then PYCMD=python3; else PYCMD=python; fi && \
    $PYCMD -c "
import sys, json
try:
    servers = json.load(sys.stdin)
    for s in servers:
        name = s.get('name', 'Unknown').ljust(18)
        os_type = s.get('os', 'Unknown').ljust(8)
        status = s.get('status', 'Unknown').ljust(11)
        print(f'  │ {name} │ {os_type} │ {status} │')
except Exception:
    print('  │ (error reading)    │          │             │')
"
    echo "  └────────────────────┴──────────┴─────────────┘"
  else
    echo -e "  ${YELLOW}⚠${NC}  No Arc servers found in $ARC_RG"
    echo "     Deploy ArcBox (https://azurearcjumpstart.com/azure_jumpstart_arcbox) first"
    MISSING=$((MISSING + 1))
  fi
fi

echo ""

# ---- Summary ----
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
if [ "$MISSING" -eq 0 ]; then
  echo -e "  ${GREEN}✓ All prerequisites met!${NC}"
  echo ""
  echo "  Next steps:"
  echo "    1. azd up                           # Deploy SRE Agent"
  echo "    2. ./scripts/post-deploy.sh         # Configure agent"
  echo "    3. ./scripts/break-cpu.sh           # Test with CPU spike"
else
  echo -e "  ${YELLOW}⚠ $MISSING issue(s) found — fix the items above then re-run${NC}"
fi
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""

# Windows-specific tips
if [ "$OS" = "windows" ]; then
  echo -e "${YELLOW}💡 Windows tips:${NC}"
  echo "   • Disable Python Store aliases: Settings → Apps → Advanced → App execution aliases"
  echo "   • If 'azd up' fails with 'bash not found', run post-deploy manually:"
  echo "     \"C:\\Program Files\\Git\\bin\\bash.exe\" scripts/post-deploy.sh"
  echo ""
fi

exit $MISSING

// ============================================================
// Main Bicep — On-Prem VM Management via Azure Arc + SRE Agent
// Deploys: Monitoring + SRE Agent + RBAC + Alert Rules
// ArcBox is deployed separately as a prerequisite.
// ============================================================
targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the environment (auto-populated by azd)')
param environmentName string

@description('Primary location for all resources')
@allowed(['swedencentral', 'eastus2', 'australiaeast'])
param location string = 'swedencentral'

@description('Name of the existing ArcBox resource group containing Arc-enrolled servers')
param arcResourceGroup string

@description('Object ID of the deploying user (for SRE Agent Administrator role)')
param deployingUserObjectId string = ''

// Tags applied to all resources
var tags = {
  'azd-env-name': environmentName
  purpose: 'onprem-vm-management'
  environment: 'demo'
}

// Resource group for SRE Agent and monitoring resources
resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}

// Reference the existing ArcBox resource group
resource arcRg 'Microsoft.Resources/resourceGroups@2021-04-01' existing = {
  name: arcResourceGroup
}

// ---- Monitoring (LAW + Application Insights) ----
module monitoring 'modules/monitoring.bicep' = {
  scope: rg
  name: 'monitoring'
  params: {
    location: location
    logAnalyticsName: 'law-${environmentName}'
    appInsightsName: 'appi-${environmentName}'
  }
}

// ---- SRE Agent (Managed Identity + Microsoft.App/agents) ----
module sreAgent 'modules/sre-agent.bicep' = {
  scope: rg
  name: 'sre-agent'
  params: {
    location: location
    environmentName: environmentName
    tags: tags
    managedResourceGroupId: rg.id
    deployingUserObjectId: deployingUserObjectId
  }
}

// ---- RBAC on the SRE Agent resource group ----
module rolesSreRg 'modules/roles.bicep' = {
  scope: rg
  name: 'roles-sre-rg'
  params: {
    principalId: sreAgent.outputs.managedIdentityPrincipalId
  }
}

// ---- RBAC on the ArcBox resource group (so the agent can manage Arc servers) ----
module rolesArcRg 'modules/roles.bicep' = {
  scope: arcRg
  name: 'roles-arc-rg'
  params: {
    principalId: sreAgent.outputs.managedIdentityPrincipalId
  }
}

// ---- Subscription-level RBAC ----
module subscriptionRbac 'modules/subscription-rbac.bicep' = {
  name: 'subscription-rbac'
  params: {
    principalId: sreAgent.outputs.managedIdentityPrincipalId
  }
}

// ---- Alert Rules for Arc servers (scheduled query alerts on LAW) ----
module alertRules 'modules/alert-rules-arc.bicep' = {
  scope: rg
  name: 'alert-rules-arc'
  params: {
    location: location
    environmentName: environmentName
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    tags: tags
  }
}

// ============================================================
// Outputs
// ============================================================
output SRE_AGENT_ENDPOINT string = sreAgent.outputs.agentEndpoint
output RESOURCE_GROUP_NAME string = rg.name
output LAW_WORKSPACE_ID string = monitoring.outputs.workspaceId
output ARC_RESOURCE_GROUP string = arcResourceGroup

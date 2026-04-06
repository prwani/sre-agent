// ============================================================
// SRE Agent module — Managed Identity + Microsoft.App/agents
// ============================================================

@description('Location for all resources')
param location string

@description('Environment name for naming')
param environmentName string

@description('Tags for all resources')
param tags object

@description('Resource group ID that the agent should monitor')
param managedResourceGroupId string

@description('Object ID of the deploying user (for SRE Agent Administrator role)')
param deployingUserObjectId string = ''

// ---- Managed Identity for the SRE Agent ----
resource agentIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-sreagent-${environmentName}'
  location: location
  tags: tags
}

// ---- SRE Agent ----
#disable-next-line BCP081
resource agent 'Microsoft.App/agents@2025-02-02-preview' = {
  name: 'sreagent-${environmentName}'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${agentIdentity.id}': {}
    }
  }
  properties: {
    knowledgeGraphConfiguration: {
      identity: agentIdentity.id
      managedResources: [
        managedResourceGroupId
      ]
    }
    actionConfiguration: {
      mode: 'autonomous'
      identity: agentIdentity.id
      accessLevel: 'High'
    }
    mcpServers: []
  }
}

// ---- SRE Agent Administrator role for deploying user ----
var sreAgentAdminRoleId = 'e79298df-d852-4c6d-84f9-5d13249d1e55'

resource agentAdminRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployingUserObjectId)) {
  name: guid(agent.id, deployingUserObjectId, sreAgentAdminRoleId)
  scope: agent
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', sreAgentAdminRoleId)
    principalId: deployingUserObjectId
    principalType: 'User'
  }
}

// ============================================================
// Outputs
// ============================================================
output agentEndpoint string = agent.properties.agentEndpoint
output agentName string = agent.name
output managedIdentityPrincipalId string = agentIdentity.properties.principalId
output managedIdentityId string = agentIdentity.id

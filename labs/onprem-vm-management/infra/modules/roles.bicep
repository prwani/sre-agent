// ============================================================
// Roles Module — Resource group RBAC for SRE Agent
// Deploy once per RG the agent needs access to.
// ============================================================

@description('Principal ID of the managed identity to assign roles to')
param principalId string

@description('Principal type for the role assignments')
param principalType string = 'ServicePrincipal'

var roles = [
  {
    name: 'Reader'
    id: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
  }
  {
    name: 'Log Analytics Reader'
    id: '73c42c96-874c-492b-b04d-ab87d138a893'
  }
  {
    name: 'Monitoring Reader'
    id: '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
  }
  {
    name: 'Monitoring Contributor'
    id: '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
  }
  {
    // Allows the agent to run commands on Arc-enrolled servers
    name: 'Azure Connected Machine Resource Manager'
    id: 'cd570a14-e51a-42ad-bac8-bafd67325302'
  }
  {
    // Allows the agent to manage extensions on Arc-enrolled servers
    name: 'Azure Connected Machine Resource Administrator'
    id: '7b1f81f9-4196-4058-8aae-762e593270df'
  }
]

resource roleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for role in roles: {
  name: guid(resourceGroup().id, principalId, role.id)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role.id)
    principalId: principalId
    principalType: principalType
  }
}]

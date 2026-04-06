// ============================================================
// Alert Rules — Scheduled query alerts for Arc-enrolled servers
// Queries Heartbeat and Perf tables populated by Azure Monitor Agent
// ============================================================

@description('Location for resources')
param location string

@description('Environment name for naming')
param environmentName string

@description('Log Analytics Workspace resource ID')
param logAnalyticsWorkspaceId string

@description('Tags for all resources')
param tags object

// ---- Heartbeat Loss (Sev 0) ----
resource heartbeatLossAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-heartbeat-loss-${environmentName}'
  location: location
  tags: tags
  properties: {
    displayName: 'Arc Server Heartbeat Loss'
    description: 'Fires when an Arc-enrolled server has not sent a heartbeat in 15 minutes'
    severity: 0
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT20M'
    scopes: [
      logAnalyticsWorkspaceId
    ]
    criteria: {
      allOf: [
        {
          query: '''Heartbeat
| summarize LastHeartbeat = max(TimeGenerated) by Computer, OSType
| where LastHeartbeat < ago(15m)
| project Computer, OSType, LastHeartbeat, MinutesAgo = datetime_diff('minute', now(), LastHeartbeat)'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
}

// ---- High CPU (Sev 1) ----
resource highCpuAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-high-cpu-${environmentName}'
  location: location
  tags: tags
  properties: {
    displayName: 'Arc Server High CPU'
    description: 'Fires when average CPU exceeds 90% over 5 minutes on any Arc-enrolled server'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    scopes: [
      logAnalyticsWorkspaceId
    ]
    criteria: {
      allOf: [
        {
          query: '''Perf
| where ObjectName == "Processor" and CounterName == "% Processor Time" and InstanceName == "_Total"
| where TimeGenerated > ago(5m)
| summarize AvgCPU = avg(CounterValue) by Computer
| where AvgCPU > 90'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
}

// ---- High Memory (Sev 2) ----
resource highMemoryAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-high-memory-${environmentName}'
  location: location
  tags: tags
  properties: {
    displayName: 'Arc Server High Memory'
    description: 'Fires when average memory usage exceeds 90% over 5 minutes on any Arc-enrolled server'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    scopes: [
      logAnalyticsWorkspaceId
    ]
    criteria: {
      allOf: [
        {
          query: '''Perf
| where TimeGenerated > ago(5m)
| where (ObjectName == "Memory" and CounterName == "% Committed Bytes In Use")
    or (ObjectName == "Memory" and CounterName == "% Used Memory")
| summarize AvgMem = avg(CounterValue) by Computer
| where AvgMem > 90'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
}

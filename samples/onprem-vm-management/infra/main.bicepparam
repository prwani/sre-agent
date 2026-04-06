using './main.bicep'

param environmentName = readEnvironmentVariable('AZURE_ENV_NAME', 'sre-onprem')
param location = readEnvironmentVariable('AZURE_LOCATION', 'swedencentral')
param arcResourceGroup = readEnvironmentVariable('ARC_RESOURCE_GROUP', 'rg-arcbox-itpro')
param deployingUserObjectId = readEnvironmentVariable('DEPLOYING_USER_OID', '')

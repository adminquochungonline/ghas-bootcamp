// Hạ tầng Azure Container Apps cho OctoGallery (ghas-bootcamp).
// Triển khai 2 pha (deploy.sh tự xử lý):
//   1. deployApps=false : Log Analytics, ACR, managed identity (AcrPull), Container Apps environment
//   2. deployApps=true  : thêm các container app sau khi image đã được build vào ACR
//
// Topology:
//   Internet --HTTPS--> frontend (ingress external, nginx)
//                         |-- /api/authn/*   --> authn-service   (ingress internal)
//                         |-- /api/gallery/* --> gallery-service (ingress internal)
//   storage-service (tuỳ chọn, ingress internal) - frontend hiện không gọi tới.

targetScope = 'resourceGroup'

@description('Region triển khai')
param location string = resourceGroup().location

@description('Tiền tố tên resource (chữ thường, số, dấu -)')
@minLength(2)
@maxLength(12)
param prefix string = 'ghas'

@description('false = chỉ tạo hạ tầng; true = tạo thêm các container app')
param deployApps bool = false

@description('Tag image trong ACR')
param imageTag string = 'latest'

@description('Client ID của GitHub OAuth App')
param githubClientId string = ''

@description('Client secret của GitHub OAuth App')
@secure()
param githubClientSecret string = ''

@description('Secret ký/kiểm tra JWT. Phải trùng secret authn-service dùng (hardcode trong source)')
@secure()
param jwtSecret string = ''

@description('true = giữ tối thiểu 1 replica cho frontend/authn (không cold start, tốn phí hơn)')
param alwaysOn bool = false

@description('Triển khai thêm storage-service (cần AWS S3)')
param deployStorageService bool = false

param awsS3Bucket string = ''
param awsRegion string = 'us-east-1'
@secure()
param awsAccessKeyId string = ''
@secure()
param awsSecretAccessKey string = ''

@description('Danh sách CIDR được phép truy cập frontend (rỗng = mở cho toàn Internet). App chứa lỗ hổng cố ý, nên giới hạn.')
param frontendAllowedCidrs array = []

param tags object = {
  project: 'ghas-bootcamp'
}

var suffix = uniqueString(resourceGroup().id, prefix)
var acrName = take('${replace(prefix, '-', '')}acr${suffix}', 50)
var frontendName = '${prefix}-frontend'
var authnName = '${prefix}-authn-service'
var galleryName = '${prefix}-gallery-service'
var storageName = '${prefix}-storage-service'
var acrPullRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')

// ---------------------------------------------------------------- Hạ tầng dùng chung

resource logs 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: '${prefix}-logs'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: false
  }
}

resource pullIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-acr-pull'
  location: location
  tags: tags
}

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, pullIdentity.id, acrPullRoleId)
  scope: acr
  properties: {
    roleDefinitionId: acrPullRoleId
    principalId: pullIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: '${prefix}-env'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

var frontendFqdn = '${frontendName}.${env.properties.defaultDomain}'
var oauthCallbackUrl = 'https://${frontendFqdn}/login/callback'

var commonConfig = {
  activeRevisionsMode: 'Single'
  registries: [
    {
      server: acr.properties.loginServer
      identity: pullIdentity.id
    }
  ]
}

var frontendIpRules = [for (cidr, i) in frontendAllowedCidrs: {
  name: 'allow-${i}'
  action: 'Allow'
  ipAddressRange: cidr
}]

var appIdentity = {
  type: 'UserAssigned'
  userAssignedIdentities: {
    '${pullIdentity.id}': {}
  }
}

// ---------------------------------------------------------------- Container apps

resource authn 'Microsoft.App/containerApps@2024-03-01' = if (deployApps) {
  name: authnName
  location: location
  tags: tags
  identity: appIdentity
  dependsOn: [ acrPull ]
  properties: {
    environmentId: env.id
    workloadProfileName: 'Consumption'
    configuration: union(commonConfig, {
      ingress: {
        external: false
        targetPort: 5000
        transport: 'http'
        // nginx gọi http://<app> trong cùng environment, không redirect sang HTTPS
        allowInsecure: true
      }
      secrets: [
        { name: 'github-client-secret', value: githubClientSecret }
      ]
    })
    template: {
      containers: [
        {
          name: 'authn-service'
          image: '${acr.properties.loginServer}/authn-service:${imageTag}'
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [
            { name: 'CLIENT_ID', value: githubClientId }
            { name: 'CLIENT_SECRET', secretRef: 'github-client-secret' }
            { name: 'OAUTH_REDIRECT_URI', value: oauthCallbackUrl }
          ]
        }
      ]
      scale: { minReplicas: alwaysOn ? 1 : 0, maxReplicas: 2 }
    }
  }
}

resource gallery 'Microsoft.App/containerApps@2024-03-01' = if (deployApps) {
  name: galleryName
  location: location
  tags: tags
  identity: appIdentity
  dependsOn: [ acrPull ]
  properties: {
    environmentId: env.id
    workloadProfileName: 'Consumption'
    configuration: union(commonConfig, {
      ingress: {
        external: false
        targetPort: 8081
        transport: 'http'
        allowInsecure: true
      }
      secrets: [
        { name: 'jwt-secret', value: jwtSecret }
      ]
    })
    template: {
      containers: [
        {
          name: 'gallery-service'
          image: '${acr.properties.loginServer}/gallery-service:${imageTag}'
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [
            { name: 'JWT_SECRET', secretRef: 'jwt-secret' }
            { name: 'DATABASE_PATH', value: '/data/galleries.db' }
            { name: 'ALLOWED_ORIGINS', value: 'https://${frontendFqdn}' }
          ]
        }
      ]
      // SQLite nằm trên filesystem của replica: cố định đúng 1 replica.
      // Dữ liệu mất khi replica bị thay (deploy revision mới, restart) - chấp nhận được cho lab.
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
}

resource frontend 'Microsoft.App/containerApps@2024-03-01' = if (deployApps) {
  name: frontendName
  location: location
  tags: tags
  identity: appIdentity
  // nginx resolve tên upstream lúc khởi động nên tạo backend trước
  dependsOn: [ acrPull, authn, gallery ]
  properties: {
    environmentId: env.id
    workloadProfileName: 'Consumption'
    configuration: union(commonConfig, {
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
        ipSecurityRestrictions: frontendIpRules
      }
    })
    template: {
      containers: [
        {
          name: 'frontend'
          image: '${acr.properties.loginServer}/frontend:${imageTag}'
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [
            { name: 'GITHUB_CLIENT_ID', value: githubClientId }
            { name: 'AUTHN_UPSTREAM', value: 'http://${authnName}' }
            { name: 'GALLERY_UPSTREAM', value: 'http://${galleryName}' }
          ]
          probes: [
            {
              type: 'Liveness'
              httpGet: { path: '/healthz', port: 8080 }
            }
            {
              type: 'Readiness'
              httpGet: { path: '/healthz', port: 8080 }
            }
          ]
        }
      ]
      scale: { minReplicas: alwaysOn ? 1 : 0, maxReplicas: 2 }
    }
  }
}

resource storage 'Microsoft.App/containerApps@2024-03-01' = if (deployApps && deployStorageService) {
  name: storageName
  location: location
  tags: tags
  identity: appIdentity
  dependsOn: [ acrPull ]
  properties: {
    environmentId: env.id
    workloadProfileName: 'Consumption'
    configuration: union(commonConfig, {
      ingress: {
        external: false
        targetPort: 8082
        transport: 'http'
        allowInsecure: true
      }
      secrets: [
        { name: 'jwt-secret', value: jwtSecret }
        { name: 'aws-access-key-id', value: awsAccessKeyId }
        { name: 'aws-secret-access-key', value: awsSecretAccessKey }
      ]
    })
    template: {
      containers: [
        {
          name: 'storage-service'
          image: '${acr.properties.loginServer}/storage-service:${imageTag}'
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: [
            { name: 'JWT_SECRET', secretRef: 'jwt-secret' }
            { name: 'CLOUD_AWS_S3_BUCKET', value: awsS3Bucket }
            { name: 'CLOUD_AWS_REGION_STATIC', value: awsRegion }
            { name: 'CLOUD_AWS_STACK_AUTO', value: 'false' }
            { name: 'CLOUD_AWS_CREDENTIALS_ACCESSKEY', secretRef: 'aws-access-key-id' }
            { name: 'CLOUD_AWS_CREDENTIALS_SECRETKEY', secretRef: 'aws-secret-access-key' }
          ]
        }
      ]
      scale: { minReplicas: 0, maxReplicas: 1 }
    }
  }
}

// ---------------------------------------------------------------- Outputs

output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output environmentName string = env.name
output environmentDefaultDomain string = env.properties.defaultDomain
output frontendUrl string = 'https://${frontendFqdn}'
output oauthCallbackUrl string = oauthCallbackUrl

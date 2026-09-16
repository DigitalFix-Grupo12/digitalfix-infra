<#
  Configura el API Manager (AWS API Gateway HTTP API) de DigitalFix. Idempotente.
   - Integracion HTTP_PROXY hacia el BFF en EC2 (reenvia el path original)
   - JWT Authorizer de Entra ID: valida firma (JWKS), expiracion, issuer y audience
   - Rutas explicitas por endpoint, protegidas con JWT + scope access_as_user
   - /actuator/health publico (monitoreo)
   - CORS restringido a los origenes del frontend

  Uso:
    .\scripts\Configure-ApiGateway.ps1 -BackendHost 54.160.201.130
#>
param(
  [Parameter(Mandatory = $true)][string]$BackendHost,
  [string]$Region = 'us-east-1',
  [string]$ApiId = '7s6qn2mb8h',
  [string]$TenantId = 'ac1c32f1-bc10-4ded-b8c0-102ac9a1fd68',
  [string]$ApiClientId = 'fb8ea665-ee45-4790-8112-eade3bd230e5',
  [string]$Scope = 'access_as_user',
  [string[]]$AllowedOrigins = @('http://localhost:4200', 'https://main.dehlzhnwtqj7a.amplifyapp.com')
)
$ErrorActionPreference = 'Stop'
function Invoke-Aws { $out = & aws.exe @args --region $Region --output json; if ($LASTEXITCODE -ne 0) { throw "aws $($args -join ' ') fallo" }; if ($out) { ($out | Out-String) | ConvertFrom-Json } }

$authName = 'entra-id-jwt'
$integrationDesc = 'digitalfix-bff'
$issuer = "https://login.microsoftonline.com/$TenantId/v2.0"

# Rutas: metodo + path (los {param} se reenvian tal cual al BFF)
$routes = @(
  'GET /api/workorders',
  'POST /api/workorders',
  'GET /api/workorders/{id}',
  'PUT /api/workorders/{id}/status',
  'GET /api/catalog/services',
  'GET /api/catalog/services/{id}',
  'GET /api/report/kpis',
  'GET /api/audit'
)
$publicRoutes = @('GET /actuator/health')

# 1) Integracion hacia el BFF
$integrations = (Invoke-Aws apigatewayv2 get-integrations --api-id $ApiId).Items
$integ = $integrations | Where-Object { $_.Description -eq $integrationDesc } | Select-Object -First 1
$uri = "http://${BackendHost}:8080"
$paramsFile = Join-Path $env:TEMP 'apigw-request-params.json'
[IO.File]::WriteAllText($paramsFile, '{"overwrite:path":"$request.path"}')
$paramsArg = "file://$paramsFile"
if ($integ) {
  Invoke-Aws apigatewayv2 update-integration --api-id $ApiId --integration-id $integ.IntegrationId `
    --integration-uri $uri --request-parameters $paramsArg | Out-Null
} else {
  $integ = Invoke-Aws apigatewayv2 create-integration --api-id $ApiId --integration-type HTTP_PROXY `
    --integration-method ANY --integration-uri $uri --payload-format-version 1.0 `
    --request-parameters $paramsArg --timeout-in-millis 29000 --description $integrationDesc
}
$target = "integrations/$($integ.IntegrationId)"
Write-Host "Integracion $($integ.IntegrationId) -> $uri"

# 2) JWT Authorizer (Entra ID v2: aud = GUID; se acepta tambien api://GUID)
$auth = (Invoke-Aws apigatewayv2 get-authorizers --api-id $ApiId).Items | Where-Object { $_.Name -eq $authName } | Select-Object -First 1
$jwtCfg = "Issuer=$issuer,Audience=$ApiClientId,api://$ApiClientId"
if ($auth) {
  Invoke-Aws apigatewayv2 update-authorizer --api-id $ApiId --authorizer-id $auth.AuthorizerId --jwt-configuration $jwtCfg | Out-Null
} else {
  $auth = Invoke-Aws apigatewayv2 create-authorizer --api-id $ApiId --name $authName --authorizer-type JWT `
    --identity-source '$request.header.Authorization' --jwt-configuration $jwtCfg
}
Write-Host "Authorizer $($auth.AuthorizerId) issuer=$issuer"

# 3) Rutas
$existing = (Invoke-Aws apigatewayv2 get-routes --api-id $ApiId).Items
foreach ($rk in $routes + $publicRoutes) {
  $isPublic = $publicRoutes -contains $rk
  $r = $existing | Where-Object { $_.RouteKey -eq $rk } | Select-Object -First 1
  $authArgs = if ($isPublic) { @('--authorization-type', 'NONE') } else {
    @('--authorization-type', 'JWT', '--authorizer-id', $auth.AuthorizerId, '--authorization-scopes', $Scope) }
  if ($r) {
    Invoke-Aws apigatewayv2 update-route --api-id $ApiId --route-id $r.RouteId --target $target @authArgs | Out-Null
  } else {
    Invoke-Aws apigatewayv2 create-route --api-id $ApiId --route-key $rk --target $target @authArgs | Out-Null
  }
  Write-Host ("  {0,-34} {1}" -f $rk, $(if ($isPublic) { 'publica' } else { "JWT + scope $Scope" }))
}

# 4) Eliminar rutas que no son parte del contrato (ej. el antiguo ANY /{proxy+})
$wanted = $routes + $publicRoutes
foreach ($r in (Invoke-Aws apigatewayv2 get-routes --api-id $ApiId).Items) {
  if ($wanted -notcontains $r.RouteKey) {
    Invoke-Aws apigatewayv2 delete-route --api-id $ApiId --route-id $r.RouteId | Out-Null
    Write-Host "  eliminada: $($r.RouteKey)"
  }
}
# Integraciones huerfanas
$used = (Invoke-Aws apigatewayv2 get-routes --api-id $ApiId).Items | ForEach-Object { $_.Target }
foreach ($i in (Invoke-Aws apigatewayv2 get-integrations --api-id $ApiId).Items) {
  if ($used -notcontains "integrations/$($i.IntegrationId)") {
    Invoke-Aws apigatewayv2 delete-integration --api-id $ApiId --integration-id $i.IntegrationId | Out-Null
    Write-Host "  integracion eliminada: $($i.IntegrationId)"
  }
}

# 5) CORS
$origins = $AllowedOrigins -join ','
Invoke-Aws apigatewayv2 update-api --api-id $ApiId `
  --cors-configuration "AllowOrigins=$origins,AllowMethods=GET,POST,PUT,OPTIONS,AllowHeaders=authorization,content-type,MaxAge=3600" | Out-Null
Write-Host "CORS: $origins (GET, POST, PUT, OPTIONS; headers authorization, content-type)"
Write-Host 'API Gateway configurado.' -ForegroundColor Green

<#
  Aplica los tenants de Microsoft Entra ID de config\tenants.json (opcion A: una URL, dos nubes).

  Cada integrante tiene su tenant y su propia cuenta de AWS (EC2 apps + ec2-mq + API Gateway).
  El frontend es uno solo (Amplify en la cuenta de Kevin) y su selector de tenant envia cada
  login al API Gateway de la cuenta de ese integrante.

  En la cuenta del integrante indicado con -Owner:
   1. SSM /digitalfix/entra/bff-env  -> AZURE_TENANT_ID / AZURE_API_CLIENT_ID de SU tenant
      (la EC2 los copia a /etc/digitalfix/entra.env al arrancar).
   2. API Gateway (apiGatewayId o, si esta vacio, uno nuevo llamado apiGatewayName) con el
      JWT authorizer de su tenant y CORS hacia la URL de Amplify, apuntando al BFF de su EC2.
   3. BFF de la EC2 actual: reinicio por SSM Run Command (si la cuenta lo permite).
   4. frontend-digitalfix/src/app/core/config/tenants.ts con TODOS los tenants completos
      que ya tienen API Gateway (lo publica Kevin con Deploy-Frontend.ps1).
  Guarda en tenants.json el apiGatewayId y la cuenta AWS del integrante; si se ejecuta con
  credenciales de otra cuenta, se detiene.

  Uso:
    .\scripts\Apply-Tenants.ps1                  # cuenta de Kevin
    .\scripts\Apply-Tenants.ps1 -Owner boris     # cuenta de Boris
#>
param(
  [ValidateSet('kevin', 'boris')][string]$Owner = 'kevin',
  [string]$Region = 'us-east-1',
  [string[]]$AllowedOrigins = @('http://localhost:4200', 'https://main.dehlzhnwtqj7a.amplifyapp.com'),
  [switch]$SkipEc2Restart
)
$ErrorActionPreference = 'Stop'
function Invoke-Aws { $out = & aws.exe @args --region $Region --output json; if ($LASTEXITCODE -ne 0) { throw "aws $($args -join ' ') fallo" }; if ($out) { ($out | Out-String) | ConvertFrom-Json } }
. (Join-Path $PSScriptRoot 'DigitalFix.Common.ps1')
function Write-Utf8NoBom([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false)) }

$root = Split-Path $PSScriptRoot -Parent
$cfgPath = Join-Path $root 'config\tenants.json'
$cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
$all = @($cfg.tenants | ForEach-Object { $_ })
$guid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

$complete = @()
foreach ($t in $all) {
  $missing = @('domain', 'tenantId', 'spaClientId', 'apiClientId' | Where-Object { -not $t.$_ })
  if ($missing.Count -gt 0) { Write-Warning "$($t.label) incompleto: falta $($missing -join ', ') en config\tenants.json"; continue }
  foreach ($f in 'tenantId', 'spaClientId', 'apiClientId') {
    if ($t.$f -notmatch $guid) { throw "$($t.label): $f no es un GUID valido ($($t.$f))" }
  }
  $complete += $t
}
$me = $complete | Where-Object { $_.key -eq $Owner } | Select-Object -First 1
if (-not $me) { throw "El tenant '$Owner' no esta completo en config\tenants.json." }

$account = Get-AwsAccountId
if (-not ($me.PSObject.Properties.Name -contains 'awsAccountId')) { $me | Add-Member -NotePropertyName awsAccountId -NotePropertyValue '' }
if ($me.awsAccountId -and $me.awsAccountId -ne $account) {
  throw "Las credenciales AWS son de la cuenta $account, pero $($me.label) usa la cuenta $($me.awsAccountId). Revisa ~\.aws\credentials."
}
$me.awsAccountId = $account
$tenants = @($me)
Write-Host "Cuenta AWS $account -> $($me.label) ($($me.domain))" -ForegroundColor Cyan

# 1) Variables del BFF en SSM (Parameter Store)
$envLines = @()
for ($i = 0; $i -lt $tenants.Count; $i++) {
  $suffix = if ($i -eq 0) { '' } else { "_$($i + 1)" }
  $envLines += "AZURE_TENANT_ID$suffix=$($tenants[$i].tenantId)"
  $envLines += "AZURE_API_CLIENT_ID$suffix=$($tenants[$i].apiClientId)"
}
$envLines += "DIGITALFIX_DEMO_DOMAIN=$($tenants[0].domain)"
$envText = $envLines -join "`n"
$paramFile = Join-Path $env:TEMP 'digitalfix-entra-param.json'
Write-Utf8NoBom $paramFile (@{ Name = '/digitalfix/entra/bff-env'; Type = 'String'; Overwrite = $true; Value = $envText } | ConvertTo-Json)
Invoke-Aws ssm put-parameter --cli-input-json "file://$paramFile" | Out-Null
Write-Host "SSM /digitalfix/entra/bff-env actualizado ($($tenants.Count) tenant(s))"

# 2) Un API Gateway por tenant, hacia el BFF en la IP elastica
$eip = (Invoke-Aws ec2 describe-addresses --filters 'Name=tag:Name,Values=digitalfix-eip').Addresses | Select-Object -First 1
if (-not $eip) {
  Write-Warning 'Aun no existe la IP elastica digitalfix-eip: el API Gateway se configura en Deploy-EC2.ps1.'
  $tenants4gw = @()
} else { $tenants4gw = $tenants }
foreach ($t in $tenants4gw) {
  Write-Host "`n--- $($t.label) ---" -ForegroundColor Cyan
  & (Join-Path $PSScriptRoot 'Configure-ApiGateway.ps1') -BackendHost $eip.PublicIp -Region $Region `
    -ApiId $t.apiGatewayId -ApiName $t.apiGatewayName -TenantId $t.tenantId -ApiClientId $t.apiClientId `
    -AllowedOrigins $AllowedOrigins
  if (-not $t.apiGatewayId) {
    $t.apiGatewayId = ((Invoke-Aws apigatewayv2 get-apis).Items | Where-Object { $_.Name -eq $t.apiGatewayName } | Select-Object -First 1).ApiId
  }
}
Write-Utf8NoBom $cfgPath ($cfg | ConvertTo-Json -Depth 5)

# 3) BFF en la EC2 actual (SSM Run Command)
if (-not $SkipEc2Restart -and $eip) {
  if (-not $eip.InstanceId) {
    Write-Warning 'La IP elastica no esta asociada a ninguna EC2: se aplicara en el proximo Deploy-EC2.ps1.'
  } else {
    $unit = '/etc/systemd/system/ms-digitalfix-bff.service'
    $cmds = @(
      'set -e',
      'mkdir -p /etc/digitalfix',
      "aws ssm get-parameter --region $Region --name /digitalfix/entra/bff-env --query Parameter.Value --output text > /etc/digitalfix/entra.env",
      "sed -i '/^Environment=AZURE_/d' $unit",
      "grep -q entra.env $unit || sed -i '/^\[Service\]/a EnvironmentFile=-/etc/digitalfix/entra.env' $unit",
      'systemctl daemon-reload',
      'systemctl restart ms-digitalfix-bff',
      'for i in $(seq 1 30); do curl -sf http://localhost:8080/actuator/health && exit 0; sleep 5; done; exit 1'
    )
    $cmdFile = Join-Path $env:TEMP 'digitalfix-bff-cmd.json'
    Write-Utf8NoBom $cmdFile (@{ commands = $cmds } | ConvertTo-Json)
    try {
      $sent = Invoke-Aws ssm send-command --instance-ids $eip.InstanceId --document-name AWS-RunShellScript `
        --comment 'DigitalFix: tenants Entra ID del BFF' --parameters "file://$cmdFile"
      $cmdId = $sent.Command.CommandId
      Write-Host "Reiniciando BFF en $($eip.InstanceId) (comando $cmdId)..."
      $status = 'Pending'
      for ($i = 0; $i -lt 40 -and $status -in 'Pending', 'InProgress', 'Delayed'; $i++) {
        Start-Sleep 5
        try { $status = (Invoke-Aws ssm get-command-invocation --command-id $cmdId --instance-id $eip.InstanceId 2>$null).Status } catch { }
      }
      if ($status -eq 'Success') { Write-Host 'BFF reiniciado con los tenants nuevos (health UP).' -ForegroundColor Green }
      else { Write-Warning "El reinicio remoto termino en estado '$status'. Revisa con: sudo journalctl -u ms-digitalfix-bff -n 50" }
    } catch {
      Write-Warning "No se pudo usar SSM Run Command ($($_.Exception.Message)). Aplica el cambio con .\scripts\Deploy-EC2.ps1 -TerminateOld"
    }
  }
}

# 4) Config del frontend (solo tenants completos)
$front = Join-Path (Split-Path $root -Parent) 'frontend-digitalfix\src\app\core\config\tenants.ts'
if (Test-Path (Split-Path $front -Parent)) {
  $items = foreach ($t in ($complete | Where-Object { $_.apiGatewayId })) {
@"
  {
    key: '$($t.key)',
    label: '$($t.label)',
    domain: '$($t.domain)',
    tenantId: '$($t.tenantId)',
    spaClientId: '$($t.spaClientId)',
    apiClientId: '$($t.apiClientId)',
    apiBaseUrl: 'https://$($t.apiGatewayId).execute-api.$Region.amazonaws.com',
  },
"@
  }
  $ts = "// Generado por digitalfix-infra/scripts/Apply-Tenants.ps1 desde config/tenants.json.`n" +
        "// No editar a mano: actualiza tenants.json y vuelve a ejecutar el script.`n" +
        "import { TenantProfile } from './tenant-profile';`n`n" +
        "export const tenantProfiles: TenantProfile[] = [`n" + (($items -join "`n") -replace "`r", '') + "`n];`n"
  Write-Utf8NoBom $front $ts
  Write-Host "Frontend: $front generado. Kevin lo publica con .\scripts\Deploy-Frontend.ps1 (commit de tenants.json y tenants.ts)"
} else {
  Write-Warning "No encontre frontend-digitalfix junto a digitalfix-infra; tenants.ts no se genero."
}

Write-Host "`nResumen:" -ForegroundColor Green
$complete | Where-Object { $_.apiGatewayId } | ForEach-Object {
  [PSCustomObject]@{ Tenant = $_.label; Dominio = $_.domain; Gateway = "https://$($_.apiGatewayId).execute-api.$Region.amazonaws.com" }
} | Format-Table -AutoSize

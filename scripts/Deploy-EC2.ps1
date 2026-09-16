<#
  Despliega los 5 servicios de DigitalFix en una EC2 nueva con IP elastica y
  configura el API Gateway hacia ella.

  Requisitos:
   - Repos publicos en https://github.com/DigitalFix-Grupo12
   - Base de datos creada con .\scripts\Create-Database.ps1 (si no, los servicios usan H2)

  Uso:
    .\scripts\Deploy-EC2.ps1 -Name digitalfix-v5
    .\scripts\Deploy-EC2.ps1 -Name digitalfix-v5 -TerminateOld   # termina las otras EC2 digitalfix
#>
param(
  [string]$Name = ('digitalfix-' + (Get-Date -Format 'yyyyMMdd-HHmm')),
  [string]$Region = 'us-east-1',
  [string]$Ami = 'ami-0b301e023c868669e',
  [string]$InstanceType = 't3.micro',
  [string]$KeyName = 'digitalfix-key',
  [string]$SecurityGroup = 'sg-0618473c6254147c7',
  [string]$InstanceProfile = 'LabInstanceProfile',
  [string[]]$AllowedOrigins = @('http://localhost:4200', 'https://main.dehlzhnwtqj7a.amplifyapp.com'),
  [int]$TimeoutMin = 30,
  [switch]$TerminateOld
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$userData = Join-Path $root 'aws\ec2-user-data.sh'
$ebs = Join-Path $root 'aws\ebs-block-device.json'
function Invoke-Aws { $out = & aws.exe @args --region $Region --output json; if ($LASTEXITCODE -ne 0) { throw "aws $($args -join ' ') fallo" }; if ($out) { ($out | Out-String) | ConvertFrom-Json } }

# 1) Verificar repos antes de gastar una instancia
foreach ($svc in 'ms-digitalfix-bff','ms-digitalfix-workorders','ms-digitalfix-catalog','ms-digitalfix-report','ms-digitalfix-audit') {
  git ls-remote "https://github.com/DigitalFix-Grupo12/$svc.git" *> $null
  if ($LASTEXITCODE -ne 0) { throw "El repo $svc no existe o no es publico." }
}
Write-Host 'Repos OK' -ForegroundColor Green

# 2) Lanzar instancia (rol LabInstanceProfile para leer SSM)
$run = Invoke-Aws ec2 run-instances --image-id $Ami --instance-type $InstanceType `
  --key-name $KeyName --security-group-ids $SecurityGroup `
  --iam-instance-profile "Name=$InstanceProfile" `
  --block-device-mappings "file://$ebs" --user-data "file://$userData" `
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$Name},{Key=Project,Value=DigitalFix}]"
$id = $run.Instances[0].InstanceId
Write-Host "Instancia $id lanzada, esperando estado running..."
aws.exe ec2 wait instance-running --region $Region --instance-ids $id

# 3) IP elastica (se reutiliza la misma entre despliegues y sobrevive a stop/start del lab)
$eip = (Invoke-Aws ec2 describe-addresses --filters 'Name=tag:Name,Values=digitalfix-eip').Addresses | Select-Object -First 1
if (-not $eip) {
  $eip = Invoke-Aws ec2 allocate-address --domain vpc --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=digitalfix-eip}]'
}
Invoke-Aws ec2 associate-address --allocation-id $eip.AllocationId --instance-id $id --allow-reassociation | Out-Null
$ip = $eip.PublicIp
Write-Host "IP elastica: $ip"

# 4) Esperar fin del bootstrap (log expuesto temporalmente en :8081)
$deadline = (Get-Date).AddMinutes($TimeoutMin)
$log = ''
while ((Get-Date) -lt $deadline) {
  Start-Sleep 30
  try {
    # python http.server sirve .log como binario -> PowerShell entrega byte[]
    $raw = (Invoke-WebRequest "http://${ip}:8081/setup-debug.log" -UseBasicParsing -TimeoutSec 10).Content
    $log = if ($raw -is [byte[]]) { [Text.Encoding]::UTF8.GetString($raw) } else { [string]$raw }
  } catch { $log = '' }
  $last = ($log -split "`n" | Where-Object { $_ -match '^\+ (timeout|systemctl|cp)' } | Select-Object -Last 1)
  Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $last)
  if ($log -match '=== FIN') { break }
}
if ($log -notmatch '=== FIN') { throw "Timeout esperando bootstrap. Revisa http://${ip}:8081/setup-debug.log" }
$healthBlock = (($log -split '=== HEALTH ===')[1] -split '=== SYSTEMD')[0]
Write-Host "Health:`n$healthBlock"

# 5) Verificar BFF y configurar el API Gateway
$bff = try { (Invoke-WebRequest "http://${ip}:8080/actuator/health" -UseBasicParsing -TimeoutSec 10).StatusCode } catch { 0 }
if ($bff -ne 200) { throw "El BFF no responde en ${ip}:8080. Gateway NO modificado." }
& (Join-Path $PSScriptRoot 'Configure-ApiGateway.ps1') -BackendHost $ip -Region $Region -AllowedOrigins $AllowedOrigins

# 6) Opcional: terminar instancias antiguas
if ($TerminateOld) {
  try {
    $old = @((Invoke-Aws ec2 describe-instances --filters 'Name=tag:Project,Values=DigitalFix' 'Name=instance-state-name,Values=running,stopped').Reservations |
      ForEach-Object { $_.Instances } | Where-Object { $_.InstanceId -ne $id } | ForEach-Object { $_.InstanceId })
    if ($old.Count -gt 0) {
      $ErrorActionPreference = 'Continue'
      & aws.exe ec2 terminate-instances --region $Region --instance-ids $old --query 'TerminatingInstances[].InstanceId' --output text 2>$null
      Write-Host "Terminadas: $($old -join ', ')"
      $ErrorActionPreference = 'Stop'
    }
  } catch {
    Write-Warning "No se pudieron terminar las instancias antiguas: $($_.Exception.Message). Terminalas desde la consola."
  }
}

$gw = 'https://7s6qn2mb8h.execute-api.us-east-1.amazonaws.com'
$code = try { (Invoke-WebRequest "$gw/api/workorders" -UseBasicParsing -TimeoutSec 15).StatusCode } catch { [int]$_.Exception.Response.StatusCode }
Write-Host "Gateway sin token -> HTTP $code (esperado 401)" -ForegroundColor Cyan
Write-Host "Listo. Instancia: $id ($ip)" -ForegroundColor Green

<#
  Despliega los 5 servicios de DigitalFix en una EC2 nueva y apunta el
  API Gateway a ella. Requisito: los 5 repos existen y estan pusheados en
  https://github.com/DigitalFix-Grupo12/<servicio>.

  Uso:
    .\scripts\Deploy-EC2.ps1                    # crea digitalfix-v4 y cambia el Gateway
    .\scripts\Deploy-EC2.ps1 -Name digitalfix-v5
#>
param(
  [string]$Name = 'digitalfix-v4',
  [string]$Region = 'us-east-1',
  [string]$Ami = 'ami-0b301e023c868669e',
  [string]$InstanceType = 't3.micro',
  [string]$KeyName = 'digitalfix-key',
  [string]$SecurityGroup = 'sg-0618473c6254147c7',
  [string]$ApiId = '7s6qn2mb8h',
  [string]$IntegrationId = 'epnlkok',
  [string]$AllowedOrigin = 'http://localhost:4200',
  [int]$TimeoutMin = 30
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$userData = Join-Path $root 'aws\ec2-user-data.sh'
$ebs = Join-Path $root 'aws\ebs-block-device.json'

# 1) Verificar que los repos existen antes de gastar una instancia
foreach ($svc in 'ms-digitalfix-bff','ms-digitalfix-workorders','ms-digitalfix-catalog','ms-digitalfix-report','ms-digitalfix-audit') {
  git ls-remote "https://github.com/DigitalFix-Grupo12/$svc.git" *> $null
  if ($LASTEXITCODE -ne 0) { throw "El repo $svc no existe o no es publico. Crealo y haz push antes de desplegar." }
}
Write-Host 'Repos OK' -ForegroundColor Green

# 2) Lanzar instancia
$id = aws ec2 run-instances --region $Region --image-id $Ami --instance-type $InstanceType `
  --key-name $KeyName --security-group-ids $SecurityGroup `
  --block-device-mappings "file://$ebs" --user-data "file://$userData" `
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$Name}]" `
  --query 'Instances[0].InstanceId' --output text
Write-Host "Instancia $id lanzada, esperando estado running..."
aws ec2 wait instance-running --region $Region --instance-ids $id
$ip = aws ec2 describe-instances --region $Region --instance-ids $id --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
Write-Host "IP publica: $ip"

# 3) Esperar fin del bootstrap (log expuesto en :8081)
$deadline = (Get-Date).AddMinutes($TimeoutMin)
$log = ''
while ((Get-Date) -lt $deadline) {
  Start-Sleep 30
  try {
    # python http.server sirve .log como binario -> PowerShell entrega byte[]
    $raw = (Invoke-WebRequest "http://${ip}:8081/setup-debug.log" -UseBasicParsing -TimeoutSec 10).Content
    $log = if ($raw -is [byte[]]) { [Text.Encoding]::UTF8.GetString($raw) } else { [string]$raw }
  } catch { $log = '' }
  $last = ($log -split "`n" | Where-Object { $_ -match '^(\+ )?(timeout|systemctl|echo)' } | Select-Object -Last 1)
  Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $last)
  if ($log -match '=== FIN') { break }
}
if ($log -notmatch '=== FIN') { throw "Timeout esperando bootstrap. Revisa http://${ip}:8081/setup-debug.log" }

$healthBlock = ($log -split '=== HEALTH ===')[1] -split '=== SYSTEMD' | Select-Object -First 1
Write-Host "Health:`n$healthBlock"

# 4) Verificar BFF directo y apuntar el Gateway
$bff = try { (Invoke-WebRequest "http://${ip}:8080/actuator/health" -UseBasicParsing -TimeoutSec 10).StatusCode } catch { 0 }
if ($bff -ne 200) { throw "El BFF no responde en ${ip}:8080. Gateway NO modificado." }

aws apigatewayv2 update-integration --region $Region --api-id $ApiId --integration-id $IntegrationId `
  --integration-uri "http://${ip}:8080/{proxy}" --query 'IntegrationUri' --output text

# CORS en el API Manager (API Gateway responde el preflight e ignora los headers CORS del backend)
aws apigatewayv2 update-api --region $Region --api-id $ApiId `
  --cors-configuration "AllowOrigins=$AllowedOrigin,AllowMethods=GET,POST,PUT,DELETE,OPTIONS,AllowHeaders=authorization,content-type,MaxAge=3600" `
  --query 'CorsConfiguration.AllowOrigins' --output text

$gw = "https://$ApiId.execute-api.$Region.amazonaws.com/api/workorders"
$code = try { (Invoke-WebRequest $gw -UseBasicParsing -TimeoutSec 15).StatusCode } catch { [int]$_.Exception.Response.StatusCode }
Write-Host "Gateway sin token -> HTTP $code (esperado 401)" -ForegroundColor Cyan
Write-Host "Listo. Instancia: $id ($ip)" -ForegroundColor Green

<#
  Entorno local identico para todos los integrantes (EP3/EP4):
   1. Cluster RabbitMQ de 2 nodos con docker compose (mq/compose.yml)
   2. Compila y levanta los microservicios, cada uno en su propia ventana
      (perfil por defecto = H2 en memoria; RabbitMQ en localhost:5672,5673)

  Requisitos: Docker Desktop, JDK 17+, Maven, repos clonados en la misma carpeta:
    digitalfix\digitalfix-infra, digitalfix\ms-digitalfix-*, digitalfix\frontend-digitalfix

  Uso (desde digitalfix-infra):
    .\scripts\Start-Local.ps1                  # cluster + todos los servicios
    .\scripts\Start-Local.ps1 -SoloMq          # solo el cluster RabbitMQ
    .\scripts\Start-Local.ps1 -SinCompilar     # usa los jar ya compilados
  Detener: cerrar las ventanas de los servicios y  docker compose -f mq\compose.yml down
#>
param(
  [switch]$SoloMq,
  [switch]$SinCompilar
)
$ErrorActionPreference = 'Stop'
$infra = Split-Path $PSScriptRoot -Parent
$root = Split-Path $infra -Parent
$mq = Join-Path $infra 'mq'

# 1) Cluster RabbitMQ
if (-not (Test-Path (Join-Path $mq '.env'))) {
  Copy-Item (Join-Path $mq '.env.example') (Join-Path $mq '.env')
  Write-Host 'mq\.env creado desde .env.example (usuario digitalfix)' -ForegroundColor Yellow
}
Push-Location $mq
docker compose up -d
if ($LASTEXITCODE -ne 0) { Pop-Location; throw 'docker compose fallo: Docker Desktop esta abierto?' }
Write-Host 'Esperando que rabbit1 y rabbit2 queden healthy...'
for ($i = 0; $i -lt 36; $i++) {
  $healthy = @(docker compose ps --format '{{.Health}}' | Where-Object { $_ -eq 'healthy' }).Count
  if ($healthy -ge 2) { break }
  Start-Sleep 5
}
docker compose ps
docker exec rabbit1 rabbitmqctl cluster_status
Pop-Location
Write-Host 'UI: http://localhost:15672 y http://localhost:15673' -ForegroundColor Cyan
if ($SoloMq) { return }

# Credenciales de las apps = las del .env del cluster
$envVars = @{}
Get-Content (Join-Path $mq '.env') | Where-Object { $_ -match '^\s*([A-Z_]+)=(.*)$' } | ForEach-Object {
  $envVars[$Matches[1]] = $Matches[2].Trim()
}

# 2) Servicios (notify antes que workorders: declara colas y DLQ)
$services = [ordered]@{
  'ms-digitalfix-audit'        = 8085
  'ms-digitalfix-catalog'      = 8083
  'ms-digitalfix-notify'       = 8086
  'ms-digitalfix-workorders'   = 8082
  'ms-digitalfix-report'       = 8084
  'ms-digitalfix-rabbit-admin' = 8087
  'ms-digitalfix-bff'          = 8080
}
foreach ($svc in $services.Keys) {
  $dir = Join-Path $root $svc
  if (-not (Test-Path $dir)) { Write-Warning "No existe $dir (clonar el repo)"; continue }
  if (-not $SinCompilar) {
    Write-Host "Compilando $svc..."
    Push-Location $dir
    mvn -q -B package -DskipTests
    $ok = $LASTEXITCODE -eq 0
    Pop-Location
    if (-not $ok) { throw "Fallo la compilacion de $svc" }
  }
  $jar = Get-ChildItem (Join-Path $dir 'target') -Filter '*.jar' | Where-Object { $_.Name -notlike '*original*' } | Select-Object -First 1
  $cmd = @(
    "`$host.UI.RawUI.WindowTitle = '$svc :$($services[$svc])'",
    "`$env:RABBITMQ_USERNAME = '$($envVars['RABBITMQ_USER'])'",
    "`$env:RABBITMQ_PASSWORD = '$($envVars['RABBITMQ_PASS'])'",
    "`$env:AZURE_TENANT_ID = 'ac1c32f1-bc10-4ded-b8c0-102ac9a1fd68'",
    "`$env:AZURE_API_CLIENT_ID = 'fb8ea665-ee45-4790-8112-eade3bd230e5'",
    "java -jar '$($jar.FullName)'"
  ) -join '; '
  Start-Process powershell -ArgumentList '-NoExit', '-Command', $cmd
  Write-Host "  $svc -> http://localhost:$($services[$svc])" -ForegroundColor Green
  Start-Sleep 8
}
Write-Host ''
Write-Host 'Listo. Frontend: cd ..\frontend-digitalfix; ng serve  (para usar el BFF local cambiar baseUrl en app-config.ts)' -ForegroundColor Cyan

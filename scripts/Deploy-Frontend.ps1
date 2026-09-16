<#
  Publica el frontend Angular en AWS Amplify Hosting (HTTPS, CDN) mediante
  deploy manual (zip). Idempotente: reutiliza la app/rama si ya existen.

  Requisitos: frontend-digitalfix clonado junto a digitalfix-infra, Node + Angular CLI.

  Uso:
    .\scripts\Deploy-Frontend.ps1
#>
param(
  [string]$Region = 'us-east-1',
  [string]$AppName = 'digitalfix-frontend',
  [string]$Branch = 'main',
  [switch]$SkipBuild
)
$ErrorActionPreference = 'Stop'
function Invoke-Aws { $out = & aws.exe @args --region $Region --output json; if ($LASTEXITCODE -ne 0) { throw "aws $($args -join ' ') fallo" }; if ($out) { ($out | Out-String) | ConvertFrom-Json } }

$workspace = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$front = Join-Path $workspace 'frontend-digitalfix'
$dist = Join-Path $front 'dist\frontend-digitalfix\browser'

# 1) Build de produccion
if (-not $SkipBuild) {
  Push-Location $front
  try {
    cmd /c 'npx ng build --configuration production'
    if ($LASTEXITCODE -ne 0) { throw 'ng build fallo' }
  } finally { Pop-Location }
}
if (-not (Test-Path (Join-Path $dist 'index.html'))) { throw "No existe $dist\index.html" }

# 2) Zip con rutas '/' (Compress-Archive de PS 5.1 usa '\' y Amplify no lo acepta)
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zip = Join-Path $env:TEMP 'digitalfix-frontend.zip'
Remove-Item $zip -ErrorAction SilentlyContinue
$archive = [IO.Compression.ZipFile]::Open($zip, 'Create')
try {
  Get-ChildItem $dist -Recurse -File | ForEach-Object {
    $entry = $_.FullName.Substring($dist.Length + 1).Replace('\', '/')
    [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $_.FullName, $entry)
  }
} finally { $archive.Dispose() }
Write-Host "Zip: $zip ($([math]::Round((Get-Item $zip).Length / 1KB)) KB)"

# 3) App Amplify con rewrite SPA (rutas de Angular -> index.html)
$rulesFile = Join-Path $env:TEMP 'amplify-rules.json'
$rules = '[{"source":"</^[^.]+$|\\.(?!(css|gif|ico|jpg|jpeg|js|png|txt|svg|woff|woff2|ttf|map|json|webp)$)([^.]+$)/>","target":"/index.html","status":"200"}]'
[IO.File]::WriteAllText($rulesFile, $rules)

$app = (Invoke-Aws amplify list-apps).apps | Where-Object { $_.name -eq $AppName } | Select-Object -First 1
if (-not $app) {
  $app = (Invoke-Aws amplify create-app --name $AppName --platform WEB --custom-rules "file://$rulesFile" `
    --description 'DigitalFix - SPA Angular con MSAL').app
} else {
  Invoke-Aws amplify update-app --app-id $app.appId --custom-rules "file://$rulesFile" | Out-Null
}
$appId = $app.appId
$branches = (Invoke-Aws amplify list-branches --app-id $appId).branches
if (-not ($branches | Where-Object { $_.branchName -eq $Branch })) {
  Invoke-Aws amplify create-branch --app-id $appId --branch-name $Branch --stage PRODUCTION | Out-Null
}

# 4) Deploy manual
$dep = Invoke-Aws amplify create-deployment --app-id $appId --branch-name $Branch
Invoke-WebRequest -Uri $dep.zipUploadUrl -Method Put -InFile $zip -ContentType 'application/zip' -UseBasicParsing | Out-Null
$job = (Invoke-Aws amplify start-deployment --app-id $appId --branch-name $Branch --job-id $dep.jobId).jobSummary
do {
  Start-Sleep 5
  $status = (Invoke-Aws amplify get-job --app-id $appId --branch-name $Branch --job-id $job.jobId).job.summary.status
  Write-Host "  deploy: $status"
} while ($status -in 'PENDING', 'PROVISIONING', 'RUNNING', 'CANCELLING')
if ($status -ne 'SUCCEED') { throw "Deploy Amplify termino en $status" }

$url = "https://$Branch.$($app.defaultDomain)"
Write-Host "Frontend publicado: $url" -ForegroundColor Green
Write-Host 'Recuerda: esta URL debe estar como Redirect URI (SPA) en Entra ID y como origen CORS del API Gateway.'
$url

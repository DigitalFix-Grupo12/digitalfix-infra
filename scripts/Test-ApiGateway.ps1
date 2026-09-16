<#
  Evidencia del API Manager: prueba cada ruta del API Gateway sin token,
  con token invalido y con un access token real, y guarda un reporte Markdown.

  Obtener el token: frontend -> "Mi sesion" -> "Copiar access token".

  Uso:
    .\scripts\Test-ApiGateway.ps1 -Token "eyJ0eXAi..."
    .\scripts\Test-ApiGateway.ps1                      # solo pruebas sin token / CORS
#>
param(
  [string]$Token,
  [string]$BaseUrl = 'https://7s6qn2mb8h.execute-api.us-east-1.amazonaws.com',
  [string]$Origin = 'https://main.dehlzhnwtqj7a.amplifyapp.com',
  [string]$ReportPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'evidencias\api-gateway.md'),
  [switch]$WriteFlow
)
$ErrorActionPreference = 'Stop'

function Invoke-Api([string]$Method, [string]$Path, [hashtable]$Headers = @{}, [string]$Body) {
  $p = @{ Method = $Method; Uri = "$BaseUrl$Path"; Headers = $Headers; UseBasicParsing = $true; TimeoutSec = 20 }
  if ($Body) { $p.Body = [Text.Encoding]::UTF8.GetBytes($Body); $p.ContentType = 'application/json; charset=utf-8' }
  try {
    $r = Invoke-WebRequest @p
    $raw = $r.RawContentStream.ToArray()
    return [pscustomobject]@{ Status = [int]$r.StatusCode; Body = [Text.Encoding]::UTF8.GetString($raw); Headers = $r.Headers }
  } catch {
    $resp = $_.Exception.Response
    if (-not $resp) { return [pscustomobject]@{ Status = 0; Body = $_.Exception.Message; Headers = @{} } }
    $txt = (New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)).ReadToEnd()
    return [pscustomobject]@{ Status = [int]$resp.StatusCode; Body = $txt; Headers = $resp.Headers }
  }
}

function Get-Claims([string]$Jwt) {
  $b64 = $Jwt.Split('.')[1].Replace('-', '+').Replace('_', '/')
  switch ($b64.Length % 4) { 2 { $b64 += '==' } 3 { $b64 += '=' } }
  [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | ConvertFrom-Json
}

function Short([string]$s, [int]$n = 90) {
  $s = ($s -replace '\s+', ' ').Trim()
  if ($s.Length -gt $n) { $s.Substring(0, $n) + '...' } else { $s }
}

$routes = @(
  @{ M = 'GET'; P = '/api/workorders';                 Roles = @('Admin', 'Supervisor', 'Cliente') },
  @{ M = 'GET'; P = '/api/workorders/1';               Roles = @('Admin', 'Supervisor', 'Cliente') },
  @{ M = 'GET'; P = '/api/catalog/services';           Roles = @('Admin', 'Supervisor') },
  @{ M = 'GET'; P = '/api/catalog/services/1';         Roles = @('Admin', 'Supervisor') },
  @{ M = 'GET'; P = '/api/report/kpis?range=last24h';  Roles = @('Admin') },
  @{ M = 'GET'; P = '/api/audit?limit=5';              Roles = @('Admin', 'Auditor') }
)

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# Evidencia API Gateway - DigitalFix")
$lines.Add("")
$lines.Add("- Fecha: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') (hora local)")
$lines.Add("- API: $BaseUrl")

$claims = $null
if ($Token) {
  $claims = Get-Claims $Token
  $exp = [DateTimeOffset]::FromUnixTimeSeconds([int64]$claims.exp).LocalDateTime
  $lines.Add("- Usuario: $($claims.preferred_username) | roles: $(@($claims.roles) -join ', ') | scp: $($claims.scp)")
  $lines.Add("- iss: $($claims.iss) | aud: $($claims.aud) | exp: $exp")
  if ($exp -lt (Get-Date)) { Write-Warning 'El token ya expiro: copia uno nuevo desde "Mi sesion".' }
}
$lines.Add("")

# 1) Salud (ruta publica)
$h = Invoke-Api GET '/actuator/health'
$lines.Add("## Ruta publica")
$lines.Add("| Ruta | Status | Respuesta |")
$lines.Add("|---|---|---|")
$lines.Add("| GET /actuator/health | $($h.Status) | ``$(Short $h.Body)`` |")
$lines.Add("")

# 2) Rutas protegidas
$lines.Add("## Rutas protegidas (JWT Authorizer + autorizacion por rol en el BFF)")
$lines.Add("| Ruta | Roles | Sin token | Token invalido | Con token | Esperado | Respuesta con token |")
$lines.Add("|---|---|---|---|---|---|---|")
$fake = 'Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJodHRwczovL2V2aWwuZXhhbXBsZSIsImF1ZCI6InguIiwiZXhwIjo0MTAyNDQ0ODAwfQ.ZmFrZQ'
$fail = 0
foreach ($r in $routes) {
  $none = Invoke-Api $r.M $r.P
  $bad = Invoke-Api $r.M $r.P @{ Authorization = $fake }
  $withCol = '-'; $expected = '401 / 401'; $bodyCol = ''
  if ($Token) {
    $ok = Invoke-Api $r.M $r.P @{ Authorization = "Bearer $Token" }
    $allowed = @($claims.roles | Where-Object { $r.Roles -contains $_ }).Count -gt 0
    $exp = if ($allowed) { 200 } else { 403 }
    $withCol = $ok.Status
    $expected = "401 / 401 / $exp"
    $bodyCol = "``$(Short $ok.Body)``"
    if ($ok.Status -ne $exp) { $fail++ }
  }
  if ($none.Status -ne 401 -or $bad.Status -ne 401) { $fail++ }
  $lines.Add("| $($r.M) $($r.P) | $($r.Roles -join ', ') | $($none.Status) | $($bad.Status) | $withCol | $expected | $bodyCol |")
}
$lines.Add("")

# 3) Flujo de escritura (crear orden y avanzar estados)
if ($Token -and $WriteFlow) {
  $lines.Add("## Flujo de escritura")
  $c = Invoke-Api POST '/api/workorders' @{ Authorization = "Bearer $Token" } '{"descripcion":"Evidencia: falla de alumbrado publico","clienteId":"cliente-evidencia"}'
  $lines.Add("- POST /api/workorders -> **$($c.Status)** ``$(Short $c.Body 120)``")
  if ($c.Status -eq 201) {
    $id = ($c.Body | ConvertFrom-Json).id
    $inv = Invoke-Api PUT "/api/workorders/$id/status" @{ Authorization = "Bearer $Token" } '{"status":"EN_EJECUCION"}'
    $lines.Add("- PUT status CREADA -> EN_EJECUCION (regla de negocio) -> **$($inv.Status)** ``$(Short $inv.Body 120)``")
    foreach ($st in 'ASIGNADA', 'EN_DESPLAZAMIENTO', 'EN_EJECUCION', 'CERRADA') {
      $u = Invoke-Api PUT "/api/workorders/$id/status" @{ Authorization = "Bearer $Token" } "{`"status`":`"$st`",`"tecnicoId`":`"tecnico-07`"}"
      $lines.Add("- PUT status -> $st -> **$($u.Status)**")
    }
    $a = Invoke-Api GET "/api/audit?limit=5" @{ Authorization = "Bearer $Token" }
    $lines.Add("- GET /api/audit -> **$($a.Status)** ``$(Short $a.Body 160)``")
  }
  $lines.Add("")
}

# 4) CORS (preflight)
$lines.Add("## CORS (preflight)")
$lines.Add("| Origen | Status | Access-Control-Allow-Origin | Allow-Methods |")
$lines.Add("|---|---|---|---|")
foreach ($o in @($Origin, 'http://localhost:4200', 'https://sitio-no-autorizado.example')) {
  $pf = Invoke-Api OPTIONS '/api/workorders' @{ Origin = $o; 'Access-Control-Request-Method' = 'POST'; 'Access-Control-Request-Headers' = 'authorization,content-type' }
  $lines.Add("| $o | $($pf.Status) | $($pf.Headers['Access-Control-Allow-Origin']) | $($pf.Headers['Access-Control-Allow-Methods']) |")
}
$lines.Add("")
$lines.Add("Resultado: $(if ($fail -eq 0) { 'todas las rutas responden lo esperado' } else { "$fail diferencias con lo esperado" })")

New-Item -ItemType Directory -Force (Split-Path $ReportPath -Parent) | Out-Null
[IO.File]::WriteAllText($ReportPath, ($lines -join "`n"), (New-Object Text.UTF8Encoding($false)))
$lines | ForEach-Object { Write-Host $_ }
Write-Host "`nReporte: $ReportPath" -ForegroundColor Green

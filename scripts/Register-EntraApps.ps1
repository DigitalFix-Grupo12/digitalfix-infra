<#
.SYNOPSIS
    Automatiza el registro completo de las dos apps de DigitalFix en Microsoft
    Entra ID (SPA Angular + API/BFF Spring Boot).

.DESCRIPTION
    Autenticacion app-only: pasa -TenantId, -ClientId y -ClientSecret de un
    App Registration propio con permisos de aplicacion ya consentidos
    (Application.ReadWrite.All, AppRoleAssignment.ReadWrite.All, User.Read.All).

.EXAMPLE
    ./Register-EntraApps.ps1 -TenantId "xxxx" -ClientId "yyyy" -ClientSecret "zzzz"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TenantId,
    [Parameter(Mandatory = $true)][string]$ClientId,
    [Parameter(Mandatory = $true)][string]$ClientSecret,
    [string]$ApiAppName = "digitalfix-api",
    [string]$SpaAppName = "digitalfix-frontend",
    [string]$SpaRedirectUri = "http://localhost:4200",
    [string]$ScopeName = "access_as_user",
    [string]$AssignRoleToUserUPN,
    [ValidateSet("Admin", "Supervisor", "Cliente", "Auditor")]
    [string]$AssignRoleName
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) {
    Write-Host "`n==> $msg" -ForegroundColor Cyan
}

function Write-Manual($msg) {
    Write-Host "`n[ACCION MANUAL REQUERIDA] $msg" -ForegroundColor Yellow
}

# Azure AD tiene replicacion eventual: tras crear un objeto, leerlo/editarlo
# de inmediato a veces devuelve 404. Reintenta con backoff corto.
function Invoke-WithRetry {
    param([scriptblock]$Action, [int]$MaxAttempts = 5, [int]$DelaySeconds = 3)
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            return & $Action
        } catch {
            if ($i -eq $MaxAttempts) { throw }
            Write-Host "  (reintentando, intento $i/${MaxAttempts}: $($_.Exception.Message))"
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

# ---------------------------------------------------------------------------
# 1. Modulo de Microsoft Graph
# ---------------------------------------------------------------------------
Write-Step "Verificando modulo Microsoft.Graph.Applications"
$requiredModules = @("Microsoft.Graph.Authentication", "Microsoft.Graph.Applications", "Microsoft.Graph.Users")
foreach ($m in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        Install-Module -Name $m -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module $m -ErrorAction Stop
}

# ---------------------------------------------------------------------------
# 2. Conexion a Microsoft Graph (app-only)
# ---------------------------------------------------------------------------
Write-Step "Conectando a Microsoft Graph"
$secureSecret = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential($ClientId, $secureSecret)
Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $credential -NoWelcome
Write-Host "Conectado en modo app-only. Tenant: $TenantId"

# ---------------------------------------------------------------------------
# 3. App Registration de la API (digitalfix-api)
# ---------------------------------------------------------------------------
Write-Step "Registrando (o reutilizando) la app de la API: $ApiAppName"

$apiApp = Get-MgApplication -Filter "displayName eq '$ApiAppName'" -ErrorAction SilentlyContinue
if (-not $apiApp) {
    $apiApp = New-MgApplication -DisplayName $ApiAppName -SignInAudience "AzureADMyOrg"
    Write-Host "App API creada: AppId=$($apiApp.AppId)"
    Start-Sleep -Seconds 5
} else {
    Write-Host "App API ya existia: AppId=$($apiApp.AppId)"
}

Invoke-WithRetry { Update-MgApplication -ApplicationId $apiApp.Id -IdentifierUris @("api://$($apiApp.AppId)") }
Write-Host "IdentifierUri configurado."

$roleNames = @("Admin", "Supervisor", "Cliente", "Auditor")
$roleDescriptions = @{
    Admin      = "Administra catalogo de servicios/repuestos y ve KPIs de la red"
    Supervisor = "Acepta ordenes, asigna tecnico y cierra el trabajo"
    Cliente    = "Crea y sigue sus ordenes de mantencion"
    Auditor    = "Consulta el timeline de auditoria (solo lectura)"
}
$existingRoles = (Get-MgApplication -ApplicationId $apiApp.Id).AppRoles
if (-not $existingRoles -or $existingRoles.Count -eq 0) {
    $appRoles = foreach ($r in $roleNames) {
        @{
            Id                 = (New-Guid).Guid
            DisplayName        = $r
            Value              = $r
            Description        = $roleDescriptions[$r]
            AllowedMemberTypes = @("User")
            IsEnabled          = $true
        }
    }
    Invoke-WithRetry { Update-MgApplication -ApplicationId $apiApp.Id -AppRoles $appRoles }
    Write-Host "App roles creados: $($roleNames -join ', ')"
} else {
    Write-Host "App roles ya existian."
}

$existingScopes = (Get-MgApplication -ApplicationId $apiApp.Id).Api.Oauth2PermissionScopes
if (-not $existingScopes -or $existingScopes.Count -eq 0) {
    $scopeId = (New-Guid).Guid
    Invoke-WithRetry {
        Update-MgApplication -ApplicationId $apiApp.Id -Api @{
            Oauth2PermissionScopes = @(
                @{
                    Id                      = $scopeId
                    AdminConsentDisplayName = "Acceder a la API de DigitalFix"
                    AdminConsentDescription = "Permite al frontend llamar a la API de DigitalFix en nombre del usuario autenticado"
                    UserConsentDisplayName  = "Acceder a DigitalFix en tu nombre"
                    UserConsentDescription  = "Permite a la aplicacion acceder a DigitalFix en tu nombre"
                    Value                   = $ScopeName
                    Type                    = "User"
                    IsEnabled               = $true
                }
            )
        }
    }
    Write-Host "Scope '$ScopeName' creado."
} else {
    Write-Host "Scope ya existia."
}

$apiSp = Get-MgServicePrincipal -Filter "appId eq '$($apiApp.AppId)'" -ErrorAction SilentlyContinue
if (-not $apiSp) {
    $apiSp = Invoke-WithRetry { New-MgServicePrincipal -AppId $apiApp.AppId }
    Write-Host "Service Principal de la API creado."
}

$apiScope = Invoke-WithRetry { $s = (Get-MgApplication -ApplicationId $apiApp.Id).Api.Oauth2PermissionScopes | Where-Object { $_.Value -eq $ScopeName } | Select-Object -First 1; if (-not $s) { throw "scope aun no visible" }; $s }
if (-not $apiScope) { throw "No se pudo obtener el scope '$ScopeName' recien creado." }

# ---------------------------------------------------------------------------
# 4. App Registration del SPA (digitalfix-frontend)
# ---------------------------------------------------------------------------
Write-Step "Registrando (o reutilizando) la app SPA: $SpaAppName"

$spaApp = Get-MgApplication -Filter "displayName eq '$SpaAppName'" -ErrorAction SilentlyContinue
if (-not $spaApp) {
    $spaApp = New-MgApplication -DisplayName $SpaAppName -SignInAudience "AzureADMyOrg"
    Write-Host "App SPA creada: AppId=$($spaApp.AppId)"
    Start-Sleep -Seconds 5
} else {
    Write-Host "App SPA ya existia: AppId=$($spaApp.AppId)"
}

Invoke-WithRetry { Update-MgApplication -ApplicationId $spaApp.Id -Spa @{ RedirectUris = @($SpaRedirectUri) } }
Write-Host "Redirect URI (SPA) configurado."

Invoke-WithRetry {
    Update-MgApplication -ApplicationId $spaApp.Id -RequiredResourceAccess @(
        @{
            ResourceAppId  = $apiApp.AppId
            ResourceAccess = @(
                @{ Id = $apiScope.Id; Type = "Scope" }
            )
        }
    )
}
Write-Host "Permiso delegado hacia la API configurado."

$spaSp = Get-MgServicePrincipal -Filter "appId eq '$($spaApp.AppId)'" -ErrorAction SilentlyContinue
if (-not $spaSp) {
    $spaSp = Invoke-WithRetry { New-MgServicePrincipal -AppId $spaApp.AppId }
    Write-Host "Service Principal del SPA creado."
}

# ---------------------------------------------------------------------------
# 5. Admin consent del scope delegado SPA -> API
# ---------------------------------------------------------------------------
Write-Step "Otorgando admin consent para el scope delegado"
try {
    $existingGrant = Get-MgOauth2PermissionGrant -Filter "clientId eq '$($spaSp.Id)' and resourceId eq '$($apiSp.Id)'" -ErrorAction SilentlyContinue
    if (-not $existingGrant) {
        New-MgOauth2PermissionGrant -BodyParameter @{
            ClientId    = $spaSp.Id
            ConsentType = "AllPrincipals"
            ResourceId  = $apiSp.Id
            Scope       = $ScopeName
        } | Out-Null
        Write-Host "Admin consent otorgado automaticamente para '$ScopeName'." -ForegroundColor Green
    } else {
        Write-Host "El consentimiento ya existia."
    }
} catch {
    $portalUrl = "https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/CallAnAPI/appId/$($spaApp.AppId)/isMSAApp~/false"
    Write-Manual "No se pudo otorgar el admin consent automaticamente: $($_.Exception.Message). Ve a Entra ID > Registros de aplicaciones > $SpaAppName > API permissions > Grant admin consent. Link: $portalUrl"
}

# ---------------------------------------------------------------------------
# 6. (Opcional) Asignar un rol a un usuario de prueba
# ---------------------------------------------------------------------------
if ($AssignRoleToUserUPN -and $AssignRoleName) {
    Write-Step "Asignando rol '$AssignRoleName' a $AssignRoleToUserUPN"
    try {
        $user = Get-MgUser -Filter "userPrincipalName eq '$AssignRoleToUserUPN'"
        $role = (Get-MgServicePrincipal -ServicePrincipalId $apiSp.Id).AppRoles | Where-Object { $_.Value -eq $AssignRoleName }

        New-MgUserAppRoleAssignment -UserId $user.Id -BodyParameter @{
            PrincipalId = $user.Id
            ResourceId  = $apiSp.Id
            AppRoleId   = $role.Id
        } | Out-Null

        Write-Host "Rol asignado correctamente." -ForegroundColor Green
    } catch {
        Write-Manual "No se pudo asignar el rol automaticamente: $($_.Exception.Message). Asignalo manualmente en Entra ID > Enterprise applications > $ApiAppName > Users and groups."
    }
}

# ---------------------------------------------------------------------------
# 7. Generar archivos de configuracion para frontend y backend
# ---------------------------------------------------------------------------
Write-Step "Actualizando archivos de configuracion del proyecto"

# workspace = carpeta que contiene digitalfix-infra, frontend-digitalfix y ms-digitalfix-bff
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$frontendConfigPath = Join-Path $repoRoot "frontend-digitalfix/src/app/core/config/app-config.ts"
$bffRunScriptPath = Join-Path $repoRoot "ms-digitalfix-bff/run-bff.ps1"

if (Test-Path $frontendConfigPath) {
    $content = Get-Content -Path $frontendConfigPath -Raw
    $content = $content -replace "REEMPLAZA_CON_TU_SPA_CLIENT_ID", $spaApp.AppId
    $content = $content -replace "REEMPLAZA_CON_TU_TENANT_ID", $TenantId
    $content = $content -replace "REEMPLAZA_CON_TU_API_CLIENT_ID", $apiApp.AppId
    Set-Content -Path $frontendConfigPath -Value $content -NoNewline
    Write-Host "Actualizado: $frontendConfigPath"
} else {
    Write-Manual "No encontre $frontendConfigPath. Copia los valores del resumen final manualmente en app-config.ts."
}

$runScriptLines = @(
    '# Generado por Register-EntraApps.ps1 -- variables de entorno para levantar el BFF localmente.',
    ('$env:AZURE_TENANT_ID = "' + $TenantId + '"'),
    ('$env:AZURE_API_CLIENT_ID = "' + $apiApp.AppId + '"'),
    'mvn spring-boot:run'
)
Set-Content -Path $bffRunScriptPath -Value $runScriptLines
Write-Host "Generado: $bffRunScriptPath"

# ---------------------------------------------------------------------------
# Resumen
# ---------------------------------------------------------------------------
Write-Step "Resumen (guarda esto)"
[PSCustomObject]@{
    TenantId       = $TenantId
    ApiAppId       = $apiApp.AppId
    ApiScopeUri    = "api://$($apiApp.AppId)/$ScopeName"
    SpaAppId       = $spaApp.AppId
    SpaRedirectUri = $SpaRedirectUri
} | Format-List


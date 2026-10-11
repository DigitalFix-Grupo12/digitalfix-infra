<#
.SYNOPSIS
    Configura desde cero un tenant de Microsoft Entra ID para DigitalFix.

.DESCRIPTION
    Login interactivo (delegado) como Global Administrator del tenant nuevo.
    Crea/reutiliza:
      - App "digitalfix-api": Application ID URI api://<appId>, scope
        access_as_user, App Roles (Admin, Supervisor, Cliente, Auditor) y
        tokens v2 (requestedAccessTokenVersion = 2, issuer .../v2.0).
      - App "digitalfix-frontend" (SPA, Authorization Code + PKCE) con redirect
        URIs de localhost y Amplify, permiso delegado a la API y admin consent.
      - Usuarios demo <rol>.demo@<dominio> con su App Role asignado.
    Escribe los IDs resultantes en ..\..\..\entra-tenant.json (fuera de los repos).
    Solo requiere el modulo Microsoft.Graph.Authentication.

.EXAMPLE
    .\Setup-EntraTenant.ps1 -TenantId "<Directory (tenant) ID>"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TenantId,
    [string]$ApiAppName = "digitalfix-api",
    [string]$SpaAppName = "digitalfix-frontend",
    [string[]]$SpaRedirectUris = @("http://localhost:4200", "https://main.dehlzhnwtqj7a.amplifyapp.com"),
    [string]$ScopeName = "access_as_user",
    [string]$DemoPassword,
    [switch]$SkipAssignAdminToMe
)

$ErrorActionPreference = "Stop"
$GraphAppId = "00000003-0000-0000-c000-000000000000"

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

# Entra replica con consistencia eventual: reintenta lecturas/escrituras recien creadas.
function Invoke-WithRetry {
    param([scriptblock]$Action, [int]$MaxAttempts = 6, [int]$DelaySeconds = 5)
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try { return & $Action }
        catch {
            if ($i -eq $MaxAttempts) { throw }
            Write-Host "  (reintento $i/${MaxAttempts}: $($_.Exception.Message))" -ForegroundColor DarkGray
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Invoke-Graph {
    param([string]$Method, [string]$Uri, $Body)
    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Depth 10
        return Invoke-MgGraphRequest -Method $Method -Uri $Uri -Body $json -ContentType "application/json" -OutputType HashTable
    }
    return Invoke-MgGraphRequest -Method $Method -Uri $Uri -OutputType HashTable
}

function Get-First([string]$Uri) {
    $r = Invoke-Graph GET $Uri
    if ($r.value -and $r.value.Count -gt 0) { return $r.value[0] }
    return $null
}

function Get-OrCreateServicePrincipal([string]$AppId) {
    $sp = Get-First "v1.0/servicePrincipals?`$filter=appId eq '$AppId'"
    if (-not $sp) { $sp = Invoke-WithRetry { Invoke-Graph POST "v1.0/servicePrincipals" @{ appId = $AppId } } }
    return $sp
}

function Grant-AdminConsent($ClientSp, $ResourceSp, [string]$Scope) {
    $existing = Get-First "v1.0/oauth2PermissionGrants?`$filter=clientId eq '$($ClientSp.id)' and resourceId eq '$($ResourceSp.id)'"
    if ($existing) {
        Invoke-Graph PATCH "v1.0/oauth2PermissionGrants/$($existing.id)" @{ scope = $Scope } | Out-Null
    } else {
        Invoke-WithRetry {
            Invoke-Graph POST "v1.0/oauth2PermissionGrants" @{
                clientId = $ClientSp.id; consentType = "AllPrincipals"; resourceId = $ResourceSp.id; scope = $Scope
            }
        } | Out-Null
    }
}

function Add-AppRoleAssignment($PrincipalId, $ApiSp, [string]$RoleId) {
    $assigned = Invoke-Graph GET "v1.0/servicePrincipals/$($ApiSp.id)/appRoleAssignedTo"
    if ($assigned.value | Where-Object { $_.principalId -eq $PrincipalId -and $_.appRoleId -eq $RoleId }) { return }
    Invoke-WithRetry {
        Invoke-Graph POST "v1.0/servicePrincipals/$($ApiSp.id)/appRoleAssignedTo" @{
            principalId = $PrincipalId; resourceId = $ApiSp.id; appRoleId = $RoleId
        }
    } | Out-Null
}

# ---------------------------------------------------------------------------
Write-Step "Modulo Microsoft.Graph.Authentication"
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -Scope CurrentUser -Force | Out-Null
    }
    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber
}
Import-Module Microsoft.Graph.Authentication

Write-Step "Login interactivo en el tenant $TenantId (usa la cuenta Global Administrator)"
try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { }
Connect-MgGraph -TenantId $TenantId -ContextScope Process -NoWelcome -Scopes @(
    "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All",
    "DelegatedPermissionGrant.ReadWrite.All", "User.ReadWrite.All", "Domain.Read.All")
$ctx = Get-MgContext
if ($ctx.TenantId -ne $TenantId) { throw "Conectado al tenant $($ctx.TenantId), no a $TenantId." }
Write-Host "Conectado como $($ctx.Account)"

$domain = ((Invoke-Graph GET "v1.0/domains").value | Where-Object { $_.isInitial } | Select-Object -First 1).id
Write-Host "Dominio inicial: $domain"

# ---------------------------------------------------------------------------
Write-Step "App de la API: $ApiAppName"
$roleDescriptions = [ordered]@{
    Admin      = "Administra catalogo, reporteria, auditoria y mensajeria"
    Supervisor = "Acepta ordenes, asigna tecnico y cierra el trabajo"
    Cliente    = "Crea y sigue sus ordenes de mantencion"
    Auditor    = "Consulta el timeline de auditoria (solo lectura)"
}
$apiApp = Get-First "v1.0/applications?`$filter=displayName eq '$ApiAppName'"
if (-not $apiApp) {
    $appRoles = @(foreach ($r in $roleDescriptions.Keys) {
        @{ id = [guid]::NewGuid().ToString(); displayName = $r; value = $r; description = $roleDescriptions[$r];
           allowedMemberTypes = @("User"); isEnabled = $true }
    })
    $apiApp = Invoke-Graph POST "v1.0/applications" @{
        displayName    = $ApiAppName
        signInAudience = "AzureADMyOrg"
        appRoles       = $appRoles
        api            = @{
            requestedAccessTokenVersion = 2
            oauth2PermissionScopes      = @(@{
                id = [guid]::NewGuid().ToString(); value = $ScopeName; type = "User"; isEnabled = $true
                adminConsentDisplayName = "Acceder a la API de DigitalFix"
                adminConsentDescription = "Permite al frontend llamar a la API de DigitalFix en nombre del usuario"
                userConsentDisplayName  = "Acceder a DigitalFix en tu nombre"
                userConsentDescription  = "Permite a la aplicacion acceder a DigitalFix en tu nombre"
            })
        }
    }
    Write-Host "Creada. AppId=$($apiApp.appId)"
} else {
    Write-Host "Ya existia. AppId=$($apiApp.appId)"
}
Invoke-WithRetry { Invoke-Graph PATCH "v1.0/applications/$($apiApp.id)" @{ identifierUris = @("api://$($apiApp.appId)") } } | Out-Null
$apiApp = Invoke-WithRetry { Invoke-Graph GET "v1.0/applications/$($apiApp.id)" }
if ($apiApp.api.requestedAccessTokenVersion -ne 2) {
    Invoke-Graph PATCH "v1.0/applications/$($apiApp.id)" @{ api = @{ requestedAccessTokenVersion = 2 } } | Out-Null
}
$scope = $apiApp.api.oauth2PermissionScopes | Where-Object { $_.value -eq $ScopeName } | Select-Object -First 1
if (-not $scope) { throw "La app $ApiAppName no tiene el scope $ScopeName." }
$apiSp = Get-OrCreateServicePrincipal $apiApp.appId

# ---------------------------------------------------------------------------
Write-Step "App SPA: $SpaAppName (Authorization Code + PKCE)"
$graphAccess = @(
    @{ id = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"; type = "Scope" },  # User.Read
    @{ id = "37f7f235-527c-4136-accd-4a02d197296e"; type = "Scope" },  # openid
    @{ id = "14dad69e-099b-42c9-810b-d002981feec1"; type = "Scope" },  # profile
    @{ id = "7427e0e9-2fba-42fe-b0c0-848c9e6a8182"; type = "Scope" }   # offline_access
)
$spaBody = @{
    spa                    = @{ redirectUris = $SpaRedirectUris }
    requiredResourceAccess = @(
        @{ resourceAppId = $apiApp.appId; resourceAccess = @(@{ id = $scope.id; type = "Scope" }) },
        @{ resourceAppId = $GraphAppId; resourceAccess = $graphAccess }
    )
}
$spaApp = Get-First "v1.0/applications?`$filter=displayName eq '$SpaAppName'"
if (-not $spaApp) {
    $spaBody.displayName = $SpaAppName
    $spaBody.signInAudience = "AzureADMyOrg"
    $spaApp = Invoke-Graph POST "v1.0/applications" $spaBody
    Write-Host "Creada. AppId=$($spaApp.appId)"
} else {
    Invoke-WithRetry { Invoke-Graph PATCH "v1.0/applications/$($spaApp.id)" $spaBody } | Out-Null
    Write-Host "Ya existia (actualizada). AppId=$($spaApp.appId)"
}
$spaSp = Get-OrCreateServicePrincipal $spaApp.appId

Write-Step "Admin consent (SPA -> API y SPA -> Microsoft Graph)"
$graphSp = Get-OrCreateServicePrincipal $GraphAppId
Grant-AdminConsent $spaSp $apiSp $ScopeName
Grant-AdminConsent $spaSp $graphSp "openid profile offline_access User.Read"
Write-Host "Consentimiento otorgado."

# ---------------------------------------------------------------------------
Write-Step "Usuarios demo y App Roles"
if (-not $DemoPassword) { $DemoPassword = "DigitalFix#" + (Get-Random -Minimum 1000 -Maximum 9999) }
$apiSp = Invoke-WithRetry { Invoke-Graph GET "v1.0/servicePrincipals/$($apiSp.id)" }
$users = @()
foreach ($roleName in $roleDescriptions.Keys) {
    $upn = "$($roleName.ToLower()).demo@$domain"
    $user = Get-First "v1.0/users?`$filter=userPrincipalName eq '$upn'"
    if (-not $user) {
        $user = Invoke-Graph POST "v1.0/users" @{
            accountEnabled = $true; displayName = "Demo $roleName"; mailNickname = "$($roleName.ToLower()).demo"
            userPrincipalName = $upn; usageLocation = "CL"
            passwordProfile = @{ password = $DemoPassword; forceChangePasswordNextSignIn = $false }
        }
        Write-Host "Usuario creado: $upn"
    } else {
        Write-Host "Usuario ya existia: $upn (su clave NO se cambio)"
    }
    $roleId = ($apiSp.appRoles | Where-Object { $_.value -eq $roleName }).id
    Add-AppRoleAssignment $user.id $apiSp $roleId
    Write-Host "  rol $roleName asignado"
    $users += [ordered]@{ role = $roleName; upn = $upn }
}

if (-not $SkipAssignAdminToMe) {
    try {
        $me = Invoke-Graph GET "v1.0/me"
        $adminRoleId = ($apiSp.appRoles | Where-Object { $_.value -eq "Admin" }).id
        Add-AppRoleAssignment $me.id $apiSp $adminRoleId
        Write-Host "Rol Admin asignado tambien a $($me.userPrincipalName)"
    } catch {
        Write-Host "No se pudo asignar Admin a tu cuenta: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
$outFile = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "entra-tenant.json"
$result = [ordered]@{
    tenantId     = $TenantId
    domain       = $domain
    apiAppId     = $apiApp.appId
    apiScope     = "api://$($apiApp.appId)/$ScopeName"
    spaAppId     = $spaApp.appId
    redirectUris = $SpaRedirectUris
    demoPassword = $DemoPassword
    users        = $users
}
$result | ConvertTo-Json -Depth 5 | Set-Content -Path $outFile -Encoding UTF8
Write-Step "Listo. Resumen guardado en $outFile (NO subir a GitHub: tiene la clave demo)"
$result | ConvertTo-Json -Depth 5

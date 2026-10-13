<#
  Funciones comunes de los scripts de despliegue (se cargan con: . "$PSScriptRoot\DigitalFix.Common.ps1").
  Requieren que el script que las carga defina $Region e Invoke-Aws.
  Permiten desplegar en cualquier cuenta de AWS Academy (Kevin o Boris) sin IDs fijos.
#>

# Security Group de la EC2 de aplicaciones:
#  1) el indicado por parametro, 2) el llamado digitalfix-apps-sg,
#  3) el que ya autoriza AMQP en digitalfix-mq-sg (cuentas desplegadas antes de este cambio),
#  4) si no existe ninguno, se crea digitalfix-apps-sg.
function Get-AppSecurityGroup([string]$Preferred) {
  if ($Preferred) { return $Preferred }
  $vpc = (Invoke-Aws ec2 describe-vpcs --filters 'Name=is-default,Values=true').Vpcs[0].VpcId
  $sg = (Invoke-Aws ec2 describe-security-groups --filters 'Name=group-name,Values=digitalfix-apps-sg' "Name=vpc-id,Values=$vpc").SecurityGroups | Select-Object -First 1
  if ($sg) { return $sg.GroupId }

  $mqSg = (Invoke-Aws ec2 describe-security-groups --filters 'Name=group-name,Values=digitalfix-mq-sg' "Name=vpc-id,Values=$vpc").SecurityGroups | Select-Object -First 1
  if ($mqSg) {
    $ref = $mqSg.IpPermissions | Where-Object { $_.FromPort -eq 5672 } | ForEach-Object { $_.UserIdGroupPairs } | Select-Object -First 1
    if ($ref) { return $ref.GroupId }
  }

  $myIp = (Invoke-RestMethod 'https://checkip.amazonaws.com').Trim()
  $sgId = (Invoke-Aws ec2 create-security-group --group-name digitalfix-apps-sg --vpc-id $vpc `
    --description 'DigitalFix apps - BFF 8080 para API Gateway, SSH y log de arranque desde tu IP').GroupId
  Invoke-Aws ec2 authorize-security-group-ingress --group-id $sgId --ip-permissions `
    'IpProtocol=tcp,FromPort=8080,ToPort=8080,IpRanges=[{CidrIp=0.0.0.0/0,Description=api-gateway-bff}]' `
    "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$myIp/32,Description=ssh-admin}]" `
    "IpProtocol=tcp,FromPort=8081,ToPort=8081,IpRanges=[{CidrIp=$myIp/32,Description=bootstrap-log}]" | Out-Null
  Write-Host "Security Group digitalfix-apps-sg creado: $sgId" -ForegroundColor Green
  return $sgId
}

# Abre SSH y el log de arranque (:8081) del SG de apps a la IP actual (cambia entre redes).
function Grant-MyIpToAppSecurityGroup([string]$SgId) {
  $myIp = (Invoke-RestMethod 'https://checkip.amazonaws.com').Trim()
  foreach ($perm in @("IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$myIp/32,Description=ssh-admin}]",
                      "IpProtocol=tcp,FromPort=8081,ToPort=8081,IpRanges=[{CidrIp=$myIp/32,Description=bootstrap-log}]")) {
    & aws.exe ec2 authorize-security-group-ingress --region $Region --group-id $SgId --ip-permissions $perm 2>$null | Out-Null
  }
}

# Par de claves SSH: si no existe en la cuenta se crea y el .pem se guarda junto a los repos
# como <KeyName>-<cuenta>.pem (no pisa el digitalfix-key.pem de otra cuenta).
function Initialize-KeyPair([string]$KeyName, [string]$Workspace) {
  & aws.exe ec2 describe-key-pairs --region $Region --key-names $KeyName 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) { return }
  $account = (& aws.exe sts get-caller-identity --query Account --output text).Trim()
  $pem = Join-Path $Workspace "$KeyName-$account.pem"
  $material = & aws.exe ec2 create-key-pair --region $Region --key-name $KeyName --query KeyMaterial --output text
  if ($LASTEXITCODE -ne 0) { throw "No se pudo crear el par de claves $KeyName" }
  [IO.File]::WriteAllText($pem, (($material -join "`n").Trim() + "`n"), (New-Object Text.UTF8Encoding $false))
  icacls $pem /inheritance:r /grant:r "$($env:USERNAME):(R)" | Out-Null
  Write-Host "Par de claves $KeyName creado. Clave privada: $pem (no subir a GitHub)" -ForegroundColor Green
}

# Cuenta AWS de las credenciales actuales
function Get-AwsAccountId { (& aws.exe sts get-caller-identity --query Account --output text).Trim() }

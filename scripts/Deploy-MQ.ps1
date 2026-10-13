<#
  Despliega la capa de mensajeria de DigitalFix: EC2 "ec2-mq" con el cluster
  RabbitMQ de 2 nodos levantado con docker compose (mq/compose.yml). Idempotente
  en credenciales y Security Group; crea una instancia nueva por ejecucion.

   - Credenciales y cookie de Erlang en SSM Parameter Store (SecureString)
   - Security Group digitalfix-mq-sg:
       5672-5673  (AMQP)        solo desde el SG de la EC2 de aplicaciones
       15672-15673 (Management) desde el SG de aplicaciones (rabbit-admin) y tu IP (demo)
       22 (SSH)                 solo tu IP
   - IP elastica propia (digitalfix-mq-eip) para que la UI no cambie de URL
   - Publica la IP PRIVADA en /digitalfix/mq/host: las apps hablan con RabbitMQ
     por la red interna de la VPC

  Uso:
    .\scripts\Deploy-MQ.ps1
    .\scripts\Deploy-MQ.ps1 -TerminateOld     # termina las ec2-mq anteriores
#>
param(
  [string]$Name = ('digitalfix-mq-' + (Get-Date -Format 'yyyyMMdd-HHmm')),
  [string]$Region = 'us-east-1',
  [string]$Ami = 'ami-0b301e023c868669e',
  [string]$InstanceType = 't3.small',
  [string]$KeyName = 'digitalfix-key',
  [string]$AppSecurityGroup = '',          # vacio = se resuelve/crea digitalfix-apps-sg
  [string]$InstanceProfile = 'LabInstanceProfile',
  [string]$MqUser = 'digitalfix',
  [int]$TimeoutMin = 15,
  [switch]$TerminateOld
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$userData = Join-Path $root 'aws\ec2-mq-user-data.sh'
$ebs = Join-Path $root 'aws\ebs-block-device.json'
function Invoke-Aws { $out = & aws.exe @args --region $Region --output json; if ($LASTEXITCODE -ne 0) { throw "aws $($args -join ' ') fallo" }; if ($out) { ($out | Out-String) | ConvertFrom-Json } }
$workspace = Split-Path $root -Parent
. (Join-Path $PSScriptRoot 'DigitalFix.Common.ps1')
function New-Secret([int]$Length) {
  $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'.ToCharArray()
  $bytes = New-Object byte[] $Length
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}
function Get-Param([string]$Path) {
  try { (Invoke-Aws ssm get-parameter --name $Path --with-decryption 2>$null).Parameter.Value } catch { $null }
}

# 1) Credenciales en SSM (se generan solo la primera vez)
Invoke-Aws ssm put-parameter --name /digitalfix/mq/username --type String --value $MqUser --overwrite | Out-Null
if (-not (Get-Param /digitalfix/mq/password)) {
  Invoke-Aws ssm put-parameter --name /digitalfix/mq/password --type SecureString --value (New-Secret 24) --overwrite | Out-Null
}
if (-not (Get-Param /digitalfix/mq/erlang-cookie)) {
  Invoke-Aws ssm put-parameter --name /digitalfix/mq/erlang-cookie --type SecureString --value (New-Secret 32) --overwrite | Out-Null
}
Write-Host 'Credenciales RabbitMQ en SSM: /digitalfix/mq/{username,password,erlang-cookie}' -ForegroundColor Green

# 2) Security Group (y par de claves SSH si la cuenta es nueva)
Initialize-KeyPair $KeyName $workspace
$AppSecurityGroup = Get-AppSecurityGroup $AppSecurityGroup
$myIp = (Invoke-RestMethod 'https://checkip.amazonaws.com').Trim()
$vpc = (Invoke-Aws ec2 describe-vpcs --filters 'Name=is-default,Values=true').Vpcs[0].VpcId
$sg = (Invoke-Aws ec2 describe-security-groups --filters 'Name=group-name,Values=digitalfix-mq-sg' "Name=vpc-id,Values=$vpc").SecurityGroups | Select-Object -First 1
if (-not $sg) {
  $sgId = (Invoke-Aws ec2 create-security-group --group-name digitalfix-mq-sg --vpc-id $vpc `
    --description 'DigitalFix RabbitMQ - AMQP solo desde apps, UI desde apps y admin').GroupId
  Invoke-Aws ec2 authorize-security-group-ingress --group-id $sgId --ip-permissions `
    "IpProtocol=tcp,FromPort=5672,ToPort=5673,UserIdGroupPairs=[{GroupId=$AppSecurityGroup,Description=amqp-apps}]" `
    "IpProtocol=tcp,FromPort=15672,ToPort=15673,UserIdGroupPairs=[{GroupId=$AppSecurityGroup,Description=mgmt-rabbit-admin}]" | Out-Null
} else { $sgId = $sg.GroupId }
# Tu IP actual (cambia entre redes): UI y SSH. Se ignora el error si la regla ya existe.
foreach ($perm in @("IpProtocol=tcp,FromPort=15672,ToPort=15673,IpRanges=[{CidrIp=$myIp/32,Description=ui-admin}]",
                    "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$myIp/32,Description=ssh-admin}]")) {
  try { & aws.exe ec2 authorize-security-group-ingress --region $Region --group-id $sgId --ip-permissions $perm 2>$null | Out-Null } catch {}
}
Write-Host "SG $sgId (AMQP desde $AppSecurityGroup; UI/SSH desde $myIp)"

# 3) Instancia
$run = Invoke-Aws ec2 run-instances --image-id $Ami --instance-type $InstanceType `
  --key-name $KeyName --security-group-ids $sgId `
  --iam-instance-profile "Name=$InstanceProfile" `
  --block-device-mappings "file://$ebs" --user-data "file://$userData" `
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$Name},{Key=Project,Value=DigitalFix-MQ}]"
$id = $run.Instances[0].InstanceId
Write-Host "Instancia $id lanzada, esperando running..."
aws.exe ec2 wait instance-running --region $Region --instance-ids $id
$inst = (Invoke-Aws ec2 describe-instances --instance-ids $id).Reservations[0].Instances[0]
$privateIp = $inst.PrivateIpAddress

# 4) IP elastica de la capa de mensajeria
$eip = (Invoke-Aws ec2 describe-addresses --filters 'Name=tag:Name,Values=digitalfix-mq-eip').Addresses | Select-Object -First 1
if (-not $eip) {
  $eip = Invoke-Aws ec2 allocate-address --domain vpc --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=digitalfix-mq-eip}]'
}
Invoke-Aws ec2 associate-address --allocation-id $eip.AllocationId --instance-id $id --allow-reassociation | Out-Null
$publicIp = $eip.PublicIp
Invoke-Aws ssm put-parameter --name /digitalfix/mq/host --type String --value $privateIp --overwrite | Out-Null
Write-Host "IP privada $privateIp (en /digitalfix/mq/host) | IP publica $publicIp"

# 5) Esperar el cluster (Management API con 2 nodos en ejecucion)
$user = Get-Param /digitalfix/mq/username
$pass = Get-Param /digitalfix/mq/password
$auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${user}:${pass}"))
$deadline = (Get-Date).AddMinutes($TimeoutMin)
$nodes = @()
while ((Get-Date) -lt $deadline) {
  Start-Sleep 20
  try {
    # PowerShell 5.1 entrega el arreglo JSON como un solo objeto: se desenrolla con ForEach-Object
    $nodes = @(Invoke-RestMethod "http://${publicIp}:15672/api/nodes" -Headers @{ Authorization = $auth } -TimeoutSec 10 | ForEach-Object { $_ })
    $running = @($nodes | Where-Object { $_.running }).Count
    Write-Host ("[{0:HH:mm:ss}] nodos en ejecucion: {1}" -f (Get-Date), $running)
    if ($running -ge 2) { break }
  } catch { Write-Host ("[{0:HH:mm:ss}] esperando RabbitMQ..." -f (Get-Date)) }
}
if (@($nodes | Where-Object { $_.running }).Count -lt 2) { throw "El cluster no quedo con 2 nodos. Revisa /var/log/setup-mq.log por SSH." }
$nodes | ForEach-Object { Write-Host "  $($_.name) running=$($_.running)" -ForegroundColor Green }

# 6) Opcional: terminar ec2-mq anteriores
if ($TerminateOld) {
  $old = @((Invoke-Aws ec2 describe-instances --filters 'Name=tag:Project,Values=DigitalFix-MQ' 'Name=instance-state-name,Values=running,stopped').Reservations |
    ForEach-Object { $_.Instances } | Where-Object { $_.InstanceId -ne $id } | ForEach-Object { $_.InstanceId })
  if ($old.Count -gt 0) {
    $ErrorActionPreference = 'Continue'
    & aws.exe ec2 terminate-instances --region $Region --instance-ids $old --query 'TerminatingInstances[].InstanceId' --output text
  }
}

Write-Host ''
Write-Host "Management UI: http://${publicIp}:15672  y  http://${publicIp}:15673  (usuario $user)" -ForegroundColor Cyan
Write-Host "SSH: ssh -i digitalfix-key.pem ec2-user@$publicIp   ->  cd /opt/digitalfix-infra/mq; docker compose ps" -ForegroundColor Cyan
Write-Host 'Siguiente paso: .\scripts\Deploy-EC2.ps1 -TerminateOld  (las apps leen /digitalfix/mq/host al arrancar)' -ForegroundColor Yellow

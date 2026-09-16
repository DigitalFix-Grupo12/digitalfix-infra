<#
  Crea la base de datos cloud de DigitalFix (Amazon RDS PostgreSQL). Idempotente.
   - Security Group propio: 5432 solo desde el SG de la EC2 (no publica)
   - Credenciales generadas y guardadas en SSM Parameter Store (SecureString)
   - Un schema por microservicio (workorders, catalog, audit) en la misma instancia;
     cada servicio crea su schema al arrancar (hibernate.hbm2ddl.create_namespaces)

  Uso:
    .\scripts\Create-Database.ps1
#>
param(
  [string]$Region = 'us-east-1',
  [string]$DbId = 'digitalfix-db',
  [string]$DbName = 'digitalfix',
  [string]$DbUser = 'digitalfix_app',
  [string]$InstanceClass = 'db.t3.micro',
  [string]$AppSecurityGroup = 'sg-0618473c6254147c7'
)
$ErrorActionPreference = 'Stop'
function Invoke-Aws { $out = & aws.exe @args --region $Region --output json; if ($LASTEXITCODE -ne 0) { throw "aws $($args -join ' ') fallo" }; if ($out) { ($out | Out-String) | ConvertFrom-Json } }

$vpc = (Invoke-Aws ec2 describe-vpcs --filters "Name=is-default,Values=true").Vpcs[0].VpcId

# 1) Security Group de la base
$sg = (Invoke-Aws ec2 describe-security-groups --filters "Name=group-name,Values=digitalfix-rds-sg" "Name=vpc-id,Values=$vpc").SecurityGroups | Select-Object -First 1
if (-not $sg) {
  $sgId = (Invoke-Aws ec2 create-security-group --group-name digitalfix-rds-sg --vpc-id $vpc `
    --description 'DigitalFix RDS - PostgreSQL solo desde la EC2 de la aplicacion').GroupId
  Invoke-Aws ec2 authorize-security-group-ingress --group-id $sgId `
    --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=$AppSecurityGroup,Description=digitalfix-app}]" | Out-Null
} else { $sgId = $sg.GroupId }
Write-Host "SG base de datos: $sgId (5432 solo desde $AppSecurityGroup)"

# 2) Credenciales en SSM
$existingPwd = $null
try { $existingPwd = (Invoke-Aws ssm get-parameter --name /digitalfix/db/password --with-decryption 2>$null).Parameter.Value } catch {}
if (-not $existingPwd) {
  $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'.ToCharArray()
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  $bytes = New-Object byte[] 24; $rng.GetBytes($bytes)
  $existingPwd = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
  Invoke-Aws ssm put-parameter --name /digitalfix/db/password --type SecureString --value $existingPwd --overwrite | Out-Null
}
Invoke-Aws ssm put-parameter --name /digitalfix/db/username --type String --value $DbUser --overwrite | Out-Null

# 3) Instancia RDS
$db = $null
try { $db = (Invoke-Aws rds describe-db-instances --db-instance-identifier $DbId 2>$null).DBInstances[0] } catch {}
if (-not $db) {
  Invoke-Aws rds create-db-instance --db-instance-identifier $DbId --engine postgres `
    --db-instance-class $InstanceClass --allocated-storage 20 --storage-type gp2 `
    --db-name $DbName --master-username $DbUser --master-user-password $existingPwd `
    --vpc-security-group-ids $sgId --no-publicly-accessible --backup-retention-period 1 `
    --no-multi-az --storage-encrypted --tags "Key=Project,Value=DigitalFix" | Out-Null
  Write-Host "RDS $DbId en creacion..."
}
Write-Host 'Esperando estado available (5-15 min)...'
aws.exe rds wait db-instance-available --db-instance-identifier $DbId --region $Region
$db = (Invoke-Aws rds describe-db-instances --db-instance-identifier $DbId).DBInstances[0]
$endpoint = $db.Endpoint.Address
Invoke-Aws ssm put-parameter --name /digitalfix/db/host --type String --value $endpoint --overwrite | Out-Null
Invoke-Aws ssm put-parameter --name /digitalfix/db/name --type String --value $DbName --overwrite | Out-Null
Write-Host "RDS listo: $endpoint ($($db.Engine) $($db.EngineVersion))" -ForegroundColor Green

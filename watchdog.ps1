# Runs every 5 minutes. Restarts the stack if /api/health fails.
$Deploy = $PSScriptRoot
New-Item -ItemType Directory -Force "$Deploy\logs" | Out-Null
$Log = "$Deploy\logs\watchdog.log"
function Log($m) { "$(Get-Date -Format s)  $m" | Out-File $Log -Append -Encoding utf8 }
$port = (Get-Content "$Deploy\.env" | Where-Object { $_ -match '^APP_PORT=' }) -replace 'APP_PORT=',''
if (-not $port) { $port = "80" }
function Healthy { try { (Invoke-WebRequest "http://localhost:$port/api/health" -UseBasicParsing -TimeoutSec 15).StatusCode -eq 200 } catch { $false } }

docker info *> $null
if ($LASTEXITCODE -ne 0) { Log "Docker down - running start-stack"; & "$Deploy\start-stack.ps1"; exit }
if (Healthy) { exit 0 }

Set-Location $Deploy
Log "Health failed - compose up"
docker compose up -d 2>&1 | ForEach-Object { Log $_ }
Start-Sleep -Seconds 120
if (-not (Healthy)) { Log "Still failing - restarting app"; docker compose restart app 2>&1 | ForEach-Object { Log $_ } }

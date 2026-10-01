# ONE-TIME SETUP. Admin PowerShell, from the deploy folder:
#   Set-ExecutionPolicy -Scope Process Bypass; .\setup.ps1
$ErrorActionPreference = "Stop"
$Deploy = $PSScriptRoot
$Repo   = Split-Path -Parent $Deploy
Set-Location $Deploy
function Env($k) { (Get-Content "$Deploy\.env" | Where-Object { $_ -match "^$k=" }) -replace "^$k=","" }

Write-Host "`n[1/9] NVIDIA driver..." -ForegroundColor Cyan
nvidia-smi | Out-Null; if ($LASTEXITCODE) { throw "nvidia-smi failed. Install the latest NVIDIA driver." }

Write-Host "[2/9] Docker..." -ForegroundColor Cyan
docker info *> $null; if ($LASTEXITCODE) { throw "Docker not running. Install Docker Desktop (WSL2 backend) and start it." }

Write-Host "[3/9] GPU inside Docker..." -ForegroundColor Cyan
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
if ($LASTEXITCODE) { throw "GPU not visible in Docker. Update Docker Desktop + NVIDIA driver, run 'wsl --update'." }

Write-Host "[4/9] Config..." -ForegroundColor Cyan
if (-not (Test-Path "$Deploy\.env")) { Copy-Item "$Deploy\.env.example" "$Deploy\.env" }
if (-not (Test-Path "$Repo\backend\data\talent_pool.db")) {
  Write-Warning "backend\data\talent_pool.db not found - the app will start with an EMPTY pool."
}
$wslcfg = "$env:USERPROFILE\.wslconfig"
if (-not (Test-Path $wslcfg)) {
  "[wsl2]`nmemory=20GB`nprocessors=12`n" | Set-Content $wslcfg
  Write-Host "  Wrote $wslcfg. Restart Docker Desktop once after setup for it to apply."
}

Write-Host "[5/9] Building image..." -ForegroundColor Cyan
docker compose build

Write-Host "[6/9] Starting Ollama + pulling models..." -ForegroundColor Cyan
docker compose up -d ollama
Start-Sleep -Seconds 15
docker compose exec ollama ollama pull (Env "TEXT_MODEL")
docker compose exec ollama ollama pull (Env "OCR_MODEL")

Write-Host "[7/9] Starting app (first run seeds the database)..." -ForegroundColor Cyan
docker compose up -d
$ok = $false
$port = Env "APP_PORT"; if (-not $port) { $port = "80" }
for ($i = 0; $i -lt 40; $i++) {
  try { $h = Invoke-RestMethod "http://localhost:$port/api/health" -TimeoutSec 5; $ok = $true; break } catch { Start-Sleep 5 }
}
if ($ok) { $h | ConvertTo-Json -Depth 5 } else { Write-Warning "Health check not passing yet. Check: docker compose logs app" }

Write-Host "[8/9] Firewall (office subnet only) + power..." -ForegroundColor Cyan
if (-not (Get-NetFirewallRule -DisplayName "RLD Talent Portal" -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -DisplayName "RLD Talent Portal" -Direction Inbound -Protocol TCP -LocalPort $port `
    -RemoteAddress LocalSubnet -Action Allow -Profile Domain,Private | Out-Null
}
Get-NetConnectionProfile | Where-Object NetworkCategory -eq Public | ForEach-Object {
  Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private
  Write-Host "  Network '$($_.Name)' switched from Public to Private"
}
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0

Write-Host "[9/9] Scheduled tasks (start, watchdog, backup)..." -ForegroundColor Cyan
$user = "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1)
function Task($name, $script, $trigger) {
  $a = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Deploy\$script`""
  Register-ScheduledTask -TaskName $name -Action $a -Trigger $trigger -Settings $settings -User $user -RunLevel Highest -Force | Out-Null
}
$t1 = New-ScheduledTaskTrigger -AtLogOn -User $user; $t1.Delay = "PT30S"
Task "RLD-Talent-Start"    "start-stack.ps1" $t1
Task "RLD-Talent-Watchdog" "watchdog.ps1"    (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 5))
Task "RLD-Talent-Backup"   "backup.ps1"      (New-ScheduledTaskTrigger -Daily -At 7pm)

$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch '^(127|169\.254|172\.)' } | Select-Object -First 1).IPAddress
Write-Host "`nDone. Portal: http://$env:COMPUTERNAME (or http://$ip) on port $port" -ForegroundColor Green
Write-Host "Manual steps left: see OFFICE-HOSTING.md Part B (PC name, Autologon, BIOS power-on, fixed IP)."

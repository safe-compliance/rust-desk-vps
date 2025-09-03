# WindowsAgentAIOInstall_SafeCompliance.ps1
# Auto-eleva, instala/atualiza RustDesk, aplica CFG e senha fixa, firewall,
# trava TOMLs e cria tarefa de manutenção.

$ErrorActionPreference = 'Stop'

# ======= AJUSTE AQUI se mudar seu domínio/credenciais do gohttpserver =======
$ServerDomain = 'remoto.safecompliance.com.br'   # seu domínio
$HttpUser     = 'admin'                           # basic auth do gohttpserver
$HttpPass     = '3g49JdOkUCrgp4xg'                # basic auth do gohttpserver
# ============================================================================

# Auto-elevação
$me = [Security.Principal.WindowsIdentity]::GetCurrent()
$admin = (New-Object Security.Principal.WindowsPrincipal $me).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
  Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
  exit
}

# Lê o agent-config.json do servidor com Basic Auth
$cfgUrl = "http://$ServerDomain:8000/agent-config.json"
$basic  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$HttpUser`:$HttpPass"))
$hdrs   = @{ Authorization = "Basic $basic" }

try {
  $raw  = Invoke-WebRequest $cfgUrl -Headers $hdrs -UseBasicParsing
  $obj  = $raw.Content | ConvertFrom-Json
} catch {
  Write-Host "Falha ao baixar agent-config.json de $cfgUrl" -f Red
  throw
}

$RUSTDESK_CFG    = $obj.cfg
$RUSTDESK_PERM_PW= $obj.perm_pw
$RUSTDESK_HOST   = $obj.host
$ALLOW_IP        = $obj.allow_ip
$PORTS           = $obj.firewall_ports

$RUSTDESK_EXE = 'C:\Program Files\RustDesk\rustdesk.exe'
$PDATA        = 'C:\ProgramData\SafeCompliance\RustDesk'
New-Item -ItemType Directory -Force $PDATA -ErrorAction SilentlyContinue | Out-Null

function Get-LatestRustDeskTag {
  try {
    $u = 'https://github.com/rustdesk/rustdesk/releases/latest'
    ([System.Net.WebRequest]::Create($u).GetResponse()).ResponseUri.OriginalString.Split('/')[-1].Trim('v')
  } catch { $null }
}

function Install-Or-UpdateRustDesk {
  if (!(Test-Path $RUSTDESK_EXE)) {
    Write-Host "Instalando RustDesk..." -f Cyan
  } else {
    Write-Host "Verificando atualização do RustDesk..." -f Cyan
  }

  $tag = Get-LatestRustDeskTag
  $dl  = if ($tag) {
    "https://github.com/rustdesk/rustdesk/releases/download/$tag/rustdesk-$tag-x86_64.exe"
  } else {
    "https://github.com/rustdesk/rustdesk/releases/latest/download/rustdesk-x86_64.exe"
  }

  $tmp = Join-Path $env:TEMP 'rustdesk-setup.exe'
  Invoke-WebRequest $dl -OutFile $tmp
  Start-Process $tmp --% --silent-install -Wait
  Start-Sleep 6

  if (-not (Get-Service -Name rustdesk -ErrorAction SilentlyContinue)) {
    Start-Process $RUSTDESK_EXE --% --install-service -Wait
    Start-Sleep 6
  }
  $svc = Get-Service rustdesk -ErrorAction SilentlyContinue
  if ($svc.Status -ne 'Running') { Start-Service rustdesk }
}

function Apply-Cfg-And-Password {
  if (-not $RUSTDESK_CFG) { throw "CFG string não encontrada no agent-config.json" }
  Write-Host "Aplicando configuração e senha permanente..." -f Cyan
  Start-Process $RUSTDESK_EXE --% --config "$RUSTDESK_CFG" -WindowStyle Hidden -Wait
  Start-Process $RUSTDESK_EXE --% --password "$RUSTDESK_PERM_PW" -WindowStyle Hidden -Wait
}

# Lock com SIDs (independe de idioma)
function Lock-Dir($dir) {
  if (!(Test-Path $dir)) { return }
  icacls $dir /inheritance:r | Out-Null
  icacls $dir /grant:r "*S-1-5-18:(OI)(CI)(F)" "*S-1-5-32-544:(OI)(CI)(F)" | Out-Null  # SYSTEM + Administrators
  icacls $dir /deny      "*S-1-5-32-545:(OI)(CI)(W,M,DC)" "*S-1-1-0:(OI)(CI)(W,M,DC)" | Out-Null  # Users + Everyone
}

function Lock-UsersToml {
  & $RUSTDESK_EXE --get-id | Out-Null
  $meToml = Join-Path $env:APPDATA 'RustDesk\config\RustDesk2.toml'

  $profiles = Get-CimInstance Win32_UserProfile |
    Where-Object { $_.LocalPath -like 'C:\Users\*' -and (Split-Path -Leaf $_.LocalPath) -notin @('Public','Default','Default User','All Users') }

  foreach ($p in $profiles) {
    $cfgDir = Join-Path $p.LocalPath 'AppData\Roaming\RustDesk\config'
    New-Item -ItemType Directory -Force $cfgDir | Out-Null
    if (Test-Path $meToml) {
      Copy-Item $meToml (Join-Path $cfgDir 'RustDesk2.toml') -Force -ErrorAction SilentlyContinue
    }
    Lock-Dir $cfgDir
  }
  Write-Host "• TOMLs de usuários travados." -f Green
}

function Lock-ServiceToml {
  $svcDir = "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config"
  Start-Service rustdesk -ErrorAction SilentlyContinue; Start-Sleep 2
  Stop-Service  rustdesk -ErrorAction SilentlyContinue; Start-Sleep 2
  Start-Service rustdesk -ErrorAction SilentlyContinue; Start-Sleep 3

  $svcScript = @'
$svcDir = "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config"
if (Test-Path $svcDir) {
  icacls $svcDir /inheritance:r | Out-Null
  icacls $svcDir /grant:r "*S-1-5-18:(OI)(CI)(F)" "*S-1-5-32-544:(OI)(CI)(F)" | Out-Null
  icacls $svcDir /deny      "*S-1-5-32-545:(OI)(CI)(W,M,DC)" "*S-1-1-0:(OI)(CI)(W,M,DC)" | Out-Null
}
'@
  $svcScriptPath = Join-Path $PDATA 'lock-rd-svc.ps1'
  $svcScript | Set-Content -Encoding UTF8 $svcScriptPath

  $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$svcScriptPath`""
  $trg = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddSeconds(10))
  $pri = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

  Register-ScheduledTask -TaskName 'LockRustDeskSvcOnce' -Action $act -Trigger $trg -Principal $pri -Force | Out-Null
  Start-ScheduledTask   -TaskName 'LockRustDeskSvcOnce'
  Start-Sleep 15
  Unregister-ScheduledTask -TaskName 'LockRustDeskSvcOnce' -Confirm:$false | Out-Null

  Write-Host "• TOML do serviço travado." -f Green
}

function Keep-Locked-OnLogon {
  $maint = @'
$profiles = Get-ChildItem -Directory C:\Users | Where-Object { $_.Name -notin "Public","Default","Default User","All Users" }
foreach ($u in $profiles) {
  $d = "$($u.FullName)\AppData\Roaming\RustDesk\config"
  if (Test-Path $d) {
    icacls $d /inheritance:r | Out-Null
    icacls $d /grant:r "*S-1-5-18:(OI)(CI)(F)" "*S-1-5-32-544:(OI)(CI)(F)" | Out-Null
    icacls $d /deny      "*S-1-5-32-545:(OI)(CI)(W,M,DC)" "*S-1-1-0:(OI)(CI)(W,M,DC)" | Out-Null
  }
}
'@
  $maintPath = Join-Path $PDATA 'lock-rd-maint.ps1'
  $maint | Set-Content -Encoding UTF8 $maintPath

  $trg = New-ScheduledTaskTrigger -AtLogOn
  $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$maintPath`""
  $pri = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

  Register-ScheduledTask -TaskName 'LockRustDeskConfig' -Trigger $trg -Action $act -Principal $pri -Force | Out-Null
  Write-Host "• Tarefa de manutenção criada (trava a cada logon)." -f Green
}

function Configure-Firewall {
  Write-Host "Aplicando regras de firewall..." -f Cyan
  $remote = if ($ALLOW_IP) { "$RUSTDESK_HOST,$ALLOW_IP" } else { $RUSTDESK_HOST }
  $ports  = if ($PORTS) { ($PORTS -join ',') } else { '21115,21116,21117,21118,21119,443' }

  New-NetFirewallRule -DisplayName "RustDesk - SafeCompliance allow" `
    -Program "$RUSTDESK_EXE" `
    -Direction Outbound -Action Allow `
    -RemoteAddress $remote `
    -RemotePort $ports `
    -Protocol TCP -ErrorAction SilentlyContinue | Out-Null

  New-NetFirewallRule -DisplayName "RustDesk - block others" `
    -Program "$RUSTDESK_EXE" `
    -Direction Outbound -Action Block -ErrorAction SilentlyContinue | Out-Null
}

# ===== EXECUÇÃO =====
Install-Or-UpdateRustDesk
Apply-Cfg-And-Password
Lock-UsersToml
Lock-ServiceToml
Keep-Locked-OnLogon
Configure-Firewall

try {
  $id = & $RUSTDESK_EXE --get-id
  Write-Host ""
  Write-Host "========================================="
  Write-Host " RustDesk ID........: $id"
  Write-Host " Senha permanente...: $RUSTDESK_PERM_PW"
  Write-Host " Servidor...........: $RUSTDESK_HOST"
  Write-Host "========================================="
} catch {}

Write-Host "Concluído." -f Green

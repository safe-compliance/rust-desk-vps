# WindowsAgentAIOInstall_SafeCompliance.ps1
# Executar este arquivo (ele se auto-eleva). Faz tudo sozinho.
# - Instala/atualiza RustDesk
# - Aplica cfg + senha permanente
# - Regras de firewall (allow seu host/porta + block resto para o processo)
# - Trava TOMLs em todos os usuários e no serviço (LocalService)
# - Cria tarefa "de manutenção" para travar configs em logons futuros

$ErrorActionPreference = 'Stop'

### ==== AJUSTES DA SAFE COMPLIANCE ==== ###
$RUSTDESK_CFG = '0nI98WYPdGek52MytWdyd3N3ZHRjt0Z4Q2YsZlQEZFWSN1N0g0NMNmVRRHN1lmI6ISeltmIsIici5SbvNmLlNmbhlGbw12bjVmZhNnLvR3btVmcv8iOzBHd0hmI6ISawFmIsIici5SbvNmLlNmbhlGbw12bjVmZhNnLvR3btVmciojI5FGblJnIsIici5SbvNmLlNmbhlGbw12bjVmZhNnLvR3btVmciojI0N3boJye'

# Senha permanente que só vocês sabem
$RUSTDESK_PERM_PW = 'Safe@2025#'

# Seu domínio/IP do servidor
$RUSTDESK_HOST = 'remoto.safecompliance.com.br'
$ALLOW_IP      = '172.93.106.219'     # opcional: IP do servidor
### ===================================== ###

# Caminhos
$RUSTDESK_EXE  = 'C:\Program Files\RustDesk\rustdesk.exe'
$PDATA         = 'C:\ProgramData\SafeCompliance\RustDesk'
$null = New-Item -ItemType Directory -Force $PDATA -ErrorAction SilentlyContinue

# Auto-elevação
$me = [Security.Principal.WindowsIdentity]::GetCurrent()
$admin = (New-Object Security.Principal.WindowsPrincipal $me).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
  Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
  exit
}

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

  # instala serviço se faltar
  if (-not (Get-Service -Name rustdesk -ErrorAction SilentlyContinue)) {
    Start-Process $RUSTDESK_EXE --% --install-service -Wait
    Start-Sleep 6
  }

  # garante serviço rodando
  $svc = Get-Service rustdesk -ErrorAction SilentlyContinue
  if ($svc.Status -ne 'Running') { Start-Service rustdesk }
}

function Apply-Cfg-And-Password {
  if (-not $RUSTDESK_CFG -or $RUSTDESK_CFG -eq 'COLE_AQUI_A_SUA_CFG_STRING') {
    throw "Você precisa colar a **CFG string** em `\$RUSTDESK_CFG`."
  }
  Write-Host "Aplicando configuração e senha permanente..." -f Cyan
  Start-Process $RUSTDESK_EXE --% --config "$RUSTDESK_CFG" -WindowStyle Hidden -Wait
  Start-Process $RUSTDESK_EXE --% --password "$RUSTDESK_PERM_PW" -WindowStyle Hidden -Wait
}

# Lock com SIDs (independente de idioma)
# S-1-5-18(LocalSystem) | S-1-5-32-544(Administrators) | S-1-5-32-545(Users) | S-1-1-0(Everyone)
function Lock-Dir($dir) {
  if (!(Test-Path $dir)) { return }
  icacls $dir /inheritance:r | Out-Null
  icacls $dir /grant:r "*S-1-5-18:(OI)(CI)(F)" "*S-1-5-32-544:(OI)(CI)(F)" | Out-Null
  icacls $dir /deny      "*S-1-5-32-545:(OI)(CI)(W,M,DC)" "*S-1-1-0:(OI)(CI)(W,M,DC)" | Out-Null
}

function Lock-UsersToml {
  # Gera estrutura do usuário atual
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
  # Garante que o serviço já criou a estrutura
  Start-Service rustdesk -ErrorAction SilentlyContinue
  Start-Sleep 3
  Stop-Service  rustdesk -ErrorAction SilentlyContinue
  Start-Sleep 2
  Start-Service rustdesk -ErrorAction SilentlyContinue
  Start-Sleep 3

  # Script que roda como SYSTEM para travar o diretório do serviço
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
  # Allow somente seu host/IP e portas necessárias para o processo do RustDesk
  $remote = if ($ALLOW_IP) { "$RUSTDESK_HOST,$ALLOW_IP" } else { $RUSTDESK_HOST }
  New-NetFirewallRule -DisplayName "RustDesk - SafeCompliance allow" `
    -Program "$RUSTDESK_EXE" `
    -Direction Outbound -Action Allow `
    -RemoteAddress $remote `
    -RemotePort 21115,21116,21117,21118,21119,443 `
    -Protocol TCP -ErrorAction SilentlyContinue | Out-Null

  # Bloqueia o resto para o processo
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

# Mostra ID e resumo
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

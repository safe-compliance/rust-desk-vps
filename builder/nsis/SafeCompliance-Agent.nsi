!include "LogicLib.nsh"
!include "FileFunc.nsh"
!include "x64.nsh"

Name "SafeCompliance Remote Agent"
OutFile "SafeCompliance-Agent.exe"
RequestExecutionLevel admin
InstallDir "$PROGRAMFILES64\SafeCompliance\RemoteAgent"
ShowInstDetails nevershow
SilentInstall silent

Var RUSTDESK_EXE
Var RUSTDESK_BIN
Var PASS

Section "Install"

  SetOutPath "$INSTDIR"
  ; === Embutir os artefatos (VOCÊS colocam estes 2 arquivos na pasta do script) ===
  File /oname=rustdesk-setup.exe "rustdesk-win-x64.exe"
  File /oname=RustDesk2.toml "RustDesk2.toml"

  ; Caminho do binário instalado do RustDesk
  ${If} ${AtLeastWin7}
    StrCpy $RUSTDESK_BIN "$PROGRAMFILES64\RustDesk\rustdesk.exe"
  ${Else}
    StrCpy $RUSTDESK_BIN "$PROGRAMFILES\RustDesk\rustdesk.exe"
  ${EndIf}

  ; 1) Instala silenciosamente o RustDesk
  nsExec::ExecToStack '"$INSTDIR\rustdesk-setup.exe" --silent-install'
  Pop $0
  ${IfThen} $0 != 0 ${|} DetailPrint "WARN: installer exitcode $0" ${|}

  ; 2) Importa a config (aponta para SEU servidor + Key)
  nsExec::ExecToStack '"$RUSTDESK_BIN" --import-config "$INSTDIR\RustDesk2.toml"'
  Pop $0

  ; 3) Copia RustDesk2.toml para o perfil do serviço (LocalService) e do usuário atual
  nsExec::ExecToStack 'powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$u = Join-Path $env:APPDATA ''RustDesk\config''; ^
     $s = ''C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config''; ^
     New-Item -Force -ItemType Directory $u, $s | Out-Null; ^
     Copy-Item ''$INSTDIR\RustDesk2.toml'' (Join-Path $u ''RustDesk2.toml'') -Force; ^
     Copy-Item ''$INSTDIR\RustDesk2.toml'' (Join-Path $s ''RustDesk2.toml'') -Force"'
  Pop $0

  ; 4) Gera senha aleatória e aplica (salva em arquivo local para o admin)
  nsExec::ExecToStack 'powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$pwd=[guid]::NewGuid().ToString(''N'').Substring(0,16); ^
     & ''$RUSTDESK_BIN'' --password $pwd; ^
     Set-Content -Path ''$INSTDIR\agent_password.txt'' -Value $pwd -Encoding ASCII"'
  Pop $0

  ; 5) Instala o serviço (tenta via CLI; se falhar, usa SC)
  nsExec::ExecToStack '"$RUSTDESK_BIN" --install-service'
  Pop $0
  ${If} $0 != 0
    nsExec::ExecToStack 'sc create "RustDesk Service" binPath= "\"$RUSTDESK_BIN\" --service" start= auto'
    Pop $0
    nsExec::ExecToStack 'sc start "RustDesk Service"'
    Pop $0
  ${EndIf}

  ; 6) BLOQUEIA edição das configs (ACL somente leitura para Users/Everyone)
  nsExec::ExecToStack 'powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$u = Join-Path $env:APPDATA ''RustDesk\config\RustDesk2.toml''; ^
     $s = ''C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk2.toml''; ^
     foreach($p in @($u,$s)){ ^
       if(Test-Path $p){ ^
         icacls $p /inheritance:r | Out-Null; ^
         icacls $p /grant:r SYSTEM:F Administrators:F | Out-Null; ^
         icacls $p /deny Users:W Everyone:W | Out-Null; ^
       } ^
     }"'
  Pop $0

  ; 7) (Opcional) Regras de firewall: permite só seu servidor e bloqueia o resto (comente se não quiser)
  nsExec::ExecToStack 'powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Try { ^
      New-NetFirewallRule -DisplayName ''RustDesk → SafeCompliance allow'' ^
        -Program ''$RUSTDESK_BIN'' -Direction Outbound -Action Allow ^
        -RemoteAddress 172.93.106.219, remoto.safecompliance.com.br ^
        -RemotePort 21115-21119,443 -Protocol TCP -ErrorAction SilentlyContinue; ^
      New-NetFirewallRule -DisplayName ''RustDesk → Block others'' ^
        -Program ''$RUSTDESK_BIN'' -Direction Outbound -Action Block -ErrorAction SilentlyContinue; ^
    } Catch { }"'
  Pop $0

  ; 8) Mostra info final (apenas se não for /S)
  IfSilent +2 0
    MessageBox MB_OK "Instalação concluída.$\r$\nSenha de acesso está em: $INSTDIR\agent_password.txt"

SectionEnd

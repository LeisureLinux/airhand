; Airhand 安装包的附加步骤：Tauri NSIS 模板的钩子（tauri.conf.json → bundle.windows.nsis.installerHooks）。
;
; 两种安装方式（tauri.conf.json 的 installMode 是 both：NSIS 的 MultiUser.nsh 让用户选择，结果在 $MultiUser.InstallMode）：
; * 为所有用户安装（AllUsers，需要管理员权限，装到 Program Files）：被控端作为系统服务运行，锁屏、登录界面和 UAC 确认框
;   也能控制（见 src/winsvc/mod.rs）；
; * 仅为我安装（CurrentUser，不需要管理员权限，装到 %LOCALAPPDATA%\Programs）：没有系统服务，被控端在托盘进程里运行
;   （见 src/winsvc/user.rs）。管理员账户运行安装程序时可以选择（下面 AirhandMode* 是选择页面上的说明）；
;   没有管理员权限的账户 MultiUser 不显示选择页面，只能这样安装，安装程序启动时先说明一下（AirhandExplainUserInstall）。
;
; 为所有用户安装：
; * 安装：复制完文件后运行 `airhand.exe --install`：注册并启动系统服务 Airhand（被控端），
;   按 config.toml 设置开机自动启动；config.toml 不存在时新建；
; * 升级：复制文件之前运行旧版本的 `airhand.exe --stop-service`，停止服务、等托盘退出，否则 airhand.exe 正在使用，无法覆盖；
; * 卸载：运行 `airhand.exe --uninstall`：停止并删除服务、删除开机启动项、等托盘退出。
; 仅为我安装：
; * 安装：复制完文件后运行 `airhand.exe --install-user`：记下安装的位置（HKCU\Software\Airhand，程序启动时据此认出自己是装好的），
;   按 config.toml 设置登录时自动启动；config.toml 不存在时新建；
; * 升级：复制文件之前运行旧版本的 `airhand.exe --quit`，让托盘退出；
; * 卸载：运行 `airhand.exe --uninstall-user`：删除登录时自动启动和记下的安装位置、让托盘退出。
; 两种方式卸载时都删除安装目录里程序运行时生成的文件（config.toml）、安装程序和 Tauri 记下的注册表项和应用数据目录
; （不管有没有勾选"删除应用程序数据"）、防火墙里为 airhand.exe 添加的规则。
;
; 升级时如果选择"先卸载旧版本"，旧版本的卸载程序由新的安装程序启动：安装程序启动时设置环境变量 AIRHAND_UPGRADE，
; 卸载程序继承了它，就保留 config.toml（控制码、服务器设置、控制台的"我的设备"）。直接卸载时没有这个变量，配置文件一起删除。
; 重新运行同一个版本的安装程序、在里面选"卸载 Airhand"是真的卸载：安装程序还把自己的版本放进 AIRHAND_INSTALLER_VERSION，
; 卸载程序看到和自己的版本一样，就照样全部删除。被动安装（/P）遇到同一个版本时会自动先卸载再装，那是重装，不传版本、保留配置。
; 删除配置文件时服务已经停了（PREUNINSTALL），服务里"配置文件被删掉就重新生成"的检查不会再把它写回来。

; 这个文件在加载语言之前引入：LangString 直接用语言 ID（2052 简体中文、1033 英语，和 tauri.conf.json 的 languages 对应）

; 安装方式页面（MultiUser.nsh）上的说明：写清楚两种方式的区别
LangString AirhandModeTop 2052 "为所有用户安装：Airhand 作为系统服务运行，锁屏、登录界面和 UAC 确认框也能被远程控制，开机后不用登录就能连上。$\r$\n$\r$\n仅为我安装：不需要管理员权限，但上面这些都不行，以管理员身份运行的窗口也只能看、不能操作。"
LangString AirhandModeTop 1033 "For all users: Airhand runs as a system service, so the lock screen, the sign-in screen and UAC prompts can be controlled too, even before anyone signs in.$\r$\n$\r$\nJust for me: no administrator rights needed, but none of the above, and windows running as administrator can only be viewed."
LangString AirhandModeAllUsers 2052 "为所有用户安装（推荐）"
LangString AirhandModeAllUsers 1033 "Install for all users (recommended)"
LangString AirhandModeCurrentUser 2052 "仅为我安装"
LangString AirhandModeCurrentUser 1033 "Install just for me"
!define MULTIUSER_INSTALLMODEPAGE_TEXT_TOP "$(AirhandModeTop)"
!define MULTIUSER_INSTALLMODEPAGE_TEXT_ALLUSERS "$(AirhandModeAllUsers)"
!define MULTIUSER_INSTALLMODEPAGE_TEXT_CURRENTUSER "$(AirhandModeCurrentUser)"

; 没有管理员权限的账户运行安装程序时的说明
LangString AirhandUserOnly 2052 "这个账户没有管理员权限，Airhand 只能仅为你安装：锁屏、登录界面和 UAC 确认框不能被远程控制，以管理员身份运行的窗口也只能看、不能操作。$\r$\n$\r$\n要为所有用户安装：取消后右键安装程序，选择“以管理员身份运行”。"
LangString AirhandUserOnly 1033 "This account has no administrator rights, so Airhand can only be installed just for you: the lock screen, the sign-in screen and UAC prompts can't be controlled remotely, and windows running as administrator can only be viewed.$\r$\n$\r$\nTo install for all users, click Cancel, then right-click the installer and choose “Run as administrator”."

; 安装程序的界面初始化时（在"已安装旧版本"页面之前）调用
!define MUI_CUSTOMFUNCTION_GUIINIT AirhandGuiInit
Function AirhandGuiInit
  System::Call 'kernel32::SetEnvironmentVariableW(w "AIRHAND_UPGRADE", w "1")'
  Push $0
  ClearErrors
  ${GetOptions} $CMDLINE "/P" $0
  ${If} ${Errors}
    Call AirhandShareVersion
    Call AirhandExplainUserInstall
  ${EndIf}
  Pop $0
FunctionEnd

; 没有管理员权限的账户：MultiUser 不显示安装方式页面，直接仅为当前用户安装。先说明做不到的事，可以取消后以管理员身份运行。
; 已经仅为这个用户安装过（升级）时不再说明。$MultiUser.Privileges 在这里还用不了（MultiUser.nsh 在这个文件之后才引入），自己问
Function AirhandExplainUserInstall
  Push $0
  UserInfo::GetAccountType
  Pop $0
  ${If} $0 != "Admin"
  ${AndIf} $0 != "Power"
    ; 和 src/winsvc/user.rs 里记下安装位置的注册表项一样
    ReadRegStr $0 HKCU "Software\Airhand" "UserInstall"
    ${If} $0 == ""
      MessageBox MB_OKCANCEL|MB_ICONINFORMATION "$(AirhandUserOnly)" IDOK +2
      Quit
    ${EndIf}
  ${EndIf}
  Pop $0
FunctionEnd

; 把本安装程序的版本放进环境变量 AIRHAND_INSTALLER_VERSION。版本取自安装程序版本信息里的 ProductVersion
; （Tauri 模板里写的就是 ${VERSION}）：这个文件比模板里的 !define VERSION 更早被引入，这里用不了 ${VERSION}，只能运行时读。
; 读不到时不设置，卸载程序就按升级处理（保留配置），和以前一样
Function AirhandShareVersion
  Push $0
  Push $1
  Push $2
  Push $3
  Push $4
  StrCpy $4 ""
  System::Call 'version::GetFileVersionInfoSizeW(w "$EXEPATH", p 0) i .r0'
  ${If} $0 > 0
    System::Alloc $0
    Pop $1
    System::Call 'version::GetFileVersionInfoW(w "$EXEPATH", i 0, i r0, p r1) i .r2'
    ${If} $2 <> 0
      ; 版本信息里的语言和代码页（NSIS 只写一组）
      System::Call 'version::VerQueryValueW(p r1, w "\VarFileInfo\Translation", *p .r2, *i .r3) i .r0'
      ${If} $0 <> 0
      ${AndIf} $3 >= 4
        System::Call '*$2(&i2 .r0, &i2 .r3)'
        IntFmt $0 "%04x" $0
        IntFmt $3 "%04x" $3
        System::Call 'version::VerQueryValueW(p r1, w "\StringFileInfo\$0$3\ProductVersion", *p .r2, *i .r3) i .r0'
        ${If} $0 <> 0
        ${AndIf} $3 > 0
          System::Call '*$2(&w$3 .r4)'
        ${EndIf}
      ${EndIf}
    ${EndIf}
    System::Free $1
  ${EndIf}
  ${If} $4 != ""
    System::Call 'kernel32::SetEnvironmentVariableW(w "AIRHAND_INSTALLER_VERSION", w r4)'
  ${EndIf}
  Pop $4
  Pop $3
  Pop $2
  Pop $1
  Pop $0
FunctionEnd

!macro NSIS_HOOK_PREINSTALL
  ${If} ${FileExists} "$INSTDIR\${MAINBINARYNAME}.exe"
    ${If} $MultiUser.InstallMode == "CurrentUser"
      DetailPrint "Closing Airhand…"
      nsExec::ExecToLog '"$INSTDIR\${MAINBINARYNAME}.exe" --quit'
    ${Else}
      DetailPrint "Stopping the Airhand service…"
      nsExec::ExecToLog '"$INSTDIR\${MAINBINARYNAME}.exe" --stop-service'
    ${EndIf}
    Pop $0
  ${EndIf}
!macroend

!macro NSIS_HOOK_POSTINSTALL
  ${If} $MultiUser.InstallMode == "CurrentUser"
    DetailPrint "Setting up Airhand for this user…"
    nsExec::ExecToLog '"$INSTDIR\${MAINBINARYNAME}.exe" --install-user'
    Pop $0
    ${If} $0 != 0
      MessageBox MB_ICONEXCLAMATION "无法完成 Airhand 的安装（$0），Airhand 不能运行。$\r$\nCan't finish installing Airhand ($0), it won't run."
    ${EndIf}
  ${Else}
    DetailPrint "Installing the Airhand service…"
    nsExec::ExecToLog '"$INSTDIR\${MAINBINARYNAME}.exe" --install'
    Pop $0
    ${If} $0 != 0
      MessageBox MB_ICONEXCLAMATION "无法安装 Airhand 系统服务（$0），本机将不能被远程控制。$\r$\nCan't install the Airhand system service ($0), this computer can't be controlled remotely."
    ${EndIf}
  ${EndIf}
!macroend

!macro NSIS_HOOK_PREUNINSTALL
  ${If} $MultiUser.InstallMode == "CurrentUser"
    DetailPrint "Removing Airhand for this user…"
    nsExec::ExecToLog '"$INSTDIR\${MAINBINARYNAME}.exe" --uninstall-user'
    Pop $0
    ${If} $0 != 0
      ; airhand.exe 运行失败（例如已经损坏）：直接删除登录时自动启动和记下的安装位置
      DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "Airhand"
      ; 只删自己的值：这个键（不分大小写）也是 Tauri 记安装位置和语言的 ${MANUKEY}，空了才删
      DeleteRegValue HKCU "Software\Airhand" "UserInstall"
      DeleteRegKey /ifempty HKCU "Software\Airhand"
    ${EndIf}
  ${Else}
    DetailPrint "Removing the Airhand service…"
    nsExec::ExecToLog '"$INSTDIR\${MAINBINARYNAME}.exe" --uninstall'
    Pop $0
    ${If} $0 != 0
      ; airhand.exe 运行失败（例如已经损坏）：用系统工具删除服务和开机启动项
      nsExec::ExecToLog '"$SYSDIR\sc.exe" stop Airhand'
      Pop $0
      Sleep 3000
      nsExec::ExecToLog '"$SYSDIR\sc.exe" delete Airhand'
      Pop $0
      DeleteRegValue HKLM "Software\Microsoft\Windows\CurrentVersion\Run" "Airhand"
    ${EndIf}
  ${EndIf}
!macroend

!macro NSIS_HOOK_POSTUNINSTALL
  ReadEnvStr $0 AIRHAND_UPGRADE
  ; 同一个版本的安装程序里选"卸载 Airhand"：不是升级，是真的卸载
  ReadEnvStr $1 AIRHAND_INSTALLER_VERSION
  ${If} $1 == "${VERSION}"
    StrCpy $0 ""
  ${EndIf}
  ${If} $UpdateMode <> 1
  ${AndIf} $0 != "1"
    Delete "$INSTDIR\config.toml"
    Delete "$INSTDIR\config.toml.tmp"
    RMDir "$INSTDIR"
    ; 安装程序记下的安装位置和语言（Tauri 只在勾选"删除应用程序数据"时删除）
    DeleteRegKey SHCTX "${MANUPRODUCTKEY}"
    DeleteRegKey /ifempty SHCTX "${MANUKEY}"
    DeleteRegValue HKCU "${MANUPRODUCTKEY}" "Installer Language"
    DeleteRegKey /ifempty HKCU "${MANUPRODUCTKEY}"
    DeleteRegKey /ifempty HKCU "${MANUKEY}"
    ; 仅为我安装时记下的安装位置：PREUNINSTALL 的 --uninstall-user 已经删了；不分大小写时它和上面的 MANUKEY 是同一个键，这里不依赖这一点
    DeleteRegValue HKCU "Software\Airhand" "UserInstall"
    DeleteRegKey /ifempty HKCU "Software\Airhand"
    ; Tauri 的应用数据目录（Tauri 同样只在勾选"删除应用程序数据"时删除；Airhand 不用它们，以防万一）。
    ; 要在上面按 SHCTX 删完之后再切换到当前用户
    SetShellVarContext current
    RMDir /r "$APPDATA\${BUNDLEID}"
    RMDir /r "$LOCALAPPDATA\${BUNDLEID}"
    ; 用户在 Windows 防火墙的提示里允许 airhand.exe 时系统添加的规则（仅为我安装时没有管理员权限的话删不掉，规则只对这个路径有效）
    nsExec::ExecToLog '"$SYSDIR\netsh.exe" advfirewall firewall delete rule name=all program="$INSTDIR\${MAINBINARYNAME}.exe"'
    Pop $0
  ${EndIf}
  ; 控制台的 WebView 临时目录（正常退出时已经删除，这里清理强制结束时的残留）
  FindFirst $1 $2 "$TEMP\airhand-webview-*"
  ${DoWhile} $2 != ""
    RMDir /r "$TEMP\$2"
    FindNext $1 $2
  ${Loop}
  FindClose $1
!macroend

; Use the same assisted NSIS pages and defaults as JellyGoGo.
; No license page: MIT and third-party notices remain inside the payload.
!define NOASR_INNO_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\{B9866D08-10BD-4B43-A98D-F0EE5021C620}_is1"

!macro customInit
  ; Reuse this user's existing preview location without running its old uninstaller.
  ReadRegStr $R0 HKCU "${NOASR_INNO_KEY}" "InstallLocation"
  ${If} $R0 != ""
    StrCpy $INSTDIR "$R0"
  ${EndIf}
!macroend

!macro customInstall
  ExecWait '"$INSTDIR\NoASR.exe" --installer-migrate' $R0
  ${If} $R0 != 0
    MessageBox MB_OK|MB_ICONINFORMATION "旧安装记录未能完全更新。程序和用户数据已保留，请反馈此提示。"
  ${EndIf}
!macroend

!macro customUnInstall
  ${IfNot} ${isUpdated}
    ExecWait '"$INSTDIR\NoASR.exe" --uninstall-cleanup' $R0
    ${If} $R0 != 0
      MessageBox MB_OK|MB_ICONINFORMATION "自启动项未能完全清理。请以管理员身份关闭 NoASR 的开机自启动，或检查任务计划程序中的 DaiwenVoiceInput。用户数据已保留。"
    ${EndIf}
  ${EndIf}
!macroend

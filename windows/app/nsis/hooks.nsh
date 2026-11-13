; SpaceSaver installer hooks (Tauri NSIS).
;
; SpaceSaver keeps its activity log and last scan in %LOCALAPPDATA%\SpaceSaver, which is also
; the default per-user install folder. Tauri's "Delete the application data" checkbox only
; removes the folders named after the bundle identifier, so this removes SpaceSaver's own data
; files too, and then the folder if nothing else is left in it. Nothing else is touched.

!macro NSIS_HOOK_POSTUNINSTALL
  ${If} $DeleteAppDataCheckboxState = 1
  ${AndIf} $UpdateMode <> 1
    SetShellVarContext current
    Delete "$LOCALAPPDATA\SpaceSaver\activity.json"
    Delete "$LOCALAPPDATA\SpaceSaver\activity.json.lock"
    Delete "$LOCALAPPDATA\SpaceSaver\activity.json.corrupt-*"
    Delete "$LOCALAPPDATA\SpaceSaver\activity.json.tmp-*"
    Delete "$LOCALAPPDATA\SpaceSaver\last-scan.json"
    Delete "$LOCALAPPDATA\SpaceSaver\last-scan.json.tmp-*"
    RMDir "$LOCALAPPDATA\SpaceSaver"
  ${EndIf}
!macroend

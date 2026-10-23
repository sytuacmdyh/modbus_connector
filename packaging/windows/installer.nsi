Unicode true
!include "MUI2.nsh"
!include "x64.nsh"
Name "Modbus Connector ${VERSION}"
OutFile "${OUTPUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\ModbusConnector"
InstallDirRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ModbusConnector" "InstallLocation"
RequestExecutionLevel user
SetCompressor /SOLID lzma
ShowInstDetails show
ShowUninstDetails show
VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "Modbus Connector"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "FileVersion" "${VERSION}.0"
VIAddVersionKey "FileDescription" "Modbus Connector Windows x64 Setup"
VIAddVersionKey "LegalCopyright" "MIT License - Modbus Connector contributors"
!define MUI_ICON "${ICON_FILE}"
!define MUI_UNICON "${ICON_FILE}"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_NOAUTOCLOSE
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${LICENSE_FILE}"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_UNPAGE_FINISH
!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

Function .onInit
  ${IfNot} ${RunningX64}
    MessageBox MB_ICONSTOP "This application requires 64-bit Windows."
    Abort
  ${EndIf}
  SetRegView 64
  SetShellVarContext current
FunctionEnd

Function un.onInit
  SetRegView 64
  SetShellVarContext current
FunctionEnd

Section "Modbus Connector" Main
  SectionIn RO
  SetOutPath "$INSTDIR"
  ClearErrors
  File /r "${BUNDLE_FILES}"
  IfErrors 0 +3
    SetErrorLevel 1
    Abort
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateDirectory "$SMPROGRAMS\Modbus Connector"
  CreateShortcut "$SMPROGRAMS\Modbus Connector\Modbus Connector.lnk" "$INSTDIR\ModbusConnector.exe"
  CreateShortcut "$SMPROGRAMS\Modbus Connector\Uninstall.lnk" "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ModbusConnector" "DisplayName" "Modbus Connector"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ModbusConnector" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ModbusConnector" "Publisher" "Modbus Connector contributors"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ModbusConnector" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ModbusConnector" "DisplayIcon" "$INSTDIR\ModbusConnector.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ModbusConnector" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ModbusConnector" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ModbusConnector" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ModbusConnector" "NoRepair" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ModbusConnector" "EstimatedSize" ${INSTALLED_KIB}
SectionEnd

Section "Uninstall"
  !include "${UNINSTALL_FILES}"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  Delete "$SMPROGRAMS\Modbus Connector\Modbus Connector.lnk"
  Delete "$SMPROGRAMS\Modbus Connector\Uninstall.lnk"
  RMDir "$SMPROGRAMS\Modbus Connector"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ModbusConnector"
SectionEnd

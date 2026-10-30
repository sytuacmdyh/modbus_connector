Unicode true
!include "MUI2.nsh"
!include "x64.nsh"
Name "Modbus Connector Flutter ${VERSION}"
OutFile "${OUTPUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\ModbusConnectorFlutter"
InstallDirRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ModbusConnectorFlutter" "InstallLocation"
RequestExecutionLevel user
SetCompressor /SOLID lzma
ShowInstDetails show
ShowUninstDetails show
VIProductVersion "${VERSION_QUAD}"
VIAddVersionKey "ProductName" "Modbus Connector Flutter"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "FileVersion" "${VERSION_QUAD}"
VIAddVersionKey "FileDescription" "Modbus Connector Flutter Windows x64 Setup"
VIAddVersionKey "LegalCopyright" "MIT License - Modbus Connector Flutter contributors"
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

Section "Modbus Connector Flutter" Main
  SectionIn RO
  SetOutPath "$INSTDIR"
  ClearErrors
  File /r "${BUNDLE_FILES}"
  IfErrors 0 +3
    SetErrorLevel 1
    Abort
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateDirectory "$SMPROGRAMS\Modbus Connector Flutter"
  CreateShortcut "$SMPROGRAMS\Modbus Connector Flutter\Modbus Connector Flutter.lnk" "$INSTDIR\modbus_desktop.exe"
  CreateShortcut "$SMPROGRAMS\Modbus Connector Flutter\Uninstall.lnk" "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ModbusConnectorFlutter" "DisplayName" "Modbus Connector Flutter"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ModbusConnectorFlutter" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ModbusConnectorFlutter" "Publisher" "Modbus Connector Flutter contributors"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ModbusConnectorFlutter" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ModbusConnectorFlutter" "DisplayIcon" "$INSTDIR\modbus_desktop.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ModbusConnectorFlutter" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ModbusConnectorFlutter" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ModbusConnectorFlutter" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ModbusConnectorFlutter" "NoRepair" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ModbusConnectorFlutter" "EstimatedSize" ${INSTALLED_KIB}
SectionEnd

Section "Uninstall"
  !include "${UNINSTALL_FILES}"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  Delete "$SMPROGRAMS\Modbus Connector Flutter\Modbus Connector Flutter.lnk"
  Delete "$SMPROGRAMS\Modbus Connector Flutter\Uninstall.lnk"
  RMDir "$SMPROGRAMS\Modbus Connector Flutter"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ModbusConnectorFlutter"
SectionEnd

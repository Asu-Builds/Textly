; Textly – Windows-Installer (Inno Setup 6)
;
; Bauen: tool\build_installer.ps1 (Release-Build, C++-Laufzeit, dann dieses Skript).
; Ergebnis: build\installer\Textly-Setup-<Version>.exe
;
; - Installation ohne Administratorrechte in den Benutzerordner (auf Wunsch für alle Benutzer)
; - Startmenü-Eintrag, auf Wunsch Desktop-Verknüpfung
; - .textly-Dateien öffnen sich per Doppelklick in Textly
; - Deinstallation über «Apps & Features»; Dokumente und Sicherungen bleiben erhalten

#define AppName "Textly"
#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#define BuildDir "..\build\windows\x64\runner\Release"

[Setup]
; Feste ID: Updates ersetzen die bestehende Installation
AppId={{8B2F4C1E-5A3D-4E7B-9C61-2D7F0A9E3B54}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Textly
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\build\installer
OutputBaseFilename=Textly-Setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\textly.exe
UninstallDisplayName={#AppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
ChangesAssociations=yes
CloseApplications=yes

[Languages]
Name: "german"; MessagesFile: "compiler:Languages\German.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\textly.exe"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\textly.exe"; Tasks: desktopicon

[Registry]
; .textly-Dateien mit Textly öffnen (HKA = pro Benutzer oder für alle, je nach Installationsart)
Root: HKA; Subkey: "Software\Classes\.textly"; ValueType: string; ValueName: ""; ValueData: "Textly.Dokument"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\Textly.Dokument"; ValueType: string; ValueName: ""; ValueData: "Textly-Dokument"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Textly.Dokument\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\textly.exe,0"
Root: HKA; Subkey: "Software\Classes\Textly.Dokument\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\textly.exe"" ""%1"""

[Run]
Filename: "{app}\textly.exe"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

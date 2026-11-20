; The Windows installer (Inno Setup 6). build-installer.ps1 builds it from the
; release build, in CI too:
;
;   ISCC /DAppVersion=0.2.0 /DAppDir=C:\...\Release /DOutputDir=C:\...\dist
;        /DOutputName=hanashi-0.2.0-windows-x64-setup packaging\windows\hanashi.iss
;
; It installs for the current user, without administrator rights, or for
; everyone when the user chooses so.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef AppDir
  #define AppDir "..\..\app\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif
#ifndef OutputName
  #define OutputName "hanashi-setup"
#endif
#define AppExe "hanashi.exe"

[Setup]
; Windows knows the installation by this ID; it must never change.
AppId={{86E84973-1A7A-4BAD-AC3F-9FEE5C4F0C00}
AppName=Hanashi
AppVersion={#AppVersion}
AppPublisher=Hanashi
DefaultDirName={autopf}\Hanashi
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename={#OutputName}
SetupIconFile=..\..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#AppDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Hanashi"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\Hanashi"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Registry]
; "Start at login" (a setting in the app) goes away with the app.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "Hanashi"; Flags: dontcreatekey uninsdeletevalue

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,Hanashi}"; Flags: nowait postinstall skipifsilent

#define MyAppName "Film Streaming"
#define MyAppVersion "1.0.5"
#define MyAppPublisher "Film Streaming"
#define MyAppExeName "film_streaming.exe"

[Setup]
AppId={{72B70AF8-217E-4A20-9EB6-A117A3ED1C66}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\Film Streaming
DefaultGroupName=Film Streaming
OutputDir=..\installer-output
OutputBaseFilename=Film-Streaming-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
UninstallDisplayName=Film Streaming
UninstallDisplayIcon={app}\{#MyAppExeName}
CloseApplications=yes
RestartApplications=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Film Streaming"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\Film Streaming"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Buat shortcut di Desktop"; GroupDescription: "Shortcut:"; Flags: unchecked

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Jalankan Film Streaming"; Flags: nowait postinstall skipifsilent

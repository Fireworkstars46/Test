#define MyAppName "Taskbar Icon Size Tuner"
#define MyAppVersion "0.7.0"
#define MyAppExeName "TaskbarIconSizeTuner.exe"

[Setup]
AppId={{3C924A61-0D43-4B75-95BD-214DBB7798A6}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
DefaultDirName={autopf}\Taskbar Icon Size Tuner
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=dist
OutputBaseFilename=Taskbar-Icon-Size-Tuner-Setup-0.7.0
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
SetupIconFile=AppIcon.ico

[Files]
Source: "bin\TaskbarIconSizeTuner.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "bin\TaskbarIconHook-0.7.dll"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

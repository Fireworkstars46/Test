#define MyAppName "Source Dock Hide for OBS"
#define MyAppVersion "0.4.0"
#define MyAppPublisher "Source Dock Hide community plugin"
#define MyAppURL "https://obsproject.com/"
#define MyAppExeName "obs64.exe"

[Setup]
AppId={{B9FBF837-13F0-4D19-95B3-14BEAC40E768}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
DefaultDirName={code:GetObsInstallDir}
DisableWelcomePage=no
DisableDirPage=no
DisableProgramGroupPage=yes
DisableReadyPage=no
DisableFinishedPage=no
LicenseFile=..\LICENSE
InfoBeforeFile=..\installer\before-install.txt
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=Source-Dock-Hide-Setup-0.4.0
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
WizardSizePercent=100
UsePreviousAppDir=yes
Uninstallable=yes
CreateUninstallRegKey=yes
CloseApplications=yes
RestartApplications=no
SetupLogging=yes
VersionInfoVersion=0.4.0.0
VersionInfoCompany=Source Dock Hide community plugin
VersionInfoDescription=Installer for Source Dock Hide OBS plugin
VersionInfoProductName=Source Dock Hide for OBS
VersionInfoProductVersion=0.4.0
VersionInfoCopyright=Community plugin; not affiliated with OBS Project

[Files]
; Install the compiled 64-bit plugin into OBS's normal Windows plugin folder.
Source: "..\stage\source-dock-hide\bin\64bit\source-dock-hide.dll"; DestDir: "{app}\obs-plugins\64bit"; Flags: ignoreversion

[Run]
Filename: "{app}\bin\64bit\obs64.exe"; Description: "Launch OBS Studio"; Flags: nowait postinstall skipifsilent unchecked

[Code]
function GetObsInstallDir(Param: String): String;
var
  Path: String;
begin
  Path := '';

  if IsWin64 then
    RegQueryStringValue(HKLM64, 'SOFTWARE\OBS Studio', '', Path);

  if Path = '' then
    RegQueryStringValue(HKLM32, 'SOFTWARE\OBS Studio', '', Path);

  if (Path = '') or (not FileExists(AddBackslash(Path) + 'bin\64bit\obs64.exe')) then
    Path := ExpandConstant('{autopf}\obs-studio');

  Result := Path;
end;

function InitializeSetup(): Boolean;
var
  ObsPath: String;
begin
  ObsPath := GetObsInstallDir('');
  Result := True;

  if not FileExists(AddBackslash(ObsPath) + 'bin\64bit\obs64.exe') then
  begin
    MsgBox(
      'OBS Studio was not found automatically.' + #13#10 + #13#10 +
      'You can choose the OBS Studio folder on the Destination Folder page.' + #13#10 +
      'The normal location is:' + #13#10 +
      'C:\Program Files\obs-studio',
      mbInformation, MB_OK);
  end;
end;

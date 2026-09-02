#define MyAppName "OBS UI Scale"
#define MyAppVersion "0.3.0"
#define MyAppPublisher "OBS UI Scale community plugin"
#define MyAppURL "https://obsproject.com/"

[Setup]
AppId={{A0BCF1D1-8E57-4CDA-9C58-A26477B6DDC4}
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
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=OBS-UI-Scale-Setup-0.3.0
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UsePreviousAppDir=yes
Uninstallable=yes
CreateUninstallRegKey=yes
CloseApplications=yes
RestartApplications=no
SetupLogging=yes
VersionInfoVersion=0.3.0.0
VersionInfoCompany=OBS UI Scale community plugin
VersionInfoDescription=Installer for the OBS UI Scale plugin
VersionInfoProductName=OBS UI Scale
VersionInfoProductVersion=0.3.0
VersionInfoCopyright=Community plugin; not affiliated with OBS Project

[Files]
Source: "..\stage\obs-ui-scale\bin\64bit\obs-ui-scale.dll"; DestDir: "{app}\obs-plugins\64bit"; Flags: ignoreversion

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
      'Choose your OBS Studio folder on the Destination Folder page.' + #13#10 +
      'The normal location is:' + #13#10 +
      'C:\Program Files\obs-studio',
      mbInformation, MB_OK);
  end;
end;

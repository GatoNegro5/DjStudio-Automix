#ifndef AppVer
  #define AppVer "1.0.0"
#endif
[Setup]
AppName=GatoMix
AppVersion={#AppVer}
DefaultDirName={autopf}\GatoMix
DefaultGroupName=GatoMix
OutputDir=.\
OutputBaseFilename=GatoMix-Installer
Compression=lzma2/ultra64
SolidCompression=yes
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=lowest
SetupIconFile=windows\runner\resources\app_icon.ico

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\GatoMix"; Filename: "{app}\gatomix_player.exe"
Name: "{autodesktop}\GatoMix"; Filename: "{app}\gatomix_player.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Crear un acceso directo en el escritorio"; GroupDescription: "Iconos adicionales:"
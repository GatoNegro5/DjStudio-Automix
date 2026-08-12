[Setup]
AppName=DjStudio
AppVersion=1.0.6
DefaultDirName={autopf}\DjStudio
DefaultGroupName=DjStudio
OutputDir=.\
OutputBaseFilename=DjStudio-Installer
Compression=lzma2/ultra64
SolidCompression=yes
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=lowest

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\DjStudio"; Filename: "{app}\djstudio_player.exe"
Name: "{autodesktop}\DjStudio"; Filename: "{app}\djstudio_player.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Crear un acceso directo en el escritorio"; GroupDescription: "Iconos adicionales:"
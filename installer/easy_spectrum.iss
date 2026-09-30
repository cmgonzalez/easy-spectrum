; Instalador de Easy Spectrum para Windows (Inno Setup 6).
; Lo compila `bash build-app.sh installer`, que pasa:
;   /DAppVersion=1.0.0 /DAppCode=1 /DSourceDir=<Release> /DRedistDir=<VC CRT x64> /DOutputDir=<raíz>
;
; - Por defecto se instala para el usuario actual (sin pedir administrador); el diálogo
;   permite elegir "para todos los usuarios". Las claves de registro usan HKA, que sigue
;   esa elección (HKCU o HKLM).
; - Runtime de VC++ copiado junto al .exe (despliegue local: no hace falta instalar el
;   redistribuible).
; - Tipos de archivo: Easy Spectrum queda siempre en "Abrir con" de .tap .tzx .z80 .sna
;   .szx .dsk .csw (y .zip); con la tarea "associate" pasa a ser el predeterminado de
;   esos (no de .zip). Al desinstalar se quita todo.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef AppCode
  #define AppCode "1"
#endif
#ifndef SourceDir
  #define SourceDir "..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir ".."
#endif

#define AppName "Easy Spectrum"
#define AppExe "EasySpectrum.exe"
#define ProgId "EasySpectrum.Media"

[Setup]
AppId={{00C6FEFD-5F2D-40BB-BCCB-B6E31CCA253C}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=EasySoft SPA
AppPublisherURL=https://www.easysoft.cl
AppSupportURL=https://www.easysoft.cl
AppContact=soporte@easysoft.cl
VersionInfoVersion={#AppVersion}.{#AppCode}
VersionInfoCompany=EasySoft SPA
VersionInfoDescription={#AppName} Setup
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
ChangesAssociations=yes
CloseApplications=yes
RestartApplications=no
OutputDir={#OutputDir}
OutputBaseFilename=EasySpectrum-Setup-{#AppVersion}-{#AppCode}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
WizardStyle=modern
WizardImageFile=wizard.bmp,wizard_200.bmp
WizardSmallImageFile=wizard_small.bmp,wizard_small_200.bmp
Compression=lzma2/max
SolidCompression=yes
ShowLanguageDialog=auto
LanguageDetectionMethod=uilanguage

[Languages]
Name: "es"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "pt"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"
Name: "it"; MessagesFile: "compiler:Languages\Italian.isl"
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"

[CustomMessages]
es.Associate=Abrir con {#AppName} los archivos de Spectrum (.tap .tzx .z80 .sna .szx .dsk .csw)
en.Associate=Open Spectrum files with {#AppName} (.tap .tzx .z80 .sna .szx .dsk .csw)
pt.Associate=Abrir arquivos do Spectrum com o {#AppName} (.tap .tzx .z80 .sna .szx .dsk .csw)
it.Associate=Apri i file dello Spectrum con {#AppName} (.tap .tzx .z80 .sna .szx .dsk .csw)
ru.Associate=Открывать файлы Spectrum в {#AppName} (.tap .tzx .z80 .sna .szx .dsk .csw)
es.FileTypes=Tipos de archivo:
en.FileTypes=File types:
pt.FileTypes=Tipos de arquivo:
it.FileTypes=Tipi di file:
ru.FileTypes=Типы файлов:
es.MediaFile=Archivo de ZX Spectrum
en.MediaFile=ZX Spectrum file
pt.MediaFile=Arquivo do ZX Spectrum
it.MediaFile=File dello ZX Spectrum
ru.MediaFile=Файл ZX Spectrum

[Tasks]
Name: "associate"; Description: "{cm:Associate}"; GroupDescription: "{cm:FileTypes}"
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
#ifdef RedistDir
Source: "{#RedistDir}\vcruntime140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#RedistDir}\vcruntime140_1.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#RedistDir}\msvcp140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#RedistDir}\msvcp140_1.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#RedistDir}\msvcp140_2.dll"; DestDir: "{app}"; Flags: ignoreversion
#endif

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Registry]
; Tipo de archivo propio (ícono y comando de apertura).
Root: HKA; Subkey: "Software\Classes\{#ProgId}"; ValueType: string; ValueData: "{cm:MediaFile}"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\{#ProgId}\DefaultIcon"; ValueType: string; ValueData: "{app}\{#AppExe},0"
Root: HKA; Subkey: "Software\Classes\{#ProgId}\shell\open\command"; ValueType: string; ValueData: """{app}\{#AppExe}"" ""%1"""
; La aplicación (para "Abrir con" y Aplicaciones predeterminadas de Windows).
Root: HKA; Subkey: "Software\Classes\Applications\{#AppExe}"; ValueType: string; ValueName: "FriendlyAppName"; ValueData: "{#AppName}"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Applications\{#AppExe}\shell\open\command"; ValueType: string; ValueData: """{app}\{#AppExe}"" ""%1"""
; Extensiones de Spectrum: siempre en "Abrir con"; predeterminado con la tarea "associate".
Root: HKA; Subkey: "Software\Classes\.tap\OpenWithProgids"; ValueType: string; ValueName: "{#ProgId}"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\Applications\{#AppExe}\SupportedTypes"; ValueType: string; ValueName: ".tap"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\.tap"; ValueType: string; ValueData: "{#ProgId}"; Flags: uninsdeletevalue; Tasks: associate
Root: HKA; Subkey: "Software\Classes\.tzx\OpenWithProgids"; ValueType: string; ValueName: "{#ProgId}"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\Applications\{#AppExe}\SupportedTypes"; ValueType: string; ValueName: ".tzx"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\.tzx"; ValueType: string; ValueData: "{#ProgId}"; Flags: uninsdeletevalue; Tasks: associate
Root: HKA; Subkey: "Software\Classes\.z80\OpenWithProgids"; ValueType: string; ValueName: "{#ProgId}"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\Applications\{#AppExe}\SupportedTypes"; ValueType: string; ValueName: ".z80"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\.z80"; ValueType: string; ValueData: "{#ProgId}"; Flags: uninsdeletevalue; Tasks: associate
Root: HKA; Subkey: "Software\Classes\.sna\OpenWithProgids"; ValueType: string; ValueName: "{#ProgId}"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\Applications\{#AppExe}\SupportedTypes"; ValueType: string; ValueName: ".sna"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\.sna"; ValueType: string; ValueData: "{#ProgId}"; Flags: uninsdeletevalue; Tasks: associate
Root: HKA; Subkey: "Software\Classes\.szx\OpenWithProgids"; ValueType: string; ValueName: "{#ProgId}"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\Applications\{#AppExe}\SupportedTypes"; ValueType: string; ValueName: ".szx"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\.szx"; ValueType: string; ValueData: "{#ProgId}"; Flags: uninsdeletevalue; Tasks: associate
Root: HKA; Subkey: "Software\Classes\.dsk\OpenWithProgids"; ValueType: string; ValueName: "{#ProgId}"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\Applications\{#AppExe}\SupportedTypes"; ValueType: string; ValueName: ".dsk"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\.dsk"; ValueType: string; ValueData: "{#ProgId}"; Flags: uninsdeletevalue; Tasks: associate
Root: HKA; Subkey: "Software\Classes\.csw\OpenWithProgids"; ValueType: string; ValueName: "{#ProgId}"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\Applications\{#AppExe}\SupportedTypes"; ValueType: string; ValueName: ".csw"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\.csw"; ValueType: string; ValueData: "{#ProgId}"; Flags: uninsdeletevalue; Tasks: associate
; .zip: solo "Abrir con" (no se apropia de todos los zip del sistema).
Root: HKA; Subkey: "Software\Classes\.zip\OpenWithProgids"; ValueType: string; ValueName: "{#ProgId}"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\Applications\{#AppExe}\SupportedTypes"; ValueType: string; ValueName: ".zip"; ValueData: ""

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

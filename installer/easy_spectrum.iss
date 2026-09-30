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
; - Queda registrada en "Aplicaciones predeterminadas" (RegisteredApplications): si otro
;   programa ya es el predeterminado, Windows solo deja cambiarlo al usuario; la casilla
;   final (y Archivo › Establecer como predeterminado, en la app) abre esa página.

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
#define RegApp "EasySpectrum"
#define CapKey "Software\EasySoft\EasySpectrum\Capabilities"

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

es.SetDefault=Elegir {#AppName} como programa predeterminado (abre Configuración de Windows)
en.SetDefault=Choose {#AppName} as the default app (opens Windows Settings)
pt.SetDefault=Escolher o {#AppName} como aplicativo padrão (abre as Configurações do Windows)
it.SetDefault=Scegli {#AppName} come app predefinita (apre Impostazioni di Windows)
ru.SetDefault=Выбрать {#AppName} приложением по умолчанию (откроются Параметры Windows)
es.AppDescription=Emulador de ZX Spectrum
en.AppDescription=ZX Spectrum emulator
pt.AppDescription=Emulador de ZX Spectrum
it.AppDescription=Emulatore di ZX Spectrum
ru.AppDescription=Эмулятор ZX Spectrum

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

; "Aplicaciones predeterminadas" de Windows (sin .zip: el botón "Establecer como
; predeterminado" de Configuración asigna todas las extensiones listadas).
Root: HKA; Subkey: "Software\EasySoft\EasySpectrum"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\EasySoft"; Flags: uninsdeletekeyifempty
Root: HKA; Subkey: "{#CapKey}"; ValueType: string; ValueName: "ApplicationName"; ValueData: "{#AppName}"
Root: HKA; Subkey: "{#CapKey}"; ValueType: string; ValueName: "ApplicationDescription"; ValueData: "{cm:AppDescription}"
Root: HKA; Subkey: "{#CapKey}"; ValueType: string; ValueName: "ApplicationIcon"; ValueData: "{app}\{#AppExe},0"
Root: HKA; Subkey: "{#CapKey}\FileAssociations"; ValueType: string; ValueName: ".tap"; ValueData: "{#ProgId}"
Root: HKA; Subkey: "{#CapKey}\FileAssociations"; ValueType: string; ValueName: ".tzx"; ValueData: "{#ProgId}"
Root: HKA; Subkey: "{#CapKey}\FileAssociations"; ValueType: string; ValueName: ".z80"; ValueData: "{#ProgId}"
Root: HKA; Subkey: "{#CapKey}\FileAssociations"; ValueType: string; ValueName: ".sna"; ValueData: "{#ProgId}"
Root: HKA; Subkey: "{#CapKey}\FileAssociations"; ValueType: string; ValueName: ".szx"; ValueData: "{#ProgId}"
Root: HKA; Subkey: "{#CapKey}\FileAssociations"; ValueType: string; ValueName: ".dsk"; ValueData: "{#ProgId}"
Root: HKA; Subkey: "{#CapKey}\FileAssociations"; ValueType: string; ValueName: ".csw"; ValueData: "{#ProgId}"
Root: HKA; Subkey: "Software\RegisteredApplications"; ValueType: string; ValueName: "{#RegApp}"; ValueData: "{#CapKey}"; Flags: uninsdeletevalue
; Windows 11 solo lista en "Abrir con" los programas que ya "reconoció" para la extensión
; (valor <ProgId>_<ext> en ApplicationAssociationToasts, que normalmente pone su aviso
; "hay una aplicación nueva"). Sin esto la app no aparece aunque esté registrada.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts"; ValueType: dword; ValueName: "{#ProgId}_.tap"; ValueData: 0; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts"; ValueType: dword; ValueName: "Applications\{#AppExe}_.tap"; ValueData: 0; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts"; ValueType: dword; ValueName: "{#ProgId}_.tzx"; ValueData: 0; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts"; ValueType: dword; ValueName: "Applications\{#AppExe}_.tzx"; ValueData: 0; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts"; ValueType: dword; ValueName: "{#ProgId}_.z80"; ValueData: 0; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts"; ValueType: dword; ValueName: "Applications\{#AppExe}_.z80"; ValueData: 0; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts"; ValueType: dword; ValueName: "{#ProgId}_.sna"; ValueData: 0; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts"; ValueType: dword; ValueName: "Applications\{#AppExe}_.sna"; ValueData: 0; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts"; ValueType: dword; ValueName: "{#ProgId}_.szx"; ValueData: 0; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts"; ValueType: dword; ValueName: "Applications\{#AppExe}_.szx"; ValueData: 0; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts"; ValueType: dword; ValueName: "{#ProgId}_.dsk"; ValueData: 0; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts"; ValueType: dword; ValueName: "Applications\{#AppExe}_.dsk"; ValueData: 0; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts"; ValueType: dword; ValueName: "{#ProgId}_.csw"; ValueData: 0; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts"; ValueType: dword; ValueName: "Applications\{#AppExe}_.csw"; ValueData: 0; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts"; ValueType: dword; ValueName: "{#ProgId}_.zip"; ValueData: 0; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts"; ValueType: dword; ValueName: "Applications\{#AppExe}_.zip"; ValueData: 0; Flags: uninsdeletevalue

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
Filename: "ms-settings:defaultapps?registeredAppUser={#RegApp}"; Description: "{cm:SetDefault}"; Flags: shellexec nowait postinstall skipifsilent; Check: not IsAdminInstallMode
Filename: "ms-settings:defaultapps?registeredAppMachine={#RegApp}"; Description: "{cm:SetDefault}"; Flags: shellexec nowait postinstall skipifsilent; Check: IsAdminInstallMode

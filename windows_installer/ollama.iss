; Inno Setup script for Hearth

#define AppName "Hearth"
#define AppPublisher "shubhamtaywade82"
#define AppURL "https://github.com/shubhamtaywade82/ollama-apk"
#define AppExeName "hearth.exe"

; #define AppVersion "1.0.1"
; #define AppArchitectures "x64"

#ifndef AppVersion
    #error AppVersion is required
#endif

#ifndef AppArchitectures
    #define AppArchitectures "x64"
#endif

[Setup]   
SourceDir=..
#if AppArchitectures == 'x64'
    ArchitecturesAllowed=x64compatible
#else
    ArchitecturesAllowed={#AppArchitectures}
#endif

AppId={{F5B5DDD2-1033-4653-98A4-96F6BCB8306C}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} v{#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
SetupIconFile=windows\runner\resources\app_icon.ico
AppCopyright=Copyright 2026 {#AppPublisher}. Portions Copyright 2024 JHubi1.

VersionInfoCompany={#AppPublisher}
VersionInfoDescription=Installation program for {#AppName}
VersionInfoOriginalFileName={#AppExeName}
VersionInfoVersion={#AppVersion}

UninstallDisplayIcon={app}\{#AppExeName}
UninstallDisplayName={#AppName}

DefaultDirName={autopf}\Hearth
OutputDir=build\windows\{#AppArchitectures}\runner
OutputBaseFilename=hearth-windows-{#AppArchitectures}-v{#AppVersion}

AppSupportURL=https://github.com/shubhamtaywade82/ollama-apk/issues
AppUpdatesURL=https://github.com/shubhamtaywade82/ollama-apk/releases

LicenseFile=windows_installer\docs\license.txt
InfoBeforeFile=windows_installer\docs\before.txt
InfoAfterFile=windows_installer\docs\after.txt

WizardImageFile=assets\brand\hearth-wizard-banner.bmp

PrivilegesRequiredOverridesAllowed=dialog
; Password=enterPasswordInCaseOfSecretBuild
; Encryption=yes

DisableWelcomePage=no
DisableProgramGroupPage=yes

Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
WizardResizable=no

SetupMutex=HearthSetup
CloseApplications=force

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "german"; MessagesFile: "compiler:Languages\German.isl"
Name: "italian"; MessagesFile: "compiler:Languages\Italian.isl"
Name: "turkish"; MessagesFile: "compiler:Languages\Turkish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "build\windows\{#AppArchitectures}\runner\Release\{#AppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "build\windows\{#AppArchitectures}\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Code]
function InitializeSetup(): Boolean;
begin
    Result := true;
    { TODO: Uncoment when arm64 is ready! }
    {if (ProcessorArchitecture = paArm64) and (ExpandConstant('{#AppArchitectures}') = 'x64') then
    begin
        if SuppressibleTaskDialogMsgBox('Architecture Compatibility', 'You are running the x64 version of the installer on an arm64 device. There is an arm64 version avaliable for download. It is recommended to be used. Do you wish to continue?', mbError, MB_YESNO, [SetupMessage(msgButtonYes), SetupMessage(msgButtonNo)], 0, IDYES) = IDNO then
        begin
            Result := false;
        end;
    end;}
end;

procedure CurUninstallStepChanged (CurUninstallStep: TUninstallStep);
    var
        mres : integer;
    begin
        case CurUninstallStep of                   
        usPostUninstall:
            begin
                mres := SuppressibleMsgBox('Do you want to Remove settings?', mbConfirmation, MB_YESNO or MB_DEFBUTTON2, IDYES)
                if mres = IDYES then
                    DelTree(ExpandConstant('{userappdata}\shubhamtaywade82\Hearth'), True, True, True);
        end;
    end;
end;

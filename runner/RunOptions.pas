unit RunOptions;

{$ALIGN ON}
{$MINENUMSIZE 4}

interface

uses
  Windows,
  SysUtils, Classes, IniFiles;

//{$define RedirectStdOut}

const
  CAllOpt = 'All';

  CInfoNam = 'Info';
  CInfos: array[0..2] of string = ('0', '1', '2');

  CBuildNam = 'Build';
  CBuilds: array[0..2] of string = (CAllOpt, 'debug', 'release');

  COSNam = 'OS';
  COSs: array[0..5] of string = (CAllOpt, 'freebsd', 'linux', 'openbsd', 'osx', 'windows');

  CX86Nam = 'X86';
  CX86s: array[0..2] of string = (CAllOpt, '32', '64');

  CDMDNam = 'DMD';
  CRunNam = 'Run';

  COptSec = 'Options';
  CFilSec = 'Files';

type
  TOptions = record
    Build: string;
    OS: string;
    X86: string;
    ProjectIniFileName: string;
    Info: Integer;
  end;

  // Valid section names
  // [Options]
  // [Options Build_Debug] [Options Build_Release]
  // [Options OS_Windows] [Options OS_...]
  // [Options X86_32] [Options X86_64]
  // [Files]
  // [Files Build_Debug] [Files Build_Release]
  // [Files OS_Windows] [Files OS_...]
  // [Files X86_32] [Files X86_64]
  TDMDOptions = class(TObject)
  private
    CheckFiles: TStringList;
    CheckOptions: TStringList;
  public
    Options: TOptions;
    RunFiles: TStringList;
    RunOptions: TStringList;
    constructor Create(const AOptions: TOptions);
    destructor Destroy; override;
    function AddFile(const AFile: string): Boolean;
    function AddOption(const AOption: string): Boolean;
    function BuildIt(const ADMD: string): Integer;
    function BuildInfo: string;
    function GetDMDArguments: string;
    procedure ReadFiles(const AProjectIniFile: TMemIniFile; const ASectionName: string);
    procedure ReadOptions(const AProjectIniFile: TMemIniFile; const ASectionName: string);
    function RunIt(const ARun: string): Integer;
  end;

  TDMDOptionsArray = array of TDMDOptions;

  TRunOptions = class(TObject)
  public
    // Build=default Debug
    // OS=default Windows
    // X86=default 32
    // Info=default 1
    Options: TOptions;
    DMD: string; // default dmd.exe
    Run: string;
    constructor Create;
    function GetDMDOptions: TDMDOptionsArray;
    function ReadOptions(var Errors: string): Boolean;
    function SetOption(const AName, AValue: string): Boolean;
    class function RunOptions: string;
  end;

function AddLine(var Lines: string; const ALine: string): string;
function AddStr(var Strs: string; const AStr: string; const ADelim: Char = ' '): string;
function BreakOption(const AStr: string; var Name, Value: string): Integer;
function IndexOf(const AStrs: array of string; const AStr: string): Integer;
function Quote(const AStr: string; const AQuote: Char = '"'): string;
function Run(const AExe, AArguments: string): Integer;
function StripQuote(const AStr: string): string;
function ToCSV(const AStrs: array of string; const ADelim: Char = ','): string;
function WriteStdOut(AStr: AnsiString): BOOL;
function WriteLnStdOut(AStr: AnsiString): BOOL;

implementation

function AddLine(var Lines: string; const ALine: string): string;
begin
  if Length(Lines) = 0 then
    Lines := ALine
  else
    Lines := Lines + sLineBreak + ALine;
  Result := Lines;
end;

function AddStr(var Strs: string; const AStr: string; const ADelim: Char = ' '): string;
begin
  if Length(Strs) = 0 then
    Strs := AStr
  else
    Strs := Strs + ADelim + AStr;
  Result := Strs;
end;

function BreakOption(const AStr: string; var Name, Value: string): Integer;
var
  I: Integer;
begin
  I := Pos('=', AStr);
  if I > 0 then
  begin
    Name := Trim(Copy(AStr, 1, I - 1));
    Value := Trim(Copy(AStr, I + 1, Length(AStr) - I));
    if Length(Name) > 0 then
    begin
      if Length(Value) > 0 then
        Result := 2
      else
        Result := 1;
    end
    else
      Result := -1;
  end
  else
  begin
    Result := 0;
  end;
end;

function IndexOf(const AStrs: array of string; const AStr: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(AStrs) do
  begin
    if AStrs[I] = AStr then
    begin
      Result := I;
      Exit;
    end;
  end;
  Result := -1;
end;

function Quote(const AStr: string; const AQuote: Char = '"'): string;
begin
  Result := AQuote + AStr + AQuote;
end;

procedure CloseHandleAndNil(var H: THandle);
begin
  if H <> INVALID_HANDLE_VALUE then
  begin
    Windows.CloseHandle(H);
    H := INVALID_HANDLE_VALUE;
  end;
end;

type
  _STARTUPINFOW = record
    cb: DWORD;
    lpReserved: LPWSTR;
    lpDesktop: LPWSTR;
    lpTitle: LPWSTR;
    dwX: DWORD;
    dwY: DWORD;
    dwXSize: DWORD;
    dwYSize: DWORD;
    dwXCountChars: DWORD;
    dwYCountChars: DWORD;
    dwFillAttribute: DWORD;
    dwFlags: DWORD;
    wShowWindow: Word;
    cbReserved2: Word;
    lpReserved2: PByte;
    hStdInput: THandle;
    hStdOutput: THandle;
    hStdError: THandle;
  end;
  TStartupInfoW = _STARTUPINFOW;

function CreateProcessW(lpApplicationName: PWideChar; lpCommandLine: PWideChar;
  lpProcessAttributes, lpThreadAttributes: PSecurityAttributes;
  bInheritHandles: BOOL; dwCreationFlags: DWORD; lpEnvironment: Pointer;
  lpCurrentDirectory: PWideChar; const lpStartupInfo: TStartupInfoW;
  var lpProcessInformation: TProcessInformation): BOOL; stdcall; external kernel32 name 'CreateProcessW';

(*
BOOL PeekNamedPipe(
  [in]            HANDLE  hNamedPipe,
  [out, optional] LPVOID  lpBuffer,
  [in]            DWORD   nBufferSize,
  [out, optional] LPDWORD lpBytesRead,
  [out, optional] LPDWORD lpTotalBytesAvail,
  [out, optional] LPDWORD lpBytesLeftThisMessage
);
*)

{$ifdef RedirectStdOut}
function RedirectStd(const AReadHandle, AWriteHandle: THandle): Boolean;
const
  CBufferSize = 1000;
var
  Buffer: array[0..CBufferSize] of Byte;
  BytesAvail, BytesRead, ByteWrites: DWORD;
begin
  BytesAvail := 0;
  BytesRead := 0;
  if not Windows.PeekNamedPipe(AReadHandle, nil, 0, @BytesRead, @BytesAvail, nil) then
  begin
    Result := False;
    Exit;
  end;
  if BytesAvail = 0 then
  begin
    Result := False;
    Exit;
  end;
  BytesRead := 0;
  if BytesAvail > CBufferSize then
    BytesAvail := CBufferSize;
  Result := Windows.ReadFile(AReadHandle, Buffer, BytesAvail, BytesRead, nil);
  if Result and (BytesRead > 0) then
  begin
    ByteWrites := 0;
    Windows.WriteFile(AWriteHandle, Buffer, BytesRead, ByteWrites, nil);
  end;
end;
{$endif}

function Run(const AExe, AArguments: string): Integer;
var
  ApplicationName, CommandLine, CurrentDirectory: WideString;
  ApplicationNameP, CommandLineP, CurrentDirectoryP: PWideChar;
  PI: TProcessInformation;
  SA: TSecurityAttributes;
  SI: TStartupInfoW;
{$ifdef RedirectStdOut}
  StdErrPipeRead, StdErrPipeWrite,
  StdOutPipeRead, StdOutPipeWrite: THandle;
  ReadOK: Boolean;
{$endif}
begin
  Result := 0;
  
  FillChar(SA, SizeOf(SA), 0);
  SA.nLength := SizeOf(SA);
  SA.bInheritHandle := True;

{$ifdef RedirectStdOut}
  StdOutPipeRead := INVALID_HANDLE_VALUE;
  StdOutPipeWrite := INVALID_HANDLE_VALUE;
  Windows.CreatePipe(StdOutPipeRead, StdOutPipeWrite, @SA, 0);
  Windows.SetHandleInformation(StdOutPipeRead, HANDLE_FLAG_INHERIT, 0);

  StdErrPipeRead := INVALID_HANDLE_VALUE;
  StdErrPipeWrite := INVALID_HANDLE_VALUE;
  Windows.CreatePipe(StdErrPipeRead, StdErrPipeWrite, @SA, 0);
  Windows.SetHandleInformation(StdErrPipeRead, HANDLE_FLAG_INHERIT, 0);
{$endif}

  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  SI.dwFlags := STARTF_USESHOWWINDOW or STARTF_USESTDHANDLES;
  SI.wShowWindow := SW_HIDE;
  SI.hStdInput := Windows.GetStdHandle(STD_INPUT_HANDLE); // don't redirect stdin
{$ifdef RedirectStdOut}
  SI.hStdOutput := StdOutPipeWrite;
  SI.hStdError := StdErrPipeWrite;
{$else}
  SI.hStdOutput := Windows.GetStdHandle(STD_OUTPUT_HANDLE);
  SI.hStdError := Windows.GetStdHandle(STD_ERROR_HANDLE);
{$endif}

  if Length(AExe) > 0 then
  begin
    ApplicationName := AExe + #0;
    ApplicationNameP := PWideChar(ApplicationName);
  end
  else
    ApplicationNameP := nil;
  if Length(AArguments) > 0 then
  begin
    CommandLine := AArguments + #0;
    CommandLineP := PWideChar(CommandLine);
  end
  else
    CommandLineP := nil;
  //CurrentDirectory := ExtractFileDir(ParamStr(0)) + #0;
  //CurrentDirectoryP := PWideChar(CurrentDirectory);
  CurrentDirectoryP := nil;

{$ifdef RedirectStdOut}
  try
    if not CreateProcessW(ApplicationNameP, CommandLineP, nil, nil, True, 0, nil, CurrentDirectoryP, SI, PI) then
    begin
      Result := GetLastError;
      Exit;
    end;

    CloseHandleAndNil(StdErrPipeWrite);
    CloseHandleAndNil(StdOutPipeWrite);
    try
      ReadOK := True; // Make Delphi 7 happy
      repeat
        case Windows.WaitForSingleObject(PI.hProcess, 1000) of
          WAIT_FAILED, WAIT_ABANDONED:
            Break;
        end;
        ReadOK := RedirectStd(StdErrPipeRead, Windows.GetStdHandle(STD_ERROR_HANDLE));
        if RedirectStd(StdOutPipeRead, Windows.GetStdHandle(STD_OUTPUT_HANDLE)) then
          ReadOK := True;
      until not ReadOK;
      // Last read after DMD closed
      RedirectStd(StdErrPipeRead, Windows.GetStdHandle(STD_ERROR_HANDLE));
      RedirectStd(StdOutPipeRead, Windows.GetStdHandle(STD_OUTPUT_HANDLE));
    finally
      Windows.CloseHandle(PI.hThread);
      Windows.CloseHandle(PI.hProcess);
    end;
  finally
    CloseHandleAndNil(StdErrPipeRead);
    CloseHandleAndNil(StdErrPipeWrite);
    CloseHandleAndNil(StdOutPipeRead);
    CloseHandleAndNil(StdOutPipeWrite);
  end;
{$else}
  if not CreateProcessW(ApplicationNameP, CommandLineP, nil, nil, True, 0, nil, CurrentDirectoryP, SI, PI) then
  begin
    Result := Windows.GetLastError;
    Exit;
  end;
  Windows.WaitForSingleObject(PI.hProcess, INFINITE);
  Windows.CloseHandle(PI.hThread);
  Windows.CloseHandle(PI.hProcess);
  Sleep(1000);
{$endif}
end;

function StripQuote(const AStr: string): string;
var
  C: Char;
begin
  if Length(AStr) > 1 then
  begin
    C := AStr[1];
    if ((C = '"') or (C = '''')) and (C = AStr[Length(AStr)]) then
      Result := Trim(Copy(AStr, 2, Length(AStr) - 2))
    else
      Result := Trim(AStr);
  end
  else
    Result := Trim(AStr);
end;

function ToCSV(const AStrs: array of string; const ADelim: Char = ','): string;
var
  I: Integer;
begin
  Result := AStrs[0];
  for I := 1 to High(AStrs) do
    Result := Result + ADelim + AStrs[I];
end;

function WriteStdOut(AStr: AnsiString): BOOL;
var
  OutHandle: THandle;
  BytesRead, ByteWrites: DWORD;
begin
  OutHandle := Windows.GetStdHandle(STD_OUTPUT_HANDLE);
  BytesRead := Length(AStr);
  ByteWrites := 0;
  if BytesRead > 0 then
    Result := Windows.WriteFile(OutHandle, AStr[1], BytesRead, ByteWrites, nil)
  else
    Result := True;
end;

function WriteLnStdOut(AStr: AnsiString): BOOL;
begin
  Result := WriteStdOut(AStr);
  if Result then
    Result := WriteStdOut(sLineBreak);
end;

{ TDMDOptions }

function TDMDOptions.AddFile(const AFile: string): Boolean;
begin
  Result := (Length(AFile) > 0) and (AFile[1] <> '#') and (CheckFiles.IndexOf(AFile) < 0);
  if Result then
  begin
    CheckFiles.Add(AFile);
    RunFiles.Add(AFile);
  end;
end;

function TDMDOptions.AddOption(const AOption: string): Boolean;
begin
  Result := (Length(AOption) > 1) and (AOption[1] <> '#') and (CheckOptions.IndexOf(AOption) < 0);
  if Result then
  begin
    CheckOptions.Add(AOption);
    RunOptions.Add(AOption);
  end;
end;

function TDMDOptions.BuildInfo: string;
begin
  Result := CBuildNam + '=' + Options.Build
    + ' ' + COSNam + '=' + Options.OS
    + ' ' + CX86Nam + '=' + Options.X86
    + ' ' + Options.ProjectIniFileName;
end;

function TDMDOptions.BuildIt(const ADMD: string): Integer;
var
  DMDArguments: string;
begin
  DMDArguments := GetDMDArguments;
  if Options.Info >= 1 then
  begin
    WriteStdOut(BuildInfo);
    WriteLnStdOut(' ...');
  end;
  if Options.Info >= 2 then
  begin
    WriteStdOut(ADMD);
    WriteStdOut(' ');
    WriteLnStdOut(DMDArguments);
  end;
  Result := Run(ADMD, DMDArguments);
  if Result <> 0 then
    WriteLnStdOut('BuildIt failed with error code: ' + IntToStr(Result));
end;

constructor TDMDOptions.Create(const AOptions: TOptions);
const
  CFilesCapacity = 1000;
  COptionsCapacity = 100;
var
  ProjectIniFile: TMemIniFile;
begin
  Options := AOptions;

  CheckFiles := TStringList.Create;
  CheckFiles.Capacity := CFilesCapacity;
  CheckFiles.Sorted := True;

  CheckOptions := TStringList.Create;
  CheckOptions.Capacity := COptionsCapacity;
  CheckOptions.Sorted := True;

  RunFiles := TStringList.Create;
  RunFiles.Capacity := CFilesCapacity;

  RunOptions := TStringList.Create;
  RunOptions.Capacity := COptionsCapacity;

  ProjectIniFile := TMemIniFile.Create(AOptions.ProjectIniFileName);
  try
    ReadOptions(ProjectIniFile, COptSec);
    ReadOptions(ProjectIniFile, COptSec + ' ' + CBuildNam + '_' + AOptions.Build);
    ReadOptions(ProjectIniFile, COptSec + ' ' + COSNam + '_' + AOptions.OS);
    ReadOptions(ProjectIniFile, COptSec + ' ' + CX86Nam + '_' + AOptions.X86);

    ReadFiles(ProjectIniFile, CFilSec);
    ReadFiles(ProjectIniFile, CFilSec + ' ' + CBuildNam + '_' + AOptions.Build);
    ReadFiles(ProjectIniFile, CFilSec + ' ' + COSNam + '_' + AOptions.OS);
    ReadFiles(ProjectIniFile, CFilSec + ' ' + CX86Nam + '_' + AOptions.X86);
  finally
    ProjectIniFile.Free;
  end;

  CheckFiles.Clear;
  CheckOptions.Clear;

  if AOptions.X86 = '32' then
    AddOption('-m32')
  else if AOptions.X86 = '64' then
    AddOption('-m64');

  if Length(AOptions.OS) > 0 then
    AddOption('-os=' + AOptions.OS);
end;

destructor TDMDOptions.Destroy;
begin
  FreeAndNil(CheckFiles);
  FreeAndNil(CheckOptions);
  FreeAndNil(RunFiles);
  FreeAndNil(RunOptions);
  inherited Destroy;
end;

function TDMDOptions.GetDMDArguments: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to RunOptions.Count - 1 do
    AddStr(Result, RunOptions[I]);
  for I := 0 to RunFiles.Count - 1 do
    AddStr(Result, Quote(RunFiles[I]));
end;

procedure TDMDOptions.ReadFiles(const AProjectIniFile: TMemIniFile; const ASectionName: string);
var
  Values: TStringList;
  I: Integer;
begin
  Values := TStringList.Create;
  try
    AProjectIniFile.ReadSectionValues(ASectionName, Values);
    for I := 0 to Values.Count - 1 do
      AddFile(Trim(Values[I]));
  finally
    Values.Free;
  end;
end;

procedure TDMDOptions.ReadOptions(const AProjectIniFile: TMemIniFile; const ASectionName: string);
var
  Values: TStringList;
  I: Integer;
begin
  Values := TStringList.Create;
  try
    AProjectIniFile.ReadSectionValues(ASectionName, Values);
    for I := 0 to Values.Count - 1 do
      AddOption(Trim(Values[I]));
  finally
    Values.Free;
  end;
end;

function TDMDOptions.RunIt(const ARun: string): Integer;
begin
  if Options.Info >= 1 then
  begin
    WriteStdOut(ARun);
    WriteLnStdOut(' ...');
  end;
  Result := Run('', ARun);
  if Result <> 0 then
    WriteLnStdOut('RunIt failed with error code: ' + IntToStr(Result));
end;

{ TRunOptions }

constructor TRunOptions.Create;
begin
  Options.Build := 'debug';
  Options.OS := 'windows';
  Options.X86 := '32';
  Options.Info := 1;
  DMD := 'dmd.exe';
end;

function TRunOptions.GetDMDOptions: TDMDOptionsArray;
var
  Builds, OSs, X86s: array of string;
  DMDOptions: TOptions;
  I, B, O, X: Integer;
begin
  if Options.Build = CAllOpt then
  begin
    SetLength(Builds, Length(CBuilds) - 1);
    for I := 1 to High(CBuilds) do
      Builds[I - 1] := CBuilds[I];
  end
  else
  begin
    SetLength(Builds, 1);
    Builds[0] := Options.Build;
  end;

  if Options.OS = CAllOpt then
  begin
    SetLength(OSs, Length(COSs) - 1);
    for I := 1 to High(COSs) do
      OSs[I - 1] := COSs[I];
  end
  else
  begin
    SetLength(OSs, 1);
    OSs[0] := Options.OS;
  end;

  if Options.X86 = CAllOpt then
  begin
    SetLength(X86s, Length(CX86s) - 1);
    for I := 1 to High(CX86s) do
      X86s[I - 1] := CX86s[I];
  end
  else
  begin
    SetLength(X86s, 1);
    X86s[0] := Options.X86;
  end;

  I := 0;
  DMDOptions := Options;
  SetLength(Result, Length(Builds) * Length(OSs) * Length(X86s));
  for B := 0 to High(Builds) do
  begin
    for O := 0 to High(OSs) do
    begin
      for X := 0 to High(X86s) do
      begin
        DMDOptions.Build := Builds[B];
        DMDOptions.OS := OSs[O];
        DMDOptions.X86 := X86s[X];
        Result[I] := TDMDOptions.Create(DMDOptions);
        Inc(I);
      end;
    end;
  end;
end;

function TRunOptions.ReadOptions(var Errors: string): Boolean;
// ParamStr(0)=program file name
var
  S, N, V: string;
  I, ErrorCount: Integer;
  procedure AddError(const AError: string);
  begin
    AddLine(Errors, AError);
    Inc(ErrorCount);
  end;
begin
  ErrorCount := 0;

  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    case BreakOption(S, N, V) of
      0:
        Options.ProjectIniFileName := StripQuote(S);
      1:
        AddError('Invalid option: ' + S);
      2:
      begin
        if not SetOption(N, V) then
          AddError('Invalid option: ' + S);
      end;
      else
        AddError('Invalid option: ' + S);
    end;
  end;

  if Length(Options.ProjectIniFileName) = 0 then
    AddError('Missing project file-name')
  else if not FileExists(Options.ProjectIniFileName) then
    AddError('Invalid project file-name: ' + Options.ProjectIniFileName);

  Result := ErrorCount = 0;
end;

class function TRunOptions.RunOptions: string;
begin
  Result := 'ProjectFileName.ini';
  AddLine(Result, CBuildNam + '=debug [' + ToCSV(CBuilds) + ']');
  AddLine(Result, COSNam + '=windows [' + ToCSV(COSs) + ']');
  AddLine(Result, CX86Nam + '=32 [' + ToCSV(CX86s) + ']');
  AddLine(Result, CInfoNam + '=1 [' + ToCSV(CInfos) + ']');
  AddLine(Result, CDMDNam + '=dmd.exe');
  AddLine(Result, CRunNam + '=???.exe arguments...');
end;

function TRunOptions.SetOption(const AName, AValue: string): Boolean;
begin
  if AName = CBuildNam then
  begin
    if IndexOf(CBuilds, AValue) >= 0 then
    begin
      Options.Build := AValue;
      Result := True;
      Exit;
    end;
  end
  else if AName = COSNam then
  begin
    if IndexOf(COSs, AValue) >= 0 then
    begin
      Options.OS := AValue;
      Result := True;
      Exit;
    end;
  end
  else if AName = CX86Nam then
  begin
    if IndexOf(CX86s, AValue) >= 0 then
    begin
      Options.X86 := AValue;
      Result := True;
      Exit;
    end;
  end
  else if AName = CInfoNam then
  begin
    if IndexOf(CInfos, AValue) >= 0 then
    begin
      Options.Info := StrToInt(AValue);
      Result := True;
      Exit;
    end;
  end
  else if AName = CDMDNam then
  begin
    DMD := StripQuote(AValue);
    Result := True;
    Exit;
  end
  else if AName = CRunNam then
  begin
    Run := StripQuote(AValue);
    Result := True;
    Exit;
  end;

  Result := False;
end;

end.

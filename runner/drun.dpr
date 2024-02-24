program drun;

{$APPTYPE CONSOLE}

uses
  SysUtils,
  RunOptions in 'RunOptions.pas';

var
  Errors: string;
  ROptions: TRunOptions;
  DOptions: TDMDOptionsArray;
  I, P, R: Integer;

begin
  ROptions := TRunOptions.Create;

  Errors := '';
  if ROptions.ReadCommandOptions(Errors) then
  begin
    DOptions := ROptions.GetDMDOptions;
    for I := 0 to High(DOptions) do
    begin
      R := DOptions[I].BuildIt(ROptions.DMD);
      if (R = 0) and (Length(ROptions.Run) > 0) then
        DOptions[I].RunIt(ROptions.Run);

      if Length(DOptions[I].PermutationOptions) > 0 then
      begin
        for P := 0 to High(DOptions[I].PermutationOptions) do
        begin
          R := DOptions[I].BuildPermutationIt(P, ROptions.DMD);
          if (R = 0) and (Length(ROptions.Run) > 0) then
            DOptions[I].RunIt(ROptions.Run);
        end;
      end;

      FreeAndNil(DOptions[I]);
    end;
    SetLength(DOptions, 0);
  end
  else
  begin
    WriteLnStdOut(Errors);
    WriteLnStdOut('');
    WriteLnStdOut('Command arguments:');
    WriteLnStdOut(TRunOptions.RunOptions);
  end;

  Errors := '';
  FreeAndNil(ROptions);
end.

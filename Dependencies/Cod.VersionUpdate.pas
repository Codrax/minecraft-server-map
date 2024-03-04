unit Cod.VersionUpdate;

{$MODE DELPHI}

interface
  uses
  SysUtils, Classes, DateUtils, IdHTTP, Cod.Math,
  Cod.Types, fpjson, IdSSLOpenSSL;

  type
    TVersionRec = record
      Major,
      Minor,
      Maintenance,
      Build: cardinal;

      APIResponse: TJsonObject;

      procedure Clear;

      // Load
      procedure Parse(From: string);
      procedure NetworkLoad(URL: string);
      procedure HtmlLoad(URL: string);
      procedure APILoad(AppName: string; Endpoint: string = 'https://api.codrutsoft.com/');

      // Comparation
      function CompareTo(Version: TVersionRec): TRelation;
      function NewerThan(Version: TVersionRec): boolean;

      // Conversion
      function ToString: string; overload;
      function ToString(IncludeBuild: boolean): string; overload;
      function ToString(Separator: char; IncludeBuild: boolean = false): string; overload;
    end;

    function MakeVersion(Major, Minor, Maintenance: cardinal; Build: cardinal = 0): TVersionRec;

implementation

function MakeVersion(Major, Minor, Maintenance: cardinal; Build: cardinal = 0): TVersionRec;
begin
  Result.Major := Major;
  Result.Minor := Minor;
  Result.Maintenance := Maintenance;
  Result.Build := Build;
end;


{ TVersionRec }

procedure TVersionRec.NetworkLoad(URL: string);
var
  IdHttp: TIdHTTP;
  HTML: string;
begin
  IdHttp := TIdHTTP.Create(nil);
  try
    HTML := IdHttp.Get(URL);

    Parse(HTML);
  finally
    IdHttp.Free;
  end;
end;


function TVersionRec.NewerThan(Version: TVersionRec): boolean;
begin
  Result := CompareTo(Version) = TRelation.Bigger;
end;

procedure TVersionRec.APILoad(AppName, Endpoint: string);
var
  HTTP: TIdHTTP;
  SSLIOHandler: TIdSSLIOHandlerSocketOpenSSL;
  Request: TJSONObject;
  RequestStream: TStringStream;
  Result: string;
begin
  // Create HTTP and SSLIOHandler components
  HTTP := TIdHTTP.Create(nil);
  SSLIOHandler := TIdSSLIOHandlerSocketOpenSSL.Create(HTTP);
  Request := TJSONObject.Create;

  // Build Request
  Request.Add('mode', 'getversion');
  Request.Add('app', AppName);

  // Request
  RequestStream := TStringStream.Create(Request.AsJSON);
  try
    // Set SSL/TLS options
    SSLIOHandler.SSLOptions.SSLVersions := [sslvTLSv1_2];
    HTTP.IOHandler := SSLIOHandler;

    // Set headers
    HTTP.Request.ContentType := 'application/json';

    // Send POST
    Result := HTTP.Post(Endpoint, RequestStream);

    // Parse
    APIResponse := GetJSON( Result ) as TJSONObject;

    // Parse response
    Parse(APIResponse.Get('version', ''));
  finally
    // Free
    HTTP.Free;
    Request.Free;
    RequestStream.Free;
  end;
end;

procedure TVersionRec.Clear;
begin
  Major := 0;
  Minor := 0;
  Maintenance := 0;
  Build := 0;
end;

function TVersionRec.CompareTo(Version: TVersionRec): TRelation;
begin
  Result := GetNumberRelation(Major, Version.Major);
  if Result <> TRelation.Equal then
    Exit;

  Result := GetNumberRelation(Minor, Version.Minor);
  if Result <> TRelation.Equal then
    Exit;

  Result := GetNumberRelation(Maintenance, Version.Maintenance);
  if Result <> TRelation.Equal then
    Exit;

  Result := GetNumberRelation(Build, Version.Build);
end;

procedure TVersionRec.HtmlLoad(URL: string);
var
  IdHttp: TIdHTTP;
  HTML: string;
begin
  IdHttp := TIdHTTP.Create(nil);
  try
    IdHttp.Request.CacheControl := 'no-cache';
    HTML := IdHttp.Get(URL);

    HTML := Trim(HTML).Replace(#13, '').DeQuotedString;

    Parse(HTML);
  finally
    IdHttp.Free;
  end;
end;

procedure TVersionRec.Parse(From: string);
var
  Separator: char;
  Splitted: TArray<string>;
  I: Integer;
  Value: cardinal;
  AVersions: integer;
begin
  // Separator
  if From.IndexOf('.') <> -1 then
    Separator := '.'
  else
  if From.IndexOf(',') <> -1 then
    Separator := ','
  else
  if From.IndexOf('-') <> -1 then
    Separator := '-'
  else
    Separator := #0;

  // Values
  Splitted := From.Split(Separator);

  AVersions := Length(Splitted);
  if AVersions < 0 then
    Exit;

  // Write
  Clear;

  for I := 0 to AVersions-1 do
    begin
      Value := Splitted[I].ToInteger;
      case I of
        0: Major := Value;
        1: Minor := Value;
        2: Maintenance := Value;
        3: Build := Value;
      end;
    end;
end;

function TVersionRec.ToString: string;
begin
  Result := ToString(false);
end;

function TVersionRec.ToString(IncludeBuild: boolean): string;
begin
  Result := ToString('.', IncludeBuild);
end;

function TVersionRec.ToString(Separator: char; IncludeBuild: boolean): string;
begin
  Result := Major.ToString + Separator + Minor.ToString + Separator + Maintenance.ToString;

  if IncludeBuild then
    Result := Result + Separator + Build.ToString;
end;

end.

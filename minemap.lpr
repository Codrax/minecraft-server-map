program minemap;

{$mode objfpc}{$H+}
{$define LINUX64}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  LibDefine,
  Classes, SysUtils, CustApp,

  // JSON
  jsonparser, fpjson,

  // Cod
  Cod.Console, Cod.Types, Cod.VersionUpdate,

  // Mapper
  MinecraftMapper,

  // Indy
  IdHTTP, IdSocketHandle, IdStack, IdContext, IdTCPClient, IdMappedPortTCP,
  IdCustomTCPServer;

type
  { TUpdaterThread }
  TUpdaterThread = class(TThread)
   private
    FSleepAmount: cardinal;
    FLastModConfig: TDateTime;
    FLastModServers: TDateTime;

    FCount,
    FDelay: cardinal;

    function GetLastModDate(FilePath: string): TDateTime;

    procedure ChangedConfig;
    procedure ChangedServers;

   protected
    procedure Execute; override;

   public
    procedure SetDelay(Value: cardinal);

    constructor Create(SleepTime: cardinal);
  end;

  { TConfigData }
   TConfigData = record
     ListenPort: word;
     UpdateCheck: boolean;
     FileMonitorDelay: integer;

     DefaultMappingAllow: boolean;
     DefaultMappingHost: string;
     DefaultMappingPort: word;
   end;

  { TMapperApplication }
  TMapperApplication = class(TCustomApplication)
  protected
    // App run
    procedure DoRun; override;
  public
    const
    CONFIG_FILE_NAME = 'config.json';
    SERVERS_FILE_NAME = 'servers.json';
    LOGS_FILE_NAME = 'mapper.log';

    KEY_LISTEN = 'listen-port';
    KEY_UPDATE = 'check-update';
    KEY_DEFAULT_ALLOW = 'allow-default-mapping';
    KEY_DEFAULT_MAP = 'default-mapping';
    KEY_MONITOR = 'file-monitor-delay';

    KEY_ADDRESS = 'address';
    KEY_HOST = 'host';
    KEY_PORT = 'port';

    var
    // Properties
    Key: TKeyData;

    // Files
    ApplicationDir: string;
    ConfigFile,
    ServersFile,
    LogsFile: string;

    // Data
    FDoCheckUpdates: boolean;
    FDoLogging: boolean;

    // File updater
    Updater: TUpdaterThread;

    // Mapper
    Mapper: TMinecraftPortTCP;

    // General
    procedure StartListen;
    function CheckQuit: boolean;

    // Utils
    procedure CheckForUpdates;

    // Database
    procedure LoadConfig;
    procedure LoadServers;

    procedure UpdateConfig;
    procedure UpdateServers;

    // Files
    procedure WriteDefaultConfig;
    procedure WriteDefaultServer;

    function ReadFile(FilePath: string): string;
    function WriteFile(FilePath: string; Contents: string): string;
    function ReadConfig: TConfigData;
    function ReadMappings: TMinecraftMappings;

    // Notify
    procedure OnBeforeConnect(AContext: TIdContext);
    procedure OnMap(AContext: TIdContext);
    procedure OnDisconnect(AContext: TIdContext);
    procedure OnReject(AContext: TIdContext);
    procedure OnFailSignature(AContext: TIdContext);
    procedure OnFailOutboundConnect(AContext: TIdContext);

    // Write
    procedure ResetNewLn;
    procedure WriteDate;
    procedure WriteNewLn;
    procedure WriteConnectionCount;
    procedure WriteError(Error: string);
    procedure WriteWarning(Warning: string);
    procedure WriteTitle(ATitle: string);
    procedure WriteHelp; virtual;
    procedure WriteMappingInfo(ATitle: string; Mapping: TMinecraftMapping);

    // Log
    procedure AddLog(Text: string; Kind: string = 'INFO');

    // Default
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;
  end;

const
  Version: TVersionRec = (Major:1;Minor:0;Maintenance:1);

var
  Application: TMapperApplication;
  ServerVersion: TVersionRec;

function TUpdaterThread.GetLastModDate(FilePath: string): TDateTime;
begin
  if not FileAge(FilePath, Result) then
    Result := 0;
end;

procedure TUpdaterThread.ChangedConfig;
begin
  Application.WriteDate;
  TConsole.WriteLn:='Configuration file changed. Indexing changes...';
  Application.ResetNewLn;

  Application.UpdateConfig;
end;

procedure TUpdaterThread.ChangedServers;
begin
  Application.WriteDate;
  TConsole.WriteLn:='Servers list file changed. Indexing changes...';
  Application.ResetNewLn;

  Application.UpdateServers;
end;

procedure TUpdaterThread.Execute;
var
  I: cardinal;
  Change: TDateTime;
begin
  repeat
    for I := 1 to FCount do
      begin
        if Terminated then
          Exit;
        Sleep(FDelay);
      end;

    // Check
    Change := GetLastModDate(Application.ConfigFile);
    if Change <> FLastModConfig then
      begin
        FLastModConfig := Change;
        @ChangedConfig;
      end;

    Change := GetLastModDate(Application.ServersFile);
    if Change <> FLastModServers then
      begin
        FLastModServers := Change;
        ChangedServers;
      end;
  until Terminated;
end;

procedure TUpdaterThread.SetDelay(Value: cardinal);
begin
  FSleepAmount:=Value;

  if FSleepAmount <= 100 then
    begin
      FCount := 1;
      FDelay := FSleepAmount;
    end
  else
    begin
      FCount := FSleepAmount div 100;
      FDelay := 100;
    end;
end;

constructor TUpdaterThread.Create(SleepTime: cardinal);
begin
  inherited Create(false);
  SetDelay(SleepTime);

  // Prep file
  FLastModConfig:=GetLastModDate(Application.ConfigFile);
  FLastModServers:=GetLastModDate(Application.ServersFile);
end;

{ TMyApplication }

procedure TMapperApplication.DoRun;
var
  I: integer;
begin
  // Check terminated
  if Terminated then
    begin
      TConsole.WriteLn:='The server will now close.';
      Exit;
    end;

  // parse parameters
  FDoLogging := HasOption('log-messages');

  // Files
  if HasOption('k', 'config-file') then
    ConfigFile := GetOptionValue('k', 'config-file');
  if HasOption('s', 'servers-file') then
    ServersFile := GetOptionValue('s', 'servers-file');

  // Data
  if HasOption('h', 'help') then begin
    WriteHelp;
    Terminate; Exit;
  end;

  if HasOption('create') then begin
    WriteDefaultConfig;
    WriteDefaultServer;
    Terminate; Exit;
  end;
  if HasOption('create-config') then begin
    WriteDefaultConfig;
    Terminate; Exit;
  end;
  if HasOption('create-server-list') then begin
    WriteDefaultServer;
    Terminate; Exit;
  end;

  if HasOption('compile') then
    begin Terminate; Exit; end;

  if HasOption('check-updates') then
    begin
      CheckForUpdates;
      WriteDate;
      if ServerVersion.NewerThan(Version) then
        TConsole.WriteLn:='A new version is avalabile.'
      else
        TConsole.WriteLn:='No new version found.';
      Terminate;
      Exit;
    end;

  // Config (+ create file monitor)
  LoadConfig;
  if Terminated then
    Exit;

  // Server list
  LoadServers;
  if Terminated then
    Exit;

  // Check for updates
  if FDoCheckUpdates and not HasOption('no-update') then
    CheckForUpdates;

  // Listen
  StartListen;
  if Terminated then
    Exit;

  // Await input
  repeat
    // Terminated
    if Terminated then
      Exit;

    // Get
    Key := TConsole.WaitUntillKeyPressed;

    case Key.Base of
      Ord('h'), Ord('H'): WriteHelp;
      Ord('c'), Ord('C'): WriteConnectionCount;
      Ord('b'), Ord('B'): begin
        WriteDate;
        TConsole.WriteLn:=Format('Bindings count: %D', [Mapper.Bindings.Count]);
      end;
      Ord('a'), Ord('A'): begin
        WriteDate;
        TConsole.WriteLn:=Format('Local address: %S', [GStack.LocalAddress]);
      end;
      Ord('l'), Ord('L'): begin
        TConsole.WriteLn:='';
        WriteTitle('Server list');
        WriteMappingInfo(Format('Default (Enabled:%S)', [booleantostring(Mapper.DefaultAllow)]), Mapper.DefaultMapping);

        for I := 0 to High(Mapper.Mappings) do
          WriteMappingInfo(Format('Mapping no. %D', [I]), Mapper.Mappings[I]);
      end;
      Ord('s'), Ord('S'): begin
        WriteTitle('Active connections');
        if Length(Mapper.ActiveConnections) =0 then
          TConsole.WriteLn:='No active connections.';

        for I := 0 to High(Mapper.ActiveConnections) do
          begin
            TConsole.TextColor:=TConsoleColor.LightBlue;
            TConsole.Write:=Mapper.ActiveConnections[I].Binding.PeerIP;
            TConsole.TextColor:=TConsoleColor.White;
            TConsole.Write:=' -> ';
            TConsole.TextColor:=TConsoleColor.LightGreen;
            TConsole.WriteLn:=Format('%S:%D', [Mapper.ActiveConnections[I].Host, Mapper.ActiveConnections[I].Port]);

            TConsole.ResetStyle;
            Self.ResetNewLn;
          end;
      end;
      Ord('q'), Ord('Q'), 3: begin
        if CheckQuit then
          Break;
      end;
    end;
  until false;

  // stop program loop
  Terminate;
end;

procedure TMapperApplication.LoadConfig;
var
  Config: TConfigData;
begin
  WriteDate;
  TConsole.WriteLn:= 'Reading configuration';

  AddLog('Reading config');

  // Read
  try
    Config := ReadConfig;
  except
    WriteError('Could not load configuration. Check --help to find out how to create a new config file.');
    Terminate;
    Exit;
  end;

  FDoCheckUpdates := Config.UpdateCheck;

  Mapper.DefaultPort:=Config.ListenPort;
  Mapper.SetDefaultMapping(Config.DefaultMappingHost, Config.DefaultMappingPort);

  // Write out
  WriteTitle('Configurations');
  if Config.FileMonitorDelay > 0 then
    TConsole.WriteLn:=Format('File monitor delay: %D', [Config.FileMonitorDelay])
  else
    TConsole.WriteLn:='File monitor is disabled';
  TConsole.WriteLn:=Format('Mapping port: %D', [Mapper.DefaultPort]);
  TConsole.WriteLn:= Format('Default server enabled: %S', [booleantostring(Mapper.DefaultAllow)]);
  TConsole.WriteLn:= Format('Default server mapping: %S:%D', [Mapper.DefaultMapping.Host, Mapper.DefaultMapping.Port]);
  TConsole.WriteLn:= '';

  // Updater
  if Config.FileMonitorDelay > 0 then
    Updater := TUpdaterThread.Create(Config.FileMonitorDelay);
end;

procedure TMapperApplication.LoadServers;
var
  List: TMinecraftMappings;
  I, J: integer;
begin
  WriteDate;
  TConsole.WriteLn:= 'Reading server list';

  AddLog('Reading server list');

  // Read
  try
    List := ReadMappings;
  except
    WriteError('Could not load server list. Check --help to find out how to create a new config file.');
    Terminate;
    Exit;
  end;

  // Check duplicates
  for I := 0 to High(List) do
    for J := 0 to High(List) do
      if (I <> J) and (List[I].Address = List[J].Address) then
        begin
          WriteError('There were duplicate addresses found in the configuration.');
          Terminate;
          Exit;
        end;

  // Check recurse
  for I := 0 to High(List) do
    if (List[I].Port = Mapper.DefaultPort) and ((List[I].Host='localhost') or (List[I].Host='127.0.0.1') or (List[I].Host='0.0.0.0')) then
      begin
        WriteWarning(Format('Server %D is potentially recursive.', [I]));
      end;

  // Set
  Mapper.Mappings := List;

  WriteDate;
  TConsole.WriteLn:= Format('Read a total of %D servers', [length(Mapper.Mappings)]);
end;

procedure TMapperApplication.UpdateConfig;
var
  Config: TConfigData;
begin
  WriteDate;
  TConsole.WriteLn:= 'Reading configuration';
  ResetNewLn;
  AddLog('Loading updated configuration');

  // Read
  try
    Config := ReadConfig;
  except
    WriteError('Could not load configuration. The previous configuration will be kept.');
    Terminate;
    Exit;
  end;

  // Change port
  if Mapper.DefaultAllow <> Config.DefaultMappingAllow then
    Mapper.DefaultAllow:=Config.DefaultMappingAllow;
  if (Mapper.DefaultMapping.Host <> Config.DefaultMappingHost) or
    (Mapper.DefaultMapping.Port <> Config.DefaultMappingPort) then
      Mapper.SetDefaultMapping(Config.DefaultMappingHost, Config.DefaultMappingPort);

  // Change default
  if Mapper.DefaultPort <> Config.ListenPort then
    begin
      Mapper.Active:=false;
      Mapper.DefaultPort:=Config.ListenPort;
      Mapper.Active:=true;
    end;

  // Change updater (cannot be disabled at this stage)
  if Config.FileMonitorDelay > 0 then
    Updater.SetDelay(Config.FileMonitorDelay);

  // Write
  WriteDate;
  TConsole.WriteLn:= 'The new configuration was successfully applied';
  ResetNewLn;
end;

procedure TMapperApplication.UpdateServers;
var
  List: TMinecraftMappings;
  I, J: integer;
  Found: boolean;
  DelCount, NewCount: integer;
begin
  WriteDate;
  TConsole.WriteLn:= 'Reading server list';
  ResetNewLn;
  AddLog('Loading updated server list');

  // Read
  try
    List := ReadMappings;
  except
    WriteError('Could not update server list. The previous indexed list will be kept.');
    Terminate;
    Exit;
  end;

  // Check duplicates
  for I := 0 to High(List) do
    for J := 0 to High(List) do
      if (I <> J) and (List[I].Address = List[J].Address) then
        begin
          WriteError('There were duplicate addresses found in the configuration. The previous list will be kept');
          Terminate;
          Exit;
        end;

  DelCount:=0;
  NewCount:=0;

  // Check for deleted
  for I := High(Mapper.Mappings) downto 0 do
    begin
      Found := false;

      for J := 0 to High(List) do
        if MappingEqual(Mapper.Mappings[I], List[J]) then
          begin
            Found := true;
            Break;
          end;

      // Delete & disconnect
      if not Found then begin
        Mapper.RemoveMapping(I);
        Inc(DelCount);
      end;
    end;

  // Check for new mappings
  for I := High(List) downto 0 do
    begin
      Found := false;

      for J := 0 to High(Mapper.Mappings) do
        if MappingEqual(List[I], Mapper.Mappings[J]) then
          begin
            Found := true;
            Break;
          end;

      if not Found then begin
        Mapper.AddMapping(List[I]);
        Inc(NewCount);
      end;
    end;

  // Write
  WriteDate;
  TConsole.WriteLn:= Format('The new servers were successfully loaded. %D new added and %D deleted.',
    [NewCount, DelCount]);
  ResetNewLn;
end;

procedure TMapperApplication.StartListen;
begin
  try
    Mapper.Active:=true;
  except
    on E: Exception do
      begin
        WriteError(E.Message);
        WriteNewLn;
        Self.Terminate;
        Halt;
      end;
  end;

  TConsole.TextColor:=TConsoleColor.LightCyan;
  TConsole.WriteLn:=Format('Started listening for local connections on port %D', [Mapper.DefaultPort]);
  TConsole.ResetStyle;
  WriteNewLn;
end;

function TMapperApplication.CheckQuit: boolean;
begin
  if (Mapper.ConnectionCount > 0) then
    begin
      WriteNewLn;
      TConsole.TextColor := TConsoleColor.LightRed;
      TConsole.WriteLn := 'Are you sure you want to quit? ';
      TConsole.TextColor := TConsoleColor.White;
      TConsole.Write := 'There are still ';
      TConsole.TextColor := TConsoleColor.LightRed;
      TConsole.Write := Mapper.ConnectionCount.ToString;
      TConsole.TextColor := TConsoleColor.White;
      TConsole.WriteLn := ' clients connected.';
      WriteNewLn;
      TConsole.Write := ' Y/N >> ';

      Key := TConsole.WaitUntillKeyPressed;
      Result := Key.Base = Ord('y');
      TConsole.WriteLn := Char(Key.Base);
      if not Result then
        begin
          TConsole.WriteLn := '';
          WriteDate;
          TConsole.TextColor := TConsoleColor.White;
          TConsole.WriteLn := 'Canceled';
          Exit;
        end;
    end;

    // Exit
    TConsole.WriteLn := '';
    WriteDate;
    TConsole.TextColor := TConsoleColor.Red;
    TConsole.WriteLn := 'Closing server...';

    Result := true;
end;

procedure TMapperApplication.CheckForUpdates;
begin
  WriteDate;
  TConsole.WriteLn:='Checking for updates';
  try
    ServerVersion.APILoad('mine-map');

    if ServerVersion.NewerThan(Version) then
      begin
        WriteTitle('There is a new version avalabile.');
        TConsole.WriteLn:=Format('Current version: %S', [Version.ToString]);
        TConsole.WriteLn:=Format('Server version: %S', [ServerVersion.ToString]);

        TConsole.WriteLn:='Download from https://www.codrutsoft.com/apps/mine-map';
        TConsole.WriteLn:='or from GitHub at https://github.com/Codrax/minecraft-server-map';
        WriteNewLn;
      end;
  except
    WriteWarning('Failed to check for updates');
  end;
end;

procedure TMapperApplication.WriteDefaultConfig;
var
  Data: TJSONObject;
  Sub: TJSONObject;
begin
  WriteDate;
  TConsole.WriteLn:='Generating default configuration file...';
  ResetNewLn;

  Data := TJSONObject.Create;
  try

    Data.Add(KEY_LISTEN, 25565);
    Data.Add(KEY_UPDATE, true);
    Data.Add(KEY_MONITOR, 3000);
    Data.Add(KEY_DEFAULT_ALLOW, false);

    Sub := TJSONObject.Create;
    Sub.Add(KEY_HOST, 'server-adress');
    Sub.Add(KEY_PORT, 25565);
    Data.Add(KEY_DEFAULT_MAP, Sub);

    WriteFile(ConfigFile, Data.FormatJSON());
  finally
    Data.Free;
  end;
end;

procedure TMapperApplication.WriteDefaultServer;
var
  Data: TJSONArray;
  Item: TJSONObject;
begin
  WriteDate;
  TConsole.WriteLn:='Generating default template servers file...';
  ResetNewLn;

  Data := TJSONArray.Create;
  try
    Item := TJSONObject.Create;
    Item.Add(KEY_ADDRESS, 'server1.site.com');
    Item.Add(KEY_HOST, 'localhost');
    Item.Add(KEY_PORT, 25566);
    Data.Add(
      Item

    );
    Item := TJSONObject.Create;
    Item.Add(KEY_ADDRESS, 'server2.site.com');
    Item.Add(KEY_HOST, 'localhost');
    Item.Add(KEY_PORT, 25567);
    Data.Add(
      Item
    );
    Item := TJSONObject.Create;
    Item.Add(KEY_ADDRESS, 'server3.site.com');
    Item.Add(KEY_HOST, '192.168.1.101');
    Item.Add(KEY_PORT, 25565);
    Data.Add(
      Item
    );
    Item := TJSONObject.Create;
    Item.Add(KEY_ADDRESS, '192.168.1.100');
    Item.Add(KEY_HOST, 'localhost');
    Item.Add(KEY_PORT, 25568);
    Data.Add(
      Item
    );

    WriteFile(ServersFile, Data.FormatJSON());
  finally
    Data.Free;
  end;
end;

function TMapperApplication.ReadFile(FilePath: string): string;
var
  F: TextFile;
  S: string;
begin
  Result := '';
  AssignFile(F, FilePath);
  Reset(F);
  while not EOF(F) do
    begin
      ReadLn(F, S);
      Result := Result+#13+S;
    end;

  CloseFile(F);
end;

function TMapperApplication.WriteFile(FilePath: string; Contents: string
  ): string;
var
  F: TextFile;
begin
  Result := '';
  AssignFile(F, FilePath);
  Rewrite(F);
  Write(F, Contents);

  CloseFile(F);
end;

function TMapperApplication.ReadConfig: TConfigData;
var
  Data: TJSONObject;
begin
  Data := GetJSON(ReadFile(ConfigFile).Replace(#13, '')) as TJSONObject;

  with Result do
    begin
      ListenPort:=Data.Get(KEY_LISTEN, 0);
      UpdateCheck:=Data.Get(KEY_UPDATE, false);
      FileMonitorDelay:=Data.Get(KEY_MONITOR, 0);
      DefaultMappingAllow:=Data.Get(KEY_DEFAULT_ALLOW, false);
      DefaultMappingHost:=Data.Get(KEY_DEFAULT_MAP, TJSONObject(nil)).Get(KEY_HOST, '');
      DefaultMappingPort:=Data.Get(KEY_DEFAULT_MAP, TJSONObject(nil)).Get(KEY_PORT, 0);
    end;
end;

function TMapperApplication.ReadMappings: TMinecraftMappings;
var
  Data: TJSONArray;
  Item: TJSONObject;
  I: integer;
begin
  Result := [];
  Data := GetJSON(ReadFile(ServersFile).Replace(#13, '')) as TJSONArray;
  SetLength(Result, Data.Count);

  // Parse
  for I := 0 to Data.Count-1 do
    begin
      Item := Data[I] as TJSONObject;

      with Result[I] do
        begin
          Address:=Item.Get(KEY_ADDRESS, '');
          Host:=Item.Get(KEY_HOST, '');
          Port:=Item.Get(KEY_PORT, 0);
        end;
    end;
end;

procedure TMapperApplication.OnBeforeConnect(AContext: TIdContext);
var
  I: integer;
begin
  // Write
  WriteDate;

  TConsole.TextColor := TConsoleColor.LightGreen;
  TConsole.Write := 'Incoming connection from ';
  TConsole.TextColor := TConsoleColor.LightBlue;
  TConsole.WriteLn := Format('"%S" on port %D', [AContext.Binding.PeerIP, AContext.Binding.Port]);
  ResetNewLn;

  AddLog(Format('New connection: "%S:%D"', [AContext.Binding.PeerIP, AContext.Binding.Port]), 'CONNECTION');
end;

procedure TMapperApplication.OnMap(AContext: TIdContext);
var
  Con: TMinecraftPortContext;
begin
  Con := TMinecraftPortContext(AContext);

  // Write
  WriteDate;

  TConsole.TextColor := TConsoleColor.Yellow;
  TConsole.Write := Format('Mapped connection "%S" with server "%S" to ', [Con.Binding.PeerIP, Con.Address]);
  TConsole.ResetStyle;
  TConsole.Write:=Format('%S:%D', [Con.Host, Con.Port]);
  if Con.UsesDefault then
    TConsole.WriteLn:=' (default mapping)'
  else
    TConsole.WriteLn:='';
  ResetNewLn;

  AddLog(Format('Mapped: "%S, server "%S" to "%S:%D"', [Con.Binding.PeerIP, Con.Address, Con.Host, Con.Port]), 'MAPPER');
end;

procedure TMapperApplication.OnDisconnect(AContext: TIdContext);
var
  Con: TMinecraftPortContext;
begin
  Con := TMinecraftPortContext(AContext);

  // Write
  WriteDate;

  TConsole.TextColor := TConsoleColor.LightRed;
  TConsole.Write := 'Disconnected from ';
  TConsole.TextColor := TConsoleColor.White;
  TConsole.WriteLn := Format('"%S", on server "%S:%D"', [Con.Binding.PeerIP, Con.Host, Con.Port]);
  ResetNewLn;

  AddLog(Format('Disconnected from: "%S:%D", server: "%S"', [Con.Binding.PeerIP, Con.Binding.PeerPort, Con.Host]), 'CONNECTION');
end;

procedure TMapperApplication.OnReject(AContext: TIdContext);
var
  Con: TMinecraftPortContext;
begin
  Con := TMinecraftPortContext(AContext);

  // Mapping failed
  WriteDate;

  TConsole.TextColor:=TConsoleColor.Red;
  TConsole.WriteLn:=Format('Connection for "%S" was dropped. No mapping found for "%S".', [Con.Binding.PeerIP, Con.Address]);
  AContext.Connection.Disconnect;
  TConsole.ResetStyle;
  ResetNewLn;

  AddLog(Format('Rejected "%S, no server named "%S" found', [Con.Binding.PeerIP, Con.Address]), 'MAPPER');
end;

procedure TMapperApplication.OnFailSignature(AContext: TIdContext);
begin
  // Signature read failed
  WriteDate;

  TConsole.TextColor:=TConsoleColor.Red;
  TConsole.WriteLn:=Format('Connection for "%S" was dropped. Could not read signature', [AContext.Binding.PeerIP]);
  AContext.Connection.Disconnect;
  TConsole.ResetStyle;
  ResetNewLn;

  AddLog(Format('Rejected "%S, invalid signature', [AContext.Binding.PeerIP]), 'SIGNATURE');
end;

procedure TMapperApplication.OnFailOutboundConnect(AContext: TIdContext);
var
  Con: TMinecraftPortContext;
begin
  Con := TMinecraftPortContext(AContext);

  // Failed outbound
  WriteDate;

  TConsole.TextColor:=TConsoleColor.Red;
  TConsole.WriteLn:=Format('Could not connect "%S" to outbound server "%S:%D".', [Con.Binding.PeerIP, Con.Host, Con.Port]);
  AContext.Connection.Disconnect;
  TConsole.ResetStyle;
  ResetNewLn;

  AddLog(Format('Could not connect "%S" to outbound server "%S:%D"', [Con.Binding.PeerIP, Con.Host, Con.Port]), 'OUTBOUND');
end;

procedure TMapperApplication.ResetNewLn;
begin
  TConsole.GoToLineBegin;
end;

procedure TMapperApplication.WriteDate;
begin
  TConsole.TextColor := TConsoleColor.White;
  TConsole.Write := Format('[%S] ', [TimeToStr(Now)]);
end;

procedure TMapperApplication.WriteNewLn;
begin
  //TConsole.CursorPos:=Point(0, TConsole.CursorPos.Y+1);
  WriteLn('');
  TConsole.GoToLineBegin;
end;

procedure TMapperApplication.WriteConnectionCount;
begin
  WriteDate;

  TConsole.TextColor := TConsoleColor.Magenta;
  TConsole.Write := Format('There are currently %D active connections', [Mapper.ConnectionCount]);

  WriteNewLn;
end;

procedure TMapperApplication.WriteError(Error: string);
begin
  WriteDate;

  TConsole.BgColor:=TConsoleColor.Red;
  TConsole.TextColor:=TConsoleColor.Black;
  TConsole.Write:='ERROR:';
  TConsole.ResetStyle;
  TConsole.Write:=' ';
  TConsole.WriteLn:=Error;

  AddLog(Error, 'ERROR');
end;

procedure TMapperApplication.WriteWarning(Warning: string);
begin
  TConsole.BgColor:=TConsoleColor.Yellow;
  TConsole.TextColor:=TConsoleColor.Black;
  TConsole.Write:='WARNING:';
  TConsole.ResetStyle;
  TConsole.Write:=' ';
  TConsole.WriteLn:=Warning;

  AddLog(Warning, 'WARNING');
end;

procedure TMapperApplication.WriteTitle(ATitle: string);
begin
  TConsole.WriteLn:='';
  TConsole.TextColor := TConsoleColor.LightBlue;
  TConsole.WriteLn:= ATitle;
  TConsole.TextColor := TConsoleColor.White;
  TConsole.WriteLn:= '====================';
  ResetNewLn;
end;

constructor TMapperApplication.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);
  StopOnException:=True;

  // Files
  ApplicationDir:=IncludeTrailingPathDelimiter(ExtractFileDir(ParamStr(0)));
  ConfigFile:=ApplicationDir+CONFIG_FILE_NAME;
  ServersFile:=ApplicationDir+SERVERS_FILE_NAME;
  LogsFile:=ApplicationDir+LOGS_FILE_NAME;

  // Status
  TConsole.TextColor:= TConsoleColor.LightBlue;
  TConsole.WriteLn:= 'Starting minecraft server mapper';
  TConsole.TextColor:= TConsoleColor.White;
  TConsole.WriteLn:= 'Version '+Version.ToString;
  TConsole.WriteLn:='';

  // Mapper
  WriteDate;
  TConsole.WriteLn:= 'Creating port mapper';
  Mapper := TMinecraftPortTCP.Create(nil);

  // Notify events
  Mapper.OnBeforeConnect := @OnBeforeConnect;
  Mapper.OnMap := @OnMap;
  Mapper.OnReject := @OnReject;
  Mapper.OnFailSignature := @OnFailSignature;
  Mapper.OnFailOutboundConnect := @OnFailOutboundConnect;
  Mapper.OnDisconnect := @OnDisconnect;

  // Defaults
  Mapper.ConnectionTimeout:=-1; // use Indy Default
  Mapper.DefaultPort := 25565;
  Mapper.DefaultAllow:=false;
end;

destructor TMapperApplication.Destroy;
begin
  WriteDate;
  TConsole.WriteLn:= 'Destroying port mapper';

  // Free mapper
  Mapper.Free;

  // Free monitor
  if (Updater <> nil) and not Updater.Finished then
    begin
      WriteDate;
      TConsole.WriteLn:= 'Waiting for file monitor';

      Updater.Terminate;
      Updater.WaitFor;
      Updater.Free;
    end;

  TConsole.WriteLn:='';
  inherited Destroy;
end;

procedure TMapperApplication.WriteHelp;
begin
  WriteTitle('Minecraft Server Mapper');
  TConsole.Write:=Format('Version %S', [Version.ToString]);
  WriteNewLn;

  WriteTitle('Avalabile parameters');
  TConsole.WriteLn:='-h --help -> Provides help documentation';
  TConsole.WriteLn:='-k --config-file <path> -> Provide custom path for config file';
  TConsole.WriteLn:='-s --servers-file <path> -> Provide custom path for servers file';
  TConsole.WriteLn:='--log-messages -> Output log file';
  TConsole.WriteLn:='--no-update -> Bypass update checking';
  TConsole.WriteLn:='--create -> Create all necesary configuration files';
  TConsole.WriteLn:='--create-config -> Write new config file';
  TConsole.WriteLn:='--create-server-list -> Write new server list file';
  TConsole.WriteLn:='--check-updates -> Check for updates';
  WriteNewLn;

  WriteTitle('App keystrokes');
  TConsole.WriteLn:='C -> Show connection count';
  TConsole.WriteLn:='S -> List all active connections';
  TConsole.WriteLn:='A -> Output local adress';
  TConsole.WriteLn:='L -> List registered servers';
  TConsole.WriteLn:='H -> Show this help information';
  TConsole.WriteLn:='Q or Ctrl+C -> Quit the server';
  WriteNewLn;
end;

procedure TMapperApplication.WriteMappingInfo(ATitle: string;
  Mapping: TMinecraftMapping);
begin
  TConsole.TextColor:=TConsoleColor.Yellow;
  TConsole.WriteLn:=ATitle+':';
  TConsole.TextColor := TConsoleColor.White;
  TConsole.WriteLn:=' Source: '+Mapping.Address;
  TConsole.WriteLn:=Format(' Destination %S:%D', [Mapping.Host, Mapping.Port]);
  ResetNewLn;
end;

procedure TMapperApplication.AddLog(Text: string; Kind: string);
var
  F: TextFile;
begin
  if not FDoLogging then
    Exit;

  AssignFile(F, LogsFile);
  try
    try
      if fileexists(LogsFile) then
        Append(F)
      else
        Rewrite(F);

      WriteLn(F, Format('[%S] %S: %S', [DateTimeToStr(Now), UpperCase(Kind), Text]));
    except
      FDoLogging := false;
      WriteError('Could not edit logs file. Logging will now be disabled.'); // no recursion, as logs are now disabled
    end;
  finally
    CloseFile(F);
  end;
end;

begin
  Application:=TMapperApplication.Create(nil);
  Application.Title:='Minecraft Mapper';
  Application.Run;
  Application.Free;
end.


// MIT License
// MakerAI - Sistema de Agentes v3.4
// Registro unificado de herramientas IAiTool con integración PPM.
//
// TAiToolRegistry centraliza todas las herramientas disponibles para
// el sistema de agentes, independientemente de su origen (legacy TAiToolBase,
// función LLM, servidor MCP, o herramienta PPM descargada).
//
// Autor: Gustavo Enríquez
// GitHub: https://github.com/gustavoeenriquez/MakerAi

unit uMakerAi.Agents.ToolRegistry;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.Generics.Collections,
  uMakerAi.Agents.IAiTool,
  uMakerAi.MCPClient.Core;

type

  { TAiRegistryEntry ------------------------------------------------------------
    Entrada del registry: herramienta + metadatos de origen.
  }
  TAiRegistryEntry = record
    Tool     : IAiTool;
    Origin   : String;  // 'local', 'mcp', 'ppm', 'legacy'
    SourceId : String;  // nombre del servidor MCP, paquete PPM, etc.
  end;

  { EAiToolNotFound }
  EAiToolNotFound = class(Exception);

  { TAiPPMPackageInfo }
  TAiPPMPackageInfo = record
    Name        : String;
    Version     : String;
    Description : String;
    DownloadUrl : String;
    Command     : String;
    Args        : String;
  end;

  { TAiToolRegistry -------------------------------------------------------------
    Registro central de herramientas IAiTool.

    Singleton global: TAiToolRegistry.Instance
    Limpiar singleton: TAiToolRegistry.DropInstance
  }
  TAiToolRegistry = class
  private
    class var FInstance: TAiToolRegistry;
    var
    FEntries  : TList<TAiRegistryEntry>;
    FPPMBase  : String;
  public
    constructor Create;
    destructor Destroy; override;

    class function  Instance: TAiToolRegistry;
    // Libera el singleton (llamar en finalization o TearDown de tests)
    class procedure DropInstance;

    // --- Registro ---
    procedure Register(const ATool: IAiTool;
                       const AOrigin: String = 'local';
                       const ASourceId: String = '');
    function RegisterFromMCP(AClient: TMCPClientCustom): Integer;

    // --- Búsqueda ---
    function Find(const AName: String): IAiTool;
    function TryFind(const AName: String; out ATool: IAiTool): Boolean;
    function GetAll: TArray<IAiTool>;
    function GetEntries: TArray<TAiRegistryEntry>;
    procedure Unregister(const AName: String);
    procedure Clear;
    function Count: Integer;

    // --- PPM ---
    function SearchPPM(const AQuery: String;
                       APage: Integer = 1;
                       APerPage: Integer = 20): TArray<TAiPPMPackageInfo>;
    function GetPPMPackage(const AName, AVersion: String): TAiPPMPackageInfo;
    function InstallFromPPM(const APkg: TAiPPMPackageInfo;
                            AOwner: TComponent = nil): TMCPClientCustom;

    property PPMBaseUrl: String read FPPMBase write FPPMBase;
  end;

implementation

uses
  System.Net.HttpClient,
  System.Net.URLClient,
  System.Net.HttpClientComponent,
  System.NetEncoding,
  uMakerAi.Agents.Tools.MCP;

{ TAiToolRegistry }

constructor TAiToolRegistry.Create;
begin
  inherited Create;
  FEntries := TList<TAiRegistryEntry>.Create;
  FPPMBase := 'https://registry.pascalai.org';
end;

destructor TAiToolRegistry.Destroy;
begin
  FEntries.Free;
  inherited;
end;

class function TAiToolRegistry.Instance: TAiToolRegistry;
begin
  if not Assigned(FInstance) then
    FInstance := TAiToolRegistry.Create;
  Result := FInstance;
end;

class procedure TAiToolRegistry.DropInstance;
begin
  FreeAndNil(FInstance);
end;

procedure TAiToolRegistry.Register(const ATool: IAiTool;
  const AOrigin, ASourceId: String);
var
  Entry    : TAiRegistryEntry;
  Existing : IAiTool;
begin
  if not Assigned(ATool) then Exit;
  if TryFind(ATool.Name, Existing) then Exit;  // evitar duplicados
  Entry.Tool     := ATool;
  Entry.Origin   := AOrigin;
  Entry.SourceId := ASourceId;
  FEntries.Add(Entry);
end;

function TAiToolRegistry.RegisterFromMCP(AClient: TMCPClientCustom): Integer;
var
  Tools : TArray<IAiTool>;
  T     : IAiTool;
begin
  Result := 0;
  if not Assigned(AClient) then Exit;
  Tools := TAiMCPToolFactory.CreateFromClient(AClient);
  for T in Tools do
  begin
    Register(T, 'mcp', AClient.Name);
    Inc(Result);
  end;
end;

function TAiToolRegistry.Find(const AName: String): IAiTool;
begin
  if not TryFind(AName, Result) then
    raise EAiToolNotFound.CreateFmt('Herramienta "%s" no encontrada en el registry.', [AName]);
end;

function TAiToolRegistry.TryFind(const AName: String; out ATool: IAiTool): Boolean;
var
  i: Integer;
begin
  for i := 0 to FEntries.Count - 1 do
    if SameText(FEntries[i].Tool.Name, AName) then
    begin
      ATool  := FEntries[i].Tool;
      Result := True;
      Exit;
    end;
  ATool  := nil;
  Result := False;
end;

function TAiToolRegistry.GetAll: TArray<IAiTool>;
var
  List : TList<IAiTool>;
  i    : Integer;
begin
  List := TList<IAiTool>.Create;
  try
    for i := 0 to FEntries.Count - 1 do
      if FEntries[i].Tool.IsAvailable then
        List.Add(FEntries[i].Tool);
    Result := List.ToArray;
  finally
    List.Free;
  end;
end;

function TAiToolRegistry.GetEntries: TArray<TAiRegistryEntry>;
begin
  Result := FEntries.ToArray;
end;

procedure TAiToolRegistry.Unregister(const AName: String);
var
  i: Integer;
begin
  for i := FEntries.Count - 1 downto 0 do
    if SameText(FEntries[i].Tool.Name, AName) then
    begin
      FEntries.Delete(i);
      Break;
    end;
end;

procedure TAiToolRegistry.Clear;
begin
  FEntries.Clear;
end;

function TAiToolRegistry.Count: Integer;
begin
  Result := FEntries.Count;
end;

function TAiToolRegistry.SearchPPM(const AQuery: String;
  APage, APerPage: Integer): TArray<TAiPPMPackageInfo>;
var
  Http   : TNetHTTPClient;
  Resp   : IHTTPResponse;
  JResp  : TJSONObject;
  JData  : TJSONArray;
  JItem  : TJSONValue;
  JObj   : TJSONObject;
  JMeta  : TJSONObject;
  List   : TList<TAiPPMPackageInfo>;
  Pkg    : TAiPPMPackageInfo;
  Url    : String;
  i      : Integer;
begin
  Result := nil;
  List   := TList<TAiPPMPackageInfo>.Create;
  Http   := TNetHTTPClient.Create(nil);
  try
    Http.Accept := 'application/json';
    Url := Format('%s/v1/search?q=%s&type=mcp&page=%d&per_page=%d',
                  [FPPMBase, TNetEncoding.URL.Encode(AQuery), APage, APerPage]);
    try
      Resp := Http.Get(Url);
      if Resp.StatusCode <> 200 then Exit;

      JResp := TJSONObject(TJSONObject.ParseJSONValue(Resp.ContentAsString));
      if not Assigned(JResp) then Exit;
      try
        if not JResp.TryGetValue<TJSONArray>('data', JData) then Exit;
        for i := 0 to JData.Count - 1 do
        begin
          JItem := JData.Items[i];
          if not (JItem is TJSONObject) then Continue;
          JObj := TJSONObject(JItem);

          Pkg := Default(TAiPPMPackageInfo);
          JObj.TryGetValue<String>('name',        Pkg.Name);
          JObj.TryGetValue<String>('version',     Pkg.Version);
          JObj.TryGetValue<String>('description', Pkg.Description);

          JMeta := nil;
          if JObj.TryGetValue<TJSONObject>('metadata', JMeta) then
          begin
            JMeta.TryGetValue<String>('command', Pkg.Command);
            JMeta.TryGetValue<String>('args',    Pkg.Args);
          end;

          if Pkg.Name <> '' then
            List.Add(Pkg);
        end;
      finally
        JResp.Free;
      end;
    except
      // Error de red: devolver lista vacía
    end;
    Result := List.ToArray;
  finally
    Http.Free;
    List.Free;
  end;
end;

function TAiToolRegistry.GetPPMPackage(const AName, AVersion: String): TAiPPMPackageInfo;
var
  Http  : TNetHTTPClient;
  Resp  : IHTTPResponse;
  JResp : TJSONObject;
  JMeta : TJSONObject;
  Url   : String;
begin
  Result := Default(TAiPPMPackageInfo);
  Http   := TNetHTTPClient.Create(nil);
  try
    Http.Accept := 'application/json';
    if AVersion = '' then
      Url := Format('%s/v1/packages/%s', [FPPMBase, AName])
    else
      Url := Format('%s/v1/packages/%s/%s', [FPPMBase, AName, AVersion]);
    try
      Resp := Http.Get(Url);
      if Resp.StatusCode <> 200 then Exit;

      JResp := TJSONObject(TJSONObject.ParseJSONValue(Resp.ContentAsString));
      if not Assigned(JResp) then Exit;
      try
        JResp.TryGetValue<String>('name',         Result.Name);
        JResp.TryGetValue<String>('version',      Result.Version);
        JResp.TryGetValue<String>('description',  Result.Description);
        JResp.TryGetValue<String>('download_url', Result.DownloadUrl);

        JMeta := nil;
        if JResp.TryGetValue<TJSONObject>('metadata', JMeta) then
        begin
          JMeta.TryGetValue<String>('command', Result.Command);
          JMeta.TryGetValue<String>('args',    Result.Args);
        end;
      finally
        JResp.Free;
      end;
    except
      // Error de red
    end;
  finally
    Http.Free;
  end;
end;

function TAiToolRegistry.InstallFromPPM(const APkg: TAiPPMPackageInfo;
  AOwner: TComponent): TMCPClientCustom;
var
  Client: TMCPClientStdIo;
begin
  Result := nil;
  if APkg.Name = '' then Exit;

  Client := TMCPClientStdIo.Create(AOwner);
  try
    Client.Name    := APkg.Name;
    Client.Enabled := True;

    if APkg.Command <> '' then
      Client.Params.Values['Command'] := APkg.Command
    else
      Client.Params.Values['Command'] := 'npx';

    if APkg.Args <> '' then
      Client.Params.Values['Arguments'] := APkg.Args
    else
      Client.Params.Values['Arguments'] := '-y ' + APkg.Name;

    if Client.Initialize then
    begin
      RegisterFromMCP(Client);
      Result := Client;
    end
    else
    begin
      if AOwner = nil then
        Client.Free;
    end;
  except
    if AOwner = nil then
      Client.Free;
    raise;
  end;
end;

initialization

finalization
  TAiToolRegistry.DropInstance;

end.

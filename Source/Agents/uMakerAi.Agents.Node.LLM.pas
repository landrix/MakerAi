// MIT License
// MakerAI - Sistema de Agentes v3.4
// TLLMNode: nodo de agente con loop ReAct integrado.
//
// TLLMNode extiende TAIAgentsNode añadiendo un modelo LLM con capacidad de
// llamar herramientas del TAiToolRegistry automáticamente. El loop LLM →
// Tool → Observación es manejado internamente por TAiChatConnection
// (function calling nativo de cada proveedor).
//
// Uso básico:
//   Node := TLLMNode.Create(Manager);
//   Node.DriverName   := 'Claude';
//   Node.Model        := 'claude-sonnet-4-5';
//   Node.ApiKey       := '@CLAUDE_API_KEY';
//   Node.SystemPrompt := 'Eres un asistente experto en...';
//   Node.UseAllTools  := True;   // inyecta todo el TAiToolRegistry.Instance
//
// Autor: Gustavo Enríquez
// GitHub: https://github.com/gustavoeenriquez/MakerAi

unit uMakerAi.Agents.Node.LLM;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  uMakerAi.Agents,
  uMakerAi.Agents.IAiTool,
  uMakerAi.Agents.ToolRegistry,
  uMakerAi.Chat.Messages,    // TAiToolsFunction
  uMakerAi.Tools.Functions;  // TAiFunctions, TFunctionActionItem, TFunctionEvent

type

  { TLLMNode -------------------------------------------------------------------
    Nodo de agente con LLM y herramientas del TAiToolRegistry integradas.

    El loop ReAct (Think → Call Tool → Observe → repeat) es transparente:
    TAiChatConnection lo maneja internamente vía function calling. TLLMNode
    sólo conecta el resultado de cada tool call al TAiToolRegistry.

    Propiedad Registry:
      - nil (default) → usa TAiToolRegistry.Instance (singleton global)
      - Asignar uno propio para aislar las herramientas de este nodo

    Ciclo de vida de los objetos internos:
      TAiChatConnection y TAiFunctions se crean y liberan en cada llamada a
      DoExecute para que no persista estado entre ejecuciones del nodo.
  }
  TLLMNode = class(TAIAgentsNode)
  private
    FDriverName    : String;
    FModel         : String;
    FApiKey        : String;
    FSystemPrompt  : String;
    FMaxTokens     : Integer;
    FUseAllTools   : Boolean;
    FRegistry      : TAiToolRegistry;

    // Estado temporal válido sólo durante DoExecute (un hilo a la vez por nodo)
    FActiveRegistry: TAiToolRegistry;

    procedure LoadRegistryTools(AFunctions: TAiFunctions);
    procedure HandleToolCall(Sender: TObject;
                             FunctionAction: TFunctionActionItem;
                             FunctionName: String;
                             ToolCall: TAiToolsFunction;
                             var Handled: Boolean);
  protected
    procedure DoExecute(aBeforeNode: TAIAgentsNode;
                        aLink: TAIAgentsLink); override;
  public
    constructor Create(aOwner: TComponent); override;

    // Referencia al registry a usar. nil = TAiToolRegistry.Instance.
    property Registry: TAiToolRegistry read FRegistry write FRegistry;
  published
    // Nombre del driver LLM: 'OpenAI', 'Claude', 'Gemini', 'Ollama', etc.
    property DriverName   : String  read FDriverName   write FDriverName;
    // Modelo específico del proveedor (vacío = usa el default del driver)
    property Model        : String  read FModel        write FModel;
    // API key. Soporta sintaxis @ENV_VAR_NAME para resolución en runtime.
    property ApiKey       : String  read FApiKey       write FApiKey;
    // Instrucción de sistema para el LLM
    property SystemPrompt : String  read FSystemPrompt write FSystemPrompt;
    // Máximo de tokens en la respuesta (0 = usa el default del driver)
    property MaxTokens    : Integer read FMaxTokens    write FMaxTokens default 0;
    // Si True, inyecta automáticamente todas las herramientas disponibles del registry
    property UseAllTools  : Boolean read FUseAllTools  write FUseAllTools default True;
  end;

implementation

uses
  uMakerAi.Chat.AiConnection;   // TAiChatConnection

{ TLLMNode }

constructor TLLMNode.Create(aOwner: TComponent);
begin
  inherited Create(aOwner);
  FDriverName    := 'Claude';
  FModel         := '';
  FApiKey        := '';
  FSystemPrompt  := '';
  FMaxTokens     := 0;
  FUseAllTools   := True;
  FRegistry      := nil;
  FActiveRegistry := nil;
end;

// ---------------------------------------------------------------------------
// Carga todas las herramientas del registry en el componente TAiFunctions.
// Cada IAiTool se convierte en un TFunctionActionItem usando SetJSon para
// transferir el nombre, descripción e inputSchema completo.
// ---------------------------------------------------------------------------
procedure TLLMNode.LoadRegistryTools(AFunctions: TAiFunctions);
var
  Tools     : TArray<IAiTool>;
  T         : IAiTool;
  Item      : TFunctionActionItem;
  Schema    : TJSONObject;
  JWrapper  : TJSONObject;
  JFunc     : TJSONObject;
begin
  if not Assigned(AFunctions) then Exit;
  if not Assigned(FActiveRegistry) then Exit;

  Tools := FActiveRegistry.GetAll;
  for T in Tools do
  begin
    // Construir el JSON que TFunctionActionItem.SetJSon espera:
    // { "type":"function", "function":{ "name":"...", "description":"...",
    //   "parameters":{...} } }
    JWrapper := TJSONObject.Create;
    try
      JWrapper.AddPair('type', 'function');
      JFunc := TJSONObject.Create;
      JFunc.AddPair('name', T.Name);
      JFunc.AddPair('description', T.Description);

      Schema := T.GetSchema;   // NO liberar — propiedad de la herramienta
      if Assigned(Schema) then
        JFunc.AddPair('parameters', TJSONObject(Schema.Clone))
      else
      begin
        var JEmptySchema: TJSONObject := TJSONObject.Create;
        JEmptySchema.AddPair('type', 'object');
        JEmptySchema.AddPair('properties', TJSONObject.Create);
        JFunc.AddPair('parameters', JEmptySchema);
      end;

      JWrapper.AddPair('function', JFunc);

      // Registrar en TAiFunctions con el handler unificado
      Item := AFunctions.Functions.AddFunction(T.Name, True, HandleToolCall);
      Item.SetJSon(JWrapper);
    finally
      JWrapper.Free;
    end;
  end;
end;

// ---------------------------------------------------------------------------
// Handler unificado para todas las tool calls del LLM.
// TAiChatConnection invoca este método cuando el modelo pide ejecutar
// una función. Buscamos la herramienta en el registry y ejecutamos.
// ---------------------------------------------------------------------------
procedure TLLMNode.HandleToolCall(Sender: TObject;
  FunctionAction: TFunctionActionItem; FunctionName: String;
  ToolCall: TAiToolsFunction; var Handled: Boolean);
var
  Tool      : IAiTool;
  ArgsJSON  : TJSONObject;
  ResultJSON: TJSONObject;
begin
  Handled := False;
  if not Assigned(FActiveRegistry) then Exit;

  if not FActiveRegistry.TryFind(FunctionName, Tool) then
  begin
    ToolCall.Response := Format('{"error":"Tool ''%s'' not found in registry"}', [FunctionName]);
    Handled := True;
    Exit;
  end;

  // Parsear argumentos
  ArgsJSON := nil;
  if ToolCall.Arguments <> '' then
  begin
    try
      ArgsJSON := TJSONObject(TJSONObject.ParseJSONValue(ToolCall.Arguments));
    except
      ArgsJSON := nil;
    end;
  end;

  ResultJSON := nil;
  try
    try
      ResultJSON := Tool.Execute(ArgsJSON);   // caller libera el resultado
      if Assigned(ResultJSON) then
        ToolCall.Response := ResultJSON.ToJSON
      else
        ToolCall.Response := '{"result":"ok"}';
    except
      on E: Exception do
        ToolCall.Response := Format('{"error":"%s"}', [E.Message]);
    end;
  finally
    ArgsJSON.Free;
    ResultJSON.Free;
  end;

  Handled := True;
end;

// ---------------------------------------------------------------------------
// Punto de entrada principal del nodo. Reemplaza el DoExecute genérico.
// Crea el chat, carga las herramientas y ejecuta el input del nodo.
// El loop ReAct es gestionado internamente por TAiChatConnection.
// ---------------------------------------------------------------------------
procedure TLLMNode.DoExecute(aBeforeNode: TAIAgentsNode;
  aLink: TAIAgentsLink);
var
  Chat      : TAiChatConnection;
  Functions : TAiFunctions;
  Response  : String;
begin
  // Determinar el registry activo para esta ejecución
  if Assigned(FRegistry) then
    FActiveRegistry := FRegistry
  else
    FActiveRegistry := TAiToolRegistry.Instance;

  Chat      := TAiChatConnection.Create(nil);
  Functions := TAiFunctions.Create(nil);
  try
    // Configurar el chat
    Chat.DriverName := FDriverName;
    if FModel <> '' then
      Chat.Model := FModel;
    // Parámetros vía TStrings (Asynchronous DEBE ser False en nodos de agente)
    Chat.Params.Values['Asynchronous'] := 'False';
    if FApiKey <> '' then
      Chat.Params.Values['ApiKey'] := FApiKey;
    if FMaxTokens > 0 then
      Chat.Params.Values['Max_tokens'] := IntToStr(FMaxTokens);
    if FSystemPrompt <> '' then
      Chat.SystemPrompt.Text := FSystemPrompt;

    // Cargar herramientas del registry en TAiFunctions
    if FUseAllTools and (FActiveRegistry.Count > 0) then
    begin
      LoadRegistryTools(Functions);
      Chat.AiFunctions := Functions;
    end;

    // Ejecutar el input del nodo (el loop de tools es automático)
    Response := Chat.AddMessageAndRun(Self.Input, 'user', []);
    Self.Output := Response;

    // Publicar en el Blackboard para que otros nodos puedan leerlo
    if Assigned(Self.Graph) and Assigned(Self.Graph.Blackboard) then
      Self.Graph.Blackboard.SetString(Self.Name + '.output', Response);

  finally
    // Desconectar el functions ANTES de liberar para evitar referencias colgantes
    Chat.AiFunctions := nil;
    Functions.Free;
    Chat.Free;
    FActiveRegistry := nil;
  end;
end;

end.

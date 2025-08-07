package lsp

import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:net"
import "core:os"
import "core:strings"
import "core:strconv"
import "../compiler"

// LSP Message Types
LSP_Message :: struct {
    jsonrpc: string,
    id:      Maybe(json.Value),
    method:  string,
    params:  json.Value,
}

LSP_Response :: struct {
    jsonrpc: string,
    id:      json.Value,
    result:  json.Value,
    error:   Maybe(LSP_Error),
}

LSP_Error :: struct {
    code:    int,
    message: string,
    data:    Maybe(json.Value),
}

LSP_Notification :: struct {
    jsonrpc: string,
    method:  string,
    params:  json.Value,
}

// LSP Types
Position :: struct {
    line:      int,
    character: int,
}

Range :: struct {
    start: Position,
    end:   Position,
}

Location :: struct {
    uri:   string,
    range: Range,
}

Diagnostic :: struct {
    range:    Range,
    severity: Maybe(int), // 1=Error, 2=Warning, 3=Information, 4=Hint
    code:     Maybe(string),
    source:   Maybe(string),
    message:  string,
}

TextDocumentIdentifier :: struct {
    uri: string,
}

VersionedTextDocumentIdentifier :: struct {
    uri:     string,
    version: int,
}

TextDocumentContentChangeEvent :: struct {
    range:       Maybe(Range),
    rangeLength: Maybe(int),
    text:        string,
}

// Server State
LSP_Server :: struct {
    documents: map[string]Document,
    cache:     ^compiler.Cache,
}

Document :: struct {
    uri:     string,
    version: int,
    content: string,
    ast:     ^compiler.Node,
    diagnostics: [dynamic]Diagnostic,
}

// Initialize the LSP server
init_lsp_server :: proc() -> ^LSP_Server {
    server := new(LSP_Server)
    server.documents = make(map[string]Document)
    server.cache = new(compiler.Cache)
    return server
}

// Main LSP server loop
run_lsp_server :: proc(server: ^LSP_Server) {
    for {
        message := read_message()
        if message == nil do break

        switch msg in message {
        case LSP_Message:
            handle_request(server, msg)
        case LSP_Notification:
            handle_notification(server, msg)
        }
    }
}

// Read LSP message from stdin
read_message :: proc() -> union{LSP_Message, LSP_Notification} {
    // Read Content-Length header
    content_length := 0
    for {
        line, ok := read_line()
        if !ok do return nil

        line = strings.trim_space(line)
        if line == "" do break // Empty line separates headers from content

        if strings.has_prefix(line, "Content-Length:") {
            length_str := strings.trim_space(line[15:])
            content_length = strconv.parse_int(length_str) or_else 0
        }
    }

    if content_length == 0 do return nil

    // Read the JSON content
    content_bytes := make([]byte, content_length)
    defer delete(content_bytes)

    total_read := 0
    for total_read < content_length {
        n, err := os.read(os.stdin, content_bytes[total_read:])
        if err != nil do return nil
        total_read += n
    }

    content := string(content_bytes)

    // Parse JSON
    json_data, json_err := json.parse_string(content)
    if json_err != nil do return nil
    defer json.destroy_value(json_data)

    obj := json_data.(json.Object) or_else return nil

    // Check if it's a request (has id) or notification
    if "id" in obj {
        msg := LSP_Message{}
        msg.jsonrpc = obj["jsonrpc"].(json.String) or_else "2.0"
        msg.id = obj["id"]
        msg.method = obj["method"].(json.String) or_else ""
        msg.params = obj["params"] or_else json.Null{}
        return msg
    } else {
        notif := LSP_Notification{}
        notif.jsonrpc = obj["jsonrpc"].(json.String) or_else "2.0"
        notif.method = obj["method"].(json.String) or_else ""
        notif.params = obj["params"] or_else json.Null{}
        return notif
    }
}

read_line :: proc() -> (string, bool) {
    builder := strings.builder_make()
    defer strings.builder_destroy(&builder)

    for {
        char_bytes := make([]byte, 1)
        defer delete(char_bytes)

        n, err := os.read(os.stdin, char_bytes)
        if err != nil || n == 0 do return "", false

        char := char_bytes[0]
        if char == '\n' do break
        if char != '\r' do strings.write_byte(&builder, char)
    }

    return strings.to_string(builder), true
}

// Handle LSP requests
handle_request :: proc(server: ^LSP_Server, msg: LSP_Message) {
    switch msg.method {
    case "initialize":
        handle_initialize(server, msg)
    case "textDocument/definition":
        handle_goto_definition(server, msg)
    case "textDocument/hover":
        handle_hover(server, msg)
    case "textDocument/completion":
        handle_completion(server, msg)
    case "textDocument/documentSymbol":
        handle_document_symbols(server, msg)
    case "shutdown":
        handle_shutdown(server, msg)
    case:
        send_error_response(msg.id, -32601, "Method not found")
    }
}

// Handle LSP notifications
handle_notification :: proc(server: ^LSP_Server, notif: LSP_Notification) {
    switch notif.method {
    case "initialized":
        // Client finished initialization
    case "textDocument/didOpen":
        handle_did_open(server, notif)
    case "textDocument/didChange":
        handle_did_change(server, notif)
    case "textDocument/didSave":
        handle_did_save(server, notif)
    case "textDocument/didClose":
        handle_did_close(server, notif)
    case "exit":
        os.exit(0)
    }
}

// Initialize response
handle_initialize :: proc(server: ^LSP_Server, msg: LSP_Message) {
    capabilities := json.Object{
        "textDocumentSync" = json.Integer(1), // Full sync
        "hoverProvider" = json.Boolean(true),
        "definitionProvider" = json.Boolean(true),
        "completionProvider" = json.Object{
            "triggerCharacters" = json.Array{json.String(".")},
        },
        "documentSymbolProvider" = json.Boolean(true),
    }

    result := json.Object{
        "capabilities" = capabilities,
        "serverInfo" = json.Object{
            "name" = json.String("Your Language Server"),
            "version" = json.String("0.1.0"),
        },
    }

    send_response(msg.id, result)
}

handle_shutdown :: proc(server: ^LSP_Server, msg: LSP_Message) {
    send_response(msg.id, json.Null{})
}

handle_did_open :: proc(server: ^LSP_Server, notif: LSP_Notification) {
    params := notif.params.(json.Object) or_else return
    text_doc := params["textDocument"].(json.Object) or_else return

    uri := text_doc["uri"].(json.String) or_else return
    version := int(text_doc["version"].(json.Integer) or_else 1)
    text := text_doc["text"].(json.String) or_else return

    doc := Document{
        uri = uri,
        version = version,
        content = text,
        diagnostics = make([dynamic]Diagnostic),
    }

    server.documents[uri] = doc
    analyze_document(server, uri)
}

handle_did_change :: proc(server: ^LSP_Server, notif: LSP_Notification) {
    params := notif.params.(json.Object) or_else return
    text_doc := params["textDocument"].(json.Object) or_else return
    changes := params["contentChanges"].(json.Array) or_else return

    uri := text_doc["uri"].(json.String) or_else return
    version := int(text_doc["version"].(json.Integer) or_else 1)

    if uri not_in server.documents do return

    doc := &server.documents[uri]
    doc.version = version

    // For full sync, just replace the entire content
    for change_val in changes {
        change := change_val.(json.Object) or_else continue
        if "range" not_in change {
            // Full document sync
            doc.content = change["text"].(json.String) or_else ""
        }
        // TODO: Implement incremental sync if needed
    }

    analyze_document(server, uri)
}

handle_did_save :: proc(server: ^LSP_Server, notif: LSP_Notification) {
    params := notif.params.(json.Object) or_else return
    text_doc := params["textDocument"].(json.Object) or_else return
    uri := text_doc["uri"].(json.String) or_else return

    analyze_document(server, uri)
}

handle_did_close :: proc(server: ^LSP_Server, notif: LSP_Notification) {
    params := notif.params.(json.Object) or_else return
    text_doc := params["textDocument"].(json.Object) or_else return
    uri := text_doc["uri"].(json.String) or_else return

    delete_key(&server.documents, uri)
}

// Analyze document and send diagnostics
analyze_document :: proc(server: ^LSP_Server, uri: string) {
    doc := &server.documents[uri]

    // Parse the document
    tokens := compiler.lex(doc.content)
    ast := compiler.parse(server.cache, tokens)
    doc.ast = ast

    // Run semantic analysis
    clear(&doc.diagnostics)

    if ast != nil {
        success := compiler.analyze(server.cache, ast)

        // Convert analyzer errors to LSP diagnostics
        if analyzer, ok := (^compiler.Analyzer)(context.user_ptr); ok {
            for error in analyzer.errors {
                diagnostic := Diagnostic{
                    range = Range{
                        start = Position{
                            line = error.position.line - 1, // LSP is 0-based
                            character = error.position.column - 1,
                        },
                        end = Position{
                            line = error.position.line - 1,
                            character = error.position.column,
                        },
                    },
                    severity = 1, // Error
                    source = "your-language-server",
                    message = error.message,
                }
                append(&doc.diagnostics, diagnostic)
            }

            for warning in analyzer.warnings {
                diagnostic := Diagnostic{
                    range = Range{
                        start = Position{
                            line = warning.position.line - 1,
                            character = warning.position.column - 1,
                        },
                        end = Position{
                            line = warning.position.line - 1,
                            character = warning.position.column,
                        },
                    },
                    severity = 2, // Warning
                    source = "your-language-server",
                    message = warning.message,
                }
                append(&doc.diagnostics, diagnostic)
            }
        }
    }

    // Send diagnostics to client
    send_diagnostics(uri, doc.diagnostics[:])
}

handle_hover :: proc(server: ^LSP_Server, msg: LSP_Message) {
    params := msg.params.(json.Object) or_else {
        send_error_response(msg.id, -32602, "Invalid params")
        return
    }

    text_doc := params["textDocument"].(json.Object) or_else {
        send_error_response(msg.id, -32602, "Invalid textDocument")
        return
    }

    position := params["position"].(json.Object) or_else {
        send_error_response(msg.id, -32602, "Invalid position")
        return
    }

    uri := text_doc["uri"].(json.String) or_else {
        send_error_response(msg.id, -32602, "Invalid URI")
        return
    }

    line := int(position["line"].(json.Integer) or_else -1)
    character := int(position["character"].(json.Integer) or_else -1)

    if uri not_in server.documents {
        send_response(msg.id, json.Null{})
        return
    }

    doc := &server.documents[uri]

    // TODO: Implement hover information based on your AST
    // For now, return empty hover
    send_response(msg.id, json.Null{})
}

handle_goto_definition :: proc(server: ^LSP_Server, msg: LSP_Message) {
    // TODO: Implement go-to-definition
    send_response(msg.id, json.Null{})
}

handle_completion :: proc(server: ^LSP_Server, msg: LSP_Message) {
    // TODO: Implement completion
    result := json.Object{
        "isIncomplete" = json.Boolean(false),
        "items" = json.Array{},
    }
    send_response(msg.id, result)
}

handle_document_symbols :: proc(server: ^LSP_Server, msg: LSP_Message) {
    // TODO: Implement document symbols
    send_response(msg.id, json.Array{})
}

// Utility functions for sending responses
send_response :: proc(id: Maybe(json.Value), result: json.Value) {
    if id == nil do return

    response := LSP_Response{
        jsonrpc = "2.0",
        id = id.?,
        result = result,
    }

    json_data, err := json.marshal(response)
    if err != nil do return
    defer delete(json_data)

    content := string(json_data)
    header := fmt.tprintf("Content-Length: %d\r\n\r\n", len(content))

    os.write_string(os.stdout, header)
    os.write_string(os.stdout, content)
}

send_error_response :: proc(id: Maybe(json.Value), code: int, message: string) {
    if id == nil do return

    response := LSP_Response{
        jsonrpc = "2.0",
        id = id.?,
        result = json.Null{},
        error = LSP_Error{
            code = code,
            message = message,
        },
    }

    json_data, err := json.marshal(response)
    if err != nil do return
    defer delete(json_data)

    content := string(json_data)
    header := fmt.tprintf("Content-Length: %d\r\n\r\n", len(content))

    os.write_string(os.stdout, header)
    os.write_string(os.stdout, content)
}

send_notification :: proc(method: string, params: json.Value) {
    notif := LSP_Notification{
        jsonrpc = "2.0",
        method = method,
        params = params,
    }

    json_data, err := json.marshal(notif)
    if err != nil do return
    defer delete(json_data)

    content := string(json_data)
    header := fmt.tprintf("Content-Length: %d\r\n\r\n", len(content))

    os.write_string(os.stdout, header)
    os.write_string(os.stdout, content)
}

send_diagnostics :: proc(uri: string, diagnostics: []Diagnostic) {
    diag_array := make(json.Array, len(diagnostics))
    defer delete(diag_array)

    for diag, i in diagnostics {
        diag_obj := json.Object{
            "range" = json.Object{
                "start" = json.Object{
                    "line" = json.Integer(diag.range.start.line),
                    "character" = json.Integer(diag.range.start.character),
                },
                "end" = json.Object{
                    "line" = json.Integer(diag.range.end.line),
                    "character" = json.Integer(diag.range.end.character),
                },
            },
            "message" = json.String(diag.message),
            "source" = json.String(diag.source.? or_else ""),
        }

        if diag.severity != nil {
            diag_obj["severity"] = json.Integer(diag.severity.?)
        }

        diag_array[i] = diag_obj
    }

    params := json.Object{
        "uri" = json.String(uri),
        "diagnostics" = diag_array,
    }

    send_notification("textDocument/publishDiagnostics", params)
}

main :: proc() {
    server := init_lsp_server()
    run_lsp_server(server)
}

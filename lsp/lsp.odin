package lsp

import "../compiler"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"

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
	uri:         string,
	version:     int,
	content:     string,
	ast:         ^compiler.Node,
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
read_message :: proc() -> union {
		LSP_Message,
		LSP_Notification,
	} {
	// Read Content-Length header
	content_length := 0
	for {
		line, ok := read_line()
		if !ok do return nil

		line = strings.trim_space(line)
		if line == "" do break // Empty line separates headers from content

		if strings.has_prefix(line, "Content-Length:") {
			length_str := strings.trim_space(line[15:])
			if parsed_length, parse_ok := strconv.parse_int(length_str); parse_ok {
				content_length = parsed_length
			}
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

	obj, obj_ok := json_data.(json.Object)
	if !obj_ok do return nil

	// Check if it's a request (has id) or notification
	if "id" in obj {
		msg := LSP_Message{}
		if jsonrpc, ok := obj["jsonrpc"].(json.String); ok {
			msg.jsonrpc = jsonrpc
		} else {
			msg.jsonrpc = "2.0"
		}
		msg.id = obj["id"]
		if method, ok := obj["method"].(json.String); ok {
			msg.method = method
		}
		if params, ok := obj["params"]; ok {
			msg.params = params
		} else {
			msg.params = json.Null{}
		}
		return msg
	} else {
		notif := LSP_Notification{}
		if jsonrpc, ok := obj["jsonrpc"].(json.String); ok {
			notif.jsonrpc = jsonrpc
		} else {
			notif.jsonrpc = "2.0"
		}
		if method, ok := obj["method"].(json.String); ok {
			notif.method = method
		}
		if params, ok := obj["params"]; ok {
			notif.params = params
		} else {
			notif.params = json.Null{}
		}
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
	// Create trigger characters array
	trigger_chars := make([dynamic]json.Value)
	append(&trigger_chars, json.String("."))

	// Create completion provider object
	completion_provider := make(map[string]json.Value)
	completion_provider["triggerCharacters"] = json.Array(trigger_chars)

	// Create capabilities object
	capabilities := make(map[string]json.Value)
	capabilities["textDocumentSync"] = json.Integer(1) // Full sync
	capabilities["hoverProvider"] = json.Boolean(true)
	capabilities["definitionProvider"] = json.Boolean(true)
	capabilities["completionProvider"] = json.Object(completion_provider)
	capabilities["documentSymbolProvider"] = json.Boolean(true)

	// Create server info object
	server_info := make(map[string]json.Value)
	server_info["name"] = json.String("Your Language Server")
	server_info["version"] = json.String("0.1.0")

	// Create result object
	result := make(map[string]json.Value)
	result["capabilities"] = json.Object(capabilities)
	result["serverInfo"] = json.Object(server_info)

	send_response(msg.id, json.Object(result))
}

handle_shutdown :: proc(server: ^LSP_Server, msg: LSP_Message) {
	send_response(msg.id, json.Null{})
}

handle_did_open :: proc(server: ^LSP_Server, notif: LSP_Notification) {
	params, params_ok := notif.params.(json.Object)
	if !params_ok do return

	text_doc, text_doc_ok := params["textDocument"].(json.Object)
	if !text_doc_ok do return

	uri, uri_ok := text_doc["uri"].(json.String)
	if !uri_ok do return

	version := 1
	if version_val, ok := text_doc["version"].(json.Integer); ok {
		version = int(version_val)
	}

	text, text_ok := text_doc["text"].(json.String)
	if !text_ok do return

	doc := Document {
		uri         = uri,
		version     = version,
		content     = text,
		diagnostics = make([dynamic]Diagnostic),
	}

	server.documents[uri] = doc
	analyze_document(server, uri)
}

handle_did_change :: proc(server: ^LSP_Server, notif: LSP_Notification) {
	params, params_ok := notif.params.(json.Object)
	if !params_ok do return

	text_doc, text_doc_ok := params["textDocument"].(json.Object)
	if !text_doc_ok do return

	changes, changes_ok := params["contentChanges"].(json.Array)
	if !changes_ok do return

	uri, uri_ok := text_doc["uri"].(json.String)
	if !uri_ok do return

	version := 1
	if version_val, ok := text_doc["version"].(json.Integer); ok {
		version = int(version_val)
	}

	if uri not_in server.documents do return

	doc := &server.documents[uri]
	doc.version = version

	// For full sync, just replace the entire content
	for change_val in changes {
		change, change_ok := change_val.(json.Object)
		if !change_ok do continue

		if "range" not_in change {
			// Full document sync
			if text, ok := change["text"].(json.String); ok {
				doc.content = text
			}
		}
		// TODO: Implement incremental sync if needed
	}

	analyze_document(server, uri)
}

handle_did_save :: proc(server: ^LSP_Server, notif: LSP_Notification) {
	params, params_ok := notif.params.(json.Object)
	if !params_ok do return

	text_doc, text_doc_ok := params["textDocument"].(json.Object)
	if !text_doc_ok do return

	uri, uri_ok := text_doc["uri"].(json.String)
	if !uri_ok do return

	analyze_document(server, uri)
}

handle_did_close :: proc(server: ^LSP_Server, notif: LSP_Notification) {
	params, params_ok := notif.params.(json.Object)
	if !params_ok do return

	text_doc, text_doc_ok := params["textDocument"].(json.Object)
	if !text_doc_ok do return

	uri, uri_ok := text_doc["uri"].(json.String)
	if !uri_ok do return

	delete_key(&server.documents, uri)
}

// Analyze document and send diagnostics
analyze_document :: proc(server: ^LSP_Server, uri: string) {
	doc := &server.documents[uri]

	// Analyze document and send diagnostics
	analyze_document :: proc(server: ^LSP_Server, uri: string) {
		doc := &server.documents[uri]

		// Parse the document using your compiler
		ast := compiler.parse(server.cache, doc.content)
		doc.ast = ast

		// Run semantic analysis
		clear(&doc.diagnostics)

		if ast != nil {
			_ = compiler.analyze(server.cache, ast)

			// Convert compiler errors to LSP diagnostics
			// Access the analyzer that was used during analysis
			// Note: You'll need to expose the analyzer errors somehow from your compiler module
			// For now, I'll show the structure but you'll need to adapt based on how
			// your compiler exposes the error information

			// TODO: Add access to analyzer errors from compiler module
			// This is a placeholder - you'll need to modify your compiler to expose
			// the analyzer state or return errors in a way the LSP can access

			// Example of what the integration might look like:
			/*
        if errors := compiler.get_analyzer_errors(server.cache); errors != nil {
            for error in errors {
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
        }
        */
		}

		// Send diagnostics to client
		send_diagnostics(uri, doc.diagnostics[:])
	}

	// Send diagnostics to client
	send_diagnostics(uri, doc.diagnostics[:])
}

handle_hover :: proc(server: ^LSP_Server, msg: LSP_Message) {
	params, params_ok := msg.params.(json.Object)
	if !params_ok {
		send_error_response(msg.id, -32602, "Invalid params")
		return
	}

	text_doc, text_doc_ok := params["textDocument"].(json.Object)
	if !text_doc_ok {
		send_error_response(msg.id, -32602, "Invalid textDocument")
		return
	}

	position, position_ok := params["position"].(json.Object)
	if !position_ok {
		send_error_response(msg.id, -32602, "Invalid position")
		return
	}

	uri, uri_ok := text_doc["uri"].(json.String)
	if !uri_ok {
		send_error_response(msg.id, -32602, "Invalid URI")
		return
	}

	line := -1
	if line_val, ok := position["line"].(json.Integer); ok {
		line = int(line_val)
	}

	character := -1
	if char_val, ok := position["character"].(json.Integer); ok {
		character = int(char_val)
	}

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
	items := make([dynamic]json.Value)
	result := make(map[string]json.Value)
	result["isIncomplete"] = json.Boolean(false)
	result["items"] = json.Array(items)
	send_response(msg.id, json.Object(result))
}

handle_document_symbols :: proc(server: ^LSP_Server, msg: LSP_Message) {
	// TODO: Implement document symbols
	symbols := make([dynamic]json.Value)
	send_response(msg.id, json.Array(symbols))
}

// Utility functions for sending responses
send_response :: proc(id: Maybe(json.Value), result: json.Value) {
	if id == nil do return

	response := LSP_Response {
		jsonrpc = "2.0",
		id      = id.?,
		result  = result,
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

	response := LSP_Response {
		jsonrpc = "2.0",
		id = id.?,
		result = json.Null{},
		error = LSP_Error{code = code, message = message},
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
	notif := LSP_Notification {
		jsonrpc = "2.0",
		method  = method,
		params  = params,
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
	diag_array := make([dynamic]json.Value)
	defer delete(diag_array)

	for diag in diagnostics {
		start_pos := make(map[string]json.Value)
		start_pos["line"] = json.Integer(diag.range.start.line)
		start_pos["character"] = json.Integer(diag.range.start.character)

		end_pos := make(map[string]json.Value)
		end_pos["line"] = json.Integer(diag.range.end.line)
		end_pos["character"] = json.Integer(diag.range.end.character)

		range_obj := make(map[string]json.Value)
		range_obj["start"] = json.Object(start_pos)
		range_obj["end"] = json.Object(end_pos)

		diag_obj := make(map[string]json.Value)
		diag_obj["range"] = json.Object(range_obj)
		diag_obj["message"] = json.String(diag.message)

		if diag.source != nil {
			diag_obj["source"] = json.String(diag.source.?)
		}

		if diag.severity != nil {
			diag_obj["severity"] = json.Integer(diag.severity.?)
		}

		append(&diag_array, json.Object(diag_obj))
	}

	params := make(map[string]json.Value)
	params["uri"] = json.String(uri)
	params["diagnostics"] = json.Array(diag_array)

	send_notification("textDocument/publishDiagnostics", json.Object(params))
}

main :: proc() {
	server := init_lsp_server()
	run_lsp_server(server)
}

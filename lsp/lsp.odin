package lsp

import "../compiler"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

/* ======================================================================
 * SECTION 1: LSP PROTOCOL TYPES
 * ====================================================================== */

LSP_Message :: struct {
	jsonrpc: string,
	id:      Maybe(json.Value),
	method:  string,
	params:  json.Value,
}

LSP_Notification :: struct {
	jsonrpc: string,
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
}

/* ======================================================================
 * SECTION 2: LSP DATA TYPES
 * ====================================================================== */

Position :: struct {
	line:      int,
	character: int,
}

Range :: struct {
	start: Position,
	end:   Position,
}

Diagnostic :: struct {
	range:    Range,
	severity: int,
	source:   string,
	message:  string,
}

/* ======================================================================
 * SECTION 3: SEMANTIC TOKEN TYPES
 * ====================================================================== */

Sem_Token_Type :: enum {
	Namespace, // 0
	Type, // 1
	Class, // 2
	Enum, // 3
	Interface, // 4
	Struct, // 5
	TypeParameter, // 6
	Parameter, // 7
	Variable, // 8
	Property, // 9
	EnumMember, // 10
	Event, // 11
	Function, // 12
	Method, // 13
	Macro, // 14
	Keyword, // 15
	Modifier, // 16
	Comment, // 17
	String, // 18
	Number, // 19
	Regexp, // 20
	Operator, // 21
	Decorator, // 22
}

SEMANTIC_TOKEN_TYPES :: [?]string {
	"namespace",
	"type",
	"class",
	"enum",
	"interface",
	"struct",
	"typeParameter",
	"parameter",
	"variable",
	"property",
	"enumMember",
	"event",
	"function",
	"method",
	"macro",
	"keyword",
	"modifier",
	"comment",
	"string",
	"number",
	"regexp",
	"operator",
	"decorator",
}

SEMANTIC_TOKEN_MODIFIERS :: [?]string{"declaration", "definition", "readonly", "static"}

Raw_Sem_Token :: struct {
	line:       int,
	start_char: int,
	length:     int,
	type:       int,
	modifiers:  int,
}

/* ======================================================================
 * SECTION 4: SERVER STATE
 * ====================================================================== */

LSP_Server :: struct {
	documents: map[string]Document,
}

Document :: struct {
	uri:      string,
	version:  int,
	content:  string,
	ast:      ^compiler.Ast,
	semantic: ^compiler.Semantic,
}

/* ======================================================================
 * SECTION 5: TRANSPORT (JSON-RPC OVER STDIN/STDOUT)
 * ====================================================================== */

read_line :: proc() -> (string, bool) {
	buf: [4096]u8
	pos := 0
	for {
		n, err := os.read(os.stdin, buf[pos:pos + 1])
		if err != nil || n == 0 do return "", false
		if buf[pos] == '\n' {
			end := pos
			if end > 0 && buf[end - 1] == '\r' do end -= 1
			return strings.clone_from_bytes(buf[:end]), true
		}
		pos += 1
		if pos >= len(buf) do return "", false
	}
}

read_message :: proc() -> union {
		LSP_Message,
		LSP_Notification,
	} {
	content_length := 0
	for {
		line, ok := read_line()
		if !ok do return nil
		defer delete(line)

		trimmed := strings.trim_space(line)
		if trimmed == "" do break

		if strings.has_prefix(trimmed, "Content-Length:") {
			length_str := strings.trim_space(trimmed[15:])
			if parsed, parse_ok := strconv.parse_int(length_str); parse_ok {
				content_length = parsed
			}
		}
	}

	if content_length == 0 do return nil

	content_bytes := make([]byte, content_length)

	total_read := 0
	for total_read < content_length {
		n, err := os.read(os.stdin, content_bytes[total_read:])
		if err != nil do return nil
		total_read += n
	}

	content_str := strings.clone_from_bytes(content_bytes)

	json_data, json_err := json.parse_string(content_str)
	if json_err != nil {
		delete(content_str)
		return nil
	}

	obj, obj_ok := json_data.(json.Object)
	if !obj_ok {
		json.destroy_value(json_data)
		delete(content_str)
		return nil
	}

	if "id" in obj {
		msg := LSP_Message {
			jsonrpc = "2.0",
		}
		msg.id = obj["id"]
		if method, ok := obj["method"].(json.String); ok {
			msg.method = strings.clone(method)
		}
		msg.params = obj["params"] or_else json.Null{}
		return msg
	} else {
		notif := LSP_Notification {
			jsonrpc = "2.0",
		}
		if method, ok := obj["method"].(json.String); ok {
			notif.method = strings.clone(method)
		}
		notif.params = obj["params"] or_else json.Null{}
		return notif
	}
}

json_to_int :: proc(v: json.Value) -> int {
	#partial switch val in v {
	case json.Integer: return int(val)
	case json.Float:   return int(val)
	}
	return 0
}

send_raw :: proc(content: string) {
	header := fmt.tprintf("Content-Length: %d\r\n\r\n", len(content))
	os.write_string(os.stdout, header)
	os.write_string(os.stdout, content)
}

json_value_to_string :: proc(b: ^strings.Builder, v: json.Value) {
	switch val in v {
	case json.Null:
		strings.write_string(b, "null")
	case json.Boolean:
		strings.write_string(b, val ? "true" : "false")
	case json.Integer:
		fmt.sbprintf(b, "%d", val)
	case json.Float:
		fmt.sbprintf(b, "%v", val)
	case json.String:
		write_json_string(b, val)
	case json.Array:
		strings.write_byte(b, '[')
		for elem, i in val {
			if i > 0 do strings.write_byte(b, ',')
			json_value_to_string(b, elem)
		}
		strings.write_byte(b, ']')
	case json.Object:
		strings.write_byte(b, '{')
		first := true
		for key, value in val {
			if !first do strings.write_byte(b, ',')
			first = false
			write_json_string(b, key)
			strings.write_byte(b, ':')
			json_value_to_string(b, value)
		}
		strings.write_byte(b, '}')
	}
}

write_json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for c in s {
		switch c {
		case '"':
			strings.write_string(b, "\\\"")
		case '\\':
			strings.write_string(b, "\\\\")
		case '\n':
			strings.write_string(b, "\\n")
		case '\r':
			strings.write_string(b, "\\r")
		case '\t':
			strings.write_string(b, "\\t")
		case:
			strings.write_rune(b, c)
		}
	}
	strings.write_byte(b, '"')
}

send_response :: proc(id: Maybe(json.Value), result: json.Value) {
	if id == nil do return
	b := strings.builder_make(0, 1024)
	defer strings.builder_destroy(&b)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":`)
	json_value_to_string(&b, id.?)
	strings.write_string(&b, `,"result":`)
	json_value_to_string(&b, result)
	strings.write_byte(&b, '}')
	send_raw(strings.to_string(b))
}

send_error_response :: proc(id: Maybe(json.Value), code: int, message: string) {
	if id == nil do return
	b := strings.builder_make(0, 256)
	defer strings.builder_destroy(&b)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":`)
	json_value_to_string(&b, id.?)
	fmt.sbprintf(&b, `,"error":{{"code":%d,"message":`, code)
	write_json_string(&b, message)
	strings.write_string(&b, `},"result":null}`)
	send_raw(strings.to_string(b))
}

send_notification :: proc(method: string, params: json.Value) {
	b := strings.builder_make(0, 1024)
	defer strings.builder_destroy(&b)
	strings.write_string(&b, `{"jsonrpc":"2.0","method":`)
	write_json_string(&b, method)
	strings.write_string(&b, `,"params":`)
	json_value_to_string(&b, params)
	strings.write_byte(&b, '}')
	send_raw(strings.to_string(b))
}

/* ======================================================================
 * SECTION 6: MAIN LOOP AND DISPATCH
 * ====================================================================== */

main :: proc() {
	server := LSP_Server {
		documents = make(map[string]Document),
	}
	for {
		message := read_message()
		if message == nil do break

		switch msg in message {
		case LSP_Message:
			handle_request(&server, msg)
		case LSP_Notification:
			handle_notification(&server, msg)
		}
	}
}

handle_request :: proc(server: ^LSP_Server, msg: LSP_Message) {
	switch msg.method {
	case "initialize":
		handle_initialize(server, msg)
	case "shutdown":
		send_response(msg.id, json.Null{})
	case "textDocument/semanticTokens/full":
		handle_semantic_tokens(server, msg)
	case "textDocument/hover":
		send_response(msg.id, json.Null{})
	case "textDocument/definition":
		handle_definition(server, msg)
	case "textDocument/references":
		handle_references(server, msg)
	case "textDocument/rename":
		handle_rename(server, msg)
	case "textDocument/prepareRename":
		handle_prepare_rename(server, msg)
	case "textDocument/completion":
		result := make(map[string]json.Value)
		result["isIncomplete"] = json.Boolean(false)
		result["items"] = json.Array(make([dynamic]json.Value))
		send_response(msg.id, json.Object(result))
	case:
		send_error_response(msg.id, -32601, "Method not found")
	}
}

handle_notification :: proc(server: ^LSP_Server, notif: LSP_Notification) {
	switch notif.method {
	case "initialized":
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

/* ======================================================================
 * SECTION 7: INITIALIZE
 * ====================================================================== */

handle_initialize :: proc(server: ^LSP_Server, msg: LSP_Message) {
	token_types := make([dynamic]json.Value)
	for t in SEMANTIC_TOKEN_TYPES {
		append(&token_types, json.String(t))
	}

	token_modifiers := make([dynamic]json.Value)
	for m in SEMANTIC_TOKEN_MODIFIERS {
		append(&token_modifiers, json.String(m))
	}

	legend := make(map[string]json.Value)
	legend["tokenTypes"] = json.Array(token_types)
	legend["tokenModifiers"] = json.Array(token_modifiers)

	sem_tokens_provider := make(map[string]json.Value)
	sem_tokens_provider["full"] = json.Boolean(true)
	sem_tokens_provider["legend"] = json.Object(legend)

	text_doc_sync := make(map[string]json.Value)
	text_doc_sync["openClose"] = json.Boolean(true)
	text_doc_sync["change"] = json.Integer(1) // Full sync

	capabilities := make(map[string]json.Value)
	capabilities["textDocumentSync"] = json.Object(text_doc_sync)
	capabilities["semanticTokensProvider"] = json.Object(sem_tokens_provider)
	capabilities["definitionProvider"] = json.Boolean(true)
	capabilities["referencesProvider"] = json.Boolean(true)
	capabilities["renameProvider"] = json.Boolean(true)

	server_info := make(map[string]json.Value)
	server_info["name"] = json.String("syn-lsp")
	server_info["version"] = json.String("0.2.0")

	result := make(map[string]json.Value)
	result["capabilities"] = json.Object(capabilities)
	result["serverInfo"] = json.Object(server_info)

	send_response(msg.id, json.Object(result))
}

/* ======================================================================
 * SECTION 8: DOCUMENT LIFECYCLE
 * ====================================================================== */

get_text_doc_uri :: proc(params: json.Value) -> (string, bool) {
	obj, ok := params.(json.Object)
	if !ok do return "", false
	td, td_ok := obj["textDocument"].(json.Object)
	if !td_ok do return "", false
	uri, uri_ok := td["uri"].(json.String)
	return uri, uri_ok
}

handle_did_open :: proc(server: ^LSP_Server, notif: LSP_Notification) {
	params, ok := notif.params.(json.Object)
	if !ok do return

	td, td_ok := params["textDocument"].(json.Object)
	if !td_ok do return

	uri, uri_ok := td["uri"].(json.String)
	if !uri_ok do return

	text, text_ok := td["text"].(json.String)
	if !text_ok do return

	version := 0
	version = json_to_int(td["version"])

	server.documents[uri] = Document {
		uri     = uri,
		version = version,
		content = text,
	}
	analyze_and_publish(server, uri)
}

handle_did_change :: proc(server: ^LSP_Server, notif: LSP_Notification) {
	params, ok := notif.params.(json.Object)
	if !ok do return

	td, td_ok := params["textDocument"].(json.Object)
	if !td_ok do return

	uri, uri_ok := td["uri"].(json.String)
	if !uri_ok do return

	if uri not_in server.documents do return

	changes, ch_ok := params["contentChanges"].(json.Array)
	if !ch_ok do return

	doc := &server.documents[uri]
	if v, v_ok := td["version"].(json.Integer); v_ok {
		doc.version = int(v)
	}

	for change_val in changes {
		change, c_ok := change_val.(json.Object)
		if !c_ok do continue
		if "range" not_in change {
			if text, t_ok := change["text"].(json.String); t_ok {
				doc.content = text
			}
		}
	}

	analyze_and_publish(server, uri)
}

handle_did_save :: proc(server: ^LSP_Server, notif: LSP_Notification) {
	uri, ok := get_text_doc_uri(notif.params)
	if !ok do return
	analyze_and_publish(server, uri)
}

handle_did_close :: proc(server: ^LSP_Server, notif: LSP_Notification) {
	uri, ok := get_text_doc_uri(notif.params)
	if !ok do return
	delete_key(&server.documents, uri)
	publish_diagnostics(uri, nil)
}

/* ======================================================================
 * SECTION 9: ANALYSIS AND DIAGNOSTICS
 * ====================================================================== */

analyze_and_publish :: proc(server: ^LSP_Server, uri: string) {
	if uri not_in server.documents do return
	doc := &server.documents[uri]

	cache := compiler.Cache{}

	ast, parse_ok := compiler.parse(&cache, doc.content)
	doc.ast = ast
	doc.semantic = nil

	diagnostics := make([dynamic]Diagnostic, 0, len(cache.parse_errors) + 16)
	defer delete(diagnostics)

	for err in cache.parse_errors {
		start_pos := compiler.span_to_position(ast, err.span.start)
		end_pos := compiler.span_to_position(ast, err.span.end)
		append(
			&diagnostics,
			Diagnostic {
				range = Range {
					start = Position{line = start_pos.line - 1, character = start_pos.column - 1},
					end = Position{line = end_pos.line - 1, character = end_pos.column - 1},
				},
				severity = 1,
				source = "syn-parse",
				message = err.message,
			},
		)
	}

	if ast != nil && parse_ok {
		compiler.analyze(&cache, ast)
		doc.semantic = cache.semantic

		for err in cache.analyze_errors {
			append(
				&diagnostics,
				Diagnostic {
					range = Range {
						start = Position {
							line = err.position.line - 1,
							character = err.position.column - 1,
						},
						end = Position {
							line = err.position.line - 1,
							character = err.position.column - 1,
						},
					},
					severity = 1,
					source = "syn-analyze",
					message = err.message,
				},
			)
		}

		for warn in cache.analyze_warnings {
			append(
				&diagnostics,
				Diagnostic {
					range = Range {
						start = Position {
							line = warn.position.line - 1,
							character = warn.position.column - 1,
						},
						end = Position {
							line = warn.position.line - 1,
							character = warn.position.column - 1,
						},
					},
					severity = 2,
					source = "syn-analyze",
					message = warn.message,
				},
			)
		}
	}

	publish_diagnostics(uri, diagnostics[:])
}

publish_diagnostics :: proc(uri: string, diagnostics: []Diagnostic) {
	diag_array := make([dynamic]json.Value)

	if diagnostics != nil {
		for d in diagnostics {
			start_pos := make(map[string]json.Value)
			start_pos["line"] = json.Integer(d.range.start.line)
			start_pos["character"] = json.Integer(d.range.start.character)

			end_pos := make(map[string]json.Value)
			end_pos["line"] = json.Integer(d.range.end.line)
			end_pos["character"] = json.Integer(d.range.end.character)

			range_obj := make(map[string]json.Value)
			range_obj["start"] = json.Object(start_pos)
			range_obj["end"] = json.Object(end_pos)

			diag_obj := make(map[string]json.Value)
			diag_obj["range"] = json.Object(range_obj)
			diag_obj["message"] = json.String(d.message)
			diag_obj["severity"] = json.Integer(d.severity)
			diag_obj["source"] = json.String(d.source)

			append(&diag_array, json.Object(diag_obj))
		}
	}

	params := make(map[string]json.Value)
	params["uri"] = json.String(uri)
	params["diagnostics"] = json.Array(diag_array)

	send_notification("textDocument/publishDiagnostics", json.Object(params))
}

/* ======================================================================
 * SECTION 10: GO TO DEFINITION
 * ====================================================================== */

handle_definition :: proc(server: ^LSP_Server, msg: LSP_Message) {
	uri, bid, _, doc, ok := resolve_binding_at(server, msg.params)
	if !ok {
		send_response(msg.id, json.Null{})
		return
	}

	ast := doc.ast
	sem := doc.semantic
	entry := &sem.bindings[bid]
	def_span := entry.name
	if def_span.start == def_span.end && entry.node != compiler.INVALID_NODE {
		def_span = ast.node_spans[entry.node]
	}
	if def_span.start == def_span.end {
		send_response(msg.id, json.Null{})
		return
	}

	def_start := compiler.span_to_position(ast, def_span.start)
	def_end := compiler.span_to_position(ast, def_span.end)
	send_response(msg.id, make_location(uri, def_start, def_end))
}

resolve_binding_at :: proc(
	server: ^LSP_Server,
	params: json.Value,
) -> (
	uri: string,
	bid: compiler.Binding_Id,
	node: compiler.Node_Index,
	doc: ^Document,
	ok: bool,
) {
	p, p_ok := params.(json.Object)
	if !p_ok do return

	u, u_ok := get_text_doc_uri(params)
	if !u_ok || u not_in server.documents do return

	pos_obj, pos_ok := p["position"].(json.Object)
	if !pos_ok do return

	line := json_to_int(pos_obj["line"])
	char := json_to_int(pos_obj["character"])

	d := &server.documents[u]
	ast := d.ast
	sem := d.semantic
	if ast == nil || sem == nil do return

	compiler.ensure_line_starts(ast)
	offset := lsp_pos_to_offset(ast, line, char)
	if offset < 0 do return

	target := find_node_at_offset(ast, u32(offset))
	if target == compiler.INVALID_NODE do return
	if ast.node_kinds[target] != .Identifier do return

	b := sem.node_sems[target].ref_binding
	if b == compiler.INVALID_BINDING {
		name_span := compiler.node_name_span(ast, target)
		if name_span.start == name_span.end do name_span = ast.node_spans[target]
		for i := 0; i < len(sem.bindings); i += 1 {
			entry := &sem.bindings[i]
			if entry.name.start == name_span.start && entry.name.end == name_span.end {
				b = compiler.Binding_Id(i)
				break
			}
		}
		if b == compiler.INVALID_BINDING do return
	}

	return u, b, target, d, true
}

find_all_ref_locations :: proc(
	uri: string,
	doc: ^Document,
	bid: compiler.Binding_Id,
	include_decl: bool,
) -> [dynamic]json.Value {
	ast := doc.ast
	sem := doc.semantic
	locations := make([dynamic]json.Value, 0, 16)

	if include_decl {
		entry := &sem.bindings[bid]
		decl_span := entry.name
		if decl_span.start != decl_span.end {
			ds := compiler.span_to_position(ast, decl_span.start)
			de := compiler.span_to_position(ast, decl_span.end)
			append(&locations, make_location(uri, ds, de))
		}
	}

	for i := 0; i < len(sem.node_sems); i += 1 {
		ns := &sem.node_sems[i]
		if ns.ref_binding != bid do continue
		if ast.node_kinds[i] != .Identifier do continue

		idx := compiler.Node_Index(i)
		span := compiler.node_name_span(ast, idx)
		if span.start == span.end do span = ast.node_spans[i]
		if span.start == span.end do continue

		s := compiler.span_to_position(ast, span.start)
		e := compiler.span_to_position(ast, span.end)
		append(&locations, make_location(uri, s, e))
	}

	return locations
}

/* ======================================================================
 * SECTION 10b: FIND ALL REFERENCES
 * ====================================================================== */

handle_references :: proc(server: ^LSP_Server, msg: LSP_Message) {
	uri, bid, _, doc, ok := resolve_binding_at(server, msg.params)
	if !ok {
		send_response(msg.id, json.Null{})
		return
	}

	include_decl := false
	if p, p_ok := msg.params.(json.Object); p_ok {
		if ctx, c_ok := p["context"].(json.Object); c_ok {
			if id, id_ok := ctx["includeDeclaration"].(json.Boolean); id_ok {
				include_decl = bool(id)
			}
		}
	}

	locations := find_all_ref_locations(uri, doc, bid, include_decl)
	send_response(msg.id, json.Array(locations))
}

/* ======================================================================
 * SECTION 10c: RENAME
 * ====================================================================== */

handle_prepare_rename :: proc(server: ^LSP_Server, msg: LSP_Message) {
	_, _, node, doc, ok := resolve_binding_at(server, msg.params)
	if !ok {
		send_error_response(msg.id, -32602, "Cannot rename this element")
		return
	}

	ast := doc.ast
	span := compiler.node_name_span(ast, node)
	if span.start == span.end do span = ast.node_spans[node]

	s := compiler.span_to_position(ast, span.start)
	e := compiler.span_to_position(ast, span.end)

	start_pos := make(map[string]json.Value)
	start_pos["line"] = json.Integer(s.line - 1)
	start_pos["character"] = json.Integer(s.column - 1)

	end_pos := make(map[string]json.Value)
	end_pos["line"] = json.Integer(e.line - 1)
	end_pos["character"] = json.Integer(e.column - 1)

	range_obj := make(map[string]json.Value)
	range_obj["start"] = json.Object(start_pos)
	range_obj["end"] = json.Object(end_pos)

	result := make(map[string]json.Value)
	result["range"] = json.Object(range_obj)
	result["placeholder"] = json.String(ast.source[span.start:span.end])

	send_response(msg.id, json.Object(result))
}

handle_rename :: proc(server: ^LSP_Server, msg: LSP_Message) {
	uri, bid, _, doc, ok := resolve_binding_at(server, msg.params)
	if !ok {
		send_error_response(msg.id, -32602, "Cannot rename this element")
		return
	}

	new_name := ""
	if p, p_ok := msg.params.(json.Object); p_ok {
		if n, n_ok := p["newName"].(json.String); n_ok {
			new_name = n
		}
	}
	if new_name == "" {
		send_error_response(msg.id, -32602, "New name is empty")
		return
	}

	locations := find_all_ref_locations(uri, doc, bid, true)

	edits := make([dynamic]json.Value, 0, len(locations))
	for loc in locations {
		loc_obj := loc.(json.Object)
		edit := make(map[string]json.Value)
		edit["range"] = loc_obj["range"]
		edit["newText"] = json.String(new_name)
		append(&edits, json.Object(edit))
	}

	doc_edits := make(map[string]json.Value)
	doc_edits[uri] = json.Array(edits)

	result := make(map[string]json.Value)
	result["changes"] = json.Object(doc_edits)

	send_response(msg.id, json.Object(result))
}

make_location :: proc(uri: string, start, end: compiler.Position) -> json.Value {
	start_pos := make(map[string]json.Value)
	start_pos["line"] = json.Integer(start.line - 1)
	start_pos["character"] = json.Integer(start.column - 1)

	end_pos := make(map[string]json.Value)
	end_pos["line"] = json.Integer(end.line - 1)
	end_pos["character"] = json.Integer(end.column - 1)

	range_obj := make(map[string]json.Value)
	range_obj["start"] = json.Object(start_pos)
	range_obj["end"] = json.Object(end_pos)

	result := make(map[string]json.Value)
	result["uri"] = json.String(uri)
	result["range"] = json.Object(range_obj)
	return json.Object(result)
}

lsp_pos_to_offset :: proc(ast: ^compiler.Ast, line, char: int) -> int {
	if line < 0 || line >= len(ast.line_starts) do return -1
	return int(ast.line_starts[line]) + char
}

find_node_at_offset :: proc(ast: ^compiler.Ast, offset: u32) -> compiler.Node_Index {
	best := compiler.INVALID_NODE
	best_size := max(u32)

	for i := 0; i < len(ast.node_kinds); i += 1 {
		span := ast.node_spans[i]
		if span.start <= offset && offset < span.end {
			size := span.end - span.start
			if size < best_size {
				best_size = size
				best = compiler.Node_Index(i)
			}
		}
	}
	return best
}

/* ======================================================================
 * SECTION 11: SEMANTIC TOKENS
 * ====================================================================== */

handle_semantic_tokens :: proc(server: ^LSP_Server, msg: LSP_Message) {
	uri, uri_ok := get_text_doc_uri(msg.params)
	if !uri_ok {
		send_response(msg.id, json.Null{})
		return
	}

	if uri not_in server.documents {
		send_response(msg.id, json.Null{})
		return
	}

	doc := &server.documents[uri]
	cache := compiler.Cache{}
	ast, _ := compiler.parse(&cache, doc.content)

	if ast == nil {
		result := make(map[string]json.Value)
		result["data"] = json.Array(make([dynamic]json.Value))
		send_response(msg.id, json.Object(result))
		return
	}

	tokens := make([dynamic]Raw_Sem_Token, 0, 256)
	defer delete(tokens)

	collect_semantic_tokens(ast, &tokens)

	sort_sem_tokens(tokens[:])

	data := make([dynamic]json.Value, 0, len(tokens) * 5)
	prev_line := 0
	prev_char := 0

	for t in tokens {
		delta_line := t.line - prev_line
		delta_char := t.start_char
		if delta_line == 0 {
			delta_char = t.start_char - prev_char
		}

		append(&data, json.Integer(delta_line))
		append(&data, json.Integer(delta_char))
		append(&data, json.Integer(t.length))
		append(&data, json.Integer(t.type))
		append(&data, json.Integer(t.modifiers))

		prev_line = t.line
		prev_char = t.start_char
	}

	result := make(map[string]json.Value)
	result["data"] = json.Array(data)
	send_response(msg.id, json.Object(result))
}

collect_semantic_tokens :: proc(ast: ^compiler.Ast, tokens: ^[dynamic]Raw_Sem_Token) {
	compiler.ensure_line_starts(ast)
	node_count := len(ast.node_kinds)

	parent_kind := make([]compiler.Node_Kind, node_count)
	defer delete(parent_kind)
	is_left := make([]bool, node_count)
	defer delete(is_left)
	build_parent_map(ast, parent_kind, is_left)

	for i := 0; i < node_count; i += 1 {
		idx := compiler.Node_Index(i)
		kind := ast.node_kinds[i]
		span := ast.node_spans[i]
		if span.start == span.end do continue

		tok_type := -1
		tok_mod := 0

		#partial switch kind {
		case .Identifier:
			name := compiler.node_name_str(ast, idx)
			_, is_builtin := compiler.resolve_builtin_by_name(name)
			if is_builtin {
				tok_type = int(Sem_Token_Type.Class)
			} else {
				pk := parent_kind[i]
				left := is_left[i]
				#partial switch pk {
				case .Pointing, .PointingPull:
					if left {
						tok_type = int(Sem_Token_Type.Function)
						tok_mod = 1
					} else {
						tok_type = int(Sem_Token_Type.Variable)
					}
				case .EventPush, .EventPull:
					tok_type = int(Sem_Token_Type.Event)
				case .ResonancePush, .ResonancePull:
					tok_type = int(Sem_Token_Type.Event)
				case .ReactivePush, .ReactivePull:
					tok_type = int(Sem_Token_Type.Event)
				case .Constraint:
					if left {
						tok_type = int(Sem_Token_Type.Type)
					} else {
						tok_type = int(Sem_Token_Type.Variable)
					}
				case .Property:
					if left {
						tok_type = int(Sem_Token_Type.Variable)
					} else {
						tok_type = int(Sem_Token_Type.Property)
					}
				case .Execute:
					tok_type = int(Sem_Token_Type.Function)
				case .External:
					tok_type = int(Sem_Token_Type.Namespace)
				case .Pattern:
					tok_type = int(Sem_Token_Type.Variable)
				case:
					tok_type = int(Sem_Token_Type.Variable)
				}
			}
			name_span := compiler.node_name_span(ast, idx)
			if name_span.start != name_span.end {
				span = name_span
			}

		case .Literal:
			lit_kind := compiler.node_literal_kind(ast, idx)
			#partial switch lit_kind {
			case .Integer, .Float, .Hexadecimal, .Binary:
				tok_type = int(Sem_Token_Type.Number)
			case .String:
				tok_type = int(Sem_Token_Type.String)
				start_pos := compiler.span_to_position(ast, span.start > 0 ? span.start - 1 : 0)
				length := int(span.end - span.start) + 2
				append(
					tokens,
					Raw_Sem_Token {
						line = start_pos.line - 1,
						start_char = start_pos.column - 1,
						length = length,
						type = tok_type,
						modifiers = 0,
					},
				)
				continue
			case .Bool:
				tok_type = int(Sem_Token_Type.Keyword)
			}

		case .Operator:
			emit_operator_tokens(ast, idx, tokens)
			continue

		case:
			continue
		}

		if tok_type < 0 do continue

		start_pos := compiler.span_to_position(ast, span.start)
		length := int(span.end - span.start)

		append(
			tokens,
			Raw_Sem_Token {
				line = start_pos.line - 1,
				start_char = start_pos.column - 1,
				length = length,
				type = tok_type,
				modifiers = tok_mod,
			},
		)
	}

	emit_punctuation_tokens(ast, tokens)
}

build_parent_map :: proc(ast: ^compiler.Ast, parent_kind: []compiler.Node_Kind, is_left: []bool) {
	node_count := len(ast.node_kinds)
	for i := 0; i < node_count; i += 1 {
		idx := compiler.Node_Index(i)
		kind := ast.node_kinds[i]

		mark_binary :: proc(
			ast: ^compiler.Ast,
			idx: compiler.Node_Index,
			kind: compiler.Node_Kind,
			parent_kind: []compiler.Node_Kind,
			is_left: []bool,
			node_count: int,
		) {
			left := compiler.node_left(ast, idx)
			right := compiler.node_right(ast, idx)
			if left != compiler.INVALID_NODE && int(left) < node_count {
				parent_kind[left] = kind
				is_left[left] = true
			}
			if right != compiler.INVALID_NODE && int(right) < node_count {
				parent_kind[right] = kind
			}
		}

		#partial switch kind {
		case .Pointing,
		     .PointingPull,
		     .ResonancePush,
		     .ResonancePull,
		     .ReactivePush,
		     .ReactivePull,
		     .EventPush:
			mark_binary(ast, idx, kind, parent_kind, is_left, node_count)
		case .EventPull:
			d := ast.node_data[i].event_pull
			if d.from != compiler.INVALID_NODE && int(d.from) < node_count {
				parent_kind[d.from] = kind
				is_left[d.from] = true
			}
			if d.to != compiler.INVALID_NODE && int(d.to) < node_count {
				parent_kind[d.to] = kind
			}
		case .Constraint:
			mark_binary(ast, idx, kind, parent_kind, is_left, node_count)
		case .Property:
			mark_binary(ast, idx, kind, parent_kind, is_left, node_count)
		case .Execute:
			target := compiler.node_execute_target(ast, idx)
			if target != compiler.INVALID_NODE && int(target) < node_count {
				parent_kind[target] = kind
				is_left[target] = true
			}
		case .External:
			d := ast.node_data[i].external
			if d.scope != compiler.INVALID_NODE && int(d.scope) < node_count {
				parent_kind[d.scope] = kind
			}
		case .Pattern:
			target := compiler.node_pattern_target(ast, idx)
			if target != compiler.INVALID_NODE && int(target) < node_count {
				parent_kind[target] = kind
			}
		case .Operator:
			left := compiler.node_operator_left(ast, idx)
			right := compiler.node_operator_right(ast, idx)
			if left != compiler.INVALID_NODE && int(left) < node_count {
				parent_kind[left] = kind
			}
			if right != compiler.INVALID_NODE && int(right) < node_count {
				parent_kind[right] = kind
			}
		}
	}
}

emit_operator_tokens :: proc(
	ast: ^compiler.Ast,
	idx: compiler.Node_Index,
	tokens: ^[dynamic]Raw_Sem_Token,
) {
	span := compiler.node_span(ast, idx)
	left := compiler.node_operator_left(ast, idx)
	right := compiler.node_operator_right(ast, idx)

	left_end := ast.node_spans[left].end if left != compiler.INVALID_NODE else span.start
	right_start := ast.node_spans[right].start if right != compiler.INVALID_NODE else span.end

	if left_end < right_start {
		src := ast.source[left_end:right_start]
		op_start: u32 = 0
		op_end: u32 = u32(len(src))
		for j: u32 = 0; j < u32(len(src)); j += 1 {
			if src[j] != ' ' && src[j] != '\t' && src[j] != '\n' && src[j] != '\r' {
				op_start = j
				break
			}
		}
		for j := u32(len(src)); j > op_start; j -= 1 {
			if src[j - 1] != ' ' &&
			   src[j - 1] != '\t' &&
			   src[j - 1] != '\n' &&
			   src[j - 1] != '\r' {
				op_end = j
				break
			}
		}
		actual_start := left_end + op_start
		actual_end := left_end + op_end
		if actual_start < actual_end {
			pos := compiler.span_to_position(ast, actual_start)
			append(
				tokens,
				Raw_Sem_Token {
					line = pos.line - 1,
					start_char = pos.column - 1,
					length = int(actual_end - actual_start),
					type = int(Sem_Token_Type.Operator),
					modifiers = 0,
				},
			)
		}
	}
}

emit_comment_tokens :: proc(ast: ^compiler.Ast, tokens: ^[dynamic]Raw_Sem_Token) {
	src := ast.source
	slen := len(src)
	i := 0
	for i < slen - 1 {
		if src[i] == '/' && src[i + 1] == '/' {
			start := u32(i)
			end := i + 2
			for end < slen && src[end] != '\n' {
				end += 1
			}
			pos := compiler.span_to_position(ast, start)
			append(
				tokens,
				Raw_Sem_Token {
					line = pos.line - 1,
					start_char = pos.column - 1,
					length = end - i,
					type = int(Sem_Token_Type.Comment),
					modifiers = 0,
				},
			)
			i = end
		} else {
			i += 1
		}
	}
}

emit_punctuation_tokens :: proc(ast: ^compiler.Ast, tokens: ^[dynamic]Raw_Sem_Token) {
	emit_comment_tokens(ast, tokens)

	lexer: compiler.Lexer
	compiler.init_lexer(&lexer, ast.source)

	for {
		tok := compiler.next_token(&lexer)
		if tok.kind == .EOF do break

		tok_type := -1
		#partial switch tok.kind {
		case .PointingPush:
			tok_type = int(Sem_Token_Type.Keyword)
		case .PointingPull:
			tok_type = int(Sem_Token_Type.Keyword)
		case .EventPush:
			tok_type = int(Sem_Token_Type.Keyword)
		case .EventPull:
			tok_type = int(Sem_Token_Type.Keyword)
		case .ResonancePush:
			tok_type = int(Sem_Token_Type.Keyword)
		case .ResonancePull:
			tok_type = int(Sem_Token_Type.Keyword)
		case .ReactivePush:
			tok_type = int(Sem_Token_Type.Keyword)
		case .ReactivePull:
			tok_type = int(Sem_Token_Type.Keyword)
		case .Question:
			tok_type = int(Sem_Token_Type.Keyword)
		case .DoubleQuestion:
			tok_type = int(Sem_Token_Type.Keyword)
		case .QuestionExclamation:
			tok_type = int(Sem_Token_Type.Modifier)
		case .Execute:
			tok_type = int(Sem_Token_Type.Function)
		case .At:
			tok_type = int(Sem_Token_Type.Decorator)
		case .Ellipsis:
			tok_type = int(Sem_Token_Type.Decorator)
		case .ConstraintBind, .ConstraintFromNone, .ConstraintToNone:
			tok_type = int(Sem_Token_Type.TypeParameter)
		case .PropertyAccess, .PropertyFromNone, .PropertyToNone:
			tok_type = int(Sem_Token_Type.Property)
		case .Plus, .Minus, .Asterisk, .Slash, .Percent:
			tok_type = int(Sem_Token_Type.Operator)
		case .Equal, .NotEqual, .Less, .Greater, .LessEqual, .GreaterEqual:
			tok_type = int(Sem_Token_Type.Operator)
		case .And, .Or, .Xor, .Not, .RShift, .LShift:
			tok_type = int(Sem_Token_Type.Operator)
		case .Range, .PrefixRange, .PostfixRange, .DoubleDot:
			tok_type = int(Sem_Token_Type.Operator)
		}

		if tok_type < 0 do continue

		pos := compiler.span_to_position(ast, tok.span.start)
		length := int(tok.span.end - tok.span.start)

		append(
			tokens,
			Raw_Sem_Token {
				line = pos.line - 1,
				start_char = pos.column - 1,
				length = length,
				type = tok_type,
				modifiers = 0,
			},
		)
	}
}

sort_sem_tokens :: proc(tokens: []Raw_Sem_Token) {
	for i := 1; i < len(tokens); i += 1 {
		key := tokens[i]
		j := i - 1
		for j >= 0 && sem_token_greater(tokens[j], key) {
			tokens[j + 1] = tokens[j]
			j -= 1
		}
		tokens[j + 1] = key
	}
}

sem_token_greater :: proc(a, b: Raw_Sem_Token) -> bool {
	if a.line != b.line do return a.line > b.line
	return a.start_char > b.start_char
}

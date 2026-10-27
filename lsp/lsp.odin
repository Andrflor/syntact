package lsp

import "../syntax"
import kernel "../kernel"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
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

SEMANTIC_TOKEN_MODIFIERS :: [?]string{"declaration", "definition", "readonly", "static", "collapsed"}

// COLLAPSED: the modifier of the name of what `!` collapses — a run.
COLLAPSED :: 1 << 4

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
	uri:     string,
	version: int,
	content: string,
	ast:     ^syntax.Ast,
	// the file, checked by the kernel: its scope (root) holds each written binding
	checked: kernel.Kernel,
	// Cursor→name resolution is lexical over the AST; the parent map is rebuilt on
	// each (re)analysis and reused by definition/references/rename/completion.
	parents: Parent_Map,
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
	case json.Integer:
		return int(val)
	case json.Float:
		return int(val)
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
		case '\b':
			strings.write_string(b, "\\b")
		case '\f':
			strings.write_string(b, "\\f")
		case:
			// JSON requires every control character (U+0000..U+001F) to be escaped
			// as \u00XX — an unescaped one (e.g. a NUL from a `'\0'`-derived type
			// string, or a non-printable char in a hover/completion detail) yields
			// "Invalid string" in the client. Other runes pass through as UTF-8.
			if c < 0x20 {
				fmt.sbprintf(b, "\\u%04x", int(c))
			} else {
				strings.write_rune(b, c)
			}
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
		handle_hover(server, msg)
	case "textDocument/definition":
		handle_definition(server, msg)
	case "textDocument/references":
		handle_references(server, msg)
	case "textDocument/rename":
		handle_rename(server, msg)
	case "textDocument/prepareRename":
		handle_prepare_rename(server, msg)
	case "textDocument/completion":
		handle_completion(server, msg)
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
	capabilities["hoverProvider"] = json.Boolean(true)

	trigger_chars := make([dynamic]json.Value)
	append(&trigger_chars, json.String("."))
	completion_opts := make(map[string]json.Value)
	completion_opts["triggerCharacters"] = json.Array(trigger_chars)
	capabilities["completionProvider"] = json.Object(completion_opts)

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

	ast, _ := syntax.parse(doc.content)
	doc.ast = ast
	doc.checked = {}

	diagnostics := make([dynamic]Diagnostic, 0, len(ast.errors) + 16)
	defer delete(diagnostics)

	for err in ast.errors {
		append(
			&diagnostics,
			Diagnostic {
				range = span_range(ast, err.span),
				severity = 1,
				source = "syn-parse",
				message = err.message,
			},
		)
	}

	if ast != nil {
		// Build the lexical parent map regardless of analysis success — it powers
		// definition/references even when analysis bailed on an error.
		doc.parents = build_parent_map(ast)

		// The kernel types whatever AST there is, even partial: an editor almost
		// always holds half-written code. It first runs apart: if it crashes or
		// does not terminate, the LSP stays alive and says so.
		if failure, failed := kernel_fails(ast); failed {
			append(&diagnostics, Diagnostic{range = span_range(ast, ast.node_spans[syntax.ast_root(ast)]), severity = 1, source = "syn-kernel", message = failure})
			publish_diagnostics(uri, diagnostics[:])
			return
		}
		doc.checked = kernel.check(ast)
		for e in doc.checked.errors {
			append(
				&diagnostics,
				Diagnostic {
					range = span_range(ast, e.span),
					// what the kernel does not handle yet is not a fault of the code
					severity = e.kind == .Unsupported ? 2 : 1,
					source = "syn-kernel",
					message = e.message,
				},
			)
		}
	}

	publish_diagnostics(uri, diagnostics[:])
}

// span_range converts a syntax Span (byte range) to an LSP range (0-based
// line/char), resolving both ends via the AST's line table. This is all the LSP
// needs: every error — of the parser and of the kernel — carries the offending
// node's span. The end is trimmed back over
// any trailing whitespace/newline the parser may have folded into the span (which
// happens for the last statement before EOF), so the highlight never bleeds onto
// the next line.
span_range :: proc(ast: ^syntax.Ast, span: syntax.Span) -> Range {
	end := span.end
	for end > span.start && int(end - 1) < len(ast.source) {
		c := ast.source[end - 1]
		if c == '\n' || c == '\r' || c == ' ' || c == '\t' do end -= 1
		else do break
	}
	s := syntax.span_to_position(ast, span.start)
	e := syntax.span_to_position(ast, end)
	return Range {
		start = Position{line = s.line - 1, character = s.column - 1},
		end = Position{line = e.line - 1, character = e.column - 1},
	}
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
	uri, decl, _, doc, ok := resolve_binding_at(server, msg.params)
	if !ok || decl == syntax.INVALID_NODE {
		send_response(msg.id, json.Null{})
		return
	}

	ast := doc.ast
	def_span := name_span(ast, decl)
	if def_span.start == def_span.end {
		send_response(msg.id, json.Null{})
		return
	}

	def_start := syntax.span_to_position(ast, def_span.start)
	def_end := syntax.span_to_position(ast, def_span.end)
	send_response(msg.id, make_location(uri, def_start, def_end))
}

// handle_hover: the binding that the identifier under the cursor designates, as
// the kernel typed it.
handle_hover :: proc(server: ^LSP_Server, msg: LSP_Message) {
	doc, offset, ok := cursor_at(server, msg.params)
	if !ok {
		send_response(msg.id, json.Null{})
		return
	}
	shown := shown_at(&doc.checked, offset)
	// half-written, the name is no term of the kernel: its binding, where it is declared
	if _, decl, use, _, found := resolve_binding_at(server, msg.params); shown == "" && found {
		ast := doc.ast
		name := syntax.node_name_str(ast, use)
		// `(h)`: a capture is named by its alias
		if name == "" do name = syntax.span_str(ast, ast.node_data[use].identifier.capture)
		if b := written_binding(&doc.checked, name, ast.node_spans[decl].start); b != nil do shown = shown_type(&doc.checked, b)
	}
	if shown == "" {
		send_response(msg.id, json.Null{})
		return
	}

	contents := make(map[string]json.Value)
	contents["kind"] = json.String("markdown")
	contents["value"] = json.String(fmt.tprintf("```syntact\n%s\n```", shown))

	result := make(map[string]json.Value)
	result["contents"] = json.Object(contents)
	send_response(msg.id, json.Object(result))
}

// cursor_at: the document and the byte offset a request's position points at.
cursor_at :: proc(server: ^LSP_Server, params: json.Value) -> (doc: ^Document, offset: u32, ok: bool) {
	p, p_ok := params.(json.Object)
	if !p_ok do return
	u, u_ok := get_text_doc_uri(params)
	if !u_ok || u not_in server.documents do return
	pos_obj, pos_ok := p["position"].(json.Object)
	if !pos_ok do return
	doc = &server.documents[u]
	if doc.ast == nil do return
	syntax.ensure_line_starts(doc.ast)
	o := lsp_pos_to_offset(doc.ast, json_to_int(pos_obj["line"]), json_to_int(pos_obj["character"]))
	if o < 0 do return
	return doc, u32(o), true
}

// resolve_binding_at maps a cursor to the identifier under it (`use`) and the
// identifier that declares its name (`decl`), resolved LEXICALLY over the AST. A
// declaration resolves to itself. Returns ok=false when the cursor is not on a
// resolvable identifier.
resolve_binding_at :: proc(
	server: ^LSP_Server,
	params: json.Value,
) -> (
	uri: string,
	decl: syntax.Node_Index,
	use: syntax.Node_Index,
	doc: ^Document,
	ok: bool,
) {
	decl = syntax.INVALID_NODE
	use = syntax.INVALID_NODE

	u, u_ok := get_text_doc_uri(params)
	if !u_ok do return
	d, offset, at := cursor_at(server, params)
	if !at do return
	ast := d.ast

	target := find_node_at_offset(ast, offset)
	if target == syntax.INVALID_NODE do return
	if ast.node_kinds[target] != .Identifier do return

	dn := resolve_definition(ast, d.parents, target)
	if dn == syntax.INVALID_NODE {
		// The name is undeclared in scope (a builtin like u8, or an undefined id).
		// Treat the identifier itself as both use and (self-)declaration so rename
		// at least scopes to same-name uses; definition will return nothing useful.
		dn = target
	}
	return u, dn, target, d, true
}

find_all_ref_locations :: proc(
	uri: string,
	doc: ^Document,
	decl: syntax.Node_Index,
	include_decl: bool,
) -> [dynamic]json.Value {
	ast := doc.ast
	locations := make([dynamic]json.Value, 0, 16)
	if decl == syntax.INVALID_NODE do return locations

	name := syntax.node_name_str(ast, decl)
	refs := all_references(ast, doc.parents, name, decl)

	for idx in refs {
		if !include_decl && idx == decl do continue
		span := name_span(ast, idx)
		if span.start == span.end do continue
		s := syntax.span_to_position(ast, span.start)
		e := syntax.span_to_position(ast, span.end)
		append(&locations, make_location(uri, s, e))
	}
	return locations
}

/* ======================================================================
 * SECTION 10b: FIND ALL REFERENCES
 * ====================================================================== */

handle_references :: proc(server: ^LSP_Server, msg: LSP_Message) {
	uri, decl, _, doc, ok := resolve_binding_at(server, msg.params)
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

	locations := find_all_ref_locations(uri, doc, decl, include_decl)
	send_response(msg.id, json.Array(locations))
}

/* ======================================================================
 * SECTION 10c: RENAME
 * ====================================================================== */

handle_prepare_rename :: proc(server: ^LSP_Server, msg: LSP_Message) {
	_, _, use, doc, ok := resolve_binding_at(server, msg.params)
	if !ok || use == syntax.INVALID_NODE {
		send_error_response(msg.id, -32602, "Cannot rename this element")
		return
	}

	ast := doc.ast
	span := name_span(ast, use)

	s := syntax.span_to_position(ast, span.start)
	e := syntax.span_to_position(ast, span.end)

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
	uri, decl, _, doc, ok := resolve_binding_at(server, msg.params)
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

	locations := find_all_ref_locations(uri, doc, decl, true)

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

make_location :: proc(uri: string, start, end: syntax.Position) -> json.Value {
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

// lsp_pos_to_offset maps an LSP (line, character) to a source byte offset. The
// result is CLAMPED to [0, len(source)] — an editor can place the cursor past the
// last column or at end-of-file (e.g. when triggering completion), and an
// unclamped offset would index out of bounds on the next `source[offset]` access.
lsp_pos_to_offset :: proc(ast: ^syntax.Ast, line, char: int) -> int {
	if line < 0 || line >= len(ast.line_starts) do return -1
	off := int(ast.line_starts[line]) + char
	if off < 0 do off = 0
	if off > len(ast.source) do off = len(ast.source)
	return off
}

find_node_at_offset :: proc(ast: ^syntax.Ast, offset: u32) -> syntax.Node_Index {
	best := syntax.INVALID_NODE
	best_size := max(u32)

	for i := 0; i < len(ast.node_kinds); i += 1 {
		span := ast.node_spans[i]
		if span.start <= offset && offset < span.end {
			size := span.end - span.start
			if size < best_size {
				best_size = size
				best = syntax.Node_Index(i)
			}
		}
	}
	return best
}

/* ======================================================================
 * SECTION 10d: COMPLETION
 * ====================================================================== */

COMPLETION_KIND_VARIABLE :: 6
COMPLETION_KIND_MODULE :: 9 // scope-valued bindings (no parens)
COMPLETION_KIND_KEYWORD :: 14
COMPLETION_KIND_PROPERTY :: 10
COMPLETION_KIND_EVENT :: 23
COMPLETION_KIND_CLASS :: 7

handle_completion :: proc(server: ^LSP_Server, msg: LSP_Message) {
	params, ok := msg.params.(json.Object)
	if !ok {
		send_empty_completion(msg.id)
		return
	}

	uri, uri_ok := get_text_doc_uri(msg.params)
	if !uri_ok || uri not_in server.documents {
		send_empty_completion(msg.id)
		return
	}

	pos_obj, pos_ok := params["position"].(json.Object)
	if !pos_ok {
		send_empty_completion(msg.id)
		return
	}

	line := json_to_int(pos_obj["line"])
	char := json_to_int(pos_obj["character"])

	doc := &server.documents[uri]
	ast := doc.ast

	if ast == nil {
		send_empty_completion(msg.id)
		return
	}

	syntax.ensure_line_starts(ast)
	offset := lsp_pos_to_offset(ast, line, char)
	if offset < 0 {
		send_empty_completion(msg.id)
		return
	}

	items := make([dynamic]json.Value, 0, 32)

	is_dot := offset > 0 && ast.source[offset - 1] == '.'

	if is_dot {
		collect_property_completions(doc, u32(offset), &items)
	} else {
		collect_scope_completions(doc, u32(offset), &items)
	}

	result := make(map[string]json.Value)
	result["isIncomplete"] = json.Boolean(false)
	result["items"] = json.Array(items)
	send_response(msg.id, json.Object(result))
}

send_empty_completion :: proc(id: Maybe(json.Value)) {
	result := make(map[string]json.Value)
	result["isIncomplete"] = json.Boolean(false)
	result["items"] = json.Array(make([dynamic]json.Value))
	send_response(id, json.Object(result))
}

// collect_property_completions: after `x.`, the named bindings presented by the
// scope that x is.
collect_property_completions :: proc(doc: ^Document, offset: u32, items: ^[dynamic]json.Value) {
	ast := doc.ast
	source_node := find_dot_source(ast, offset)
	if source_node == syntax.INVALID_NODE do return
	if ast.node_kinds[source_node] != .Identifier do return
	name := syntax.node_name_str(ast, source_node)
	b := written_binding(&doc.checked, name, ast.node_spans[source_node].start)
	// half-written, `x.` is no term of the kernel: x, where it is declared
	if b == nil {
		decl := resolve_definition(ast, doc.parents, source_node)
		if decl != syntax.INVALID_NODE do b = written_binding(&doc.checked, name, ast.node_spans[decl].start)
	}
	if b == nil do return
	// the fields of what x gives back: its effects are its scope's (specs/types.md §4.8)
	target, is_scope := kernel.binding_value(&doc.checked, b).(^kernel.Scope)
	if !is_scope do return
	for field in kernel.placed(&doc.checked, target, .Value) {
		if field.name != "" do append(items, make_completion_item(&doc.checked, field))
	}
}

find_dot_source :: proc(ast: ^syntax.Ast, offset: u32) -> syntax.Node_Index {
	best := syntax.INVALID_NODE
	best_size := max(u32)
	for i := 0; i < len(ast.node_kinds); i += 1 {
		if ast.node_kinds[i] != .Property do continue
		span := ast.node_spans[i]
		if span.start < offset && offset <= span.end + 1 {
			size := span.end - span.start
			if size < best_size {
				best_size = size
				best = syntax.Node_Index(i)
			}
		}
	}
	if best == syntax.INVALID_NODE do return syntax.INVALID_NODE
	return node_left(ast, best)
}

// collect_scope_completions: the names visible at the cursor, builtins included.
collect_scope_completions :: proc(doc: ^Document, offset: u32, items: ^[dynamic]json.Value) {
	for b in visible_bindings(doc.checked.root, offset) do append(items, make_completion_item(&doc.checked, b))
}

// make_completion_item: a binding, with its type according to the kernel.
make_completion_item :: proc(k: ^kernel.Kernel, b: ^kernel.Binding) -> json.Value {
	item := make(map[string]json.Value)
	item["label"] = json.String(b.capture != "" ? b.capture : b.name)
	item["insertTextFormat"] = json.Integer(1) // plain text

	ckind := COMPLETION_KIND_VARIABLE
	if _, is_scope := kernel.binding_value(k, b).(^kernel.Scope); is_scope do ckind = COMPLETION_KIND_MODULE
	item["kind"] = json.Integer(ckind)
	item["detail"] = json.String(shown_type(k, b))
	return json.Object(item)
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
	// Reuse the AST already parsed by analyze_and_publish — re-parsing on every
	// semanticTokens request doubles the work on a large file.
	ast := doc.ast
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

// collect_semantic_tokens classifies the document in ONE lexer pass. The parser
// already has a lexer that yields every token with its kind + span, so there is no
// need to walk the AST or re-scan the source: each token maps to a semantic type
// by its kind. The only context needed is for identifiers — an identifier directly
// FOLLOWED by a binding/constraint operator (`->`, `:`, `>-`, …) is a declaration;
// otherwise it is a use. Builtins (u8, string, …) are types. Comments are skipped
// by the lexer, so they are scanned separately (cheap, single linear pass).
collect_semantic_tokens :: proc(ast: ^syntax.Ast, tokens: ^[dynamic]Raw_Sem_Token) {
	syntax.ensure_line_starts(ast)

	emit :: proc(
		ast: ^syntax.Ast,
		tokens: ^[dynamic]Raw_Sem_Token,
		span: syntax.Span,
		type: Sem_Token_Type,
		mod := 0,
	) {
		if span.end <= span.start do return
		pos := syntax.span_to_position(ast, span.start)
		append(
			tokens,
			Raw_Sem_Token {
				line = pos.line - 1,
				start_char = pos.column - 1,
				length = int(span.end - span.start),
				type = int(type),
				modifiers = mod,
			},
		)
	}

	// collapse: the name of what `!` collapses, in the color of a run
	collapse :: proc(tokens: ^[dynamic]Raw_Sem_Token, i: int) {
		tokens[i].type, tokens[i].modifiers = int(Sem_Token_Type.Macro), COLLAPSED
	}

	lexer: syntax.Lexer
	syntax.init_lexer(&lexer, ast.source)
	// what is collapsed is named before `!`, or before the carve that `!` closes:
	// each open brace holds the token of the name it carves, -1 for a scope
	carves := make([dynamic]int, context.temp_allocator)
	named := -1 // the token of the name a carve here would carve
	prev := syntax.next_token(&lexer)
	for prev.kind != .EOF {
		cur := prev
		next := syntax.next_token(&lexer)
		carved := named
		named = -1

		#partial switch cur.kind {
		case .Identifier:
			name := ast.source[cur.span.start:cur.span.end]
			if is_builtin(name) {
				emit(ast, tokens, cur.span, .Class)
			} else if token_is_decl_op(next.kind) {
				emit(ast, tokens, cur.span, decl_token_type(next.kind), 1)
			} else {
				emit(ast, tokens, cur.span, .Variable)
				named = len(tokens) - 1
				if next.kind == .Execute do collapse(tokens, named)
			}
		case .LeftBrace:
			append(&carves, -1)
		case .LeftBraceCarve:
			append(&carves, carved)
		case .RightBrace:
			// a carve closed: `}{` carves it again, `}!` collapses it
			if len(carves) > 0 do named = pop(&carves)
			if named >= 0 && next.kind == .Execute do collapse(tokens, named)
		case .Integer, .Float, .Hexadecimal, .Binary:
			emit(ast, tokens, cur.span, .Number)
		case .String_Literal:
			emit(ast, tokens, cur.span, .String)
		case .Bool_Literal:
			// `true`/`false` are value literals — bottom types exactly like `10` — so
			// they get the same token type as a numeric literal, not a keyword color.
			emit(ast, tokens, cur.span, .Number)
		case .At:
			emit(ast, tokens, cur.span, .Decorator)
		case .Execute:
			emit(ast, tokens, cur.span, .Function)
		case .Question, .DoubleQuestion, .Effect:
			emit(ast, tokens, cur.span, .Keyword)
		case .PointingPush,
		     .PointingPull,
		     .EventPush,
		     .EventPull,
		     .ResonancePush,
		     .ResonancePull,
		     .ReactivePush,
		     .ReactivePull:
			emit(ast, tokens, cur.span, .Keyword)
		case .Colon, .Cast, .ConstraintBind, .ConstraintFromNone, .ConstraintToNone:
			emit(ast, tokens, cur.span, .TypeParameter)
		case .PropertyAccess, .PropertyFromNone, .PropertyToNone, .Dot:
			emit(ast, tokens, cur.span, .Property)
		case .Plus,
		     .Minus,
		     .Asterisk,
		     .Slash,
		     .Percent,
		     .Equal,
		     .NotEqual,
		     .Less,
		     .Greater,
		     .LessEqual,
		     .GreaterEqual,
		     .And,
		     .Or,
		     .Xor,
		     .Not,
		     .RShift,
		     .LShift,
		     .Power,
		     .BitAnd,
		     .BitOr,
		     .BitNot,
		     .Range,
		     .PrefixRange,
		     .PostfixRange,
		     .DoubleDot,
		     .Ellipsis,
		     .EllipsisNone:
			emit(ast, tokens, cur.span, .Operator)
		}

		prev = next
	}

	emit_comment_tokens(ast, tokens)
}

// token_is_decl_op reports whether `k`, directly following an identifier, marks
// that identifier as a DECLARATION.
token_is_decl_op :: proc(k: syntax.Token_Kind) -> bool {
	#partial switch k {
	case .PointingPush,
	     .PointingPull,
	     .EventPush,
	     .EventPull,
	     .ResonancePush,
	     .ResonancePull,
	     .ReactivePush,
	     .ReactivePull,
	     .Colon,
	     .ConstraintBind,
	     .ConstraintToNone:
		return true
	}
	return false
}

// decl_token_type picks the semantic type for an identifier declared with `k`:
// a constraint-colored name (`u8:x`) is a Type, an event/resonance/reactive binding
// an Event, a plain pointing binding a Function.
decl_token_type :: proc(k: syntax.Token_Kind) -> Sem_Token_Type {
	#partial switch k {
	case .Colon, .ConstraintBind, .ConstraintToNone:
		return .Type
	case .EventPush, .EventPull, .ResonancePush, .ResonancePull, .ReactivePush, .ReactivePull:
		return .Event
	}
	return .Function
}

// emit_comment_tokens scans `//` line and `/* */` (nesting) block comments — the
// lexer skips them, so they carry no token. One linear pass over the source.
emit_comment_tokens :: proc(ast: ^syntax.Ast, tokens: ^[dynamic]Raw_Sem_Token) {
	src := ast.source
	slen := len(src)
	i := 0
	for i < slen - 1 {
		start := i
		end := -1
		if src[i] == '/' && src[i + 1] == '/' {
			end = i + 2
			for end < slen && src[end] != '\n' do end += 1
		} else if src[i] == '/' && src[i + 1] == '*' {
			depth := 1
			end = i + 2
			for end < slen - 1 && depth > 0 {
				if src[end] == '/' && src[end + 1] == '*' {
					depth += 1;end += 2
				} else if src[end] == '*' && src[end + 1] == '/' {
					depth -= 1;end += 2
				} else {
					end += 1
				}
			}
		}
		if end < 0 {
			i += 1
			continue
		}
		pos := syntax.span_to_position(ast, u32(start))
		append(
			tokens,
			Raw_Sem_Token {
				line = pos.line - 1,
				start_char = pos.column - 1,
				length = end - start,
				type = int(Sem_Token_Type.Comment),
				modifiers = 0,
			},
		)
		i = end
	}
}

// sort_sem_tokens orders tokens by (line, start_char). Uses the stdlib introsort
// (O(n log n)) — the old insertion sort was O(n²) and made a large file (giga.syn,
// ~1M tokens) take minutes, so semantic highlighting never arrived.
sort_sem_tokens :: proc(tokens: []Raw_Sem_Token) {
	slice.sort_by(tokens, proc(a, b: Raw_Sem_Token) -> bool {
			if a.line != b.line do return a.line < b.line
			return a.start_char < b.start_char
		})
}

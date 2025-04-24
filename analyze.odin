package compiler

import "core:fmt"
import "core:hash"
import "core:slice"
import "core:strings"
import "core:time"

/*
 * ====================================================================
 * Semantic Analysis for Homoiconic Language
 * ====================================================================
 */

// ===========================================================================
// SECTION 1: DATA STRUCTURES
// ===========================================================================

// Extended reference kind to include imports
Reference_Kind :: enum {
	Definition,
	PullDefinition,
	Usage,
	Constraint,
	EventPush,
	EventPull,
	ResonancePush,
	ResonancePull,
	Override,
	Builtin,
	Import, // Reference is an import
	FileReference, // Reference to a file/module
}

// Extended symbol flag to track imported/file references
Symbol_Flag :: enum {
	Visited,
	Referenced,
	HasConstraint,
	IsEvent,
	IsResonance,
	IsExported,
	InGlobalIndex,
	Builtin,
	IsDriven,
	IsImported, // Symbol is imported
	IsModule, // Symbol represents a module
	InProgress, // File is being processed
	Processed, // File has been processed
	Failed, // File processing failed
}
// Symbol structure
Symbol :: struct {
	name:           string,
	node:           ^Node,
	scope:          ^Scope_Info,
	kind:           Reference_Kind,
	defining_scope: ^Scope_Info,
	constraint:     ^Symbol,
	driver:         ^Symbol,
	position:       Position,
	flags:          bit_set[Symbol_Flag],
	hash:           u64, // Pre-computed name hash
	index:          int, // Position in scope
	references:     [dynamic]^Reference,
}

// Reference structure
Reference :: struct {
	symbol:   ^Symbol,
	node:     ^Node,
	kind:     Reference_Kind,
	position: Position,
	index:    int,
}

// Scope structure with optimized lookups
Scope_Info :: struct {
	parent:              ^Scope_Info,
	symbols:             map[string]^Symbol,
	symbol_list:         [dynamic]^Symbol,
	expansions:          [dynamic]^Scope_Info,
	scope_symbol:        ^Symbol,
	is_pattern:          bool,

	// Analysis data
	branches:            [dynamic]Branch_Info,
	constraints:         [dynamic]Constraint_Info,
	resonances:          [dynamic]Resonance_Info,
	events:              [dynamic]Event_Info,

	// Lookup optimizations
	symbol_cache:        map[u64]^Symbol, // Hash-based lookup
	visible_symbols:     map[string]^Symbol, // Pre-computed visible symbols
	is_visible_computed: bool,
}

// Simplified branch info
Branch_Info :: struct {
	pattern:          ^Node,
	result:           ^Node,
	captured_symbols: map[string]^Symbol,
}

// Constraint info
Constraint_Info :: struct {
	target:     ^Symbol,
	constraint: ^Symbol,
	node:       ^Node,
}

// Event and resonance info
Event_Info :: struct {
	event:   ^Symbol,
	handler: ^Node,
	is_push: bool,
	node:    ^Node,
}

Resonance_Info :: struct {
	target:  ^Symbol,
	driver:  ^Symbol,
	is_push: bool,
	node:    ^Node,
}

// Work queue for non-recursive traversal
Work_Item :: struct {
	node:  ^Node,
	scope: ^Scope_Info,
}

// Main analyzer structure
Analyzer :: struct {
	global_scope:     ^Scope_Info,
	current_scope:    ^Scope_Info,

	// Error and warning storage
	errors:           [dynamic]string,
	warnings:         [dynamic]string,

	// State tracking
	in_pattern:       bool,
	current_pattern:  ^Node,

	// Global symbol tables and caches
	builtin_types:    map[string]^Symbol,
	global_symbols:   map[string]^Symbol, // All symbols by qualified name
	defined_symbols:  map[string]bool, // Cache for constraint checking
	resolution_cache: map[u64]^Symbol, // Hash-based resolution cache

	// Processing queue
	work_queue:       [dynamic]Work_Item,
	queue_head:       int,

	// Multiple file processing
	filename:         string,
	resolver:         ^File_Resolver,
}

// ===========================================================================
// SECTION 2: INITIALIZATION
// ===========================================================================

// Initialize the analyzer
init_analyzer :: proc(resolver: ^File_Resolver, filename: string) -> ^Analyzer {
	analyzer := new(Analyzer)

	// Init core structures
	analyzer.global_scope = init_scope(nil)
	analyzer.current_scope = analyzer.global_scope

	analyzer.filename = filename
	analyzer.resolver = resolver

	// Error tracking
	analyzer.errors = make([dynamic]string)
	analyzer.warnings = make([dynamic]string)

	// Init caches and indices
	analyzer.builtin_types = make(map[string]^Symbol)
	analyzer.global_symbols = make(map[string]^Symbol)
	analyzer.defined_symbols = make(map[string]bool)
	analyzer.resolution_cache = make(map[u64]^Symbol)

	// Work queue
	analyzer.work_queue = make([dynamic]Work_Item)
	analyzer.queue_head = 0

	// Register built-ins
	register_builtin_types(analyzer)

	return analyzer
}

// Initialize a scope
init_scope :: proc(parent: ^Scope_Info) -> ^Scope_Info {
	scope := new(Scope_Info)
	scope.parent = parent

	// Initialize maps and arrays
	scope.symbols = make(map[string]^Symbol)
	scope.symbol_list = make([dynamic]^Symbol)
	scope.expansions = make([dynamic]^Scope_Info)
	scope.branches = make([dynamic]Branch_Info)
	scope.constraints = make([dynamic]Constraint_Info)
	scope.resonances = make([dynamic]Resonance_Info)
	scope.events = make([dynamic]Event_Info)

	// Optimization caches
	scope.symbol_cache = make(map[u64]^Symbol)

	return scope
}

// Register built-in types
register_builtin_types :: proc(analyzer: ^Analyzer) {
	default_pos := Position {
		line   = 0,
		column = 0,
		offset = 0,
	}

	BUILTIN_TYPES := []string {
		"u8",
		"u16",
		"u32",
		"u64",
		"i8",
		"i16",
		"i32",
		"i64",
		"f32",
		"f64",
		"char",
		"String",
		"bool",
	}

	for type_name in BUILTIN_TYPES {
		symbol := create_symbol(
			analyzer,
			type_name,
			nil,
			analyzer.global_scope,
			.Builtin,
			default_pos,
		)
		symbol.flags += {.Builtin}
		analyzer.builtin_types[type_name] = symbol
		add_symbol(analyzer, symbol)
	}
}

// Create a new symbol
create_symbol :: proc(
	analyzer: ^Analyzer,
	name: string,
	node: ^Node,
	scope: ^Scope_Info,
	kind: Reference_Kind,
	position: Position,
) -> ^Symbol {
	// Create the symbol
	symbol := new(Symbol)
	symbol.name = name
	symbol.node = node
	symbol.scope = scope
	symbol.kind = kind
	symbol.position = position
	symbol.references = make([dynamic]^Reference)

	// Pre-compute hash for faster lookups
	symbol.hash = calculate_symbol_hash(name)

	return symbol
}

// Fast hash calculation
calculate_symbol_hash :: proc(name: string) -> u64 {
	if len(name) == 0 {
		return 0
	}
	return hash.fnv64a(transmute([]byte)name)
}

// Add a reference to a symbol
add_reference :: proc(
	analyzer: ^Analyzer,
	symbol: ^Symbol,
	node: ^Node,
	kind: Reference_Kind,
	position: Position,
) -> ^Reference {
	if symbol == nil do return nil

	// Create reference
	ref := new(Reference)
	ref.symbol = symbol
	ref.node = node
	ref.kind = kind
	ref.position = position
	ref.index = symbol.index

	// Store reference
	symbol.flags += {.Referenced}
	append(&symbol.references, ref)

	return ref
}

// Add a symbol to the current scope
add_symbol :: proc(analyzer: ^Analyzer, symbol: ^Symbol) -> ^Symbol {
	if symbol == nil do return nil

	current := analyzer.current_scope

	if symbol.name != "" {
		// Check for built-in shadows
		if builtin, ok := analyzer.builtin_types[symbol.name]; ok && .Builtin not_in symbol.flags {
			add_warning(
				analyzer,
				fmt.tprintf("Definition of '%s' shadows a built-in type", symbol.name),
				symbol.position,
			)
		}

		// Set index and add to lookup tables
		symbol.index = len(current.symbol_list)
		current.symbols[symbol.name] = symbol
		current.symbol_cache[symbol.hash] = symbol

		// Add to global index if exported
		if .IsExported in symbol.flags || (symbol.name[0] >= 'A' && symbol.name[0] <= 'Z') {
			qualified_name := get_qualified_name(symbol)
			analyzer.global_symbols[qualified_name] = symbol
			symbol.flags += {.InGlobalIndex}
		}

		// Add to defined symbols for constraint checking
		analyzer.defined_symbols[symbol.name] = true
	}

	// Add to symbol list
	append(&current.symbol_list, symbol)

	// Invalidate visible symbols cache for parent scopes
	invalidate_visible_cache(current.parent)

	return symbol
}

// Invalidate visible symbols cache up the scope chain
invalidate_visible_cache :: proc(scope: ^Scope_Info) {
	current := scope
	for current != nil {
		if current.is_visible_computed {
			current.is_visible_computed = false
			if current.visible_symbols != nil {
				clear(&current.visible_symbols)
			}
		}
		current = current.parent
	}
}

// Add an error
add_error :: proc(analyzer: ^Analyzer, message: string, position: Position) {
	error_message := fmt.tprintf(
		"Error at line %d, column %d: %s",
		position.line,
		position.column,
		message,
	)
	append(&analyzer.errors, error_message)
}

// Add a warning
add_warning :: proc(analyzer: ^Analyzer, message: string, position: Position) {
	warning_message := fmt.tprintf(
		"Warning at line %d, column %d: %s",
		position.line,
		position.column,
		message,
	)
	append(&analyzer.warnings, warning_message)
}

// Enter a scope with visible symbols pre-computation
enter_scope :: proc(analyzer: ^Analyzer, scope: ^Scope_Info) -> ^Scope_Info {
	prev_scope := analyzer.current_scope
	analyzer.current_scope = scope

	// Prepare visible symbols table if needed
	if !scope.is_visible_computed && scope.parent != nil {
		if scope.visible_symbols == nil {
			scope.visible_symbols = make(map[string]^Symbol)
		} else {
			clear(&scope.visible_symbols)
		}

		// Add all symbols from parent scopes
		compute_visible_symbols(scope)
		scope.is_visible_computed = true
	}

	return prev_scope
}

// Pre-compute all symbols visible from a scope
compute_visible_symbols :: proc(scope: ^Scope_Info) {
	if scope == nil || scope.parent == nil do return

	// Ensure parent has computed its visible symbols
	parent := scope.parent
	if !parent.is_visible_computed {
		if parent.visible_symbols == nil {
			parent.visible_symbols = make(map[string]^Symbol)
		} else {
			clear(&parent.visible_symbols)
		}

		compute_visible_symbols(parent)
		parent.is_visible_computed = true
	}

	// Copy all symbols from parent's visible set
	for name, symbol in parent.visible_symbols {
		scope.visible_symbols[name] = symbol
	}

	// Add parent's direct symbols
	for name, symbol in parent.symbols {
		// Skip if already defined in a closer scope
		if _, exists := scope.visible_symbols[name]; !exists {
			scope.visible_symbols[name] = symbol
		}
	}

	// Handle expansions from parent
	for expansion in parent.expansions {
		add_expansion_symbols(scope, expansion)
	}
}

// Add all symbols from an expansion to the visible symbols
add_expansion_symbols :: proc(scope: ^Scope_Info, expansion: ^Scope_Info) {
	for name, symbol in expansion.symbols {
		// Skip if already defined in a closer scope
		if _, exists := scope.visible_symbols[name]; !exists {
			scope.visible_symbols[name] = symbol
		}
	}

	// Add nested expansions
	for nested in expansion.expansions {
		add_expansion_symbols(scope, nested)
	}
}

// Leave a scope
leave_scope :: proc(analyzer: ^Analyzer, prev_scope: ^Scope_Info) {
	analyzer.current_scope = prev_scope
}

// Create a scope for a node
create_scope_for_node :: proc(
	analyzer: ^Analyzer,
	node: ^Node,
	name: string,
	position: Position,
) -> ^Scope_Info {
	// Create scope
	scope := init_scope(analyzer.current_scope)

	// Create symbol for the scope
	symbol := create_symbol(analyzer, name, node, analyzer.current_scope, .Definition, position)
	symbol.defining_scope = scope
	scope.scope_symbol = symbol

	// Register scope
	add_symbol(analyzer, symbol)

	return scope
}

// ===========================================================================
// SECTION 3: OPTIMIZED SYMBOL LOOKUP
// ===========================================================================

// Fast cache key for resolution cache
generate_lookup_key :: proc(scope_ptr: rawptr, name_hash: u64) -> u64 {
	// Combine scope pointer and name hash
	ptr_val := u64(uintptr(scope_ptr))
	return ptr_val ~ ((name_hash << 16) | (name_hash >> 48))
}

// Optimized symbol lookup with caching
lookup_symbol :: proc(analyzer: ^Analyzer, name: string) -> ^Symbol {
	// Pre-compute hash for faster lookups
	name_hash := calculate_symbol_hash(name)

	// Try visible symbols cache first (fastest path)
	scope := analyzer.current_scope
	if scope.is_visible_computed {
		if symbol, ok := scope.visible_symbols[name]; ok {
			return symbol
		}
	}

	// Try resolution cache next
	cache_key := generate_lookup_key(scope, name_hash)
	if cached, found := analyzer.resolution_cache[cache_key]; found {
		return cached
	}

	// Try current scope's direct symbol table
	if symbol, ok := scope.symbol_cache[name_hash]; ok && symbol.name == name {
		// Found in current scope
		analyzer.resolution_cache[cache_key] = symbol
		return symbol
	}

	// Original lookup with scope traversal
	symbol := lookup_symbol_in_scope_chain(analyzer, scope, name, name_hash)

	// Cache the result (even if nil)
	analyzer.resolution_cache[cache_key] = symbol

	return symbol
}

// Optimized scope chain traversal
lookup_symbol_in_scope_chain :: proc(
	analyzer: ^Analyzer,
	scope: ^Scope_Info,
	name: string,
	name_hash: u64,
) -> ^Symbol {
	current := scope

	for current != nil {
		// Try hash lookup first (faster)
		if symbol, ok := current.symbol_cache[name_hash]; ok {
			if symbol.name == name { 	// Verify in case of hash collision
				return symbol
			}
		}

		// Fallback to map lookup
		if symbol, ok := current.symbols[name]; ok {
			return symbol
		}

		// Check expansions
		for expansion in current.expansions {
			if symbol := lookup_symbol_in_scope(expansion, name, name_hash); symbol != nil {
				return symbol
			}
		}

		current = current.parent
	}

	// Try builtin types as last resort
	if builtin, ok := analyzer.builtin_types[name]; ok {
		return builtin
	}

	// Try global index for exported symbols
	qualified_name := name // For top-level symbols, qualified = simple name
	if symbol, ok := analyzer.global_symbols[qualified_name]; ok {
		// Verify symbol is visible from current scope
		if is_symbol_visible_from(scope, symbol) {
			return symbol
		}
	}

	return nil
}

// Check if a symbol is visible from a scope
is_symbol_visible_from :: proc(from_scope: ^Scope_Info, symbol: ^Symbol) -> bool {
	if from_scope == nil || symbol == nil {
		return false
	}

	// Builtin symbols are visible everywhere
	if .Builtin in symbol.flags {
		return true
	}

	// Check if symbol is in the current scope or any parent
	current := from_scope
	for current != nil {
		if symbol.scope == current {
			return true
		}

		// Check expansions
		for expansion in current.expansions {
			if is_in_expansion(expansion, symbol) {
				return true
			}
		}

		current = current.parent
	}

	return false
}

// Check if a symbol is in an expansion
is_in_expansion :: proc(expansion: ^Scope_Info, symbol: ^Symbol) -> bool {
	if expansion == nil || symbol == nil {
		return false
	}

	// Check direct symbols
	if symbol.scope == expansion {
		return true
	}

	// Check nested expansions
	for nested in expansion.expansions {
		if is_in_expansion(nested, symbol) {
			return true
		}
	}

	return false
}

// Optimized scope lookup
lookup_symbol_in_scope :: proc(scope: ^Scope_Info, name: string, name_hash: u64 = 0) -> ^Symbol {
	if scope == nil {
		return nil
	}

	hash := name_hash == 0 ? calculate_symbol_hash(name) : name_hash

	// Try hash lookup first (faster)
	if symbol, ok := scope.symbol_cache[hash]; ok && symbol.name == name {
		return symbol
	}

	// Fallback to map lookup
	if symbol, ok := scope.symbols[name]; ok {
		return symbol
	}

	// Check expansions
	for expansion in scope.expansions {
		if symbol := lookup_symbol_in_scope(expansion, name, hash); symbol != nil {
			return symbol
		}
	}

	return nil
}

// Optimized local symbol lookup
lookup_symbol_local :: proc(analyzer: ^Analyzer, name: string) -> ^Symbol {
	name_hash := calculate_symbol_hash(name)
	scope := analyzer.current_scope

	// Try hash lookup first
	if symbol, ok := scope.symbol_cache[name_hash]; ok && symbol.name == name {
		return symbol
	}

	// Fallback to map
	if symbol, ok := scope.symbols[name]; ok {
		return symbol
	}

	// Check expansions
	for expansion in scope.expansions {
		if symbol := lookup_symbol_in_scope(expansion, name, name_hash); symbol != nil {
			return symbol
		}
	}

	return nil
}

// ===========================================================================
// SECTION 4: MAIN ANALYSIS - NON-RECURSIVE
// ===========================================================================

// Non-recursive analysis
analyze_ast :: proc(ast: ^Node, resolver: ^File_Resolver, filename: string) -> ^Analyzer {
	analyzer := init_analyzer(resolver, filename)

	// Enqueue root node
	enqueue_node(analyzer, ast, analyzer.global_scope)

	// Process all nodes with iterative approach
	process_work_queue(analyzer)

	// Final validation passes
	validate_analysis(analyzer)

	return analyzer
}

// Add a node to the work queue
enqueue_node :: proc(analyzer: ^Analyzer, node: ^Node, scope: ^Scope_Info) {
	if node == nil do return

	item := Work_Item {
		node  = node,
		scope = scope,
	}
	append(&analyzer.work_queue, item)
}

// Process work queue until empty (non-recursive traversal)
process_work_queue :: proc(analyzer: ^Analyzer) {
	for analyzer.queue_head < len(analyzer.work_queue) {
		item := analyzer.work_queue[analyzer.queue_head]
		analyzer.queue_head += 1
		process_node(analyzer, item.node, item.scope)
	}

	// Clear the queue when done
	clear(&analyzer.work_queue)
	analyzer.queue_head = 0
}

// Process a single node (replaces recursive traversal)
process_node :: proc(analyzer: ^Analyzer, node: ^Node, scope: ^Scope_Info) {
	if node == nil do return

	// Save current scope
	prev_scope := analyzer.current_scope
	if scope != analyzer.current_scope {
		analyzer.current_scope = scope
	}

	position := get_position_from_node(node)

	#partial switch n in node^ {
	case Scope:
		process_scope(analyzer, node, n, position)

	case Pointing:
		process_pointing(analyzer, node, n, position)

	case PointingPull:
		process_pointing_pull(analyzer, node, n, position)

	case EventPush:
		process_event_push(analyzer, node, n, position)

	case EventPull:
		process_event_pull(analyzer, node, n, position)

	case ResonancePush:
		process_resonance_push(analyzer, node, n, position)

	case ResonancePull:
		process_resonance_pull(analyzer, node, n, position)

	case Override:
		process_override(analyzer, node, n, position)

	case Pattern:
		process_pattern(analyzer, node, n, position)

	case Constraint:
		process_constraint(analyzer, node, n, position)

	case Product:
		process_product(analyzer, node, n, position)

	case Execute:
		if n.value != nil {
			enqueue_node(analyzer, n.value, analyzer.current_scope)
		}

	case Expand:
		process_expand(analyzer, node, n, position)

	case Identifier:
		process_identifier(analyzer, node, n, position)

	case Literal:
	// No action needed for literals

	case Operator:
		if n.left != nil {
			enqueue_node(analyzer, n.left, analyzer.current_scope)
		}
		if n.right != nil {
			enqueue_node(analyzer, n.right, analyzer.current_scope)
		}

	case Range:
		if n.start != nil {
			enqueue_node(analyzer, n.start, analyzer.current_scope)
		}
		if n.end != nil {
			enqueue_node(analyzer, n.end, analyzer.current_scope)
		}

	case Property:
		if n.source != nil {
			enqueue_node(analyzer, n.source, analyzer.current_scope)
		}
		if n.property != nil {
			enqueue_node(analyzer, n.property, analyzer.current_scope)
		}
	}

	// Restore scope
	if scope != prev_scope {
		analyzer.current_scope = prev_scope
	}
}

// Process scope nodes
process_scope :: proc(analyzer: ^Analyzer, node: ^Node, scope: Scope, position: Position) {
	// Create new scope
	scope_info := create_scope_for_node(analyzer, node, "", position)

	// Enter new scope
	prev_scope := analyzer.current_scope
	analyzer.current_scope = scope_info

	// Enqueue all children
	for i := 0; i < len(scope.value); i += 1 {
		enqueue_node(analyzer, &scope.value[i], scope_info)
	}

	// Restore scope
	analyzer.current_scope = prev_scope
}

// Process pointing nodes (name -> value)
process_pointing :: proc(
	analyzer: ^Analyzer,
	node: ^Node,
	pointing: Pointing,
	position: Position,
) {
	// Handle product case
	if pointing.name == nil {
		// Create anonymous product symbol
		product := create_symbol(analyzer, "", node, analyzer.current_scope, .Definition, position)
		add_symbol(analyzer, product)

		if pointing.value != nil {
			enqueue_node(analyzer, pointing.value, analyzer.current_scope)
		}
		return
	}

	// Get the name
	name: string
	if id, ok := pointing.name^.(Identifier); ok {
		name = id.name
	} else {
		// Complex naming
		enqueue_node(analyzer, pointing.name, analyzer.current_scope)
		if pointing.value != nil {
			enqueue_node(analyzer, pointing.value, analyzer.current_scope)
		}
		return
	}

	// Create symbol
	symbol := create_symbol(analyzer, name, node, analyzer.current_scope, .Definition, position)

	// Check for existing constraint
	existing := lookup_symbol_local(analyzer, name)
	if existing != nil && existing.constraint != nil {
		symbol.constraint = existing.constraint
		symbol.flags += {.HasConstraint}
	}

	add_symbol(analyzer, symbol)

	// Handle scope value
	if pointing.value != nil {
		if sc, ok := pointing.value^.(Scope); ok {
			// Create a new scope
			scope_info := init_scope(analyzer.current_scope)
			scope_info.scope_symbol = symbol
			symbol.defining_scope = scope_info

			// Process scope contents in the new scope
			for i := 0; i < len(sc.value); i += 1 {
				enqueue_node(analyzer, &sc.value[i], scope_info)
			}
		} else {
			// Regular value, process it in current scope
			enqueue_node(analyzer, pointing.value, analyzer.current_scope)
		}
	}
}

// Process pointing pull nodes (name <- value)
process_pointing_pull :: proc(
	analyzer: ^Analyzer,
	node: ^Node,
	pointing_pull: PointingPull,
	position: Position,
) {
	// Handle anonymous pointing pull
	if pointing_pull.name == nil {
		if pointing_pull.value != nil {
			enqueue_node(analyzer, pointing_pull.value, analyzer.current_scope)
		}
		return
	}

	// Get the name
	name: string
	if id, ok := pointing_pull.name^.(Identifier); ok {
		name = id.name
	} else {
		// Complex expression
		enqueue_node(analyzer, pointing_pull.name, analyzer.current_scope)
		if pointing_pull.value != nil {
			enqueue_node(analyzer, pointing_pull.value, analyzer.current_scope)
		}
		return
	}

	// Create parameter symbol
	symbol := create_symbol(
		analyzer,
		name,
		node,
		analyzer.current_scope,
		.PullDefinition,
		position,
	)
	add_symbol(analyzer, symbol)

	if pointing_pull.value != nil {
		enqueue_node(analyzer, pointing_pull.value, analyzer.current_scope)
	}
}

// Process event push nodes (a >- b)
process_event_push :: proc(
	analyzer: ^Analyzer,
	node: ^Node,
	event_push: EventPush,
	position: Position,
) {
	// Anonymous event push
	if event_push.name == nil {
		if event_push.value != nil {
			enqueue_node(analyzer, event_push.value, analyzer.current_scope)
		}
		return
	}

	// Process target
	enqueue_node(analyzer, event_push.name, analyzer.current_scope)

	// Create event info
	event_info := Event_Info {
		is_push = true,
		node    = node,
	}

	// Handle identifier
	if id, ok := event_push.name^.(Identifier); ok {
		symbol := lookup_symbol(analyzer, id.name)
		if symbol != nil {
			event_info.event = symbol
			symbol.flags += {.IsEvent}
			add_reference(analyzer, symbol, node, .EventPush, position)
		} else {
			// Create implicit symbol
			symbol = create_symbol(
				analyzer,
				id.name,
				node,
				analyzer.current_scope,
				.Definition,
				position,
			)
			symbol.flags += {.IsEvent}
			add_symbol(analyzer, symbol)
			event_info.event = symbol
		}
	}

	// Process handler
	if event_push.value != nil {
		event_info.handler = event_push.value
		enqueue_node(analyzer, event_push.value, analyzer.current_scope)
	}

	// Add to events list
	append(&analyzer.current_scope.events, event_info)
}

// Process event pull nodes (a -< b)
process_event_pull :: proc(
	analyzer: ^Analyzer,
	node: ^Node,
	event_pull: EventPull,
	position: Position,
) {
	// Anonymous event pull
	if event_pull.name == nil {
		if event_pull.value != nil {
			enqueue_node(analyzer, event_pull.value, analyzer.current_scope)
		}
		return
	}

	// Process handler name
	name: string = ""
	if id, ok := event_pull.name^.(Identifier); ok {
		name = id.name
	} else {
		enqueue_node(analyzer, event_pull.name, analyzer.current_scope)
	}

	// Create event info
	event_info := Event_Info {
		is_push = false,
		node    = node,
	}

	// Handle identifier
	if name != "" {
		symbol := lookup_symbol(analyzer, name)
		if symbol == nil {
			symbol = create_symbol(
				analyzer,
				name,
				node,
				analyzer.current_scope,
				.Definition,
				position,
			)
			symbol.flags += {.IsEvent}
			add_symbol(analyzer, symbol)
		} else {
			add_reference(analyzer, symbol, node, .EventPull, position)
		}
		event_info.event = symbol
	}

	// Process handler
	if event_pull.value != nil {
		event_info.handler = event_pull.value
		enqueue_node(analyzer, event_pull.value, analyzer.current_scope)
	}

	// Add to events list
	append(&analyzer.current_scope.events, event_info)
}

// Process resonance push nodes (a >>- b)
process_resonance_push :: proc(
	analyzer: ^Analyzer,
	node: ^Node,
	resonance_push: ResonancePush,
	position: Position,
) {
	// Anonymous resonance push
	if resonance_push.name == nil {
		if resonance_push.value != nil {
			enqueue_node(analyzer, resonance_push.value, analyzer.current_scope)
		}
		return
	}

	// Process target
	enqueue_node(analyzer, resonance_push.name, analyzer.current_scope)

	// Create resonance info
	resonance_info := Resonance_Info {
		is_push = true,
		node    = node,
	}

	// Handle identifier target
	if id, ok := resonance_push.name^.(Identifier); ok {
		symbol := lookup_symbol(analyzer, id.name)
		if symbol != nil {
			resonance_info.target = symbol
			symbol.flags += {.IsDriven, .IsResonance}
			add_reference(analyzer, symbol, node, .ResonancePush, position)
		} else {
			add_error(analyzer, fmt.tprintf("Undefined resonance target '%s'", id.name), position)
		}
	}

	// Process driver
	if resonance_push.value != nil {
		enqueue_node(analyzer, resonance_push.value, analyzer.current_scope)

		// Set driver if it's an identifier
		if id, ok := resonance_push.value^.(Identifier); ok {
			driver := lookup_symbol(analyzer, id.name)
			if driver != nil {
				resonance_info.driver = driver
				if resonance_info.target != nil {
					resonance_info.target.driver = driver
				}
				add_reference(analyzer, driver, node, .ResonancePush, position)
			}
		}
	}

	// Add to resonances list
	append(&analyzer.current_scope.resonances, resonance_info)
}

// Process resonance pull nodes (a -<< b)
process_resonance_pull :: proc(
	analyzer: ^Analyzer,
	node: ^Node,
	resonance_pull: ResonancePull,
	position: Position,
) {
	// Anonymous resonance pull
	if resonance_pull.name == nil {
		if resonance_pull.value != nil {
			enqueue_node(analyzer, resonance_pull.value, analyzer.current_scope)
		}
		return
	}

	// Get name from identifier
	name: string = ""
	if id, ok := resonance_pull.name^.(Identifier); ok {
		name = id.name
	}

	// Process target
	enqueue_node(analyzer, resonance_pull.name, analyzer.current_scope)

	// Create resonance info
	resonance_info := Resonance_Info {
		is_push = false,
		node    = node,
	}

	// Handle identifier
	if name != "" {
		symbol := lookup_symbol(analyzer, name)
		if symbol == nil {
			symbol = create_symbol(
				analyzer,
				name,
				node,
				analyzer.current_scope,
				.Definition,
				position,
			)
			symbol.flags += {.IsResonance}
			add_symbol(analyzer, symbol)
		}
		resonance_info.target = symbol
		add_reference(analyzer, symbol, node, .ResonancePull, position)
	}

	// Process driver
	if resonance_pull.value != nil {
		enqueue_node(analyzer, resonance_pull.value, analyzer.current_scope)

		// Set driver if it's an identifier
		if id, ok := resonance_pull.value^.(Identifier); ok {
			driver := lookup_symbol(analyzer, id.name)
			if driver != nil {
				resonance_info.driver = driver
				add_reference(analyzer, driver, node, .ResonancePull, position)
			}
		}
	}

	// Add to resonances list
	append(&analyzer.current_scope.resonances, resonance_info)
}

// Process override nodes (a{...})
process_override :: proc(
	analyzer: ^Analyzer,
	node: ^Node,
	override: Override,
	position: Position,
) {
	// Process base
	if override.source != nil {
		enqueue_node(analyzer, override.source, analyzer.current_scope)

		// Check if source exists if it's an identifier
		if id, ok := override.source^.(Identifier); ok {
			symbol := lookup_symbol(analyzer, id.name)
			if symbol == nil {
				add_error(
					analyzer,
					fmt.tprintf("Cannot override undefined '%s'", id.name),
					position,
				)
			} else {
				add_reference(analyzer, symbol, node, .Override, position)
			}
		}
	}

	// Process overrides
	for i := 0; i < len(override.overrides); i += 1 {
		enqueue_node(analyzer, &override.overrides[i], analyzer.current_scope)
	}
}

// Process pattern match nodes (target ? {...})
process_pattern :: proc(analyzer: ^Analyzer, node: ^Node, pattern: Pattern, position: Position) {
	// Process target
	if pattern.target != nil {
		enqueue_node(analyzer, pattern.target, analyzer.current_scope)
	}

	// Create pattern scope
	pattern_scope := create_scope_for_node(analyzer, node, "", position)
	pattern_scope.is_pattern = true

	// Set up pattern context
	prev_scope := analyzer.current_scope
	prev_in_pattern := analyzer.in_pattern
	prev_pattern := analyzer.current_pattern

	analyzer.current_scope = pattern_scope
	analyzer.in_pattern = true
	analyzer.current_pattern = node

	// Process branches
	for i := 0; i < len(pattern.value); i += 1 {
		branch := pattern.value[i]

		// Create branch info
		branch_info := Branch_Info {
			pattern          = branch.source,
			result           = branch.product,
			captured_symbols = make(map[string]^Symbol),
		}

		// Process pattern and result
		if branch.source != nil {
			enqueue_node(analyzer, branch.source, pattern_scope)
		}
		if branch.product != nil {
			enqueue_node(analyzer, branch.product, pattern_scope)
		}

		// Add to branches list
		append(&pattern_scope.branches, branch_info)
	}

	// Restore context
	analyzer.in_pattern = prev_in_pattern
	analyzer.current_pattern = prev_pattern
	analyzer.current_scope = prev_scope
}

// Process constraint nodes (Type: value)
process_constraint :: proc(
	analyzer: ^Analyzer,
	node: ^Node,
	constraint: Constraint,
	position: Position,
) {
	// Safety check
	if constraint.constraint == nil {
		add_error(analyzer, "Constraint type is nil", position)
		return
	}

	// Get constraint symbol
	constraint_symbol: ^Symbol
	if id, ok := constraint.constraint^.(Identifier); ok {
		constraint_symbol = lookup_symbol(analyzer, id.name)
		if constraint_symbol == nil {
			add_error(analyzer, fmt.tprintf("Undefined constraint type '%s'", id.name), position)
		}
	} else {
		// Process complex constraint
		enqueue_node(analyzer, constraint.constraint, analyzer.current_scope)
	}

	// Nameless constraint
	if constraint.value == nil {
		// Create anonymous constrained symbol
		symbol := create_symbol(analyzer, "", node, analyzer.current_scope, .Definition, position)
		symbol.constraint = constraint_symbol
		symbol.flags += {.HasConstraint}
		add_symbol(analyzer, symbol)

		// Add constraint info
		constraint_info := Constraint_Info {
			target     = symbol,
			constraint = constraint_symbol,
			node       = node,
		}

		// Add to constraints list
		append(&analyzer.current_scope.constraints, constraint_info)
		return
	}

	// Get name from value if it's an identifier
	name: string = ""
	if id, ok := constraint.value^.(Identifier); ok {
		name = id.name
	} else {
		// Process complex value
		enqueue_node(analyzer, constraint.value, analyzer.current_scope)
	}

	// Create named symbol
	if name != "" {
		symbol := create_symbol(
			analyzer,
			name,
			node,
			analyzer.current_scope,
			.Definition,
			position,
		)
		symbol.constraint = constraint_symbol
		symbol.flags += {.HasConstraint}
		add_symbol(analyzer, symbol)

		// Add to constraint info
		constraint_info := Constraint_Info {
			target     = symbol,
			constraint = constraint_symbol,
			node       = node,
		}

		// Update cache for faster constraint checking
		analyzer.defined_symbols[name] = true

		// Add to constraints list
		append(&analyzer.current_scope.constraints, constraint_info)
	}
}

// Process product nodes (-> value)
process_product :: proc(analyzer: ^Analyzer, node: ^Node, product: Product, position: Position) {
	// Create anonymous symbol
	symbol := create_symbol(analyzer, "", node, analyzer.current_scope, .Definition, position)
	add_symbol(analyzer, symbol)

	// Process value
	if product.value != nil {
		enqueue_node(analyzer, product.value, analyzer.current_scope)
	}
}

// Process expand nodes (...expr)
process_expand :: proc(analyzer: ^Analyzer, node: ^Node, expand: Expand, position: Position) {
	// Process target
	if expand.target != nil {
		enqueue_node(analyzer, expand.target, analyzer.current_scope)

		// Check if it's an identifier for expansion
		if id, ok := expand.target^.(Identifier); ok {
			symbol := lookup_symbol(analyzer, id.name)
			if symbol == nil {
				add_error(analyzer, fmt.tprintf("Cannot expand undefined '%s'", id.name), position)
			} else {
				add_reference(analyzer, symbol, node, .Usage, position)

				// Add to expansions if it has a scope
				if symbol.defining_scope != nil {
					append(&analyzer.current_scope.expansions, symbol.defining_scope)

					// Invalidate visible symbols cache
					invalidate_visible_cache(analyzer.current_scope)
				}
			}
		}
	}
}

// Process identifier nodes
process_identifier :: proc(analyzer: ^Analyzer, node: ^Node, id: Identifier, position: Position) {
	// Fast lookup using name hash
	name_hash := calculate_symbol_hash(id.name)

	// Try cache lookup first (much faster)
	cache_key := generate_lookup_key(analyzer.current_scope, name_hash)
	if cached, found := analyzer.resolution_cache[cache_key]; found {
		if cached != nil {
			add_reference(analyzer, cached, node, .Usage, position)
		}
		return
	}

	// Regular lookup
	symbol := lookup_symbol(analyzer, id.name)

	if symbol == nil {
		// Fast check for constraint-defined symbols
		if analyzer.defined_symbols[id.name] {
			// Cache result
			analyzer.resolution_cache[cache_key] = nil
			return
		}

		// Create symbol in pattern context
		if analyzer.in_pattern {
			symbol = create_symbol(
				analyzer,
				id.name,
				node,
				analyzer.current_scope,
				.Definition,
				position,
			)
			add_symbol(analyzer, symbol)

			// Update cache
			analyzer.resolution_cache[cache_key] = symbol
		} else {
			add_error(analyzer, fmt.tprintf("Undefined symbol '%s'", id.name), position)

			// Cache negative result
			analyzer.resolution_cache[cache_key] = nil
		}
	} else {
		// Add reference and cache result
		add_reference(analyzer, symbol, node, .Usage, position)
		analyzer.resolution_cache[cache_key] = symbol
	}
}

// Fast position lookup
get_position_from_node :: proc(node: ^Node) -> Position {
	if node == nil {
		return Position{line = 0, column = 0, offset = 0}
	}

	#partial switch n in node^ {
	case Scope:
		return n.position
	case Pointing:
		return n.position
	case PointingPull:
		return n.position
	case EventPush:
		return n.position
	case EventPull:
		return n.position
	case ResonancePush:
		return n.position
	case ResonancePull:
		return n.position
	case Override:
		return n.position
	case Pattern:
		return n.position
	case Constraint:
		return n.position
	case Product:
		return n.position
	case Execute:
		return n.position
	case Expand:
		return n.position
	case Identifier:
		return n.position
	case Literal:
		return n.position
	case Operator:
		return n.position
	case Range:
		return n.position
	case Property:
		return n.position
	case Branch:
		return n.position
	case FileSystem:
		return n.position
	case:
		return Position{line = 0, column = 0, offset = 0}
	}
}

// ===========================================================================
// SECTION 5: VALIDATION
// ===========================================================================

// Combined validation in a single pass
validate_analysis :: proc(analyzer: ^Analyzer) {
	if len(analyzer.errors) > 50 do return // Skip if too many errors already

	// Validate global scope
	validate_scope(analyzer, analyzer.global_scope)
}

// Validate a scope and its children
validate_scope :: proc(analyzer: ^Analyzer, scope: ^Scope_Info) {
	if scope == nil || len(analyzer.errors) > 50 do return

	// Validate resonance bindings (most critical)
	validate_resonance_bindings_in_scope(analyzer, scope)

	// Check pattern exhaustiveness if this is a pattern scope
	if scope.is_pattern {
		check_exhaustiveness(analyzer, scope)
	}

	// Validate constraints if any
	if len(scope.constraints) > 0 {
		validate_constraints_in_scope(analyzer, scope)
	}

	// Recursively check nested scopes
	for sym in scope.symbol_list {
		if sym.defining_scope != nil {
			validate_scope(analyzer, sym.defining_scope)
		}
	}
}

// Optimized constraint validation
validate_constraints_in_scope :: proc(analyzer: ^Analyzer, scope: ^Scope_Info) {
	if scope == nil || len(analyzer.errors) > 50 do return

	// Process constraints in batch
	for constraint in scope.constraints {
		if constraint.constraint != nil && constraint.target != nil {
			// Flag valid constraint for faster lookups
			if constraint.target.name != "" {
				analyzer.defined_symbols[constraint.target.name] = true
			}

			// Structure validation would go here for complex constraints
		}
	}
}

// Optimized resonance binding validation
validate_resonance_bindings_in_scope :: proc(analyzer: ^Analyzer, scope: ^Scope_Info) {
	if scope == nil || len(scope.resonances) == 0 || len(analyzer.errors) > 50 do return

	// Use a map to track driven targets
	driven_targets := make(map[^Symbol]bool)
	defer delete(driven_targets)

	// Check all resonance bindings
	for resonance in scope.resonances {
		if resonance.target != nil && resonance.is_push {
			if driven_targets[resonance.target] {
				// Target already driven, report error
				add_error(
					analyzer,
					fmt.tprintf(
						"Symbol '%s' is driven by multiple resonances",
						resonance.target.name,
					),
					get_position_from_node(resonance.node),
				)
			} else {
				driven_targets[resonance.target] = true
			}
		}
	}
}

// Optimized pattern match exhaustiveness check
check_exhaustiveness :: proc(analyzer: ^Analyzer, scope: ^Scope_Info) {
	if scope == nil || !scope.is_pattern || scope.scope_symbol == nil do return

	// Look for catch-all patterns
	has_catchall := false

	// Simple heuristic: If we have a pattern with a single identifier, it's probably a catch-all
	for branch in scope.branches {
		if branch.pattern != nil {
			if _, is_id := branch.pattern^.(Identifier); is_id {
				has_catchall = true
				break
			}
		}
	}

	if !has_catchall && len(scope.branches) > 0 {
		add_warning(
			analyzer,
			"Pattern match may not be exhaustive",
			get_position_from_node(scope.scope_symbol.node),
		)
	}
}

// Optimized constraint definition check
is_defined_by_constraint :: proc(analyzer: ^Analyzer, name: string) -> bool {
	// Use cached result for speed
	return analyzer.defined_symbols[name]
}

// ===========================================================================
// SECTION 6: QUALIFIED NAMING AND UTILITIES
// ===========================================================================

// Get a fully qualified name for a symbol
get_qualified_name :: proc(symbol: ^Symbol) -> string {
	if symbol == nil {
		return "<nil>"
	}

	if symbol.name == "" {
		return "<anonymous>"
	}

	// For built-in types, just return the name
	if .Builtin in symbol.flags {
		return symbol.name
	}

	// For global scope, just return the name
	if symbol.scope != nil && symbol.scope.parent == nil {
		if symbol.index > 0 {
			return fmt.tprintf("%s@%d", symbol.name, symbol.index)
		}
		return symbol.name
	}

	// Otherwise build the qualified name
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	// Build path from root to symbol
	build_path_to_symbol(&builder, symbol)

	// Add index if needed
	if symbol.index > 0 {
		fmt.sbprintf(&builder, "@%d", symbol.index)
	}

	return strings.to_string(builder)
}

// Build a path to a symbol recursively
build_path_to_symbol :: proc(builder: ^strings.Builder, symbol: ^Symbol) {
	if symbol == nil || builder == nil {
		return
	}

	// Start with scope path
	if symbol.scope != nil && symbol.scope.parent != nil {
		// Build path to scope symbol first
		scope_sym := symbol.scope.scope_symbol
		if scope_sym != nil {
			build_path_to_symbol(builder, scope_sym)
			strings.write_string(builder, ".")
		}
	}

	// Add this symbol's name
	if symbol.name != "" {
		strings.write_string(builder, symbol.name)
	} else {
		strings.write_string(builder, "<anonymous>")
	}
}

// ===========================================================================
// SECTION 7: SCOPE GRAPH VISUALIZATION
// ===========================================================================

// Print the scope graph for debug purposes
print_scope_graph :: proc(analyzer: ^Analyzer) {
	fmt.println("\n=== SCOPE GRAPH SUMMARY ===")
	fmt.printf("Global scope: %d symbols\n", len(analyzer.global_scope.symbol_list))

	// Count total symbols
	total_symbols := count_symbols_recursive(analyzer.global_scope)
	fmt.printf("Total symbols: %d\n", total_symbols)

	// Count scopes
	total_scopes := count_scopes_recursive(analyzer.global_scope)
	fmt.printf("Total scopes: %d\n", total_scopes)

	fmt.println("=== END SCOPE GRAPH SUMMARY ===\n")
}

// Count total symbols recursively
count_symbols_recursive :: proc(scope: ^Scope_Info) -> int {
	if scope == nil {
		return 0
	}

	count := len(scope.symbol_list)

	for sym in scope.symbol_list {
		if sym.defining_scope != nil {
			count += count_symbols_recursive(sym.defining_scope)
		}
	}

	return count
}

// Count total scopes recursively
count_scopes_recursive :: proc(scope: ^Scope_Info) -> int {
	if scope == nil {
		return 0
	}

	count := 1 // Count this scope

	for sym in scope.symbol_list {
		if sym.defining_scope != nil {
			count += count_scopes_recursive(sym.defining_scope)
		}
	}

	return count
}

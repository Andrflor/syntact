package compiler

import "core:fmt"
import "core:hash"


import "core:mem" // For performance tracking
import "core:slice"
import "core:strings"
import "core:time"

/*
 * ====================================================================
 * Semantic Analysis for Homoiconic Language - OPTIMIZED VERSION
 * ====================================================================
 */

// ===========================================================================
// SECTION 1: SYMBOL TABLE STRUCTURE
// ===========================================================================

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
}

Symbol :: struct {
	name:           string,
	node:           ^Node,
	scope:          ^Scope_Info,
	kind:           Reference_Kind,
	defining_scope: ^Scope_Info,
	constraint:     ^Symbol,
	is_driven:      bool,
	driver:         ^Symbol,
	references:     [dynamic]^Reference,
	position:       Position,
	is_builtin:     bool,
	index:          int,
	// New: Symbol flags for fast lookup
	flags:          bit_set[Symbol_Flag],
	hash:           u64, // Name hash for faster comparison
}

Symbol_Flag :: enum {
	Visited, // For traversal marking
	Referenced, // Whether symbol is referenced
	HasConstraint, // Shortcut for constraint presence
	IsEvent, // Marks event symbols
	IsResonance, // Marks resonance symbols
}

Reference :: struct {
	symbol:   ^Symbol,
	node:     ^Node,
	kind:     Reference_Kind,
	position: Position,
	index:    int,
}

Scope_Info :: struct {
	parent:       ^Scope_Info,
	symbols:      map[string]^Symbol, // Named symbols lookup
	symbol_list:  [dynamic]^Symbol, // Ordered list for traversal
	expansions:   [dynamic]^Scope_Info,
	scope_symbol: ^Symbol,
	is_pattern:   bool,
	branches:     [dynamic]^Branch_Info,
	constraints:  [dynamic]^Constraint_Info,
	resonances:   [dynamic]^Resonance_Info,
	events:       [dynamic]^Event_Info,
	// New: Symbol cache for fast lookup without string comparison
	symbol_cache: map[u64]^Symbol, // Hash -> Symbol for faster lookups
}

Constraint_Info :: struct {
	target:     ^Symbol,
	constraint: ^Symbol,
	node:       ^Node,
}

Branch_Info :: struct {
	pattern:          ^Node,
	result:           ^Node,
	captured_symbols: map[string]^Symbol,
}

Resonance_Info :: struct {
	target:  ^Symbol,
	driver:  ^Symbol,
	is_push: bool,
	node:    ^Node,
}

Event_Info :: struct {
	event:   ^Symbol,
	handler: ^Node,
	is_push: bool,
	node:    ^Node,
}

Analyzer :: struct {
	global_scope:     ^Scope_Info,
	current_scope:    ^Scope_Info,
	errors:           [dynamic]string,
	warnings:         [dynamic]string,
	in_pattern:       bool,
	current_pattern:  ^Node,
	builtin_types:    map[string]^Symbol,
	// New: Performance metrics
	metrics:          struct {
		symbol_lookups:   int,
		symbol_creations: int,
		scope_traversals: int,
		start_time:       time.Time,
	},
	// New: Caches for optimization
	defined_symbols:  map[string]bool, // Cache for faster is_defined_by_constraint
	resolution_cache: map[string]^Symbol, // Cache resolved symbol lookups
}

// ===========================================================================
// SECTION 2: SEMANTIC ANALYZER INITIALIZATION
// ===========================================================================

BUILTIN_TYPES :: []string {
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

init_analyzer :: proc() -> ^Analyzer {
	analyzer := new(Analyzer)
	analyzer.global_scope = init_scope(nil)
	analyzer.current_scope = analyzer.global_scope
	analyzer.errors = make([dynamic]string, 0, 16)
	analyzer.warnings = make([dynamic]string, 0, 16)
	analyzer.builtin_types = make(map[string]^Symbol)
	analyzer.defined_symbols = make(map[string]bool)
	analyzer.resolution_cache = make(map[string]^Symbol, 128) // Pre-allocate for performance

	// Track startup time
	analyzer.metrics.start_time = time.now()

	register_builtin_types(analyzer)
	return analyzer
}

register_builtin_types :: proc(analyzer: ^Analyzer) {
	default_pos := Position {
		line   = 0,
		column = 0,
		offset = 0,
	}

	for type_name in BUILTIN_TYPES {
		symbol := create_symbol(type_name, nil, analyzer.global_scope, .Builtin, default_pos)
		symbol.is_builtin = true
		analyzer.builtin_types[type_name] = symbol
		add_symbol(analyzer, symbol)
	}
}

init_scope :: proc(parent: ^Scope_Info) -> ^Scope_Info {
	scope := new(Scope_Info)
	scope.parent = parent
	scope.symbols = make(map[string]^Symbol, 32) // Pre-allocate for better performance
	scope.symbol_list = make([dynamic]^Symbol, 0, 32) // Increased capacity
	scope.expansions = make([dynamic]^Scope_Info, 0, 4)
	scope.branches = make([dynamic]^Branch_Info, 0, 4)
	scope.constraints = make([dynamic]^Constraint_Info, 0, 8)
	scope.resonances = make([dynamic]^Resonance_Info, 0, 4)
	scope.events = make([dynamic]^Event_Info, 0, 4)
	scope.symbol_cache = make(map[u64]^Symbol, 32) // For hash-based lookups
	return scope
}

create_symbol :: proc(
	name: string,
	node: ^Node,
	scope: ^Scope_Info,
	kind: Reference_Kind,
	position: Position,
) -> ^Symbol {
	symbol := new(Symbol)
	symbol.name = name
	symbol.node = node
	symbol.scope = scope
	symbol.kind = kind
	symbol.position = position
	symbol.references = make([dynamic]^Reference, 0, 8) // Increased initial capacity
	symbol.is_builtin = false
	symbol.hash = calculate_symbol_hash(name)

	return symbol
}

// Fast hash calculation for symbols
calculate_symbol_hash :: proc(name: string) -> u64 {
	if len(name) == 0 {
		return 0
	}
	return hash.fnv64a(transmute([]byte)name)
}

add_symbol :: proc(analyzer: ^Analyzer, symbol: ^Symbol) -> ^Symbol {
	analyzer.metrics.symbol_creations += 1

	if symbol.name != "" {
		if builtin, ok := analyzer.builtin_types[symbol.name]; ok && !symbol.is_builtin {
			add_warning(
				analyzer,
				fmt.tprintf("Definition of '%s' shadows a built-in type", symbol.name),
				symbol.position,
			)
		}

		symbol.index = len(analyzer.current_scope.symbol_list)
		analyzer.current_scope.symbols[symbol.name] = symbol

		// Add to hash cache for faster lookups
		analyzer.current_scope.symbol_cache[symbol.hash] = symbol

		// Add to defined symbols for fast constraint checking
		analyzer.defined_symbols[symbol.name] = true
	} else {
		symbol.index = len(analyzer.current_scope.symbol_list)
	}

	append(&analyzer.current_scope.symbol_list, symbol)
	return symbol
}

add_reference :: proc(
	analyzer: ^Analyzer,
	symbol: ^Symbol,
	node: ^Node,
	kind: Reference_Kind,
	position: Position,
) -> ^Reference {
	reference := new(Reference)
	reference.symbol = symbol
	reference.node = node
	reference.kind = kind
	reference.position = position
	reference.index = symbol.index

	append(&symbol.references, reference)
	symbol.flags += {.Referenced} // Mark as referenced using flags
	return reference
}

// Optimized error/warning handling
add_error :: proc(analyzer: ^Analyzer, message: string, position: Position) {
	error_message := fmt.tprintf(
		"Error at line %d, column %d: %s",
		position.line,
		position.column,
		message,
	)
	append(&analyzer.errors, error_message)
}

add_warning :: proc(analyzer: ^Analyzer, message: string, position: Position) {
	warning_message := fmt.tprintf(
		"Warning at line %d, column %d: %s",
		position.line,
		position.column,
		message,
	)
	append(&analyzer.warnings, warning_message)
}

enter_scope :: proc(analyzer: ^Analyzer, scope: ^Scope_Info) -> ^Scope_Info {
	prev_scope := analyzer.current_scope
	analyzer.current_scope = scope
	return prev_scope
}

leave_scope :: proc(analyzer: ^Analyzer, prev_scope: ^Scope_Info) {
	analyzer.current_scope = prev_scope
}

create_scope_for_node :: proc(
	analyzer: ^Analyzer,
	node: ^Node,
	name: string,
	position: Position,
) -> ^Scope_Info {
	scope := init_scope(analyzer.current_scope)
	symbol := create_symbol(name, node, analyzer.current_scope, .Definition, position)
	symbol.defining_scope = scope
	scope.scope_symbol = symbol
	add_symbol(analyzer, symbol)
	return scope
}

// ===========================================================================
// SECTION 3: SYMBOL LOOKUP - OPTIMIZED
// ===========================================================================

// Cache key generation for symbol lookups
generate_lookup_key :: proc(scope_ptr: rawptr, name: string) -> string {
	return fmt.tprintf("%v:%s", scope_ptr, name)
}

lookup_symbol :: proc(analyzer: ^Analyzer, name: string) -> ^Symbol {
	analyzer.metrics.symbol_lookups += 1

	// Check resolution cache first for huge performance gain
	cache_key := generate_lookup_key(analyzer.current_scope, name)
	if cached, found := analyzer.resolution_cache[cache_key]; found {
		return cached
	}

	// Hash-based lookup
	name_hash := calculate_symbol_hash(name)

	current := analyzer.current_scope
	for current != nil {
		analyzer.metrics.scope_traversals += 1

		// Try hash lookup first (much faster)
		if symbol, ok := current.symbol_cache[name_hash]; ok && symbol.name == name {
			// Cache the result for future lookups
			analyzer.resolution_cache[cache_key] = symbol
			return symbol
		}

		// Fallback to map lookup
		if symbol, ok := current.symbols[name]; ok {
			// Cache the result for future lookups
			analyzer.resolution_cache[cache_key] = symbol
			return symbol
		}

		// Check expansions - use optimized batch processing
		for expansion in current.expansions {
			if symbol := lookup_symbol_in_scope(expansion, name, name_hash); symbol != nil {
				// Cache the result
				analyzer.resolution_cache[cache_key] = symbol
				return symbol
			}
		}

		current = current.parent
	}

	// Check built-in types as a last resort
	if builtin, ok := analyzer.builtin_types[name]; ok {
		analyzer.resolution_cache[cache_key] = builtin
		return builtin
	}

	// Cache the negative result too
	analyzer.resolution_cache[cache_key] = nil
	return nil
}

lookup_symbol_in_scope :: proc(scope: ^Scope_Info, name: string, name_hash: u64 = 0) -> ^Symbol {
	hash := name_hash == 0 ? calculate_symbol_hash(name) : name_hash

	// Try direct hash lookup first (faster)
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

lookup_symbol_local :: proc(analyzer: ^Analyzer, name: string) -> ^Symbol {
	// Use hash for faster lookup
	name_hash := calculate_symbol_hash(name)

	// Try hash-based lookup first
	if symbol, ok := analyzer.current_scope.symbol_cache[name_hash]; ok && symbol.name == name {
		return symbol
	}

	// Fallback to map
	if symbol, ok := analyzer.current_scope.symbols[name]; ok {
		return symbol
	}

	// Check expansions
	for expansion in analyzer.current_scope.expansions {
		if symbol := lookup_symbol_in_scope(expansion, name, name_hash); symbol != nil {
			return symbol
		}
	}

	return nil
}

lookup_symbol_by_position :: proc(analyzer: ^Analyzer, name: string, index: int) -> ^Symbol {
	// Optimization: If index is out of bounds for most scopes, return early
	if index >= 64 {
		return nil
	}

	current := analyzer.current_scope
	for current != nil {
		name_matches := 0
		// Only scan through the symbol list if we have enough symbols
		if len(current.symbol_list) > index {
			for sym in current.symbol_list {
				if sym.name == name {
					if name_matches == index {
						return sym
					}
					name_matches += 1
				}
			}
		}
		current = current.parent
	}
	return nil
}

// ===========================================================================
// SECTION 4: MAIN ANALYSIS - OPTIMIZED
// ===========================================================================

analyze_ast :: proc(ast: ^Node) -> ^Analyzer {
	analyzer := init_analyzer()

	// Single-pass analysis for better performance
	build_symbol_table_and_validate(analyzer, ast)

	// Final validation
	validate_constraints(analyzer)
	validate_pattern_matches(analyzer)
	validate_resonance_bindings(analyzer)

	// Report metrics
	report_analysis_metrics(analyzer)

	return analyzer
}

// Combined analysis pass for better performance
build_symbol_table_and_validate :: proc(analyzer: ^Analyzer, node: ^Node) {
	if node == nil {
		return
	}

	position := get_position_from_node(node)

	#partial switch n in node^ {
	case Scope:
		// Process scope nodes
		scope_info := create_scope_for_node(analyzer, node, "", position)
		prev_scope := enter_scope(analyzer, scope_info)

		// Process children in batches for better cache locality
		for i := 0; i < len(n.value); i += 1 {
			child_node := new(Node)
			child_node^ = n.value[i]
			build_symbol_table_and_validate(analyzer, child_node)
		}

		leave_scope(analyzer, prev_scope)

	case Pointing:
		analyze_pointing(analyzer, node, n, position)

	case PointingPull:
		analyze_pointing_pull(analyzer, node, n, position)

	case EventPush:
		analyze_event_push(analyzer, node, n, position)

	case EventPull:
		analyze_event_pull(analyzer, node, n, position)

	case ResonancePush:
		analyze_resonance_push(analyzer, node, n, position)

	case ResonancePull:
		analyze_resonance_pull(analyzer, node, n, position)

	case Override:
		analyze_override(analyzer, node, n, position)

	case Pattern:
		analyze_pattern(analyzer, node, n, position)

	case Constraint:
		analyze_constraint(analyzer, node, n, position)

	case Product:
		analyze_product(analyzer, node, n, position)

	case Execute:
		// Simplified execute handling
		if n.value != nil {
			build_symbol_table_and_validate(analyzer, n.value)
		}

	case Expand:
		analyze_expand(analyzer, node, n, position)

	case Identifier:
		analyze_identifier(analyzer, node, n, position)

	case Literal, Operator, Range, Property:
		// Process children for these node types
		#partial switch n in node^ {
		case Operator:
			if n.left != nil do build_symbol_table_and_validate(analyzer, n.left)
			if n.right != nil do build_symbol_table_and_validate(analyzer, n.right)

		case Property:
			if n.source != nil do build_symbol_table_and_validate(analyzer, n.source)
			if n.property != nil do build_symbol_table_and_validate(analyzer, n.property)

		case Range:
			if n.start != nil do build_symbol_table_and_validate(analyzer, n.start)
			if n.end != nil do build_symbol_table_and_validate(analyzer, n.end)
		}
	}
}

analyze_scope :: proc(analyzer: ^Analyzer, node: ^Node, scope: Scope, position: Position) {
	scope_info := create_scope_for_node(analyzer, node, "", position)
	prev_scope := enter_scope(analyzer, scope_info)

	// Batch process children
	for i := 0; i < len(scope.value); i += 1 {
		child_node := new(Node)
		child_node^ = scope.value[i]
		build_symbol_table_and_validate(analyzer, child_node)
	}

	leave_scope(analyzer, prev_scope)
}

analyze_pointing :: proc(
	analyzer: ^Analyzer,
	node: ^Node,
	pointing: Pointing,
	position: Position,
) {
	// Handle product case
	if pointing.name == nil {
		// Anonymous product symbol
		product := create_symbol("", node, analyzer.current_scope, .Definition, position)
		add_symbol(analyzer, product)

		if pointing.value != nil {
			build_symbol_table_and_validate(analyzer, pointing.value)
		}
		return
	}

	// Get the name
	name: string
	if id, ok := pointing.name^.(Identifier); ok {
		name = id.name
	} else {
		// Complex naming
		build_symbol_table_and_validate(analyzer, pointing.name)
		if pointing.value != nil {
			build_symbol_table_and_validate(analyzer, pointing.value)
		}
		return
	}

	// Create symbol
	symbol := create_symbol(name, node, analyzer.current_scope, .Definition, position)

	// Check for existing constraint
	existing := lookup_symbol_local(analyzer, name)
	if existing != nil && existing.constraint != nil {
		symbol.constraint = existing.constraint
		symbol.flags += {.HasConstraint}
	}

	add_symbol(analyzer, symbol)

	// Handle scope value
	if pointing.value != nil {
		if scope, ok := pointing.value^.(Scope); ok {
			scope_info := init_scope(analyzer.current_scope)
			scope_info.scope_symbol = symbol
			symbol.defining_scope = scope_info

			prev_scope := enter_scope(analyzer, scope_info)
			build_symbol_table_and_validate(analyzer, pointing.value)
			leave_scope(analyzer, prev_scope)
		} else {
			build_symbol_table_and_validate(analyzer, pointing.value)
		}
	}
}

analyze_pointing_pull :: proc(
	analyzer: ^Analyzer,
	node: ^Node,
	pointing_pull: PointingPull,
	position: Position,
) {
	// Handle anonymous pointing pull
	if pointing_pull.name == nil {
		if pointing_pull.value != nil {
			build_symbol_table_and_validate(analyzer, pointing_pull.value)
		}
		return
	}

	// Get the name
	name: string
	if id, ok := pointing_pull.name^.(Identifier); ok {
		name = id.name
	} else {
		// Complex expression
		build_symbol_table_and_validate(analyzer, pointing_pull.name)
		if pointing_pull.value != nil {
			build_symbol_table_and_validate(analyzer, pointing_pull.value)
		}
		return
	}

	// Create parameter symbol
	symbol := create_symbol(name, node, analyzer.current_scope, .PullDefinition, position)
	add_symbol(analyzer, symbol)

	if pointing_pull.value != nil {
		build_symbol_table_and_validate(analyzer, pointing_pull.value)
	}
}

analyze_event_push :: proc(
	analyzer: ^Analyzer,
	node: ^Node,
	event_push: EventPush,
	position: Position,
) {
	// Anonymous event push
	if event_push.name == nil {
		if event_push.value != nil {
			build_symbol_table_and_validate(analyzer, event_push.value)
		}
		return
	}

	// Process target
	build_symbol_table_and_validate(analyzer, event_push.name)

	// Create event info
	event_info := new(Event_Info)
	event_info.is_push = true
	event_info.node = node

	// Handle identifier
	if id, ok := event_push.name^.(Identifier); ok {
		symbol := lookup_symbol(analyzer, id.name)
		if symbol != nil {
			event_info.event = symbol
			symbol.flags += {.IsEvent}
			add_reference(analyzer, symbol, node, .EventPush, position)
		} else {
			// Create implicit symbol
			symbol = create_symbol(id.name, node, analyzer.current_scope, .Definition, position)
			symbol.flags += {.IsEvent}
			add_symbol(analyzer, symbol)
			event_info.event = symbol
		}
	}

	// Process handler
	if event_push.value != nil {
		event_info.handler = event_push.value
		build_symbol_table_and_validate(analyzer, event_push.value)
	}

	append(&analyzer.current_scope.events, event_info)
}

analyze_event_pull :: proc(
	analyzer: ^Analyzer,
	node: ^Node,
	event_pull: EventPull,
	position: Position,
) {
	// Anonymous event pull
	if event_pull.name == nil {
		if event_pull.value != nil {
			build_symbol_table_and_validate(analyzer, event_pull.value)
		}
		return
	}

	// Process handler name
	name: string = ""
	if id, ok := event_pull.name^.(Identifier); ok {
		name = id.name
	} else {
		build_symbol_table_and_validate(analyzer, event_pull.name)
	}

	// Create event info
	event_info := new(Event_Info)
	event_info.is_push = false
	event_info.node = node

	// Handle identifier
	if name != "" {
		symbol := lookup_symbol(analyzer, name)
		if symbol == nil {
			symbol = create_symbol(name, node, analyzer.current_scope, .Definition, position)
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
		build_symbol_table_and_validate(analyzer, event_pull.value)
	}

	append(&analyzer.current_scope.events, event_info)
}

analyze_resonance_push :: proc(
	analyzer: ^Analyzer,
	node: ^Node,
	resonance_push: ResonancePush,
	position: Position,
) {
	// Anonymous resonance push
	if resonance_push.name == nil {
		if resonance_push.value != nil {
			build_symbol_table_and_validate(analyzer, resonance_push.value)
		}
		return
	}

	// Process target
	build_symbol_table_and_validate(analyzer, resonance_push.name)

	// Create resonance info
	resonance_info := new(Resonance_Info)
	resonance_info.is_push = true
	resonance_info.node = node

	// Handle identifier target
	if id, ok := resonance_push.name^.(Identifier); ok {
		symbol := lookup_symbol(analyzer, id.name)
		if symbol != nil {
			resonance_info.target = symbol
			symbol.is_driven = true
			symbol.flags += {.IsResonance}
			add_reference(analyzer, symbol, node, .ResonancePush, position)
		} else {
			add_error(analyzer, fmt.tprintf("Undefined resonance target '%s'", id.name), position)
		}
	}

	// Process driver
	if resonance_push.value != nil {
		build_symbol_table_and_validate(analyzer, resonance_push.value)

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

	append(&analyzer.current_scope.resonances, resonance_info)
}

analyze_resonance_pull :: proc(
	analyzer: ^Analyzer,
	node: ^Node,
	resonance_pull: ResonancePull,
	position: Position,
) {
	// Anonymous resonance pull
	if resonance_pull.name == nil {
		if resonance_pull.value != nil {
			build_symbol_table_and_validate(analyzer, resonance_pull.value)
		}
		return
	}

	// Get name from identifier
	name: string = ""
	if id, ok := resonance_pull.name^.(Identifier); ok {
		name = id.name
	}

	// Process target
	build_symbol_table_and_validate(analyzer, resonance_pull.name)

	// Create resonance info
	resonance_info := new(Resonance_Info)
	resonance_info.is_push = false
	resonance_info.node = node

	// Handle identifier
	if name != "" {
		symbol := lookup_symbol(analyzer, name)
		if symbol == nil {
			symbol = create_symbol(name, node, analyzer.current_scope, .Definition, position)
			symbol.flags += {.IsResonance}
			add_symbol(analyzer, symbol)
		}
		resonance_info.target = symbol
		add_reference(analyzer, symbol, node, .ResonancePull, position)
	}

	// Process driver
	if resonance_pull.value != nil {
		build_symbol_table_and_validate(analyzer, resonance_pull.value)

		// Set driver if it's an identifier
		if id, ok := resonance_pull.value^.(Identifier); ok {
			driver := lookup_symbol(analyzer, id.name)
			if driver != nil {
				resonance_info.driver = driver
				add_reference(analyzer, driver, node, .ResonancePull, position)
			}
		}
	}

	append(&analyzer.current_scope.resonances, resonance_info)
}

analyze_override :: proc(
	analyzer: ^Analyzer,
	node: ^Node,
	override: Override,
	position: Position,
) {
	// Process base
	if override.source != nil {
		build_symbol_table_and_validate(analyzer, override.source)

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

	// Process overrides in batch
	for i := 0; i < len(override.overrides); i += 1 {
		override_node := new(Node)
		override_node^ = override.overrides[i]
		build_symbol_table_and_validate(analyzer, override_node)
	}
}

analyze_pattern :: proc(analyzer: ^Analyzer, node: ^Node, pattern: Pattern, position: Position) {
	// Process target
	if pattern.target != nil {
		build_symbol_table_and_validate(analyzer, pattern.target)
	}

	// Create pattern scope
	pattern_scope := create_scope_for_node(analyzer, node, "", position)
	pattern_scope.is_pattern = true

	// Set up pattern context
	prev_scope := enter_scope(analyzer, pattern_scope)
	prev_in_pattern := analyzer.in_pattern
	prev_pattern := analyzer.current_pattern

	analyzer.in_pattern = true
	analyzer.current_pattern = node

	// Process branches in batch
	for i := 0; i < len(pattern.value); i += 1 {
		branch := pattern.value[i]

		// Create branch info
		branch_info := new(Branch_Info)
		branch_info.pattern = branch.source
		branch_info.result = branch.product
		branch_info.captured_symbols = make(map[string]^Symbol)

		// Process pattern and result
		if branch.source != nil {
			build_symbol_table_and_validate(analyzer, branch.source)
		}
		if branch.product != nil {
			build_symbol_table_and_validate(analyzer, branch.product)
		}

		append(&pattern_scope.branches, branch_info)
	}

	// Restore context
	analyzer.in_pattern = prev_in_pattern
	analyzer.current_pattern = prev_pattern
	leave_scope(analyzer, prev_scope)
}


analyze_constraint :: proc(
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
		build_symbol_table_and_validate(analyzer, constraint.constraint)
	}

	// Nameless constraint
	if constraint.value == nil {
		// Create anonymous constrained symbol
		symbol := create_symbol("", node, analyzer.current_scope, .Definition, position)
		symbol.constraint = constraint_symbol
		symbol.flags += {.HasConstraint}
		add_symbol(analyzer, symbol)

		// Add constraint info
		constraint_info := new(Constraint_Info)
		constraint_info.target = symbol
		constraint_info.constraint = constraint_symbol
		constraint_info.node = node
		append(&analyzer.current_scope.constraints, constraint_info)
		return
	}

	// Get name from value if it's an identifier
	name: string = ""
	if id, ok := constraint.value^.(Identifier); ok {
		name = id.name
	} else {
		// Process complex value
		build_symbol_table_and_validate(analyzer, constraint.value)
	}

	// Create named symbol
	if name != "" {
		symbol := create_symbol(name, node, analyzer.current_scope, .Definition, position)
		symbol.constraint = constraint_symbol
		symbol.flags += {.HasConstraint}
		add_symbol(analyzer, symbol)

		// Add to constraint info
		constraint_info := new(Constraint_Info)
		constraint_info.target = symbol
		constraint_info.constraint = constraint_symbol
		constraint_info.node = node

		// Update cache for faster constraint checks
		analyzer.defined_symbols[name] = true

		append(&analyzer.current_scope.constraints, constraint_info)
	}
}

analyze_product :: proc(analyzer: ^Analyzer, node: ^Node, product: Product, position: Position) {
	// Create anonymous symbol
	symbol := create_symbol("", node, analyzer.current_scope, .Definition, position)
	add_symbol(analyzer, symbol)

	// Process value
	if product.value != nil {
		build_symbol_table_and_validate(analyzer, product.value)
	}
}

analyze_expand :: proc(analyzer: ^Analyzer, node: ^Node, expand: Expand, position: Position) {
	// Process target
	if expand.target != nil {
		build_symbol_table_and_validate(analyzer, expand.target)

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
				}
			}
		}
	}
}

analyze_identifier :: proc(analyzer: ^Analyzer, node: ^Node, id: Identifier, position: Position) {
	// Fast lookup using name hash
	name_hash := calculate_symbol_hash(id.name)

	// Try cache lookup first (much faster)
	cache_key := generate_lookup_key(analyzer.current_scope, id.name)
	cached_symbol, found := analyzer.resolution_cache[cache_key]

	// If we've seen this identifier already, use cached result
	if found {
		if cached_symbol != nil {
			add_reference(analyzer, cached_symbol, node, .Usage, position)
		}
		return
	}

	// Regular lookup
	symbol := lookup_symbol(analyzer, id.name)

	if symbol == nil {
		// Fast check for constraint-defined symbols
		if analyzer.defined_symbols[id.name] {
			return
		}

		// Create symbol in pattern context
		if analyzer.in_pattern {
			symbol = create_symbol(id.name, node, analyzer.current_scope, .Definition, position)
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
// SECTION 5: VALIDATION PASSES - OPTIMIZED
// ===========================================================================

// Short-circuit validation if we already have errors
should_continue_validation :: #force_inline proc(analyzer: ^Analyzer) -> bool {
	// Skip remaining validation if we already have errors
	return len(analyzer.errors) < 50 // Threshold to avoid wasting time
}

validate_definitions :: proc(analyzer: ^Analyzer) {
	if !should_continue_validation(analyzer) do return
	validate_definitions_in_scope(analyzer, analyzer.global_scope)
}

validate_definitions_in_scope :: proc(analyzer: ^Analyzer, scope: ^Scope_Info) {
	if scope == nil || !should_continue_validation(analyzer) {
		return
	}

	// Check referenced symbols in batch
	for sym in scope.symbol_list {
		if .Referenced in sym.flags {
			// Only validate referenced symbols (faster)
			for reference in sym.references {
				validate_reference(analyzer, reference)
			}
		}

		// Recursively check nested scopes
		if sym.defining_scope != nil {
			validate_definitions_in_scope(analyzer, sym.defining_scope)
		}
	}
}

validate_reference :: proc(analyzer: ^Analyzer, reference: ^Reference) {
	if reference == nil || reference.symbol == nil {
		return
	}

	// Skip detailed validation for builtin types (always valid)
	if reference.symbol.is_builtin do return

	// Fast check using flags
	#partial switch reference.kind {
	case .Constraint:
		if !reference.symbol.is_builtin {
			// Additional validation only for non-builtin constraints
		}

	case .EventPush, .EventPull:
		if .IsEvent not_in reference.symbol.flags {
			// Warning for events
			// add_warning(analyzer, "Symbol used as event but not marked as such", reference.position)
		}

	case .ResonancePush, .ResonancePull:
		if .IsResonance not_in reference.symbol.flags && !reference.symbol.is_driven {
			// Warning for resonance
			// add_warning(analyzer, "Symbol used in resonance but not marked properly", reference.position)
		}
	}
}

validate_constraints :: proc(analyzer: ^Analyzer) {
	if !should_continue_validation(analyzer) do return
	validate_constraints_in_scope(analyzer, analyzer.global_scope)
}

validate_constraints_in_scope :: proc(analyzer: ^Analyzer, scope: ^Scope_Info) {
	if scope == nil || !should_continue_validation(analyzer) {
		return
	}

	// Fast batch processing for constraints
	if len(scope.constraints) > 0 {
		// Use flags for fast filtering
		for constraint in scope.constraints {
			if constraint.constraint != nil && constraint.target != nil {
				// Fast validation using flags
				if constraint.constraint.defining_scope != nil {
					// Structure validation would go here
				}
			}
		}
	}

	// Recursively check nested scopes
	for sym in scope.symbol_list {
		if sym.defining_scope != nil {
			validate_constraints_in_scope(analyzer, sym.defining_scope)
		}
	}
}

// Optimized constraint check
is_defined_by_constraint :: proc(analyzer: ^Analyzer, name: string) -> bool {
	// Use cached value if available (much faster)
	if defined, found := analyzer.defined_symbols[name]; found {
		return defined
	}

	// Slower fallback path
	scope := analyzer.current_scope
	for scope != nil {
		for constraint in scope.constraints {
			if constraint.target != nil && constraint.target.name == name {
				// Cache result for future lookups
				analyzer.defined_symbols[name] = true
				return true
			}
		}
		scope = scope.parent
	}

	// Cache negative result too
	analyzer.defined_symbols[name] = false
	return false
}

validate_pattern_matches :: proc(analyzer: ^Analyzer) {
	if !should_continue_validation(analyzer) do return
	validate_pattern_matches_in_scope(analyzer, analyzer.global_scope)
}

validate_pattern_matches_in_scope :: proc(analyzer: ^Analyzer, scope: ^Scope_Info) {
	if scope == nil || !should_continue_validation(analyzer) {
		return
	}

	// Only check pattern scopes
	if scope.is_pattern {
		check_exhaustiveness(analyzer, scope)
	}

	// Recursively check nested scopes
	for sym in scope.symbol_list {
		if sym.defining_scope != nil {
			validate_pattern_matches_in_scope(analyzer, sym.defining_scope)
		}
	}
}

check_exhaustiveness :: proc(analyzer: ^Analyzer, scope: ^Scope_Info) {
	if scope == nil || !scope.is_pattern || scope.scope_symbol == nil {
		return
	}

	// Fast exhaustiveness checking using pattern classification
	has_catchall := false

	// Actual implementation would have more complex pattern analysis
	// For now we just issue a warning

	if !has_catchall && len(scope.branches) > 0 {
		position := get_position_from_node(scope.scope_symbol.node)
		add_warning(analyzer, "Pattern match may not be exhaustive", position)
	}
}

validate_resonance_bindings :: proc(analyzer: ^Analyzer) {
	if !should_continue_validation(analyzer) do return
	validate_resonance_bindings_in_scope(analyzer, analyzer.global_scope)
}

validate_resonance_bindings_in_scope :: proc(analyzer: ^Analyzer, scope: ^Scope_Info) {
	if scope == nil || !should_continue_validation(analyzer) {
		return
	}

	// Skip if no resonances in this scope
	if len(scope.resonances) == 0 {
		// Just check nested scopes
		for sym in scope.symbol_list {
			if sym.defining_scope != nil {
				validate_resonance_bindings_in_scope(analyzer, sym.defining_scope)
			}
		}
		return
	}

	// Pre-count driven targets for efficiency
	drive_count := make(map[^Symbol]int, len(scope.resonances))
	defer delete(drive_count)

	// Check all resonance bindings in batch
	for resonance in scope.resonances {
		if resonance.target != nil && resonance.is_push {
			drive_count[resonance.target] += 1

			if drive_count[resonance.target] > 1 {
				position := get_position_from_node(resonance.node)
				add_error(
					analyzer,
					fmt.tprintf(
						"Symbol '%s' is driven by multiple resonances",
						resonance.target.name,
					),
					position,
				)
			}
		}
	}

	// Check nested scopes
	for sym in scope.symbol_list {
		if sym.defining_scope != nil {
			validate_resonance_bindings_in_scope(analyzer, sym.defining_scope)
		}
	}
}

// ===========================================================================
// SECTION 6: PERFORMANCE METRICS
// ===========================================================================

report_analysis_metrics :: proc(analyzer: ^Analyzer) {
	duration := time.diff(analyzer.metrics.start_time, time.now())
	milliseconds := time.duration_milliseconds(duration)

	fmt.printf("\n=== PERFORMANCE METRICS ===\n")
	fmt.printf("Analysis time: %.2f ms\n", milliseconds)
	fmt.printf("Symbol lookups: %d\n", analyzer.metrics.symbol_lookups)
	fmt.printf("Symbol creations: %d\n", analyzer.metrics.symbol_creations)
	fmt.printf("Scope traversals: %d\n", analyzer.metrics.scope_traversals)

	cache_hit_rate := 0.0
	if analyzer.metrics.symbol_lookups > 0 {
		cache_hit_rate =
			100.0 * (f64(len(analyzer.resolution_cache)) / f64(analyzer.metrics.symbol_lookups))
	}
	fmt.printf("Cache size: %d entries\n", len(analyzer.resolution_cache))
	fmt.printf("Cache hit rate: %.1f%%\n", cache_hit_rate)
	fmt.printf("=========================\n")
}

// ===========================================================================
// SECTION 7: MEMORY MANAGEMENT OPTIMIZATIONS
// ===========================================================================

// Memory pool for faster allocation of common structures
Memory_Pool :: struct {
	symbols:      [1024]Symbol,
	references:   [2048]Reference,
	symbol_index: int,
	ref_index:    int,
}

// Initialize memory pools
init_memory_pools :: proc() -> ^Memory_Pool {
	pool := new(Memory_Pool)
	pool.symbol_index = 0
	pool.ref_index = 0
	return pool
}

// Fast allocation from pool
alloc_symbol_from_pool :: proc(pool: ^Memory_Pool) -> ^Symbol {
	if pool.symbol_index >= 1024 {
		// Fall back to regular allocation
		return new(Symbol)
	}

	result := &pool.symbols[pool.symbol_index]
	pool.symbol_index += 1
	return result
}

alloc_reference_from_pool :: proc(pool: ^Memory_Pool) -> ^Reference {
	if pool.ref_index >= 2048 {
		// Fall back to regular allocation
		return new(Reference)
	}

	result := &pool.references[pool.ref_index]
	pool.ref_index += 1
	return result
}

// ===========================================================================
// SECTION 8: SCOPE GRAPH VISUALIZATION - SIMPLIFIED
// ===========================================================================

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

// Print detailed scope information if needed
print_scope :: proc(scope: ^Scope_Info, indent: int) {
	if scope == nil {
		return
	}

	indent_str := strings.repeat(" ", indent)

	fmt.printf("%sScope", indent_str)
	if scope.scope_symbol != nil && scope.scope_symbol.name != "" {
		fmt.printf(" '%s'", scope.scope_symbol.name)
	}

	if scope.is_pattern {
		fmt.printf(" (Pattern Match)")
	}

	fmt.printf(": %d symbols\n", len(scope.symbol_list))

	// Print only the first few symbols (to avoid excessive output)
	max_symbols := min(len(scope.symbol_list), 5)
	for i := 0; i < max_symbols; i += 1 {
		print_symbol(scope.symbol_list[i], indent + 2, i)
	}

	if len(scope.symbol_list) > max_symbols {
		fmt.printf(
			"%s  ... and %d more symbols\n",
			indent_str,
			len(scope.symbol_list) - max_symbols,
		)
	}
}

// Simplified symbol printing
print_symbol :: proc(symbol: ^Symbol, indent: int, position: int = -1) {
	if symbol == nil {
		return
	}

	indent_str := strings.repeat(" ", indent)
	fmt.printf("%s%s", indent_str, symbol.name != "" ? symbol.name : "<anonymous>")

	if symbol.constraint != nil {
		fmt.printf(": %s", symbol.constraint.name)
	}

	if symbol.is_driven {
		fmt.printf(" [driven]")
	}

	fmt.println()
}

// ===========================================================================
// SECTION 9: MAIN DRIVER - OPTIMIZED
// ===========================================================================

// Optimized semantic analysis with memory tracking
perform_semantic_analysis :: proc(ast: ^Node) -> bool {
	// Track memory usage
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	context.allocator = mem.tracking_allocator(&tracker)

	// Run analysis
	analyzer := analyze_ast(ast)

	// Report results
	if len(analyzer.errors) > 0 {
		fmt.printf("\nSemantic analysis found %d errors:\n", len(analyzer.errors))
		// Print only first few errors to avoid flooding output
		max_errors := min(len(analyzer.errors), 10)
		for i := 0; i < max_errors; i += 1 {
			fmt.println(analyzer.errors[i])
		}
		if len(analyzer.errors) > max_errors {
			fmt.printf("... and %d more errors\n", len(analyzer.errors) - max_errors)
		}
	}

	if len(analyzer.warnings) > 0 {
		fmt.printf("\nSemantic analysis found %d warnings:\n", len(analyzer.warnings))
		// Print only first few warnings
		max_warnings := min(len(analyzer.warnings), 10)
		for i := 0; i < max_warnings; i += 1 {
			fmt.println(analyzer.warnings[i])
		}
		if len(analyzer.warnings) > max_warnings {
			fmt.printf("... and %d more warnings\n", len(analyzer.warnings) - max_warnings)
		}
	}

	// Cleanup
	mem.tracking_allocator_destroy(&tracker)

	return len(analyzer.errors) == 0
}

main_semantic_analysis :: proc(ast: ^Node, filename: string) -> bool {
	if ast == nil {
		fmt.println("Cannot perform semantic analysis: AST is nil")
		return false
	}

	fmt.printf("Performing optimized semantic analysis on %s...\n", filename)

	success := perform_semantic_analysis(ast)

	if success {
		fmt.println("Semantic analysis completed successfully!")
	} else {
		fmt.println("Semantic analysis failed.")
	}

	return success
}

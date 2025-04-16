package compiler

import "core:fmt"
import "core:slice"
import "core:strings"

/*
 * ====================================================================
 * Semantic Analysis for Homoiconic Language
 *
 * This module implements:
 * 1. Symbol table for tracking scopes and definitions
 * 2. Constraint validation
 * 3. Pattern match exhaustiveness checking
 * 4. Definition usage verification
 * 5. Resonance binding analysis
 * ====================================================================
 */

// ===========================================================================
// SECTION 1: SYMBOL TABLE STRUCTURE
// ===========================================================================

/*
 * Reference_Kind represents the different ways a symbol can be referenced
 */
Reference_Kind :: enum {
	Definition, // -> (defining a new symbol)
	PullDefinition, // <- (defining a parameter)
	Usage, // Direct usage
	Constraint, // Used as a constraint (Type:value)
	EventPush, // >- (event push)
	EventPull, // -< (event pull)
	ResonancePush, // >>- (resonance push)
	ResonancePull, // -<< (resonance pull)
	Override, // Overriding in a scope
	Builtin, // Built-in type or constant
}

/*
 * Symbol represents an entity in the symbol table
 */
Symbol :: struct {
	name:           string, // Symbol name
	node:           ^Node, // AST node that defined this symbol
	scope:          ^Scope_Info, // The scope this symbol is defined in
	kind:           Reference_Kind, // How this symbol was defined
	defining_scope: ^Scope_Info, // The scope that defines this symbol (if it's a scope)
	constraint:     ^Symbol, // The constraint on this symbol (if any)
	is_driven:      bool, // Whether this symbol is driven by resonance
	driver:         ^Symbol, // What drives this symbol (if is_driven)
	references:     [dynamic]^Reference, // Places where this symbol is referenced
	position:       Position, // Source position for better error reporting
	is_builtin:     bool, // Whether this is a built-in symbol
	index:          int, // Position in scope (for positional references)
}

/*
 * Reference represents a usage of a symbol
 */
Reference :: struct {
	symbol:   ^Symbol, // The symbol being referenced
	node:     ^Node, // The AST node containing the reference
	kind:     Reference_Kind, // How the symbol is being referenced
	position: Position, // Source position of the reference
	index:    int, // For positional references
}

/*
 * Scope_Info represents a scope in the symbol table
 */
Scope_Info :: struct {
	parent:       ^Scope_Info, // Parent scope
	symbols:      map[string]^Symbol, // Named symbols in this scope by name
	symbol_list:  [dynamic]^Symbol, // Ordered list of symbols (for positional access)
	expansions:   [dynamic]^Scope_Info, // Expanded scopes
	scope_symbol: ^Symbol, // The symbol representing this scope (if named)
	is_pattern:   bool, // Whether this is a pattern matching scope
	branches:     [dynamic]^Branch_Info, // Branches in pattern match
	constraints:  [dynamic]^Constraint_Info, // Constraints in this scope
	resonances:   [dynamic]^Resonance_Info, // Resonance bindings
	events:       [dynamic]^Event_Info, // Event handlers
}

/*
 * Constraint_Info represents a constraint
 */
Constraint_Info :: struct {
	target:     ^Symbol, // Symbol being constrained
	constraint: ^Symbol, // The constraint
	node:       ^Node, // AST node for this constraint
}

/*
 * Branch_Info represents a pattern match branch
 */
Branch_Info :: struct {
	pattern:          ^Node, // Pattern to match
	result:           ^Node, // Result if pattern matches
	captured_symbols: map[string]^Symbol, // Symbols captured in this branch
}

/*
 * Resonance_Info represents a resonance binding
 */
Resonance_Info :: struct {
	target:  ^Symbol, // Target symbol being driven
	driver:  ^Symbol, // Driver symbol
	is_push: bool, // Whether this is push (>>-) or pull (-<<)
	node:    ^Node, // AST node for this resonance
}

/*
 * Event_Info represents an event handler
 */
Event_Info :: struct {
	event:   ^Symbol, // Event being handled
	handler: ^Node, // Handler expression
	is_push: bool, // Whether this is push (>-) or pull (-<)
	node:    ^Node, // AST node for this event
}

/*
 * Analyzer represents the semantic analyzer state
 */
Analyzer :: struct {
	global_scope:    ^Scope_Info, // Global scope
	current_scope:   ^Scope_Info, // Current scope being analyzed
	errors:          [dynamic]string, // Collected errors
	warnings:        [dynamic]string, // Collected warnings
	in_pattern:      bool, // Whether we're in a pattern match
	current_pattern: ^Node, // Current pattern being analyzed
	builtin_types:   map[string]^Symbol, // Built-in types available in all scopes
}

// ===========================================================================
// SECTION 2: SEMANTIC ANALYZER INITIALIZATION
// ===========================================================================

/*
 * Built-in type names
 */
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

/*
 * init_analyzer creates and initializes a new semantic analyzer
 */
init_analyzer :: proc() -> ^Analyzer {
	analyzer := new(Analyzer)
	analyzer.global_scope = init_scope(nil)
	analyzer.current_scope = analyzer.global_scope
	analyzer.errors = make([dynamic]string, 0, 16)
	analyzer.warnings = make([dynamic]string, 0, 16)
	analyzer.builtin_types = make(map[string]^Symbol)

	// Register built-in types
	register_builtin_types(analyzer)

	return analyzer
}

/*
 * register_builtin_types adds built-in types to the analyzer
 */
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

		// Also add to global scope so they're visible everywhere
		add_symbol(analyzer, symbol)
	}
}

/*
 * init_scope creates and initializes a new scope
 */
init_scope :: proc(parent: ^Scope_Info) -> ^Scope_Info {
	scope := new(Scope_Info)
	scope.parent = parent
	scope.symbols = make(map[string]^Symbol)
	scope.symbol_list = make([dynamic]^Symbol, 0, 8)
	scope.expansions = make([dynamic]^Scope_Info, 0, 2)
	scope.branches = make([dynamic]^Branch_Info, 0, 4)
	scope.constraints = make([dynamic]^Constraint_Info, 0, 4)
	scope.resonances = make([dynamic]^Resonance_Info, 0, 4)
	scope.events = make([dynamic]^Event_Info, 0, 4)

	return scope
}

/*
 * create_symbol creates a new symbol with the given properties
 */
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
	symbol.references = make([dynamic]^Reference, 0, 4)
	symbol.is_builtin = false
	// Index will be set when adding to scope

	return symbol
}

/*
 * add_symbol adds a symbol to the current scope
 */
add_symbol :: proc(analyzer: ^Analyzer, symbol: ^Symbol) -> ^Symbol {
	if symbol.name != "" {
		// Check if we're shadowing a built-in type
		if builtin, ok := analyzer.builtin_types[symbol.name]; ok && !symbol.is_builtin {
			add_warning(
				analyzer,
				fmt.tprintf("Definition of '%s' shadows a built-in type", symbol.name),
				symbol.position,
			)
		}

		// In this language, we allow multiple definitions with the same name
		// Set the index for positional reference
		symbol.index = len(analyzer.current_scope.symbol_list)

		analyzer.current_scope.symbols[symbol.name] = symbol // Note: This will replace any previous definition with same name
		append(&analyzer.current_scope.symbol_list, symbol)
	} else {
		// Anonymous symbol (still add to positional list)
		symbol.index = len(analyzer.current_scope.symbol_list)
		append(&analyzer.current_scope.symbol_list, symbol)
	}
	return symbol
}

/*
 * add_reference creates and registers a reference to a symbol
 */
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
	return reference
}

/*
 * add_error adds an error message to the analyzer
 */
add_error :: proc(analyzer: ^Analyzer, message: string, position: Position) {
	error_message := fmt.tprintf(
		"Error at line %d, column %d: %s",
		position.line,
		position.column,
		message,
	)
	append(&analyzer.errors, error_message)
}

/*
 * add_warning adds a warning message to the analyzer
 */
add_warning :: proc(analyzer: ^Analyzer, message: string, position: Position) {
	warning_message := fmt.tprintf(
		"Warning at line %d, column %d: %s",
		position.line,
		position.column,
		message,
	)
	append(&analyzer.warnings, warning_message)
}

/*
 * enter_scope enters a new scope for analysis
 */
enter_scope :: proc(analyzer: ^Analyzer, scope: ^Scope_Info) -> ^Scope_Info {
	prev_scope := analyzer.current_scope
	analyzer.current_scope = scope
	return prev_scope
}

/*
 * leave_scope leaves the current scope and returns to the previous one
 */
leave_scope :: proc(analyzer: ^Analyzer, prev_scope: ^Scope_Info) {
	analyzer.current_scope = prev_scope
}

/*
 * create_scope_for_node creates a scope for a node and sets up the scope symbol
 */
create_scope_for_node :: proc(
	analyzer: ^Analyzer,
	node: ^Node,
	name: string,
	position: Position,
) -> ^Scope_Info {
	// Create scope
	scope := init_scope(analyzer.current_scope)

	// Create symbol for the scope
	symbol := create_symbol(name, node, analyzer.current_scope, .Definition, position)
	symbol.defining_scope = scope // Set the defining_scope to point to the scope, not to self

	// Register scope
	scope.scope_symbol = symbol

	// Add to current scope
	add_symbol(analyzer, symbol)

	return scope
}

// ===========================================================================
// SECTION 3: SYMBOL LOOKUP
// ===========================================================================

/*
 * lookup_symbol looks up a symbol by name in the current and parent scopes
 */
lookup_symbol :: proc(analyzer: ^Analyzer, name: string) -> ^Symbol {
	current := analyzer.current_scope

	for current != nil {
		// Check in current scope
		if symbol, ok := current.symbols[name]; ok {
			return symbol
		}

		// Check expansions
		for expansion in current.expansions {
			if symbol := lookup_symbol_in_scope(expansion, name); symbol != nil {
				return symbol
			}
		}

		// Move up to parent scope
		current = current.parent
	}

	// Check built-in types as a last resort
	if builtin, ok := analyzer.builtin_types[name]; ok {
		return builtin
	}

	return nil
}

/*
 * lookup_symbol_in_scope looks up a symbol by name in a specific scope
 */
lookup_symbol_in_scope :: proc(scope: ^Scope_Info, name: string) -> ^Symbol {
	if symbol, ok := scope.symbols[name]; ok {
		return symbol
	}

	// Check expansions
	for expansion in scope.expansions {
		if symbol := lookup_symbol_in_scope(expansion, name); symbol != nil {
			return symbol
		}
	}

	return nil
}

/*
 * lookup_symbol_local looks up a symbol only in the current scope
 */
lookup_symbol_local :: proc(analyzer: ^Analyzer, name: string) -> ^Symbol {
	if symbol, ok := analyzer.current_scope.symbols[name]; ok {
		return symbol
	}

	// Check expansions
	for expansion in analyzer.current_scope.expansions {
		if symbol := lookup_symbol_in_scope(expansion, name); symbol != nil {
			return symbol
		}
	}

	return nil
}

/*
 * lookup_symbol_by_position looks up a symbol by its position index
 */
lookup_symbol_by_position :: proc(analyzer: ^Analyzer, name: string, index: int) -> ^Symbol {
	current := analyzer.current_scope

	for current != nil {
		// Try to find all symbols with matching name
		name_matches := 0
		for sym in current.symbol_list {
			if sym.name == name {
				// Count how many we've seen
				if name_matches == index {
					return sym
				}
				name_matches += 1
			}
		}

		// Not found in this scope, check parent
		current = current.parent
	}

	return nil
}

// ===========================================================================
// SECTION 4: MAIN ANALYSIS
// ===========================================================================

/*
 * analyze_ast performs semantic analysis on the AST
 */
analyze_ast :: proc(ast: ^Node) -> ^Analyzer {
	analyzer := init_analyzer()

	// First pass: build symbol table
	build_symbol_table(analyzer, ast)

	// Second pass: validate definitions and usages
	validate_definitions(analyzer)

	// Third pass: check constraints
	validate_constraints(analyzer)

	// Fourth pass: check pattern matches
	validate_pattern_matches(analyzer)

	// Fifth pass: check resonance bindings
	validate_resonance_bindings(analyzer)

	return analyzer
}

/*
 * build_symbol_table builds the symbol table from the AST
 */
build_symbol_table :: proc(analyzer: ^Analyzer, node: ^Node) {
	if node == nil {
		return
	}

	position := get_position_from_node(node)

	#partial switch n in node^ {
	case Scope:
		analyze_scope(analyzer, node, n, position)

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
		analyze_execute(analyzer, node, n, position)

	case Expand:
		analyze_expand(analyzer, node, n, position)

	case Identifier:
		analyze_identifier(analyzer, node, n, position)

	case Literal, Operator, Range, Property:
		// These nodes don't define symbols directly
		// But we should check their children
		#partial switch n in node^ {
		case Operator:
			if n.left != nil do build_symbol_table(analyzer, n.left)
			if n.right != nil do build_symbol_table(analyzer, n.right)

		case Property:
			if n.source != nil do build_symbol_table(analyzer, n.source)
			if n.property != nil do build_symbol_table(analyzer, n.property)

		case Range:
			if n.start != nil do build_symbol_table(analyzer, n.start)
			if n.end != nil do build_symbol_table(analyzer, n.end)
		}
	}
}

/*
 * analyze_scope analyzes a scope node
 */
analyze_scope :: proc(analyzer: ^Analyzer, node: ^Node, scope: Scope, position: Position) {
	// Create a new scope
	scope_info := create_scope_for_node(analyzer, node, "", position)

	// Enter the scope
	prev_scope := enter_scope(analyzer, scope_info)

	// Analyze the contents of the scope
	for i := 0; i < len(scope.value); i += 1 {
		child_node := new(Node)
		child_node^ = scope.value[i]
		build_symbol_table(analyzer, child_node)
	}

	// Leave the scope
	leave_scope(analyzer, prev_scope)
}

/*
 * analyze_pointing analyzes a pointing (name -> value) node
 */
analyze_pointing :: proc(
	analyzer: ^Analyzer,
	node: ^Node,
	pointing: Pointing,
	position: Position,
) {
	// Handle product case (-> value)
	if pointing.name == nil {
		// Create anonymous product symbol
		product := create_symbol("", node, analyzer.current_scope, .Definition, position)
		add_symbol(analyzer, product)

		// Analyze the value
		if pointing.value != nil {
			build_symbol_table(analyzer, pointing.value)
		}
		return
	}

	// Get the name
	name: string
	if id, ok := pointing.name^.(Identifier); ok {
		name = id.name
	} else {
		// Complex expression for name, analyze it
		build_symbol_table(analyzer, pointing.name)

		// Analyze value too
		if pointing.value != nil {
			build_symbol_table(analyzer, pointing.value)
		}
		return
	}

	// Create symbol for the pointing
	symbol := create_symbol(name, node, analyzer.current_scope, .Definition, position)

	// Check if there's already a constrained version of this symbol
	// If so, copy its constraint
	existing := lookup_symbol_local(analyzer, name)
	if existing != nil && existing.constraint != nil {
		symbol.constraint = existing.constraint
	}

	add_symbol(analyzer, symbol)

	// If value is a scope, handle it specially
	if pointing.value != nil {
		if scope, ok := pointing.value^.(Scope); ok {
			// Create a new scope
			scope_info := init_scope(analyzer.current_scope)
			scope_info.scope_symbol = symbol
			symbol.defining_scope = scope_info // Set directly to the scope

			// Enter the scope
			prev_scope := enter_scope(analyzer, scope_info)

			// Analyze the scope
			build_symbol_table(analyzer, pointing.value)

			// Leave the scope
			leave_scope(analyzer, prev_scope)
		} else {
			// Regular value, analyze it
			build_symbol_table(analyzer, pointing.value)
		}
	}
}

/*
 * analyze_pointing_pull analyzes a pointing pull (name <- value) node
 */
analyze_pointing_pull :: proc(
	analyzer: ^Analyzer,
	node: ^Node,
	pointing_pull: PointingPull,
	position: Position,
) {
	// Handle anonymous pointing pull (<- value)
	if pointing_pull.name == nil {
		if pointing_pull.value != nil {
			build_symbol_table(analyzer, pointing_pull.value)
		}
		return
	}

	// Get the name
	name: string
	if id, ok := pointing_pull.name^.(Identifier); ok {
		name = id.name
	} else {
		// Complex expression for name, analyze it
		build_symbol_table(analyzer, pointing_pull.name)

		// Analyze value too
		if pointing_pull.value != nil {
			build_symbol_table(analyzer, pointing_pull.value)
		}
		return
	}

	// Create symbol for the parameter
	symbol := create_symbol(name, node, analyzer.current_scope, .PullDefinition, position)
	add_symbol(analyzer, symbol)

	// Analyze the value
	if pointing_pull.value != nil {
		build_symbol_table(analyzer, pointing_pull.value)
	}
}

/*
 * analyze_event_push analyzes an event push (a >- b) node
 */
analyze_event_push :: proc(
	analyzer: ^Analyzer,
	node: ^Node,
	event_push: EventPush,
	position: Position,
) {
	// Handle anonymous event push (>- value)
	if event_push.name == nil {
		if event_push.value != nil {
			build_symbol_table(analyzer, event_push.value)
		}
		return
	}

	// Analyze the target
	build_symbol_table(analyzer, event_push.name)

	// Create event info
	event_info := new(Event_Info)
	event_info.is_push = true
	event_info.node = node

	// If name is an identifier, try to find the symbol
	if id, ok := event_push.name^.(Identifier); ok {
		symbol := lookup_symbol(analyzer, id.name)
		if symbol != nil {
			event_info.event = symbol
			add_reference(analyzer, symbol, node, .EventPush, position)
		} else {
			// For resonance, we might be handling a case like "response >- Get{...}"
			// where response is implicitly defined by the resonance
			symbol = create_symbol(id.name, node, analyzer.current_scope, .Definition, position)
			add_symbol(analyzer, symbol)
			event_info.event = symbol
		}
	}

	// Analyze the value
	if event_push.value != nil {
		event_info.handler = event_push.value
		build_symbol_table(analyzer, event_push.value)
	}

	// Add to events list
	append(&analyzer.current_scope.events, event_info)
}
/*
 * analyze_event_pull analyzes an event pull (a -< b) node
 */
analyze_event_pull :: proc(
	analyzer: ^Analyzer,
	node: ^Node,
	event_pull: EventPull,
	position: Position,
) {
	// Handle anonymous event pull (-< value)
	if event_pull.name == nil {
		if event_pull.value != nil {
			build_symbol_table(analyzer, event_pull.value)
		}
		return
	}

	// Analyze the handler name
	name: string = ""
	if id, ok := event_pull.name^.(Identifier); ok {
		name = id.name
	} else {
		build_symbol_table(analyzer, event_pull.name)
	}

	// Create event info
	event_info := new(Event_Info)
	event_info.is_push = false
	event_info.node = node

	// If name is an identifier, create or find the symbol
	if name != "" {
		symbol := lookup_symbol(analyzer, name)
		if symbol == nil {
			// Define a new symbol for the event handler
			symbol = create_symbol(name, node, analyzer.current_scope, .Definition, position)
			add_symbol(analyzer, symbol)
		} else {
			add_reference(analyzer, symbol, node, .EventPull, position)
		}

		event_info.event = symbol
	}

	// Analyze the handler
	if event_pull.value != nil {
		event_info.handler = event_pull.value
		build_symbol_table(analyzer, event_pull.value)
	}

	// Add to events list
	append(&analyzer.current_scope.events, event_info)
}
/*
 * analyze_resonance_push analyzes a resonance push (a >>- b) node
 */
analyze_resonance_push :: proc(
	analyzer: ^Analyzer,
	node: ^Node,
	resonance_push: ResonancePush,
	position: Position,
) {
	// Handle anonymous resonance push (>>- value)
	if resonance_push.name == nil {
		if resonance_push.value != nil {
			build_symbol_table(analyzer, resonance_push.value)
		}
		return
	}

	// Analyze the target
	build_symbol_table(analyzer, resonance_push.name)

	// Create resonance info
	resonance_info := new(Resonance_Info)
	resonance_info.is_push = true
	resonance_info.node = node

	// If name is an identifier, try to find the symbol
	if id, ok := resonance_push.name^.(Identifier); ok {
		symbol := lookup_symbol(analyzer, id.name)
		if symbol != nil {
			resonance_info.target = symbol
			symbol.is_driven = true
			add_reference(analyzer, symbol, node, .ResonancePush, position)
		} else {
			add_error(analyzer, fmt.tprintf("Undefined resonance target '%s'", id.name), position)
		}
	}

	// Analyze the driver
	if resonance_push.value != nil {
		build_symbol_table(analyzer, resonance_push.value)

		// If value is an identifier, set it as driver
		if id, ok := resonance_push.value^.(Identifier); ok {
			driver := lookup_symbol(analyzer, id.name)
			if driver != nil {
				resonance_info.driver = driver

				// Update the target's driver
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

/*
 * analyze_resonance_pull analyzes a resonance pull (a -<< b) node
 */
analyze_resonance_pull :: proc(
	analyzer: ^Analyzer,
	node: ^Node,
	resonance_pull: ResonancePull,
	position: Position,
) {
	// Handle anonymous resonance pull (-<< value)
	if resonance_pull.name == nil {
		if resonance_pull.value != nil {
			build_symbol_table(analyzer, resonance_pull.value)
		}
		return
	}

	// Get the name if it's an identifier
	name: string = ""
	if id, ok := resonance_pull.name^.(Identifier); ok {
		name = id.name
	}

	// Analyze the target
	build_symbol_table(analyzer, resonance_pull.name)

	// Create resonance info
	resonance_info := new(Resonance_Info)
	resonance_info.is_push = false
	resonance_info.node = node

	// If name is an identifier, try to find or create the symbol
	if name != "" {
		symbol := lookup_symbol(analyzer, name)
		if symbol == nil {
			// This is where we handle the case like "response >- Get{...}"
			// Create a new symbol for the resonance target
			symbol = create_symbol(name, node, analyzer.current_scope, .Definition, position)
			add_symbol(analyzer, symbol)
		}

		resonance_info.target = symbol
		add_reference(analyzer, symbol, node, .ResonancePull, position)
	}

	// Analyze the driver
	if resonance_pull.value != nil {
		build_symbol_table(analyzer, resonance_pull.value)

		// If value is an identifier, set it as driver
		if id, ok := resonance_pull.value^.(Identifier); ok {
			driver := lookup_symbol(analyzer, id.name)
			if driver != nil {
				resonance_info.driver = driver
				add_reference(analyzer, driver, node, .ResonancePull, position)
			}
		} else {
			// For complex expressions like Get{url->"..."}, we need to analyze what's being driven
			// For now, we'll just use a placeholder
			// In a real implementation, you'd analyze the structure of the driver expression
		}
	}

	// Add to resonances list
	append(&analyzer.current_scope.resonances, resonance_info)
}
/*
 * analyze_override analyzes an override (a{...}) node
 */
analyze_override :: proc(
	analyzer: ^Analyzer,
	node: ^Node,
	override: Override,
	position: Position,
) {
	// Analyze the base
	if override.source != nil {
		build_symbol_table(analyzer, override.source)
	}

	// If the source is an identifier, check that it exists
	if id, ok := override.source^.(Identifier); ok {
		symbol := lookup_symbol(analyzer, id.name)
		if symbol == nil {
			add_error(analyzer, fmt.tprintf("Cannot override undefined '%s'", id.name), position)
		} else {
			add_reference(analyzer, symbol, node, .Override, position)
		}
	}

	// Analyze the overrides
	for i := 0; i < len(override.overrides); i += 1 {
		override_node := new(Node)
		override_node^ = override.overrides[i]
		build_symbol_table(analyzer, override_node)
	}
}

/*
 * analyze_pattern analyzes a pattern match (target ? {...}) node
 */
analyze_pattern :: proc(analyzer: ^Analyzer, node: ^Node, pattern: Pattern, position: Position) {
	// Analyze the target
	if pattern.target != nil {
		build_symbol_table(analyzer, pattern.target)
	}

	// Create a pattern scope
	pattern_scope := create_scope_for_node(analyzer, node, "", position)
	pattern_scope.is_pattern = true

	// Enter pattern scope
	prev_scope := enter_scope(analyzer, pattern_scope)
	prev_in_pattern := analyzer.in_pattern
	prev_pattern := analyzer.current_pattern

	analyzer.in_pattern = true
	analyzer.current_pattern = node

	// Analyze each branch
	for i := 0; i < len(pattern.value); i += 1 {
		branch := pattern.value[i]

		// Create branch info
		branch_info := new(Branch_Info)
		branch_info.pattern = branch.source
		branch_info.result = branch.product
		branch_info.captured_symbols = make(map[string]^Symbol)

		// Analyze pattern
		if branch.source != nil {
			build_symbol_table(analyzer, branch.source)
		}

		// Analyze result
		if branch.product != nil {
			build_symbol_table(analyzer, branch.product)
		}

		// Add to branches list
		append(&pattern_scope.branches, branch_info)
	}

	// Restore state
	analyzer.in_pattern = prev_in_pattern
	analyzer.current_pattern = prev_pattern
	leave_scope(analyzer, prev_scope)
}

/*
 * analyze_constraint analyzes a constraint (Type: value) node
 */
analyze_constraint :: proc(
	analyzer: ^Analyzer,
	node: ^Node,
	constraint: Constraint,
	position: Position,
) {
	// Safety check for nil values
	if constraint.constraint == nil {
		add_error(analyzer, "Constraint type is nil", position)
		return
	}

	// First, check if constraint is a valid type
	constraint_symbol: ^Symbol
	if id, ok := constraint.constraint^.(Identifier); ok {
		constraint_symbol = lookup_symbol(analyzer, id.name)
		if constraint_symbol == nil {
			add_error(analyzer, fmt.tprintf("Undefined constraint type '%s'", id.name), position)
		}
	} else {
		// Non-identifier constraint, analyze it
		build_symbol_table(analyzer, constraint.constraint)
	}

	// If value is nil, this might be a nameless constraint like "u8:"
	if constraint.value == nil {
		// Create an anonymous constrained symbol
		symbol := create_symbol("", node, analyzer.current_scope, .Definition, position)
		symbol.constraint = constraint_symbol
		add_symbol(analyzer, symbol)

		// Create constraint info
		constraint_info := new(Constraint_Info)
		constraint_info.target = symbol
		constraint_info.constraint = constraint_symbol
		constraint_info.node = node
		append(&analyzer.current_scope.constraints, constraint_info)
		return
	}

	// Get name from the value if it's an identifier
	name: string = ""
	if id, ok := constraint.value^.(Identifier); ok {
		name = id.name
	} else {
		// If not a simple identifier, analyze the value expression
		build_symbol_table(analyzer, constraint.value)
	}

	// Create a symbol for the name if we have one
	if name != "" {
		symbol := create_symbol(name, node, analyzer.current_scope, .Definition, position)
		symbol.constraint = constraint_symbol
		add_symbol(analyzer, symbol)

		// Create constraint info
		constraint_info := new(Constraint_Info)
		constraint_info.target = symbol
		constraint_info.constraint = constraint_symbol
		constraint_info.node = node
		append(&analyzer.current_scope.constraints, constraint_info)
	}
}

/*
 * analyze_product analyzes a product (-> value) node
 */
analyze_product :: proc(analyzer: ^Analyzer, node: ^Node, product: Product, position: Position) {
	// Create an anonymous symbol for the product
	symbol := create_symbol("", node, analyzer.current_scope, .Definition, position)
	add_symbol(analyzer, symbol)

	// Analyze the value
	if product.value != nil {
		build_symbol_table(analyzer, product.value)
	}
}

/*
 * analyze_execute analyzes an execute (expr!) node
 */
analyze_execute :: proc(analyzer: ^Analyzer, node: ^Node, execute: Execute, position: Position) {
	// Analyze the value
	if execute.value != nil {
		build_symbol_table(analyzer, execute.value)
	}
}

/*
 * analyze_expand analyzes an expand (...expr) node
 */
analyze_expand :: proc(analyzer: ^Analyzer, node: ^Node, expand: Expand, position: Position) {
	// Analyze the target
	if expand.target != nil {
		build_symbol_table(analyzer, expand.target)
	}

	// If target is an identifier, try to expand it
	if id, ok := expand.target^.(Identifier); ok {
		symbol := lookup_symbol(analyzer, id.name)
		if symbol == nil {
			add_error(analyzer, fmt.tprintf("Cannot expand undefined '%s'", id.name), position)
		} else {
			add_reference(analyzer, symbol, node, .Usage, position)

			// If the symbol has a scope, add it to expansions
			if symbol.defining_scope != nil {
				append(&analyzer.current_scope.expansions, symbol.defining_scope)
			}
		}
	}
}

/*
 * analyze_identifier analyzes an identifier reference
 */
analyze_identifier :: proc(analyzer: ^Analyzer, node: ^Node, id: Identifier, position: Position) {
	// Regular name lookup
	symbol := lookup_symbol(analyzer, id.name)

	if symbol == nil {
		// Check if this might be defined by a constraint
		if is_defined_by_constraint(analyzer, id.name) {
			// It's defined by a constraint, so this is okay
			return
		}

		// In pattern context, this might be a new symbol being introduced
		if analyzer.in_pattern {
			symbol = create_symbol(id.name, node, analyzer.current_scope, .Definition, position)
			add_symbol(analyzer, symbol)
		} else {
			add_error(analyzer, fmt.tprintf("Undefined symbol '%s'", id.name), position)
		}
	} else {
		// Add reference
		add_reference(analyzer, symbol, node, .Usage, position)
	}
}

/*
 * get_position_from_node extracts position information from a node
 */
get_position_from_node :: proc(node: ^Node) -> Position {
	if node == nil {
		return Position{line = 0, column = 0, offset = 0}
	}

	// In real implementation, position would be stored in the node
	// For now we return a placeholder
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
		// If we encounter an unknown node type, print a warning for debugging
		fmt.eprintln("Unknown node type in get_position_from_node")
		return Position{line = 0, column = 0, offset = 0}
	}
}

// ===========================================================================
// SECTION 5: VALIDATION PASSES
// ===========================================================================

/*
 * validate_definitions checks that all symbol references point to defined symbols
 */
validate_definitions :: proc(analyzer: ^Analyzer) {
	validate_definitions_in_scope(analyzer, analyzer.global_scope)
}

/*
 * validate_definitions_in_scope recursively checks symbol definitions in a scope
 */
validate_definitions_in_scope :: proc(analyzer: ^Analyzer, scope: ^Scope_Info) {
	if scope == nil {
		return
	}

	// Check all symbols in this scope
	for sym in scope.symbol_list {
		// Check all references to this symbol
		for reference in sym.references {
			// Verify the reference makes sense in context
			validate_reference(analyzer, reference)
		}

		// If this symbol defines a scope, check that scope too
		if sym.defining_scope != nil {
			validate_definitions_in_scope(analyzer, sym.defining_scope)
		}
	}

	// Check nested pattern scopes
	for branch in scope.branches {
		// TODO: Check captured symbols in branch patterns
	}
}

/*
 * validate_reference checks if a symbol reference is valid
 */
validate_reference :: proc(analyzer: ^Analyzer, reference: ^Reference) {
	if reference == nil || reference.symbol == nil {
		return
	}

	// Different checks based on reference kind
	#partial switch reference.kind {
	case .Usage:
	// Usage is fine for any defined symbol

	case .Constraint:
		// Check that the symbol can be used as a constraint
		// For built-in types, this is always true
		if !reference.symbol.is_builtin {
			// Non-builtin symbols might need additional validation to be used as constraints
			// For example, they might need to be defined with a specific kind
		}

	case .Override:
	// Check that the symbol can be overridden

	case .EventPush, .EventPull:
	// Check event handlers

	case .ResonancePush, .ResonancePull:
	// Check resonance bindings
	}
}

/*
 * validate_constraints checks that all constraints are respected
 */
validate_constraints :: proc(analyzer: ^Analyzer) {
	validate_constraints_in_scope(analyzer, analyzer.global_scope)
}

/*
 * validate_constraints_in_scope checks constraints in a scope
 */
validate_constraints_in_scope :: proc(analyzer: ^Analyzer, scope: ^Scope_Info) {
	if scope == nil {
		return
	}

	// Check all constraints in this scope
	for constraint in scope.constraints {
		if constraint.constraint != nil && constraint.target != nil {
			// Record that this constraint is defined and used
			// This prevents errors about undefined symbols when they are defined via constraints

			// If the constraint has a defining scope (like Color), it can be used as a constraint itself
			if constraint.constraint.defining_scope != nil {
				// Validate that the structure matches what's expected
				// TODO: Implement detailed structure validation
			} else {
				// Built-in type or simple constraint
				// Here we would check that values assigned to constrained symbols match their constraints
				// TODO: Implement type checking for constrained values
			}
		}
	}

	// Check nested scopes in symbols
	for _, sym in scope.symbols {
		if sym.defining_scope != nil {
			validate_constraints_in_scope(analyzer, sym.defining_scope)
		}
	}
}

/*
 * is_defined_by_constraint checks if a symbol is defined by a constraint
 */
is_defined_by_constraint :: proc(analyzer: ^Analyzer, name: string) -> bool {
	scope := analyzer.current_scope
	for scope != nil {
		for constraint in scope.constraints {
			if constraint.target != nil && constraint.target.name == name {
				return true
			}
		}
		scope = scope.parent
	}
	return false
}
/*
 * validate_pattern_matches checks pattern match exhaustiveness
 */
validate_pattern_matches :: proc(analyzer: ^Analyzer) {
	validate_pattern_matches_in_scope(analyzer, analyzer.global_scope)
}

/*
 * validate_pattern_matches_in_scope checks pattern matches in a scope
 */
validate_pattern_matches_in_scope :: proc(analyzer: ^Analyzer, scope: ^Scope_Info) {
	if scope == nil {
		return
	}

	// Only check if this is a pattern match scope
	if scope.is_pattern {
		check_exhaustiveness(analyzer, scope)
	}

	// Check nested scopes in symbols
	for sym in scope.symbol_list {
		if sym.defining_scope != nil {
			validate_pattern_matches_in_scope(analyzer, sym.defining_scope)
		}
	}
}

/*
 * check_exhaustiveness checks if a pattern match is exhaustive
 */
check_exhaustiveness :: proc(analyzer: ^Analyzer, scope: ^Scope_Info) {
	if scope == nil || !scope.is_pattern || scope.scope_symbol == nil {
		return
	}

	// TODO: Implement real exhaustiveness checking
	// This would need to analyze the pattern branches and determine
	// if they cover all possible cases for the target type

	// For now, just check if there's a catch-all case
	has_catchall := false

	for branch in scope.branches {
		// Check if this branch is a catch-all (like "_" in other languages)
		// In your language, this might be different

		// TODO: Determine what constitutes a catch-all pattern in your language
	}

	if !has_catchall {
		position := get_position_from_node(scope.scope_symbol.node)
		add_warning(analyzer, "Pattern match may not be exhaustive", position)
	}
}

/*
 * validate_resonance_bindings checks resonance binding consistency
 */
validate_resonance_bindings :: proc(analyzer: ^Analyzer) {
	validate_resonance_bindings_in_scope(analyzer, analyzer.global_scope)
}

/*
 * validate_resonance_bindings_in_scope checks resonance bindings in a scope
 */
validate_resonance_bindings_in_scope :: proc(analyzer: ^Analyzer, scope: ^Scope_Info) {
	if scope == nil {
		return
	}

	// Create a map to count resonance drive targets
	drive_count := make(map[^Symbol]int)
	defer delete(drive_count)

	// Check all resonance bindings
	for resonance in scope.resonances {
		if resonance.target != nil {
			if resonance.is_push {
				// For resonance push (>>-), check if the target can be driven
				// A symbol can only be driven once
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
	}

	// Check nested scopes in symbols
	for sym in scope.symbol_list {
		if sym.defining_scope != nil {
			validate_resonance_bindings_in_scope(analyzer, sym.defining_scope)
		}
	}
}

// ===========================================================================
// SECTION 6: DRIVER CODE FOR SEMANTIC ANALYSIS
// ===========================================================================

/*
 * This section would contain the main entry point for semantic analysis
 */

/*
 * perform_semantic_analysis is the main entry point for semantic analysis
 */
perform_semantic_analysis :: proc(ast: ^Node) -> bool {
	analyzer := analyze_ast(ast)

	// Report results
	if len(analyzer.errors) > 0 {
		fmt.printf("\nSemantic analysis found %d errors:\n", len(analyzer.errors))
		for error in analyzer.errors {
			fmt.println(error)
		}
	}

	if len(analyzer.warnings) > 0 {
		fmt.printf("\nSemantic analysis found %d warnings:\n", len(analyzer.warnings))
		for warning in analyzer.warnings {
			fmt.println(warning)
		}
	}

	return len(analyzer.errors) == 0
}

// ===========================================================================
// SECTION 7: SCOPE GRAPH VISUALIZATION
// ===========================================================================

/*
 * print_scope_graph generates a visualization of the scope graph for debugging
 */
print_scope_graph :: proc(analyzer: ^Analyzer) {
	fmt.println("\n=== SCOPE GRAPH ===")
	print_scope(analyzer.global_scope, 0)
	fmt.println("=== END SCOPE GRAPH ===\n")
}

/*
 * print_scope recursively prints a scope and its symbols
 */
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

	fmt.println(":")

	// Print symbols in order by position
	for sym, i in scope.symbol_list {
		print_symbol(sym, indent + 2, i)
	}

	// Print expansions
	if len(scope.expansions) > 0 {
		fmt.printf("%s  Expansions:\n", indent_str)
		for expansion in scope.expansions {
			if expansion.scope_symbol != nil && expansion.scope_symbol.name != "" {
				fmt.printf("%s    ...%s\n", indent_str, expansion.scope_symbol.name)
			} else {
				fmt.printf("%s    ...<anonymous>\n", indent_str)
			}
		}
	}

	// Print constraints
	if len(scope.constraints) > 0 {
		fmt.printf("%s  Constraints:\n", indent_str)
		for constraint in scope.constraints {
			if constraint.constraint != nil {
				constraint_name := constraint.constraint.name
				fmt.printf("%s    %s:\n", indent_str, constraint_name)
			} else {
				fmt.printf("%s    <unknown>:\n", indent_str)
			}
		}
	}

	// Print resonances
	if len(scope.resonances) > 0 {
		fmt.printf("%s  Resonances:\n", indent_str)
		for resonance in scope.resonances {
			if resonance.target != nil {
				target_name := resonance.target.name
				if resonance.is_push {
					fmt.printf("%s    %s >>- ", indent_str, target_name)
				} else {
					fmt.printf("%s    %s -<< ", indent_str, target_name)
				}

				if resonance.driver != nil {
					fmt.printf("%s\n", resonance.driver.name)
				} else {
					fmt.println("<expression>")
				}
			}
		}
	}

	// Print events
	if len(scope.events) > 0 {
		fmt.printf("%s  Events:\n", indent_str)
		for event in scope.events {
			if event.event != nil {
				event_name := event.event.name
				if event.is_push {
					fmt.printf("%s    %s >- <handler>\n", indent_str, event_name)
				} else {
					fmt.printf("%s    %s -< <handler>\n", indent_str, event_name)
				}
			}
		}
	}
}

/*
 * print_symbol prints a symbol and its nested scopes
 */
print_symbol :: proc(symbol: ^Symbol, indent: int, position: int = -1) {
	if symbol == nil {
		return
	}

	indent_str := strings.repeat(" ", indent)

	// Print position if available
	if position >= 0 {
		fmt.printf("%s[%d] ", indent_str, position)
	} else {
		fmt.printf("%s", indent_str)
	}

	// Print name
	if symbol.name != "" {
		fmt.printf("%s", symbol.name)
	} else {
		fmt.printf("<anonymous>")
	}

	// Print kind
	#partial switch symbol.kind {
	case .Definition:
		fmt.printf(" -> ")
	case .PullDefinition:
		fmt.printf(" <- ")
	case .Builtin:
		fmt.printf(" (builtin) ")
	case:
		fmt.printf(" (unknown kind) ")
	}

	// Print constraint if any
	if symbol.constraint != nil {
		fmt.printf("%s: ", symbol.constraint.name)
	}

	// Print resonance info
	if symbol.is_driven {
		fmt.printf(" [driven]")
		if symbol.driver != nil {
			fmt.printf(" by %s", symbol.driver.name)
		}
	}

	fmt.println()

	// Print nested scope if it exists
	if symbol.defining_scope != nil {
		print_scope(symbol.defining_scope, indent + 2)
	}
}

// ===========================================================================
// SECTION 8: UTILITIES FOR CODE GENERATION
// ===========================================================================

/*
 * Scope_Path represents a path to a symbol in the scope hierarchy
 */
Scope_Path :: struct {
	segments: [dynamic]^Symbol,
}

/*
 * create_scope_path creates a new empty scope path
 */
create_scope_path :: proc() -> ^Scope_Path {
	path := new(Scope_Path)
	path.segments = make([dynamic]^Symbol, 0, 8)
	return path
}

/*
 * get_scope_path calculates the path to a symbol
 */
get_scope_path :: proc(symbol: ^Symbol) -> ^Scope_Path {
	if symbol == nil {
		return nil
	}

	path := create_scope_path()

	// Start from the symbol and work upward
	current_symbol := symbol
	current_scope := symbol.scope

	for current_scope != nil {
		// Find the owning symbol of the current scope
		if current_scope.scope_symbol != nil {
			// Add to path (prepend)
			prepend_to_path(path, current_scope.scope_symbol)

			// Move up to parent scope
			current_scope = current_scope.parent
		} else {
			// We've reached the global scope
			break
		}
	}

	return path
}

/*
 * prepend_to_path adds a symbol to the beginning of a path
 */
prepend_to_path :: proc(path: ^Scope_Path, symbol: ^Symbol) {
	if path == nil || symbol == nil {
		return
	}

	// Create a new array with room for the new element
	new_segments := make([dynamic]^Symbol, len(path.segments) + 1)

	// Add the new symbol at the beginning
	new_segments[0] = symbol

	// Copy the rest
	for i := 0; i < len(path.segments); i += 1 {
		new_segments[i + 1] = path.segments[i]
	}

	// Replace the old segments
	delete(path.segments)
	path.segments = new_segments
}

/*
 * print_scope_path prints a path in a readable format
 */
print_scope_path :: proc(path: ^Scope_Path) -> string {
	if path == nil {
		return "<nil>"
	}

	if len(path.segments) == 0 {
		return "<global>"
	}

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	for i := 0; i < len(path.segments); i += 1 {
		symbol := path.segments[i]
		if symbol.name != "" {
			strings.write_string(&builder, symbol.name)
		} else {
			strings.write_string(&builder, "<anonymous>")
		}

		if i < len(path.segments) - 1 {
			strings.write_string(&builder, ".")
		}
	}

	return strings.to_string(builder)
}

/*
 * is_reachable checks if a symbol is reachable from the current scope
 */
is_reachable :: proc(from_scope: ^Scope_Info, symbol: ^Symbol) -> bool {
	if from_scope == nil || symbol == nil {
		return false
	}

	// Check if the symbol is in the current scope
	current := from_scope
	for current != nil {
		// Check symbols
		for sym in current.symbol_list {
			if sym == symbol {
				return true
			}
		}

		// Check expansions
		for expansion in current.expansions {
			if is_reachable(expansion, symbol) {
				return true
			}
		}

		// Move up to parent scope
		current = current.parent
	}

	return false
}

/*
 * get_qualified_name returns a fully qualified name for a symbol
 */
get_qualified_name :: proc(symbol: ^Symbol) -> string {
	if symbol == nil {
		return "<nil>"
	}

	if symbol.name == "" {
		return "<anonymous>"
	}

	// For built-in types, just return the name
	if symbol.is_builtin {
		return symbol.name
	}

	// If it has a positional index, include it
	if symbol.index >= 0 {
		// Get the scope path
		path := get_scope_path(symbol)
		defer delete(path.segments) // Properly delete the dynamic array
		defer free(path) // Free the path struct itself

		// Convert path to string and append symbol name with index
		path_str := print_scope_path(path)

		if path_str == "<global>" {
			return fmt.tprintf("%s@%d", symbol.name, symbol.index)
		}

		return fmt.tprintf("%s.%s@%d", path_str, symbol.name, symbol.index)
	}

	// Get the scope path
	path := get_scope_path(symbol)
	defer delete(path.segments) // Properly delete the dynamic array
	defer free(path) // Free the path struct itself

	// Convert path to string and append symbol name
	path_str := print_scope_path(path)

	if path_str == "<global>" {
		return symbol.name
	}

	return fmt.tprintf("%s.%s", path_str, symbol.name)
}

// ===========================================================================
// SECTION 9: INTEGRATION WITH PARSER
// ===========================================================================

/*
 * analyze_file performs semantic analysis on a parsed file
 */
analyze_file :: proc(ast: ^Node, filename: string) -> bool {
	fmt.printf("Performing semantic analysis on %s...\n", filename)

	success := perform_semantic_analysis(ast)

	if success {
		fmt.println("Semantic analysis completed successfully!")
	} else {
		fmt.println("Semantic analysis failed - see errors above.")
	}

	return success
}

/*
 * Main integration point for semantic analysis
 * To be called after successful parsing
 */
main_semantic_analysis :: proc(ast: ^Node, filename: string) -> bool {
	if ast == nil {
		fmt.println("Cannot perform semantic analysis: AST is nil")
		return false
	}

	return analyze_file(ast, filename)
}

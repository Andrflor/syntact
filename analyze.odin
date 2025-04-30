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
// SECTION 1: CORE DATA STRUCTURES
// ===========================================================================

// Reference kinds
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

// Symbol flags
Symbol_Flag :: enum {
    Visited,
    Referenced,
    HasConstraint,
    IsEvent,
    IsResonance,
    IsExported,
    InGlobalIndex,
    Builtin,
    IsDriven,    // Symbol is driven by a resonance
    IsDriver,    // Symbol drives other symbols via resonance
    IsTopLevel,  // Indicates symbol is from a top-level node in a scope
}

// Scope information
Scope_Info :: struct {
    id:                  u64,  // Unique identifier
    name:                string,  // Name or "<anonymous>"
    parent:              ^Scope_Info,
    defining_symbol:     ^Symbol,  // Symbol that defines this scope (if any)

    // Symbols in this scope
    symbols:             map[string]^Symbol,
    symbol_list:         [dynamic]^Symbol,

    // Child scopes directly contained in this scope
    child_scopes:        [dynamic]^Scope_Info,

    // Expanded scopes (brought into this scope via expansion)
    expanded_scopes:     [dynamic]^Scope_Info,

    // The AST node this scope belongs to
    node:                ^Node,

    // Analysis data
    branches:            [dynamic]Branch_Info,
    constraints:         [dynamic]Constraint_Info,
    resonances:          [dynamic]Resonance_Info,
    events:              [dynamic]Event_Info,

    // Lookup optimization
    symbol_cache:        map[u64]^Symbol,  // Hash-based lookup
    visible_symbols:     map[string]^Symbol,
    is_visible_computed: bool,
    is_pattern:          bool,
}

// Symbol structure
Symbol :: struct {
    id:                  u64,  // Unique identifier
    name:                string,
    index:               int,  // Position in scope (used for anonymous symbols too)
    hash:                u64,  // Pre-computed name hash

    // Links to containing scope and AST
    containing_scope:    ^Scope_Info,  // Scope_Info this symbol belongs to
    node:                ^Node,   // AST node that defines this symbol

    // Introduced scope (if this symbol introduces a scope)
    introduced_scope:    ^Scope_Info,

    // Reference information
    kind:                Reference_Kind,
    position:            Position,
    references:          [dynamic]^Reference,

    // Constraint information
    constraint:          ^Symbol,

    // Resonance relationships
    driver:              ^Symbol,  // Symbol that drives this one (for resonance)
    driven_symbols:      [dynamic]^Symbol,  // Symbols this one drives

    // Flags
    flags:               bit_set[Symbol_Flag],
}

// Reference structure
Reference :: struct {
    symbol:              ^Symbol,
    node:                ^Node,
    kind:                Reference_Kind,
    position:            Position,
    index:               int,
}

// Analysis information structures
Branch_Info :: struct {
    pattern:            ^Node,
    result:             ^Node,
    captured_symbols:   map[string]^Symbol,
}

Constraint_Info :: struct {
    target:             ^Symbol,
    constraint:         ^Symbol,
    node:               ^Node,
}

Event_Info :: struct {
    event:              ^Symbol,
    handler:            ^Node,
    is_push:            bool,
    node:               ^Node,
}

Resonance_Info :: struct {
    target:             ^Symbol,
    driver:             ^Symbol,
    is_push:            bool,  // Push (>>-) vs Pull (-<<)
    node:               ^Node,
}

// Main analyzer structure
Analyzer :: struct {
    root_scope:         ^Scope_Info,
    current_scope:      ^Scope_Info,

    // All scopes by ID for direct lookup
    scopes_by_id:       map[u64]^Scope_Info,

    // All symbols by ID for direct lookup
    symbols_by_id:      map[u64]^Symbol,

    // Global symbol information
    builtin_types:      map[string]^Symbol,
    global_symbols:     map[string]^Symbol,
    defined_symbols:    map[string]bool,
    resolution_cache:   map[u64]^Symbol,

    // Error tracking
    errors:             [dynamic]string,
    warnings:           [dynamic]string,

    // Processing state
    in_pattern:         bool,
    current_pattern:    ^Node,
    next_scope_id:      u64,
    next_symbol_id:     u64,

    // File information
    filename:           string,
    resolver:           ^File_Resolver,
}

// ===========================================================================
// SECTION 2: INITIALIZATION
// ===========================================================================

// Initialize the analyzer with the AST root
init_analyzer :: proc(ast: ^Node, resolver: ^File_Resolver, filename: string) -> ^Analyzer {
    analyzer := new(Analyzer)

    // Initialize counters
    analyzer.next_scope_id = 1
    analyzer.next_symbol_id = 1

    // Create root scope
    analyzer.root_scope = create_scope(analyzer, nil, nil, ast, filename)
    analyzer.current_scope = analyzer.root_scope

    // Initialize maps
    analyzer.scopes_by_id = make(map[u64]^Scope_Info)
    analyzer.symbols_by_id = make(map[u64]^Symbol)
    analyzer.builtin_types = make(map[string]^Symbol)
    analyzer.global_symbols = make(map[string]^Symbol)
    analyzer.defined_symbols = make(map[string]bool)
    analyzer.resolution_cache = make(map[u64]^Symbol)

    // Error tracking
    analyzer.errors = make([dynamic]string)
    analyzer.warnings = make([dynamic]string)

    // File information
    analyzer.filename = filename
    analyzer.resolver = resolver

    // Register built-in types
    register_builtin_types(analyzer)

    return analyzer
}

// Create a new scope with proper parent-child relationships
create_scope :: proc(
    analyzer: ^Analyzer,
    parent: ^Scope_Info,
    defining_symbol: ^Symbol,
    node: ^Node,
    name: string
) -> ^Scope_Info {
    scope := new(Scope_Info)

    // Assign unique ID and register
    scope.id = analyzer.next_scope_id
    analyzer.next_scope_id += 1
    analyzer.scopes_by_id[scope.id] = scope

    // Set basic properties
    scope.name = name
    scope.parent = parent
    scope.defining_symbol = defining_symbol
    scope.node = node

    // Initialize collections
    scope.symbols = make(map[string]^Symbol)
    scope.symbol_list = make([dynamic]^Symbol)
    scope.child_scopes = make([dynamic]^Scope_Info)
    scope.expanded_scopes = make([dynamic]^Scope_Info)
    scope.branches = make([dynamic]Branch_Info)
    scope.constraints = make([dynamic]Constraint_Info)
    scope.resonances = make([dynamic]Resonance_Info)
    scope.events = make([dynamic]Event_Info)
    scope.symbol_cache = make(map[u64]^Symbol)

    // Add to parent's child scopes
    if parent != nil {
        append(&parent.child_scopes, scope)
    }

    return scope
}

// Create a new symbol with proper scope relationships
create_symbol :: proc(
    analyzer: ^Analyzer,
    name: string,
    node: ^Node,
    containing_scope: ^Scope_Info,
    kind: Reference_Kind,
    position: Position,
    is_top_level: bool = false
) -> ^Symbol {
    symbol := new(Symbol)

    // Assign unique ID and register
    symbol.id = analyzer.next_symbol_id
    analyzer.next_symbol_id += 1
    analyzer.symbols_by_id[symbol.id] = symbol

    // Set basic properties
    symbol.name = name
    symbol.node = node
    symbol.containing_scope = containing_scope
    symbol.kind = kind
    symbol.position = position
    symbol.references = make([dynamic]^Reference)
    symbol.driven_symbols = make([dynamic]^Symbol)

    // Pre-compute hash
    symbol.hash = calculate_symbol_hash(name)

    // Set top level flag if specified
    if is_top_level {
        symbol.flags += {.IsTopLevel}
    }

    return symbol
}

// Register built-in types
register_builtin_types :: proc(analyzer: ^Analyzer) {
    default_pos := Position{
        line   = 0,
        column = 0,
        offset = 0,
    }

    BUILTIN_TYPES := []string{
        "u8", "u16", "u32", "u64",
        "i8", "i16", "i32", "i64",
        "f32", "f64",
        "char", "String", "bool",
    }

    // Create a special builtins scope (not linked to root scope)
    builtins_scope := create_scope(analyzer, nil, nil, nil, "Builtins")

    for type_name in BUILTIN_TYPES {
        symbol := create_symbol(
            analyzer,
            type_name,
            nil,
            builtins_scope,
            .Builtin,
            default_pos,
            true, // Builtins are top-level
        )
        symbol.flags += {.Builtin}

        // Add to builtin_types map
        analyzer.builtin_types[type_name] = symbol

        // Add to builtins scope but NOT to root scope
        add_symbol_to_scope(analyzer, symbol, builtins_scope)
    }
}

// Helper function to add a symbol to a specific scope without the normal logic
add_symbol_to_scope :: proc(analyzer: ^Analyzer, symbol: ^Symbol, scope: ^Scope_Info) {
    if symbol == nil || scope == nil {
        return
    }

    // Set index and add to lookup tables
    symbol.index = len(scope.symbol_list)

    if symbol.name != "" {
        scope.symbols[symbol.name] = symbol
        scope.symbol_cache[symbol.hash] = symbol
    }

    // Add to symbol list
    append(&scope.symbol_list, symbol)
}

// Add a symbol to a scope with validation
add_symbol :: proc(analyzer: ^Analyzer, symbol: ^Symbol) -> ^Symbol {
    if symbol == nil || symbol.containing_scope == nil {
        return nil
    }

    scope := symbol.containing_scope

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
        symbol.index = len(scope.symbol_list)
        scope.symbols[symbol.name] = symbol
        scope.symbol_cache[symbol.hash] = symbol

        // Add to global index if exported
        if .IsExported in symbol.flags || (symbol.name[0] >= 'A' && symbol.name[0] <= 'Z') {
            qualified_name := get_qualified_name(symbol)
            analyzer.global_symbols[qualified_name] = symbol
            symbol.flags += {.InGlobalIndex}
        }

        // Add to defined symbols for constraint checking
        analyzer.defined_symbols[symbol.name] = true
    } else {
        // Anonymous symbol still gets an index
        symbol.index = len(scope.symbol_list)
    }

    // Add to symbol list
    append(&scope.symbol_list, symbol)

    // Invalidate visible symbols cache for parent scopes
    invalidate_visible_cache(scope.parent)

    return symbol
}

// Add a reference to a symbol
add_reference :: proc(
    analyzer: ^Analyzer,
    symbol: ^Symbol,
    node: ^Node,
    kind: Reference_Kind,
    position: Position
) -> ^Reference {
    if symbol == nil {
        return nil
    }

    // Create reference
    ref := new(Reference)
    ref.symbol = symbol
    ref.node = node
    ref.kind = kind
    ref.position = position
    ref.index = len(symbol.references)

    // Store reference
    symbol.flags += {.Referenced}
    append(&symbol.references, ref)

    // Handle resonance and event references
    if kind == .ResonancePush || kind == .ResonancePull {
        symbol.flags += {.IsResonance}

        // For push (>>-), the symbol is driven by something
        if kind == .ResonancePush {
            symbol.flags += {.IsDriven}
        }

        // For pull (-<<), the symbol drives something else
        if kind == .ResonancePull {
            symbol.flags += {.IsDriver}
        }
    }

    if kind == .EventPush || kind == .EventPull {
        symbol.flags += {.IsEvent}
    }

    return ref
}

// Fast hash calculation
calculate_symbol_hash :: proc(name: string) -> u64 {
    if len(name) == 0 {
        return 0
    }
    return hash.fnv64a(transmute([]byte)name)
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

// Invalidate visible symbols cache for a scope and its parents
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

// ===========================================================================
// SECTION 3: SCOPE HANDLING
// ===========================================================================

// Enter a scope with proper context switching
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

        // Compute visible symbols
        compute_visible_symbols(scope)
        scope.is_visible_computed = true
    }

    return prev_scope
}

// Leave a scope
leave_scope :: proc(analyzer: ^Analyzer, prev_scope: ^Scope_Info) {
    analyzer.current_scope = prev_scope
}

// Compute visible symbols for a scope
compute_visible_symbols :: proc(scope: ^Scope_Info) {
    if scope == nil || scope.parent == nil {
        return
    }

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

    // Copy all symbols from parent's visible set, respect resonance visibility
    for name, symbol in parent.visible_symbols {
        // Skip symbols hidden by resonance (>>-)
        if .IsDriven in symbol.flags && symbol.driver != nil {
            // Only add if this is a pull resonance (-<<) which remains visible
            // or if the driver isn't visible from this scope
            if is_push_resonance(parent, symbol) {
                continue
            }
        }
        scope.visible_symbols[name] = symbol
    }

    // Add parent's direct symbols, respect resonance
    for name, symbol in parent.symbols {
        // Skip if already defined in a closer scope
        if _, exists := scope.visible_symbols[name]; !exists {
            // Skip symbols hidden by resonance
            if .IsDriven in symbol.flags && symbol.driver != nil {
                if is_push_resonance(parent, symbol) {
                    continue
                }
            }
            scope.visible_symbols[name] = symbol
        }
    }

    // Handle expanded scopes from parent
    for expansion in parent.expanded_scopes {
        add_expansion_symbols(scope, expansion)
    }
}

// Check if a symbol is hidden by resonance (>>- operation)
is_push_resonance :: proc(scope: ^Scope_Info, symbol: ^Symbol) -> bool {
    if !(.IsDriven in symbol.flags) || symbol.driver == nil {
        return false
    }

    // Look for resonance info in this scope
    for res in scope.resonances {
        if res.target == symbol {
            return res.is_push  // Push resonance (>>-) hides by default
        }
    }

    // Check parent scopes if needed
    if scope.parent != nil {
        return is_push_resonance(scope.parent, symbol)
    }

    // Default for resonance is false (visible)
    return false
}

// Add expansion symbols to visible symbols
add_expansion_symbols :: proc(scope: ^Scope_Info, expansion: ^Scope_Info) {
    for name, symbol in expansion.symbols {
        // Skip if already defined in a closer scope
        if _, exists := scope.visible_symbols[name]; !exists {
            // Skip symbols hidden by resonance
            if .IsDriven in symbol.flags && symbol.driver != nil {
                if is_push_resonance(expansion, symbol) {
                    continue
                }
            }
            scope.visible_symbols[name] = symbol
        }
    }

    // Add nested expansions
    for nested in expansion.expanded_scopes {
        add_expansion_symbols(scope, nested)
    }
}

// ===========================================================================
// SECTION 4: SYMBOL LOOKUP
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
        // Check if symbol is hidden by resonance
        if .IsDriven in symbol.flags && symbol.driver != nil {
            if is_push_resonance(scope, symbol) {
                // Symbol is hidden by resonance, continue lookup in parent
            } else {
                // Symbol is visible
                analyzer.resolution_cache[cache_key] = symbol
                return symbol
            }
        } else {
            // Normal symbol, not driven by resonance
            analyzer.resolution_cache[cache_key] = symbol
            return symbol
        }
    }

    // Original lookup with scope traversal
    symbol := lookup_symbol_in_scope_chain(analyzer, scope, name, name_hash)

    // If not found in scope chain, try builtins as last resort
    if symbol == nil {
        if builtin, ok := analyzer.builtin_types[name]; ok {
            symbol = builtin
        }
    }

    // Cache the result (even if nil)
    analyzer.resolution_cache[cache_key] = symbol

    return symbol
}

// Lookup in scope chain with resonance awareness
lookup_symbol_in_scope_chain :: proc(
    analyzer: ^Analyzer,
    scope: ^Scope_Info,
    name: string,
    name_hash: u64
) -> ^Symbol {
    current := scope

    for current != nil {
        // Try hash lookup first (faster)
        if symbol, ok := current.symbol_cache[name_hash]; ok {
            if symbol.name == name { // Verify in case of hash collision
                // Skip if hidden by resonance
                if .IsDriven in symbol.flags && symbol.driver != nil {
                    if is_push_resonance(current, symbol) {
                        current = current.parent
                        continue
                    }
                }
                return symbol
            }
        }

        // Fallback to map lookup
        if symbol, ok := current.symbols[name]; ok {
            // Skip if hidden by resonance
            if .IsDriven in symbol.flags && symbol.driver != nil {
                if is_push_resonance(current, symbol) {
                    current = current.parent
                    continue
                }
            }
            return symbol
        }

        // Check expanded scopes
        for expansion in current.expanded_scopes {
            if symbol := lookup_symbol_in_scope(expansion, name, name_hash); symbol != nil {
                return symbol
            }
        }

        current = current.parent
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

// Lookup in a specific scope
lookup_symbol_in_scope :: proc(scope: ^Scope_Info, name: string, name_hash: u64 = 0) -> ^Symbol {
    if scope == nil {
        return nil
    }

    hash := name_hash == 0 ? calculate_symbol_hash(name) : name_hash

    // Try hash lookup first (faster)
    if symbol, ok := scope.symbol_cache[hash]; ok && symbol.name == name {
        // Skip if hidden by resonance
        if .IsDriven in symbol.flags && symbol.driver != nil {
            if is_push_resonance(scope, symbol) {
                return nil
            }
        }
        return symbol
    }

    // Fallback to map lookup
    if symbol, ok := scope.symbols[name]; ok {
        // Skip if hidden by resonance
        if .IsDriven in symbol.flags && symbol.driver != nil {
            if is_push_resonance(scope, symbol) {
                return nil
            }
        }
        return symbol
    }

    // Check expanded scopes
    for expansion in scope.expanded_scopes {
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
        // Skip if hidden by resonance
        if .IsDriven in symbol.flags && symbol.driver != nil {
            if is_push_resonance(scope, symbol) {
                return nil
            }
        }
        return symbol
    }

    // Fallback to map
    if symbol, ok := scope.symbols[name]; ok {
        // Skip if hidden by resonance
        if .IsDriven in symbol.flags && symbol.driver != nil {
            if is_push_resonance(scope, symbol) {
                return nil
            }
        }
        return symbol
    }

    // Check expanded scopes
    for expansion in scope.expanded_scopes {
        if symbol := lookup_symbol_in_scope(expansion, name, name_hash); symbol != nil {
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
        if symbol.containing_scope == current {
            // Skip if hidden by resonance
            if .IsDriven in symbol.flags && symbol.driver != nil {
                if is_push_resonance(current, symbol) {
                    return false
                }
            }
            return true
        }

        // Check expanded scopes
        for expansion in current.expanded_scopes {
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
    if symbol.containing_scope == expansion {
        // Skip if hidden by resonance
        if .IsDriven in symbol.flags && symbol.driver != nil {
            if is_push_resonance(expansion, symbol) {
                return false
            }
        }
        return true
    }

    // Check nested expansions
    for nested in expansion.expanded_scopes {
        if is_in_expansion(nested, symbol) {
            return true
        }
    }

    return false
}

// ===========================================================================
// SECTION 5: MAIN ANALYSIS FUNCTIONS
// ===========================================================================

// Analyze the AST with proper scope handling
analyze_ast :: proc(ast: ^Node, resolver: ^File_Resolver, filename: string) -> ^Analyzer {
    // Initialize analyzer with the AST root as the global scope
    analyzer := init_analyzer(ast, resolver, filename)

    // Process the root scope directly - top-down traversal
    #partial switch n in ast {
    case Scope:
        for i := 0; i < len(n.value); i += 1 {
            // All direct children of a scope are top-level nodes
            process_node(analyzer, &n.value[i], analyzer.root_scope, true)
        }
    }

    // Final validation passes
    validate_analysis(analyzer)

    return analyzer
}

// Process a single node - enhanced for resonance
process_node :: proc(analyzer: ^Analyzer, node: ^Node, scope: ^Scope_Info, is_top_level: bool = false) {
    if node == nil {
        return
    }

    // Save current scope
    prev_scope := analyzer.current_scope
    if scope != analyzer.current_scope {
        analyzer.current_scope = scope
    }

    position := get_position_from_node(node)

    // CORE PRINCIPLE: Any direct child of a scope gets a symbol
    // If this is a top-level node (direct child of a scope), create a symbol for it
    if is_top_level {
        name := ""

        #partial switch n in node^ {
        case Pointing:
            if n.name != nil {
                if id, ok := n.name^.(Identifier); ok {
                    name = id.name
                }
            }
        case PointingPull:
            if n.name != nil {
                if id, ok := n.name^.(Identifier); ok {
                    name = id.name
                }
            }
        case Identifier:
            name = n.name
        }
    }

    // Process by node type
    #partial switch n in node^ {
    case Scope:
        // Handle empty scope vs. scope with content
        if len(n.value) == 0 {
            // Empty scope - symbol already created if top level
            if !is_top_level {
                symbol := create_symbol(analyzer, "", node, analyzer.current_scope, .Definition, position)
                add_symbol(analyzer, symbol)
            }
        } else {
            // Regular scope with content
            scope_info := create_scope(analyzer, analyzer.current_scope, nil, node, "")

            // Enter new scope
            prev_inner_scope := enter_scope(analyzer, scope_info)

            // Process all children - ALL direct children of a scope are top-level in that scope
            for i := 0; i < len(n.value); i += 1 {
                process_node(analyzer, &n.value[i], scope_info, true)
            }

            // Restore scope
            leave_scope(analyzer, prev_inner_scope)
        }

    case Pointing:
        process_pointing(analyzer, node, n, position, is_top_level)

    case PointingPull:
        process_pointing_pull(analyzer, node, n, position, is_top_level)

    case EventPush:
        process_event_push(analyzer, node, n, position, is_top_level)

    case EventPull:
        process_event_pull(analyzer, node, n, position, is_top_level)

    case ResonancePush:
        process_resonance_push(analyzer, node, n, position, is_top_level)

    case ResonancePull:
        process_resonance_pull(analyzer, node, n, position, is_top_level)

    case Override:
        process_override(analyzer, node, n, position, is_top_level)

    case Pattern:
        process_pattern(analyzer, node, n, position, is_top_level)

    case Constraint:
        process_constraint(analyzer, node, n, position, is_top_level)
case Product:
        process_product(analyzer, node, n, position, is_top_level)

    case Execute:
        if n.value != nil {
            process_node(analyzer, n.value, analyzer.current_scope, false)
        }

    case Expand:
        process_expand(analyzer, node, n, position, is_top_level)

    case Identifier:
        process_identifier(analyzer, node, n, position, is_top_level)

    case Literal:
        // Don't need to create a symbol here - top-level literals get symbols from the general rule above
        // Non-top-level literals don't get symbols

    case Operator:
        // Operators don't get symbols, but their children are not top-level
        if n.left != nil {
            process_node(analyzer, n.left, analyzer.current_scope, false)
        }
        if n.right != nil {
            process_node(analyzer, n.right, analyzer.current_scope, false)
        }

    case Range:
        // Children of a range are not top-level
        if n.start != nil {
            process_node(analyzer, n.start, analyzer.current_scope, false)
        }
        if n.end != nil {
            process_node(analyzer, n.end, analyzer.current_scope, false)
        }

    case Property:
        // Children of a property are not top-level
        if n.source != nil {
            process_node(analyzer, n.source, analyzer.current_scope, false)
        }
        if n.property != nil {
            process_node(analyzer, n.property, analyzer.current_scope, false)
        }
    }

    // Restore scope
    if scope != prev_scope {
        analyzer.current_scope = prev_scope
    }
}

// Process pointing nodes (name -> value)
process_pointing :: proc(
    analyzer: ^Analyzer,
    node: ^Node,
    pointing: Pointing,
    position: Position,
    is_top_level: bool,
) {
    // A pointing node must have a name
    if pointing.name == nil {
        add_error(analyzer, "Pointing node has no name", position)
        return
    }

    // Only top-level nodes should create symbols
    if !is_top_level {
        // Process children nodes without creating symbols
        process_node(analyzer, pointing.name, analyzer.current_scope, false)
        if pointing.value != nil {
            process_node(analyzer, pointing.value, analyzer.current_scope, false)
        }
        return
    }

    // For top-level pointing nodes, determine name and constraint
    name := ""
    constraint_symbol: ^Symbol = nil

    // Extract name and constraint from the name field
    if id, is_id := pointing.name^.(Identifier); is_id {
        // Simple case: name is an identifier
        name = id.name
    } else if constraint, is_constraint := pointing.name^.(Constraint); is_constraint {
        // The name is a constraint expression

        // Get constraint type
        if type_id, is_type_id := constraint.constraint^.(Identifier); is_type_id {
            constraint_symbol = lookup_symbol(analyzer, type_id.name)
            if constraint_symbol == nil {
                add_error(analyzer, fmt.tprintf("Undefined constraint type '%s'", type_id.name), position)
            }
        } else {
            // Complex constraint type, process it
            process_node(analyzer, constraint.constraint, analyzer.current_scope, false)
        }

        // Get the name from constraint value if present
        if constraint.value != nil {
            if value_id, is_value_id := constraint.value^.(Identifier); is_value_id {
                name = value_id.name
            } else {
                // Complex constraint value, process it
                process_node(analyzer, constraint.value, analyzer.current_scope, false)
            }
        }
    } else {
        // Complex name expression, process it
        process_node(analyzer, pointing.name, analyzer.current_scope, false)
    }

    // Create a symbol for this pointing (named or anonymous)
    symbol := create_symbol(analyzer, name, node, analyzer.current_scope, .Definition, position, true)

    // Apply constraint if one was found
    if constraint_symbol != nil {
        symbol.constraint = constraint_symbol
        symbol.flags += {.HasConstraint}

        // Add constraint info to the scope
        constraint_info := Constraint_Info{
            target     = symbol,
            constraint = constraint_symbol,
            node       = node,
        }

        append(&analyzer.current_scope.constraints, constraint_info)
    }

    // Add the symbol to the scope
    add_symbol(analyzer, symbol)

    // Process the value
    if pointing.value != nil {
        if sc, ok := pointing.value^.(Scope); ok {
            // Create child scope if value is a non-empty scope
            if len(sc.value) > 0 {
                scope_info := create_scope(
                    analyzer,
                    analyzer.current_scope,
                    symbol,
                    pointing.value,
                    name == "" ? "<anonymous>" : name
                )

                symbol.introduced_scope = scope_info

                // Process scope contents
                prev_scope := enter_scope(analyzer, scope_info)

                for i := 0; i < len(sc.value); i += 1 {
                    process_node(analyzer, &sc.value[i], scope_info, true)
                }

                leave_scope(analyzer, prev_scope)
            }
        } else {
            // Regular value
            process_node(analyzer, pointing.value, analyzer.current_scope, false)
        }
    }
}

// Process pointing pull nodes (name <- value)
process_pointing_pull :: proc(
    analyzer: ^Analyzer,
    node: ^Node,
    pointing_pull: PointingPull,
    position: Position,
    is_top_level: bool,
) {
    // Handle anonymous pointing pull
    if pointing_pull.name == nil {
        // Anonymous symbol already created if top-level

        if pointing_pull.value != nil {
            // Value is not top-level
            process_node(analyzer, pointing_pull.value, analyzer.current_scope, false)
        }
        return
    }

    // Get the name
    name: string
    if id, ok := pointing_pull.name^.(Identifier); ok {
        name = id.name
    } else {
        // Complex expression
        process_node(analyzer, pointing_pull.name, analyzer.current_scope, false)
        if pointing_pull.value != nil {
            process_node(analyzer, pointing_pull.value, analyzer.current_scope, false)
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
        is_top_level,
    )
    add_symbol(analyzer, symbol)

    if pointing_pull.value != nil {
        // Process constraint value
        if id, is_id := pointing_pull.value^.(Identifier); is_id {
            constraint := lookup_symbol(analyzer, id.name)
            if constraint != nil {
                symbol.constraint = constraint
                symbol.flags += {.HasConstraint}

                constraint_info := Constraint_Info{
                    target = symbol,
                    constraint = constraint,
                    node = node,
                }

                append(&analyzer.current_scope.constraints, constraint_info)
                add_reference(analyzer, constraint, node, .Constraint, position)
            }
        } else {
            // Complex constraint, process it
            process_node(analyzer, pointing_pull.value, analyzer.current_scope, false)
        }
    }
}

// Process event push nodes (a >- b)
process_event_push :: proc(
    analyzer: ^Analyzer,
    node: ^Node,
    event_push: EventPush,
    position: Position,
    is_top_level: bool,
) {
    // Anonymous event push
    if event_push.name == nil {
        // Anonymous symbol already created if top-level

        if event_push.value != nil {
            // Value is not top-level
            process_node(analyzer, event_push.value, analyzer.current_scope, false)
        }
        return
    }

    // Process target
    process_node(analyzer, event_push.name, analyzer.current_scope, false)

    // Create event info
    event_info := Event_Info{
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
                is_top_level,
            )
            symbol.flags += {.IsEvent}
            add_symbol(analyzer, symbol)
            event_info.event = symbol
        }
    }

    // Process handler
    if event_push.value != nil {
        event_info.handler = event_push.value
        // Handler is not top-level
        process_node(analyzer, event_push.value, analyzer.current_scope, false)
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
    is_top_level: bool,
) {
    // Anonymous event pull
    if event_pull.name == nil {
        // Anonymous symbol already created if top-level

        if event_pull.value != nil {
            // Value is not top-level
            process_node(analyzer, event_pull.value, analyzer.current_scope, false)
        }
        return
    }

    // Process handler name
    name: string = ""
    if id, ok := event_pull.name^.(Identifier); ok {
        name = id.name
    } else {
        process_node(analyzer, event_pull.name, analyzer.current_scope, false)
    }

    // Create event info
    event_info := Event_Info{
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
                is_top_level,
            )
            symbol.flags += {.IsEvent}
            add_symbol(analyzer, symbol)
        } else {
            add_reference(analyzer, symbol, node, .EventPull, position)
            event_info.event = symbol
        }

        // Process handler
        if event_pull.value != nil {
            event_info.handler = event_pull.value
            // Handler is not top-level
            process_node(analyzer, event_pull.value, analyzer.current_scope, false)
        }

        // Add to events list
        append(&analyzer.current_scope.events, event_info)
    }
}

// Process resonance push nodes (a >>- b)
process_resonance_push :: proc(
    analyzer: ^Analyzer,
    node: ^Node,
    resonance_push: ResonancePush,
    position: Position,
    is_top_level: bool,
) {
    // Anonymous resonance push
    if resonance_push.name == nil {
        // Anonymous symbol already created if top-level

        if resonance_push.value != nil {
            // Value is not top-level
            process_node(analyzer, resonance_push.value, analyzer.current_scope, false)
        }
        return
    }

    // Process target
    process_node(analyzer, resonance_push.name, analyzer.current_scope, false)

    // Create resonance info
    resonance_info := Resonance_Info{
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
        // Value is not top-level
        process_node(analyzer, resonance_push.value, analyzer.current_scope, false)

        // Set driver if it's an identifier
        if id, ok := resonance_push.value^.(Identifier); ok {
            driver := lookup_symbol(analyzer, id.name)
            if driver != nil {
                resonance_info.driver = driver
                driver.flags += {.IsDriver}

                if resonance_info.target != nil {
                    resonance_info.target.driver = driver
                    append(&driver.driven_symbols, resonance_info.target)
                }

                add_reference(analyzer, driver, node, .ResonancePush, position)
            }
        }
    }

    // Add to resonances list
    append(&analyzer.current_scope.resonances, resonance_info)

    // Invalidate visible symbols cache since resonance affects visibility
    invalidate_visible_cache(analyzer.current_scope)
}

// Process resonance pull nodes (a -<< b)
process_resonance_pull :: proc(
    analyzer: ^Analyzer,
    node: ^Node,
    resonance_pull: ResonancePull,
    position: Position,
    is_top_level: bool,
) {
    // Anonymous resonance pull
    if resonance_pull.name == nil {
        // Anonymous symbol already created if top-level

        if resonance_pull.value != nil {
            // Value is not top-level
            process_node(analyzer, resonance_pull.value, analyzer.current_scope, false)
        }
        return
    }

    // Get name from identifier
    name: string = ""
    if id, ok := resonance_pull.name^.(Identifier); ok {
        name = id.name
    }

    // Process target
    process_node(analyzer, resonance_pull.name, analyzer.current_scope, false)

    // Create resonance info
    resonance_info := Resonance_Info{
        is_push = false, // Pull resonance (-<<)
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
                is_top_level,
            )
            symbol.flags += {.IsResonance, .IsDriver}
            add_symbol(analyzer, symbol)
        }
        resonance_info.target = symbol
        add_reference(analyzer, symbol, node, .ResonancePull, position)
    }

    // Process driver
    if resonance_pull.value != nil {
        // Value is not top-level
        process_node(analyzer, resonance_pull.value, analyzer.current_scope, false)

        // Set driver if it's an identifier
        if id, ok := resonance_pull.value^.(Identifier); ok {
            driver := lookup_symbol(analyzer, id.name)
            if driver != nil {
                resonance_info.driver = driver
                driver.flags += {.IsDriven}

                if resonance_info.target != nil {
                    driver.driver = resonance_info.target
                    append(&resonance_info.target.driven_symbols, driver)
                }

                add_reference(analyzer, driver, node, .ResonancePull, position)
            }
        }
    }

    // Add to resonances list
    append(&analyzer.current_scope.resonances, resonance_info)

    // Invalidate visible symbols cache since resonance affects visibility
    invalidate_visible_cache(analyzer.current_scope)
}

// Process override nodes (a{...})
process_override :: proc(
    analyzer: ^Analyzer,
    node: ^Node,
    override: Override,
    position: Position,
    is_top_level: bool,
) {
    // Process base
    if override.source != nil {
        // Source is not top-level
        process_node(analyzer, override.source, analyzer.current_scope, false)

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
        // Overrides are not top-level
        process_node(analyzer, &override.overrides[i], analyzer.current_scope, false)
    }
}

// Process pattern match nodes (target ? {...})
process_pattern :: proc(
    analyzer: ^Analyzer,
    node: ^Node,
    pattern: Pattern,
    position: Position,
    is_top_level: bool,
) {
    // Process target
    if pattern.target != nil {
        // Target is not top-level
        process_node(analyzer, pattern.target, analyzer.current_scope, false)
    }

    // Create pattern scope
    pattern_scope := create_scope(analyzer, analyzer.current_scope, nil, node, "")
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
        branch_info := Branch_Info{
            pattern          = branch.source,
            result           = branch.product,
            captured_symbols = make(map[string]^Symbol),
        }

        // Process pattern and result (they are top-level in the pattern scope)
        if branch.source != nil {
            process_node(analyzer, branch.source, pattern_scope, true)
        }
        if branch.product != nil {
            process_node(analyzer, branch.product, pattern_scope, true)
        }

        // Add to branches list
        append(&pattern_scope.branches, branch_info)
    }

    // Restore context
    analyzer.in_pattern = prev_in_pattern
    analyzer.current_pattern = prev_pattern
    analyzer.current_scope = prev_scope
}

// Process constraint nodes (Constraint: value)
process_constraint :: proc(
    analyzer: ^Analyzer,
    node: ^Node,
    constraint: Constraint,
    position: Position,
    is_top_level: bool,
) {
    // Only top-level constraints should create symbols
    if !is_top_level {
        // Process children without creating symbols
        process_node(analyzer, constraint.constraint, analyzer.current_scope, false)
        if constraint.value != nil {
            process_node(analyzer, constraint.value, analyzer.current_scope, false)
        }
        return
    }

    // For top-level constraints, create symbols and add to scope

    // Get constraint type
    constraint_symbol: ^Symbol = nil
    if id, is_id := constraint.constraint^.(Identifier); is_id {
        constraint_symbol = lookup_symbol(analyzer, id.name)
        if constraint_symbol == nil {
            add_error(analyzer, fmt.tprintf("Undefined constraint type '%s'", id.name), position)
        }
    } else {
        process_node(analyzer, constraint.constraint, analyzer.current_scope, false)
    }

    // Create symbol based on constraint value
    if constraint.value == nil {
        // Anonymous constraint
        symbol := create_symbol(analyzer, "", node, analyzer.current_scope, .Definition, position, true)

        if constraint_symbol != nil {
            symbol.constraint = constraint_symbol
            symbol.flags += {.HasConstraint}

            constraint_info := Constraint_Info{
                target     = symbol,
                constraint = constraint_symbol,
                node       = node,
            }

            append(&analyzer.current_scope.constraints, constraint_info)
        }

        add_symbol(analyzer, symbol)
    } else if id, is_id := constraint.value^.(Identifier); is_id {
        // Named constraint
        symbol := create_symbol(analyzer, id.name, node, analyzer.current_scope, .Definition, position, true)

        if constraint_symbol != nil {
            symbol.constraint = constraint_symbol
            symbol.flags += {.HasConstraint}

            constraint_info := Constraint_Info{
                target     = symbol,
                constraint = constraint_symbol,
                node       = node,
            }

            append(&analyzer.current_scope.constraints, constraint_info)
        }

        add_symbol(analyzer, symbol)
    } else {
        // Complex value
        process_node(analyzer, constraint.value, analyzer.current_scope, false)

        // Create anonymous symbol for the constraint
        symbol := create_symbol(analyzer, "", node, analyzer.current_scope, .Definition, position, true)

        if constraint_symbol != nil {
            symbol.constraint = constraint_symbol
            symbol.flags += {.HasConstraint}

            constraint_info := Constraint_Info{
                target     = symbol,
                constraint = constraint_symbol,
                node       = node,
            }

            append(&analyzer.current_scope.constraints, constraint_info)
        }

        add_symbol(analyzer, symbol)
    }
}

// Process product nodes (-> value)
process_product :: proc(analyzer: ^Analyzer, node: ^Node, product: Product, position: Position, is_top_level: bool) {
    // Anonymous symbol already created if top-level

    // Process value - not top-level
    if product.value != nil {
        process_node(analyzer, product.value, analyzer.current_scope, false)
    }
}

// Process expand nodes (...expr)
process_expand :: proc(
    analyzer: ^Analyzer,
    node: ^Node,
    expand: Expand,
    position: Position,
    is_top_level: bool,
) {
    // Process target - not top-level
    if expand.target != nil {
        process_node(analyzer, expand.target, analyzer.current_scope, false)

        // Check if it's an identifier for expansion
        if id, ok := expand.target^.(Identifier); ok {
            symbol := lookup_symbol(analyzer, id.name)
            if symbol == nil {
                add_error(analyzer, fmt.tprintf("Cannot expand undefined '%s'", id.name), position)
            } else {
                add_reference(analyzer, symbol, node, .Usage, position)

                // Add to expansions if it has an introduced scope
                if symbol.introduced_scope != nil {
                    append(&analyzer.current_scope.expanded_scopes, symbol.introduced_scope)

                    // Invalidate visible symbols cache
                    invalidate_visible_cache(analyzer.current_scope)
                }
            }
        }
    }
}

// Process identifier nodes
process_identifier :: proc(analyzer: ^Analyzer, node: ^Node, id: Identifier, position: Position, is_top_level: bool) {
    // Fast lookup using name hash
    name_hash := calculate_symbol_hash(id.name)

    // If this is a top-level identifier, we've already created a symbol for it
    if is_top_level && analyzer.in_pattern {
        // In pattern context, we define symbols for identifiers
        symbol := create_symbol(
            analyzer,
            id.name,
            node,
            analyzer.current_scope,
            .Definition,
            position,
            true,
        )
        add_symbol(analyzer, symbol)
        return
    }

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
                is_top_level,
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

// ===========================================================================
// SECTION 6: VALIDATION
// ===========================================================================

// Combined validation passes
validate_analysis :: proc(analyzer: ^Analyzer) {
    // Validate all constraints
    validate_constraints(analyzer)

    // Validate resonance relationships
    validate_resonance(analyzer)

    // Validate patterns
    validate_patterns(analyzer)

    // Validate events
    validate_events(analyzer)
}

// Validate constraints and check completeness
validate_constraints :: proc(analyzer: ^Analyzer) {
    // Check for constraint conflicts
    for _, scope in analyzer.scopes_by_id {
        for constraint in scope.constraints {
            validate_constraint(analyzer, constraint)
        }
    }
}

// Validate a single constraint
validate_constraint :: proc(analyzer: ^Analyzer, constraint: Constraint_Info) {
    if constraint.target == nil || constraint.constraint == nil {
        return
    }

    // Special check for None constraint - these are allowed to be overridden
    if constraint.constraint.name == "None" {
        // Allow multiple None constraints
        return
    }

    // For non-None constraints, check for conflicts
    target := constraint.target
    if target.constraint != nil && target.constraint != constraint.constraint {
        // Check if one is a None constraint (allowed)
        if target.constraint.name == "None" || constraint.constraint.name == "None" {
            return
        }

        // Otherwise it's a conflict
        add_error(
            analyzer,
            fmt.tprintf("Incompatible constraints for '%s': %s and %s",
                target.name,
                target.constraint.name,
                constraint.constraint.name),
            get_position_from_node(constraint.node)
        )
    }
}

// Validate resonance relationships
validate_resonance :: proc(analyzer: ^Analyzer) {
    // Check for multiple drivers of the same symbol
    driven_symbols := make(map[u64]^Symbol)
    defer delete(driven_symbols)

    for _, scope in analyzer.scopes_by_id {
        for resonance in scope.resonances {
            if resonance.target != nil && resonance.is_push {
                // For push resonance (>>-), check if target already has a driver
                if previous, has_driver := driven_symbols[resonance.target.id]; has_driver {
                    add_error(
                        analyzer,
                        fmt.tprintf("Symbol '%s' is driven by multiple resonances",
                            resonance.target.name),
                        get_position_from_node(resonance.node)
                    )
                } else {
                    driven_symbols[resonance.target.id] = resonance.target
                }
            }
        }
    }
}

// Validate pattern completeness
validate_patterns :: proc(analyzer: ^Analyzer) {
    for _, scope in analyzer.scopes_by_id {
        if scope.is_pattern {
            // Check for a catchall case
            has_catchall := false
            for branch in scope.branches {
                if branch.pattern == nil {
                    has_catchall = true
                    break
                }

                // A lone identifier in a pattern is also a catchall
                if id, is_id := branch.pattern^.(Identifier); is_id {
                    has_catchall = true
                    break
                }
            }

            if !has_catchall && len(scope.branches) > 0 {
                add_warning(
                    analyzer,
                    "Pattern match may not be exhaustive, consider adding a catchall case",
                    get_position_from_node(scope.node)
                )
            }
        }
    }
}

// Validate event handlers
validate_events :: proc(analyzer: ^Analyzer) {
    // Track which events have handlers
    event_handlers := make(map[u64]bool)
    defer delete(event_handlers)

    // First pass: collect all event handlers
    for _, scope in analyzer.scopes_by_id {
        for event in scope.events {
            if !event.is_push && event.event != nil {
                event_handlers[event.event.id] = true
            }
        }
    }

    // Second pass: check for unhandled events
    for _, scope in analyzer.scopes_by_id {
        for event in scope.events {
            if event.is_push && event.event != nil {
                if !event_handlers[event.event.id] {
                    add_warning(
                        analyzer,
                        fmt.tprintf("Event '%s' is pushed but not handled by any event handler",
                            event.event.name),
                        get_position_from_node(event.node)
                    )
                }
            }
        }
    }
}

// ===========================================================================
// SECTION 7: UTILITIES
// ===========================================================================

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

// Get a fully qualified name for a symbol
get_qualified_name :: proc(symbol: ^Symbol) -> string {
    if symbol == nil {
        return "<nil>"
    }

    if symbol.name == "" {
        return fmt.tprintf("<anonymous>@%d", symbol.index)
    }

    // For built-in types, just return the name
    if .Builtin in symbol.flags {
        return symbol.name
    }

    // For global scope, just return the name
    if symbol.containing_scope != nil && symbol.containing_scope.parent == nil {
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

    return strings.to_string(builder)
}

// Build a path to a symbol
build_path_to_symbol :: proc(builder: ^strings.Builder, symbol: ^Symbol) {
    if symbol == nil || builder == nil {
        return
    }

    // Build path to containing scope first
    scope := symbol.containing_scope
    if scope != nil && scope.parent != nil {
        if scope.defining_symbol != nil {
            // Recurse up the chain
            build_path_to_symbol(builder, scope.defining_symbol)
            strings.write_string(builder, ".")
        }
    }

    // Add this symbol's name
    if symbol.name != "" {
        strings.write_string(builder, symbol.name)
        if symbol.index > 0 {
            fmt.sbprintf(builder, "@%d", symbol.index)
        }
    } else {
        fmt.sbprintf(builder, "<anonymous>@%d", symbol.index)
    }
}

// ===========================================================================
// SECTION 8: PRETTY PRINTING
// ===========================================================================

// Print the symbol table with proper scope nesting
print_symbol_table :: proc(analyzer: ^Analyzer) {
    fmt.println("\n=== SYMBOL TABLE ===")

    // Print builtins section
    fmt.println("Builtins:")
    for name, symbol in analyzer.builtin_types {
        fmt.printf("  %s (id:%d, flag:%v)\n", name, symbol.id, symbol.flags)
    }

    // Print the root scope with detailed debug info
    fmt.println("\n")
    print_scope(analyzer.root_scope, 0)

    fmt.println("=== END SYMBOL TABLE  ===\n")
}

// Printing with node types and IDs
print_scope :: proc(scope: ^Scope_Info, depth: int) {
    if scope == nil do return

    indent := strings.repeat("  ", depth)

    // Print scope details
    scope_name := "Global Scope"
    if scope.defining_symbol != nil {
        if scope.defining_symbol.name != "" {
            scope_name = scope.defining_symbol.name
        } else {
            scope_name = "<anonymous>"
        }
        node_type_name := "nil"
        if scope.node != nil {
            node_type_name = fmt.tprintf("%T", scope.node^)
        }
        fmt.printf("%sScope: %s (id:%d, symbol_id:%d, node_type:%s)\n",
            indent, scope_name, scope.id, scope.defining_symbol.id, node_type_name)
    } else {
        node_type_name := "nil"
        if scope.node != nil {
            node_type_name = fmt.tprintf("%T", scope.node^)
        }
        fmt.printf("%sScope: <unnamed> (id:%d, no_defining_symbol, node_type:%s)\n",
            indent, scope.id, node_type_name)
    }

    // Print all symbols in this scope with detailed info
    for symbol in scope.symbol_list {
        // Get node type info
        node_type := "nil"
        if symbol.node != nil {
            #partial switch n in symbol.node^ {
            case Scope:
                node_type = "Scope"
            case Pointing:
                node_type = "Pointing"
            case PointingPull:
                node_type = "PointingPull"
            case Literal:
                node_type = "Literal"
            case Identifier:
                node_type = "Identifier"
            case Product:
                node_type = "Product"
            case:
                node_type = fmt.tprintf("%T", symbol.node^)
            }
        }

        // Print symbol with debug info including flags and constraints on the same line
        symbol_info := ""

        // Add flags to info
        if symbol.flags != {} {
            symbol_info = fmt.tprintf("%s, flags:%v", symbol_info, symbol.flags)
        }

        // Add constraint to info
        if .HasConstraint in symbol.flags && symbol.constraint != nil {
            constraint_name: string
            if symbol.constraint.name != "" {
                constraint_name = symbol.constraint.name
            } else {
                constraint_name = fmt.tprintf("<anonymous>@%d", symbol.constraint.index)
            }
            symbol_info = fmt.tprintf("%s, constraint:%s", symbol_info, constraint_name)
        }

        // Add driver to info
        if .IsDriven in symbol.flags && symbol.driver != nil {
            driver_name: string
            if symbol.driver.name != "" {
                driver_name = symbol.driver.name
            } else {
                driver_name = fmt.tprintf("<anonymous>@%d", symbol.driver.index)
            }
            symbol_info = fmt.tprintf("%s, driven_by:%s", symbol_info, driver_name)
        }

        // Print the symbol with all the combined info
        if symbol.name != "" {
            fmt.printf("%s  Symbol: %s (id:%d, index:%d, node_type:%s, kind:%v%s)\n",
                indent, symbol.name, symbol.id, symbol.index, node_type, symbol.kind, symbol_info)
        } else {
            fmt.printf("%s  Symbol: <anonymous> (id:%d, index:%d, node_type:%s, kind:%v%s)\n",
                indent, symbol.id, symbol.index, node_type, symbol.kind, symbol_info)
        }

        // Print references count if any
        if len(symbol.references) > 0 {
            fmt.printf("%s    References: %d\n", indent, len(symbol.references))
        }

        // Print info about introduced scope if any
        if symbol.introduced_scope != nil {
            fmt.printf("%s    → Introduces scope (id:%d)\n", indent, symbol.introduced_scope.id)
            print_scope(symbol.introduced_scope, depth + 1)
        }
    }


    // Print resonances section if any resonances exist
    if len(scope.resonances) > 0 {
        fmt.printf("%s  === Resonances (%d) ===\n", indent, len(scope.resonances))
        for resonance, i in scope.resonances {
            target_name := "nil"
            if resonance.target != nil {
                if resonance.target.name != "" {
                    target_name = resonance.target.name
                } else {
                    target_name = fmt.tprintf("<anonymous>@%d", resonance.target.index)
                }
            }

            driver_name := "nil"
            if resonance.driver != nil {
                if resonance.driver.name != "" {
                    driver_name = resonance.driver.name
                } else {
                    driver_name = fmt.tprintf("<anonymous>@%d", resonance.driver.index)
                }
            }

            direction: string
            if resonance.is_push {
                direction = "push"
            } else {
                direction = "pull"
            }

            fmt.printf("%s    Resonance %d: %s %s driver %s\n",
                indent, i, target_name, direction, driver_name)
        }
    }

    // Print events section if any events exist
    if len(scope.events) > 0 {
        fmt.printf("%s  === Events (%d) ===\n", indent, len(scope.events))
        for event, i in scope.events {
            event_name := "nil"
            if event.event != nil {
                if event.event.name != "" {
                    event_name = event.event.name
                } else {
                    event_name = fmt.tprintf("<anonymous>@%d", event.event.index)
                }
            }

            direction: string
            if event.is_push {
                direction = "push"
            } else {
                direction = "pull"
            }

            has_handler: string
            if event.handler != nil {
                has_handler = "with handler"
            } else {
                has_handler = "no handler"
            }

            fmt.printf("%s    Event %d: %s (%s) %s\n",
                indent, i, event_name, direction, has_handler)
        }
    }

    // Print branches section if this is a pattern scope
    if scope.is_pattern && len(scope.branches) > 0 {
        fmt.printf("%s  === Pattern Branches (%d) ===\n", indent, len(scope.branches))
        for i := 0; i < len(scope.branches); i += 1 {
            fmt.printf("%s    Branch %d: pattern-match branch\n", indent, i)
        }
    }

    // Print child scopes that don't have defining symbols
    for child in scope.child_scopes {
        if child.defining_symbol == nil {
            print_scope(child, depth + 1)
        }
    }
}

// Print scope graph summary
print_scope_graph :: proc(analyzer: ^Analyzer) {
    fmt.println("\n=== SCOPE GRAPH SUMMARY ===")
    fmt.printf("Total scopes: %d\n", len(analyzer.scopes_by_id))
    fmt.printf("Total symbols: %d\n", len(analyzer.symbols_by_id))
    fmt.printf("Root scope symbols: %d\n", len(analyzer.root_scope.symbol_list))
    fmt.println("=== END SCOPE GRAPH SUMMARY ===\n")
}

// ===========================================================================
// SECTION 9: MEMORY MANAGEMENT & CLEANUP
// ===========================================================================

// Clean up all resources
destroy_analyzer :: proc(analyzer: ^Analyzer) {
    if analyzer == nil do return

    // Free all scopes
    for _, scope in analyzer.scopes_by_id {
        destroy_scope(scope)
    }

    // Free all symbols
    for _, symbol in analyzer.symbols_by_id {
        destroy_symbol(symbol)
    }

    // Free collections
    delete(analyzer.scopes_by_id)
    delete(analyzer.symbols_by_id)
    delete(analyzer.builtin_types)
    delete(analyzer.global_symbols)
    delete(analyzer.defined_symbols)
    delete(analyzer.resolution_cache)
    delete(analyzer.errors)
    delete(analyzer.warnings)

    // Free the analyzer itself
    free(analyzer)
}

// Destroy a scope
destroy_scope :: proc(scope: ^Scope_Info) {
    if scope == nil do return

    // Free collections
    delete(scope.symbols)
    delete(scope.symbol_list)
    delete(scope.child_scopes)
    delete(scope.expanded_scopes)
    delete(scope.branches)
    delete(scope.constraints)
    delete(scope.resonances)
    delete(scope.events)
    delete(scope.symbol_cache)

    if scope.visible_symbols != nil {
        delete(scope.visible_symbols)
    }
}

// Destroy a symbol
destroy_symbol :: proc(symbol: ^Symbol) {
    if symbol == nil do return

    // Free references
    for ref in symbol.references {
        free(ref)
    }
    delete(symbol.references)
    delete(symbol.driven_symbols)
}

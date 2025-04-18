package compiler

import "base:runtime"
import "core:fmt"
import "core:hash"
import vmem "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

/*
 * ====================================================================
 * High-Performance File System Resolver for Homoiconic Language
 *
 * This module integrates with the existing optimized analyzer
 * to handle @references with efficient caching, threading, and memory
 * management techniques.
 * ====================================================================
 */

// State flags for file processing
STATE_UNPROCESSED :: u32(0)
STATE_QUEUED :: u32(1)
STATE_PROCESSING :: u32(2)
STATE_PROCESSED :: u32(3)
STATE_FAILED :: u32(4)

// File cache entry
File_Cache_Entry :: struct {
	path:         string, // Full path to the file
	mod_time:     i64, // Modification time
	file_size:    i64, // File size for quick change detection
	hash:         u64, // Content hash
	ast:          ^Node, // Parsed AST
	analyzer:     ^Analyzer, // Analyzer for this file
	symbol:       ^Symbol, // Symbol representing this file
	dependencies: [dynamic]string, // Files this file depends on
	state:        u32, // Processing state (atomic)
	worker_id:    i32, // ID of worker processing this file
	lock:         sync.Atomic_Mutex, // Lock for updating this entry
}

// Thread pool worker
Worker :: struct {
	id:          int, // Worker ID
	thread:      ^thread.Thread, // Thread handle
	pool:        ^Thread_Pool, // Pointer to thread pool
	arena:       vmem.Arena, // Worker-specific memory arena
	allocator:   runtime.Allocator, // Worker-specific allocator
	active:      bool, // Whether worker is processing a file
	file_path:   string, // Current file being processed
	should_exit: bool, // Signal to exit (atomic)
}

// Thread pool
Thread_Pool :: struct {
	workers:      [dynamic]Worker, // Worker threads
	work_queue:   [dynamic]string, // Files to process
	queue_mutex:  sync.Mutex, // Mutex for queue access
	wait_group:   sync.Wait_Group, // For waiting on completion
	active_count: int, // Number of active workers (atomic)
	should_exit:  bool, // Signal all workers to exit (atomic)
}

// File System Resolver
File_System_Resolver :: struct {
	// Configuration
	base_dir:        string, // Base directory for resolving paths
	file_cache:      map[string]^File_Cache_Entry, // Cache of processed files
	cache_mutex:     sync.RW_Mutex, // Mutex for cache access
	thread_pool:     Thread_Pool, // Thread pool for parallel processing
	global_scope:    ^Scope_Info, // Global scope for sharing symbols
	global_arena:    ^vmem.Arena, // Global memory arena

	// Analysis state
	main_file:       string, // Main file being processed
	analyzer:        ^Analyzer, // Main analyzer
	verbose:         bool, // Verbose output flag
	timing:          bool, // Output timing information

	// Statistics (all atomic)
	files_processed: int, // Total files processed
	cache_hits:      int, // Cache hits
	parse_errors:    int, // Parse errors
	semantic_errors: int, // Semantic analysis errors
}

// Initialize the file system resolver
init_file_resolver :: proc(
	resolver: ^File_System_Resolver,
	main_file: string,
	global_arena: ^vmem.Arena,
	options: Compiler_Options,
) {
	resolver.base_dir = filepath.dir(main_file)
	resolver.file_cache = make(map[string]^File_Cache_Entry)
	resolver.global_arena = global_arena
	resolver.main_file = main_file
	resolver.verbose = options.verbose
	resolver.timing = options.timing

	// Initialize mutex
	// sync.rw_mutex_init(&resolver.cache_mutex)

	// Initialize thread pool
	init_thread_pool(resolver)

	// Initialize atomic counters
	resolver.files_processed = 0
	resolver.cache_hits = 0
	resolver.parse_errors = 0
	resolver.semantic_errors = 0

	if options.verbose {
		num_threads := len(resolver.thread_pool.workers)
		fmt.printf("File resolver initialized with %d worker threads\n", num_threads)
	}
}


// Initialize thread pool
init_thread_pool :: proc(resolver: ^File_System_Resolver) {
	// Determine optimal thread count (leave one core for main thread)
	num_threads := os.processor_core_count()

	// Initialize pool structures
	pool := &resolver.thread_pool
	pool.workers = make([dynamic]Worker, num_threads)
	pool.work_queue = make([dynamic]string, 0, 32)
	// sync.mutex_init(&pool.queue_mutex)
	// sync.wait_group_init(&pool.wait_group)
	pool.active_count = 0
	pool.should_exit = false

	// Create worker threads
	for i := 0; i < num_threads; i += 1 {
		worker := &pool.workers[i]
		worker.id = i
		worker.pool = pool
		worker.active = false
		worker.should_exit = false

		// Initialize arena
		WORKER_ARENA_SIZE :: 8 * 1024 * 1024 // 8 MB per worker
		err := vmem.arena_init_growing(&worker.arena, WORKER_ARENA_SIZE)
		if err != nil {
			fmt.eprintf("Error initializing arena for worker %d: %v\n", i, err)
			continue
		}
		worker.allocator = vmem.arena_allocator(&worker.arena)

		// Create thread
		worker_proc :: proc(data: ^thread.Thread) {
			worker := cast(^Worker)data
			resolver := cast(^File_System_Resolver)worker.pool
			worker_thread_proc(worker, resolver)
		}

		worker.thread = thread.create(worker_proc)
	}
}

// Worker thread procedure
worker_thread_proc :: proc(worker: ^Worker, resolver: ^File_System_Resolver) {
	// Set up worker context
	context.allocator = worker.allocator

	for !worker.should_exit && !resolver.thread_pool.should_exit {
		// Get file from queue
		file_path: string
		got_work := false

		{
			sync.mutex_lock(&worker.pool.queue_mutex)
			if len(worker.pool.work_queue) > 0 {
				file_path = worker.pool.work_queue[0]
				ordered_remove(&worker.pool.work_queue, 0)
				worker.active = true
				worker.file_path = strings.clone(file_path)
				sync.atomic_add(&worker.pool.active_count, 1)
				got_work = true
			}
			sync.mutex_unlock(&worker.pool.queue_mutex)
		}

		if !got_work {
			// No work available, sleep briefly
			time.sleep(1 * time.Millisecond)
			continue
		}

		// Process the file
		process_file_worker(resolver, worker, file_path)

		// Clean up
		worker.active = false
		delete(worker.file_path)
		worker.file_path = ""

		// Update stats and signal completion
		sync.atomic_sub(&worker.pool.active_count, 1)
		sync.atomic_add(&resolver.files_processed, 1)
		sync.wait_group_done(&worker.pool.wait_group)
	}
}

// Clean up thread pool
destroy_thread_pool :: proc(resolver: ^File_System_Resolver) {
	pool := &resolver.thread_pool

	// Signal all threads to exit
	pool.should_exit = true

	// Wait for all threads to exit
	for &worker in &pool.workers {
		worker.should_exit = true
		if worker.thread != nil {
			thread.join(worker.thread)
		}

		// Clean up worker resources
		vmem.arena_destroy(&worker.arena)
	}

	// Clean up pool resources
	// sync.mutex_destroy(&pool.queue_mutex)
	// sync.wait_group_destroy(&pool.wait_group)
	delete(pool.workers)
	delete(pool.work_queue)
}

// Clean up resolver resources
destroy_file_resolver :: proc(resolver: ^File_System_Resolver) {
	// Clean up thread pool
	destroy_thread_pool(resolver)

	// Clean up cache entries
	sync.rw_mutex_lock(&resolver.cache_mutex)
	for _, entry in resolver.file_cache {
		if entry != nil {
			delete(entry.path)
			if len(entry.dependencies) != 0 {
				delete(entry.dependencies)
			}
			free(entry)
		}
	}
	delete(resolver.file_cache)
	sync.rw_mutex_unlock(&resolver.cache_mutex)

	// Clean up mutex
	// sync.rw_mutex_destroy(&resolver.cache_mutex)
}

// Queue a file for processing
queue_file :: proc(resolver: ^File_System_Resolver, file_path: string) -> bool {
	// Normalize path
	norm_path := filepath.clean(file_path)

	// Check if file exists
	if !os.exists(norm_path) {
		if resolver.verbose {
			fmt.eprintf("Error: File '%s' not found\n", norm_path)
		}
		return false
	}

	// Check cache to see if already processed or in progress
	sync.rw_mutex_lock(&resolver.cache_mutex)
	entry, in_cache := resolver.file_cache[norm_path]
	if in_cache {
		state := sync.atomic_load(&entry.state)
		if state == STATE_PROCESSED || state == STATE_PROCESSING || state == STATE_QUEUED {
			// Already processed or in queue
			sync.rw_mutex_unlock(&resolver.cache_mutex)
			return true
		}
	}
	sync.rw_mutex_unlock(&resolver.cache_mutex)

	// Create or update cache entry
	sync.rw_mutex_lock(&resolver.cache_mutex)

	// Check again in case another thread updated while we were waiting
	entry, in_cache = resolver.file_cache[norm_path]
	if in_cache {
		state := sync.atomic_load(&entry.state)
		if state == STATE_PROCESSED || state == STATE_PROCESSING || state == STATE_QUEUED {
			// Already processed or in queue
			sync.rw_mutex_unlock(&resolver.cache_mutex)
			return true
		}

		// Update state
		sync.atomic_store(&entry.state, STATE_QUEUED)
	} else {
		// Get file stats
		mod_time, file_size, ok := get_file_stats(norm_path)
		if !ok {
			sync.rw_mutex_unlock(&resolver.cache_mutex)
			if resolver.verbose {
				fmt.eprintf("Error: Could not get stats for '%s'\n", norm_path)
			}
			return false
		}

		// Create new entry
		entry = new(File_Cache_Entry)
		entry.path = strings.clone(norm_path)
		entry.mod_time = mod_time
		entry.file_size = file_size
		entry.dependencies = make([dynamic]string)
		entry.state = STATE_QUEUED
		entry.worker_id = -1

		// sync.atomic_mutex_init(&entry.lock)
		resolver.file_cache[norm_path] = entry
	}

	sync.rw_mutex_unlock(&resolver.cache_mutex)

	// Add to work queue
	{
		sync.mutex_lock(&resolver.thread_pool.queue_mutex)
		append(&resolver.thread_pool.work_queue, norm_path)
		sync.mutex_unlock(&resolver.thread_pool.queue_mutex)
	}

	// Increment wait group
	sync.wait_group_add(&resolver.thread_pool.wait_group, 1)

	return true
}

// Get file stats (modification time and size)
get_file_stats :: proc(file_path: string) -> (mod_time: i64, size: i64, success: bool) {
	when ODIN_OS == .Windows {
		path_w := win32_utf8_to_utf16(file_path)
		defer delete(path_w)

		info: os.Wstat_t
		err := os.wstat(path_w, &info)
		if err != 0 {
			return 0, 0, false
		}

		return info.mtime, info.size, true
	} else {
		file_info, err := os.stat(file_path)
		if err != 0 {
			return 0, 0, false
		}

		unix_time := time.time_to_unix(file_info.modification_time)
		return unix_time, file_info.size, true
	}
}

// Convert UTF-8 string to UTF-16 for Windows
when ODIN_OS == .Windows {
	win32_utf8_to_utf16 :: proc(s: string) -> []u16 {
		return utf8_to_utf16le(s)
	}
}

// Has the file been modified since last cached?
file_modified :: proc(resolver: ^File_System_Resolver, file_path: string) -> bool {
	sync.rw_mutex_lock(&resolver.cache_mutex)
	defer sync.rw_mutex_unlock(&resolver.cache_mutex)

	entry, exists := resolver.file_cache[file_path]
	if !exists {
		return true
	}

	// Get current stats
	current_mod_time, current_size, ok := get_file_stats(file_path)
	if !ok {
		return true // Assume modified if can't get stats
	}

	// Changed if either mod time or size changed
	return entry.mod_time != current_mod_time || entry.file_size != current_size
}

// Process a file (worker implementation)
process_file_worker :: proc(resolver: ^File_System_Resolver, worker: ^Worker, file_path: string) {
	// Get cache entry
	sync.rw_mutex_lock(&resolver.cache_mutex)
	entry, exists := resolver.file_cache[file_path]
	sync.rw_mutex_unlock(&resolver.cache_mutex)

	if !exists {
		if resolver.verbose {
			fmt.eprintf("Error: File '%s' not found in cache during processing\n", file_path)
		}
		return
	}

	// Update entry state
	sync.atomic_store(&entry.state, STATE_PROCESSING)
	entry.worker_id = i32(worker.id)

	// Start timing
	start_time: time.Time
	if resolver.timing {
		start_time = time.now()
	}

	// Read the file
	source, read_ok := os.read_entire_file(file_path)
	if !read_ok {
		if resolver.verbose {
			fmt.eprintf("Error: Could not read file '%s'\n", file_path)
		}
		sync.atomic_store(&entry.state, STATE_FAILED)
		sync.atomic_add(&resolver.parse_errors, 1)
		return
	}
	defer delete(source)

	// Compute content hash
	content_hash := hash.fnv64a(source)

	// Check if we can reuse existing AST (hash matches)
	if entry.ast != nil && entry.hash == content_hash {
		sync.atomic_add(&resolver.cache_hits, 1)
		sync.atomic_store(&entry.state, STATE_PROCESSED)
		return
	}

	// Update content hash
	entry.hash = content_hash

	// Initialize lexer and parser
	lexer: Lexer
	init_lexer(&lexer, string(source))

	parser: Parser
	init_parser(&parser, &lexer)

	// Parse the file
	ast := parse(&parser)

	parse_time: time.Duration
	if resolver.timing {
		parse_time = time.diff(start_time, time.now())
	}

	// Update cache with new AST
	entry.ast = ast

	// Extract @references from AST
	references := extract_references(ast)

	// Process each reference
	for ref in references {
		resolved_path := resolve_file_reference(resolver, ref, file_path)
		if resolved_path != "" {
			// Add dependency
			add_dependency(entry, resolved_path)

			// Queue the dependency for processing
			queue_file(resolver, resolved_path)
		}
	}

	delete(references)

	// Mark as processed
	sync.atomic_store(&entry.state, STATE_PROCESSED)

	if resolver.timing && resolver.verbose {
		process_time := time.diff(start_time, time.now())
		fmt.printf(
			"File '%s' processed in %.3fms (parsing: %.3fms)\n",
			filepath.base(file_path),
			f64(time.duration_milliseconds(process_time)),
			f64(time.duration_milliseconds(parse_time)),
		)
	}
}

// Add a dependency to a file
add_dependency :: proc(entry: ^File_Cache_Entry, dependency: string) {
	if entry == nil {
		return
	}

	sync.atomic_mutex_lock(&entry.lock)
	defer sync.atomic_mutex_unlock(&entry.lock)

	// Check if dependency already exists
	for dep in entry.dependencies {
		if dep == dependency {
			return
		}
	}

	// Add dependency
	append(&entry.dependencies, strings.clone(dependency))
}

// Extract @references from an AST
extract_references :: proc(node: ^Node) -> [dynamic]string {
	refs := make([dynamic]string)
	extract_references_impl(node, &refs)
	return refs
}

// Implementation of reference extraction
extract_references_impl :: proc(node: ^Node, refs: ^[dynamic]string) {
	if node == nil {
		return
	}

	#partial switch n in node^ {
	case FileSystem:
		// Extract file reference
		ref_path := get_filesystem_path(n)
		if ref_path != "" {
			append(refs, ref_path)
		}

		// Also check target for nested references
		if n.target != nil {
			extract_references_impl(n.target, refs)
		}

	case Scope:
		for i := 0; i < len(n.value); i += 1 {
			child_node := new(Node)
			child_node^ = n.value[i]
			extract_references_impl(child_node, refs)
		}

	case Pointing:
		if n.name != nil {
			extract_references_impl(n.name, refs)
		}
		if n.value != nil {
			extract_references_impl(n.value, refs)
		}

	case PointingPull:
		if n.name != nil {
			extract_references_impl(n.name, refs)
		}
		if n.value != nil {
			extract_references_impl(n.value, refs)
		}

	case EventPush:
		if n.name != nil {
			extract_references_impl(n.name, refs)
		}
		if n.value != nil {
			extract_references_impl(n.value, refs)
		}

	case EventPull:
		if n.name != nil {
			extract_references_impl(n.name, refs)
		}
		if n.value != nil {
			extract_references_impl(n.value, refs)
		}

	case ResonancePush:
		if n.name != nil {
			extract_references_impl(n.name, refs)
		}
		if n.value != nil {
			extract_references_impl(n.value, refs)
		}

	case ResonancePull:
		if n.name != nil {
			extract_references_impl(n.name, refs)
		}
		if n.value != nil {
			extract_references_impl(n.value, refs)
		}

	case Override:
		if n.source != nil {
			extract_references_impl(n.source, refs)
		}
		for i := 0; i < len(n.overrides); i += 1 {
			override_node := new(Node)
			override_node^ = n.overrides[i]
			extract_references_impl(override_node, refs)
		}

	case Pattern:
		if n.target != nil {
			extract_references_impl(n.target, refs)
		}
		for branch in n.value {
			if branch.source != nil {
				extract_references_impl(branch.source, refs)
			}
			if branch.product != nil {
				extract_references_impl(branch.product, refs)
			}
		}

	case Constraint:
		if n.constraint != nil {
			extract_references_impl(n.constraint, refs)
		}
		if n.value != nil {
			extract_references_impl(n.value, refs)
		}

	case Operator:
		if n.left != nil {
			extract_references_impl(n.left, refs)
		}
		if n.right != nil {
			extract_references_impl(n.right, refs)
		}

	case Execute:
		if n.value != nil {
			extract_references_impl(n.value, refs)
		}

	case Property:
		if n.source != nil {
			extract_references_impl(n.source, refs)
		}
		if n.property != nil {
			extract_references_impl(n.property, refs)
		}

	case Expand:
		if n.target != nil {
			extract_references_impl(n.target, refs)
		}

	case Product:
		if n.value != nil {
			extract_references_impl(n.value, refs)
		}

	case Range:
		if n.start != nil {
			extract_references_impl(n.start, refs)
		}
		if n.end != nil {
			extract_references_impl(n.end, refs)
		}
	}
}

// Extract filesystem path from FileSystem node
get_filesystem_path :: proc(node: FileSystem) -> string {
	if node.target == nil {
		return ""
	}

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	strings.write_string(&builder, "@")

	// Extract the path
	#partial switch target in node.target^ {
	case Identifier:
		strings.write_string(&builder, target.name)
		return strings.to_string(builder)

	case Property:
		// Build property chain
		property_chain := make([dynamic]string)
		defer delete(property_chain)

		target_var := target
		current := &target_var
		for {
			#partial switch prop in current.property^ {
			case Identifier:
				append(&property_chain, prop.name)
			}

			#partial switch source in current.source^ {
			case Identifier:
				append(&property_chain, source.name)
				break
			case Property:
				current = (^Property)(current.source)
				continue
			}
			break
		}

		// Reverse and join the chain
		for i := len(property_chain) - 1; i >= 0; i -= 1 {
			if i < len(property_chain) - 1 {
				strings.write_string(&builder, ".")
			}
			strings.write_string(&builder, property_chain[i])
		}

		return strings.to_string(builder)
	}

	return ""
}

// Resolve a file reference
resolve_file_reference :: proc(
	resolver: ^File_System_Resolver,
	reference: string,
	source_file: string,
) -> string {
	if len(reference) == 0 || reference[0] != '@' {
		return ""
	}

	// Remove @ prefix
	path_ref := reference[1:]

	// Split into components
	components := strings.split(path_ref, ".")
	defer delete(components)

	// Start from the directory of the source file
	current_path := filepath.dir(source_file)

	return resolve_path_components(resolver, components, current_path)
}

// Resolve path components recursively
resolve_path_components :: proc(
	resolver: ^File_System_Resolver,
	components: []string,
	base_path: string,
) -> string {
	if len(components) == 0 {
		return ""
	}

	current_path := base_path

	for i := 0; i < len(components); i += 1 {
		component := components[i]

		// Check for .st file first
		st_file := filepath.join({current_path, fmt.tprintf("%s.st", component)})
		defer delete(st_file)

		if os.exists(st_file) {
			// Found a .st file
			if i == len(components) - 1 {
				// This is the last component, so we're good
				return strings.clone(st_file)
			} else {
				// File in the middle of the path - can't go deeper
				if resolver.verbose {
					fmt.eprintf(
						"Error: '%s' is a file, not a directory, can't access '%s'\n",
						st_file,
						components[i + 1],
					)
				}
				return ""
			}
		}

		// Check for directory
		dir_path := filepath.join({current_path, component})
		defer delete(dir_path)

		if !os.exists(dir_path) {
			// Path doesn't exist
			if resolver.verbose {
				fmt.eprintf("Error: Component '%s' not found at '%s'\n", component, current_path)
			}
			return ""
		}

		// If this is the last component, we've found a directory
		if i == len(components) - 1 {
			return "" // No file to process, just a directory
		}

		// Continue with the next component
		current_path = strings.clone(dir_path)
	}

	return ""
}

// Main entry point to process a file and all its dependencies
process_file_deps :: proc(
	resolver: ^File_System_Resolver,
	file_path: string,
) -> (
	^Node,
	^Analyzer,
	bool,
) {
	if resolver.verbose {
		fmt.printf("Processing file: %s\n", file_path)
	}

	start_time := time.now()

	// Queue the file for processing
	if !queue_file(resolver, file_path) {
		fmt.eprintf("Error: Failed to queue file '%s' for processing\n", file_path)
		return nil, nil, false
	}

	// Wait for all files to be processed
	sync.wait_group_wait(&resolver.thread_pool.wait_group)

	// Get the main file's AST
	sync.rw_mutex_lock(&resolver.cache_mutex)
	main_entry, exists := resolver.file_cache[file_path]
	sync.rw_mutex_unlock(&resolver.cache_mutex)

	if !exists || main_entry.ast == nil {
		fmt.eprintf("Error: Main file '%s' could not be processed\n", file_path)
		return nil, nil, false
	}

	// Create analyzer for semantic analysis
	analyzer := init_analyzer()
	resolver.analyzer = analyzer

	// Integrate imported modules
	integrate_modules(resolver, analyzer)

	// Analyze main file
	analyze_success := main_semantic_analysis(main_entry.ast, file_path)

	if resolver.timing {
		duration := time.diff(start_time, time.now())
		fmt.printf("\nFile processing statistics:\n")
		fmt.printf("  Total time:       %.3fms\n", f64(time.duration_milliseconds(duration)))
		fmt.printf("  Files processed:  %d\n", resolver.files_processed)
		fmt.printf("  Cache hits:       %d\n", resolver.cache_hits)
		fmt.printf("  Parse errors:     %d\n", resolver.parse_errors)
		fmt.printf("  Semantic errors:  %d\n", resolver.semantic_errors)
	}

	return main_entry.ast, analyzer, analyze_success
}

// Integrate modules into the analyzer
integrate_modules :: proc(resolver: ^File_System_Resolver, analyzer: ^Analyzer) {
	sync.rw_mutex_lock(&resolver.cache_mutex)
	defer sync.rw_mutex_unlock(&resolver.cache_mutex)

	// First pass: Register all modules in global scope
	for path, entry in resolver.file_cache {
		if entry.ast == nil || sync.atomic_load(&entry.state) != STATE_PROCESSED {
			continue
		}

		// Create a module symbol for this file
		module_name := filepath.base(path)
		module_name = strings.trim_suffix(module_name, ".st")

		// Create a symbol for the module
		symbol := create_symbol(
			analyzer,
			module_name,
			nil,
			analyzer.global_scope,
			.FileReference,
			Position{line = 0, column = 0, offset = 0},
		)

		symbol.flags += {.IsModule, .IsExported}
		entry.symbol = symbol

		// Register in global scope
		add_symbol(analyzer, symbol)
	}
}

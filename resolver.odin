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
File_Cache :: struct {
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
	thread_pool: ^Thread_Pool, // Pointer to thread pool
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

File_Entry :: struct {
	path:         string, // Full path to the file
	state:        u32, // Processing state (atomic)
	parser:       ^Parser, // Parser instance
	analyzer:     ^Analyzer, // Analyzer instance
	ast:          ^Node, // Parsed AST
	dependencies: [dynamic]string, // Files this file depends on
}

// File System Resolver
File_Resolver :: struct {
	base_dir:        string, // Base directory for resolving paths
	file_entries:    map[string]^File_Entry, // Map of file entries
	cache_mutex:     sync.RW_Mutex, // Mutex for cache access
	thread_pool:     Thread_Pool, // Thread pool for parallel processing
	global_scope:    ^Scope_Info, // Global scope for sharing symbols
	global_arena:    ^vmem.Arena, // Global memory arena
	options:         Compiler_Options, // Compiler options

	// Analysis state
	main_file:       string, // Main file being processed
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
	resolver: ^File_Resolver,
	main_file: string,
	global_arena: ^vmem.Arena,
	options: Compiler_Options,
) {
	resolver.base_dir = filepath.dir(main_file)
	resolver.file_entries = make(map[string]^File_Entry) // Add this line
	resolver.global_arena = global_arena
	resolver.main_file = main_file
	resolver.verbose = options.verbose
	resolver.timing = options.timing
	resolver.options = options

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

// Called whenever we find a file reference during parsing
enqueue_file_reference :: proc(parser: ^Parser, ref_path: string, position: Position) -> bool {
	if parser.file_resolver == nil {
		return false
	}

	resolver := parser.file_resolver

	// Resolve the actual path
	resolved_path := resolve_file_reference(resolver, ref_path, parser.filename)
	if resolved_path == "" {
		error_at(
			parser,
			parser.current_token,
			fmt.tprintf("Could not resolve file reference '%s'", ref_path),
		)
		return false
	}

	// Track dependency
	add_dependency(parser.filename, resolved_path, resolver)

	// Check if already processed or queued
	sync.rw_mutex_lock(&resolver.cache_mutex)
	_, already_exists := resolver.file_entries[resolved_path]
	sync.rw_mutex_unlock(&resolver.cache_mutex)

	if already_exists {
		return true // Already handled
	}

	// Create new entry
	entry := new(File_Entry)
	entry.path = strings.clone(resolved_path)
	entry.state = STATE_QUEUED
	entry.dependencies = make([dynamic]string)

	// Register entry
	sync.rw_mutex_lock(&resolver.cache_mutex)
	resolver.file_entries[resolved_path] = entry
	sync.rw_mutex_unlock(&resolver.cache_mutex)

	// Queue for processing
	sync.mutex_lock(&resolver.thread_pool.queue_mutex)
	append(&resolver.thread_pool.work_queue, resolved_path)
	sync.mutex_unlock(&resolver.thread_pool.queue_mutex)

	// Increment wait group
	sync.wait_group_add(&resolver.thread_pool.wait_group, 1)

	return true
}


// Initialize thread pool
init_thread_pool :: proc(resolver: ^File_Resolver) {
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
		worker.thread_pool = pool
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
			resolver := cast(^File_Resolver)worker.thread_pool
			worker_thread_proc(worker, resolver)
		}

		worker.thread = thread.create(worker_proc)
	}
}

// Worker thread procedure

worker_thread_proc :: proc(worker: ^Worker, resolver: ^File_Resolver) {
	// Set up worker context
	context.allocator = worker.allocator

	for !worker.should_exit && !resolver.thread_pool.should_exit {
		// Get file from queue
		file_path: string
		got_work := false

		{
			sync.mutex_lock(&worker.thread_pool.queue_mutex)
			if len(worker.thread_pool.work_queue) > 0 {
				file_path = worker.thread_pool.work_queue[0]
				ordered_remove(&worker.thread_pool.work_queue, 0)
				worker.active = true
				worker.file_path = strings.clone(file_path)
				sync.atomic_add(&worker.thread_pool.active_count, 1)
				got_work = true
			}
			sync.mutex_unlock(&worker.thread_pool.queue_mutex)
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
		sync.atomic_sub(&worker.thread_pool.active_count, 1)
		sync.atomic_add(&resolver.files_processed, 1)
		sync.wait_group_done(&resolver.thread_pool.wait_group)
	}
}

// Clean up thread pool
destroy_thread_pool :: proc(resolver: ^File_Resolver) {
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

// Queue a file for processing
queue_file :: proc(resolver: ^File_Resolver, file_path: string) -> bool {
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
	entry, in_cache := resolver.file_entries[norm_path]
	if in_cache {
		state := sync.atomic_load(&entry.state)
		if state == STATE_PROCESSED || state == STATE_PROCESSING || state == STATE_QUEUED {
			// Already processed or in queue
			sync.rw_mutex_unlock(&resolver.cache_mutex)
			return true
		}
	}
	sync.rw_mutex_unlock(&resolver.cache_mutex)

	// Create or update entry
	sync.rw_mutex_lock(&resolver.cache_mutex)

	// Check again in case another thread updated while we were waiting
	entry, in_cache = resolver.file_entries[norm_path]
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
		entry = new(File_Entry)
		entry.path = strings.clone(norm_path)
		entry.state = STATE_QUEUED
		entry.dependencies = make([dynamic]string)

		// Register in file entries
		resolver.file_entries[norm_path] = entry
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
file_modified :: proc(resolver: ^File_Resolver, file_path: string) -> bool {
	sync.rw_mutex_lock(&resolver.cache_mutex)
	defer sync.rw_mutex_unlock(&resolver.cache_mutex)

	entry, exists := resolver.file_entries[file_path]
	if !exists {
		return true
	}

	// For now, always return true to force reprocessing
	// In the future, you could store mod_time and file_size in File_Entry
	return true
}

// Process a file (worker implementation)
process_file_worker :: proc(resolver: ^File_Resolver, worker: ^Worker, file_path: string) {
	// Get entry
	sync.rw_mutex_lock(&resolver.cache_mutex)
	entry, exists := resolver.file_entries[file_path]
	sync.rw_mutex_unlock(&resolver.cache_mutex)

	if !exists || entry == nil {
		fmt.eprintf("Error: Missing entry for '%s'\n", file_path)
		return
	}

	// Update state
	sync.atomic_store(&entry.state, STATE_PROCESSING)

	// Read the file
	source, read_ok := os.read_entire_file(file_path)
	if !read_ok {
		sync.atomic_store(&entry.state, STATE_FAILED)
		return
	}
	defer delete(source)

	// Initialize lexer
	lexer: Lexer
	init_lexer(&lexer, string(source))

	// Create parser
	parser := new(Parser)
	init_parser(parser, &lexer)
	parser.file_resolver = resolver
	parser.filename = file_path
	entry.parser = parser

	// Parse file
	ast := parse(parser)
	entry.ast = ast

	// Skip analysis if parse-only flag is set
	if resolver.options.parse_only {
		sync.atomic_store(&entry.state, STATE_PROCESSED)
		return
	}

	// Skip analysis if there were parse errors
	if parser.had_error {
		sync.atomic_store(&entry.state, STATE_PROCESSED)
		return
	}

	// Skip analysis if analyze-only flag is not set
	if !resolver.options.analyze_only {
		sync.atomic_store(&entry.state, STATE_PROCESSED)
		return
	}

	// Create analyzer
	analyzer := init_analyzer(ast, parser.file_resolver, file_path)
	entry.analyzer = analyzer

	// Analyze file (we'll integrate imports later)
	enqueue_node(analyzer, ast, analyzer.root_scope)
	process_work_queue(analyzer)

	// Mark as processed
	sync.atomic_store(&entry.state, STATE_PROCESSED)
}
// Add a dependency to a file
add_dependency :: proc(source_file, target_file: string, resolver: ^File_Resolver) {
	if resolver == nil || source_file == "" || target_file == "" {
		return
	}

	sync.rw_mutex_lock(&resolver.cache_mutex)
	defer sync.rw_mutex_unlock(&resolver.cache_mutex)

	source_entry, exists := resolver.file_entries[source_file]
	if !exists || source_entry == nil {
		return
	}

	// Check if already exists
	for dep in source_entry.dependencies {
		if dep == target_file {
			return
		}
	}

	// Add dependency
	append(&source_entry.dependencies, strings.clone(target_file))
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
	resolver: ^File_Resolver,
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
	resolver: ^File_Resolver,
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

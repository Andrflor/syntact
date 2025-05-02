package compiler
import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

/*
 * ====================================================================
 * Resolver System
 *
 * The resolver coordinates compilation of source files using a thread
 * pool to process files in parallel. It maintains a cache of compiled
 * files to optimize recompilation of unchanged files.
 * ====================================================================
 */

/*
 * Resolver manages the compilation process across multiple files
 */
Resolver :: struct {
	files:       map[string]^Cache, // Map of file paths to cache entries
	files_mutex: sync.Mutex, // Mutex to protect concurrent access to files map
	entry:       ^Cache, // Entry point file cache
	options:     Options, // Compilation options
	pool:        thread.Pool, // Thread pool for parallel processing
}

// Global resolver instance
resolver: Resolver

/*
 * Status represents the compilation stage of a file
 */
Status :: enum {
	Fresh, // Initial state
	Parsing, // Currently parsing
	Parsed, // Successfully parsed
	Analyzing, // Currently analyzing
	Analyzed, // Successfully analyzed
}

/*
 * Cache stores compilation data for a single file
 */
Cache :: struct {
	path:          string, // File path
	analyzer:      ^Analyzer, // Analyzer instance
	parser:        ^Parser, // Parser instance
	ast:           ^Node, // Abstract syntax tree
	source:        string, // Source code
	status:        Status, // Current compilation status
	last_modified: time.Time, // Last modification timestamp
	arena:         vmem.Arena, // Memory arena
	allocator:     mem.Allocator, // Allocator for this cache
	mutex:         sync.Mutex, // Mutex for thread safety
}

/*
 * TimingInfo tracks performance metrics during compilation
 */
TimingInfo :: struct {
	total_time:       time.Duration, // Total compilation time
	parsing_time:     time.Duration, // Time spent parsing
	analysis_time:    time.Duration, // Time spent analyzing
	file_read_time:   time.Duration, // Time spent reading files
	thread_wait_time: time.Duration, // Time spent waiting for threads
}

// Global timing data
timing_data: TimingInfo

/*
 * resolve_entry is the main entry point for the compilation process
 * Returns true if compilation succeeds, false otherwise
 */
resolve_entry :: proc() -> bool {
	resolver.options = parse_args()
	success := true

	// Start total time measurement if timing is enabled
	total_start: time.Time
	if resolver.options.timing {
		total_start = time.now()
		if resolver.options.verbose {
			fmt.println("[TIMING] Starting overall timing measurement")
		}
	}

	load_all_caches_from_disk()

	// Debug start
	if resolver.options.verbose {
		fmt.println("[DEBUG] Starting resolve_entry procedure")
		fmt.printf("[DEBUG] Input path: %s\n", resolver.options.input_path)
	}

	// Optimal thread count - one per core
	num_threads := max(os.processor_core_count() - 1, 1)
	if resolver.options.verbose {
		fmt.printf("[DEBUG] Initializing thread pool with %d threads\n", num_threads)
	}

	thread.pool_init(&resolver.pool, context.allocator, num_threads)
	thread.pool_start(&resolver.pool)

	maybe_entry := resolver.files[resolver.options.input_path]

	if (maybe_entry == nil) {
		if resolver.options.verbose {
			fmt.printf("[DEBUG] Creating cache for entry file: %s\n", resolver.options.input_path)
		}
		resolver.entry = create_cache(resolver.options.input_path)
		resolver.files[resolver.entry.path] = resolver.entry
	} else {
		if resolver.options.verbose {
			fmt.printf("[DEBUG] Loading cache for entry file: %s\n", resolver.options.input_path)
		}
		resolver.entry = maybe_entry
	}

	// Process the entry file
	if (resolver.entry != nil) {
		if resolver.options.verbose {
			fmt.println("[DEBUG] Entry file cache created successfully, processing...")
		}
		process_cache(resolver.entry)
	} else {
		fmt.printf("[ERROR] Impossible to load %s from filesystem\n", resolver.options.input_path)
		success = false
	}

	// Measure thread wait time
	thread_wait_start: time.Time
	if resolver.options.timing {
		thread_wait_start = time.now()
		if resolver.options.verbose {
			fmt.println("[TIMING] Starting thread wait timing measurement")
		}
	}

	// Wait for completion
	if resolver.options.verbose {
		fmt.println("[DEBUG] Waiting for thread pool tasks to complete")
	}

	thread.pool_finish(&resolver.pool)
	thread.pool_destroy(&resolver.pool)

	// Calculate thread wait time
	if resolver.options.timing {
		timing_data.thread_wait_time = time.diff(thread_wait_start, time.now())
		if resolver.options.verbose {
			fmt.printf("[TIMING] Thread wait time: %v\n", timing_data.thread_wait_time)
		}
	}

	if resolver.options.verbose {
		fmt.printf("[DEBUG] resolve_entry completed with success: %t\n", success)
	}

	// Format timing summary at completion
	if resolver.options.timing {
		timing_data.total_time = time.diff(total_start, time.now())

		// Print timing summary with clearer formatting
		fmt.println("\n---- Compilation Timing Summary ----")
		fmt.printf("Total elapsed time: %v\n", timing_data.total_time)

		// Display user time breakdown
		user_time :=
			timing_data.file_read_time + timing_data.parsing_time + timing_data.analysis_time
		fmt.printf(
			"User processing time: %v (%.2f%%)\n",
			user_time,
			f64(user_time) / f64(timing_data.total_time) * 100,
		)

		fmt.printf(
			"  ├─ File reading: %v (%.2f%%)\n",
			timing_data.file_read_time,
			f64(timing_data.file_read_time) / f64(timing_data.total_time) * 100,
		)

		fmt.printf(
			"  ├─ Parsing:      %v (%.2f%%)\n",
			timing_data.parsing_time,
			f64(timing_data.parsing_time) / f64(timing_data.total_time) * 100,
		)

		if !resolver.options.analyze_only {
			fmt.printf(
				"  └─ Analysis:     %v (%.2f%%)\n",
				timing_data.analysis_time,
				f64(timing_data.analysis_time) / f64(timing_data.total_time) * 100,
			)
		}

		// System overhead
		system_overhead := timing_data.total_time - user_time - timing_data.thread_wait_time
		fmt.printf(
			"System overhead:    %v (%.2f%%)\n",
			system_overhead,
			f64(system_overhead) / f64(timing_data.total_time) * 100,
		)

		fmt.printf(
			"Thread wait time:   %v (%.2f%%)\n",
			timing_data.thread_wait_time,
			f64(timing_data.thread_wait_time) / f64(timing_data.total_time) * 100,
		)

		fmt.println("----------------------------------")
	}
	return success
}

/*
 * process_cache schedules a file for processing in the thread pool
 */
process_cache :: proc(cache: ^Cache) {
	if resolver.options.verbose {
		fmt.printf(
			"[DEBUG] Adding process task for file: %s (status: %v)\n",
			cache.path,
			cache.status,
		)
	}
	thread.pool_add_task(&resolver.pool, context.allocator, process_cache_task, cache, 0)
}

/*
 * process_cache_task handles the actual compilation of a file
 * This is executed in a worker thread from the pool
 */
process_cache_task :: proc(task: thread.Task) {
	cache := cast(^Cache)task.data

	if resolver.options.verbose {
		fmt.printf("[DEBUG] Starting process_cache_task for file: %s\n", cache.path)
	}

	// Lock for the entire task
	sync.mutex_lock(&cache.mutex)
	defer sync.mutex_unlock(&cache.mutex)

	if resolver.options.verbose {
		fmt.printf("[DEBUG] Mutex locked for file: %s\n", cache.path)
	}


	// Check modification time
	if resolver.options.verbose {
		fmt.printf("[DEBUG] Checking file modification time for: %s\n", cache.path)
	}

	file_info, err := os.stat(cache.path)
	if err != os.ERROR_NONE {
		if resolver.options.verbose {
			fmt.printf("[ERROR] Failed to stat file: %s, error: %v\n", cache.path, err)
		}
		return
	}

	if file_info.modification_time == cache.last_modified && cache.status != .Fresh {
		if resolver.options.verbose {
			fmt.printf("[DEBUG] File %s unchanged, skipping processing\n", cache.path)
		}
		return // File unchanged, nothing to do
	}

	context.allocator = cache.allocator
	vmem.arena_destroy(&cache.arena)

	cache.last_modified = file_info.modification_time
	cache.status = .Parsing

	if resolver.options.verbose {
		fmt.printf(
			"[DEBUG] File %s has changed, status updated to: %v\n",
			cache.path,
			cache.status,
		)
		fmt.printf("[DEBUG] File size: %d bytes\n", file_info.size)
	}

	// Get file size from file_info
	file_size := int(file_info.size)

	// Create temporary allocator
	temp_arena: mem.Arena
	mem.arena_init(&temp_arena, make([]byte, file_size))
	temp_allocator := mem.arena_allocator(&temp_arena)

	if resolver.options.verbose {
		fmt.printf("[DEBUG] Temporary arena initialized with size: %d bytes\n", file_size)
	}

	// Start file read timing
	file_read_start: time.Time
	if resolver.options.timing {
		file_read_start = time.now()
		if resolver.options.verbose {
			fmt.printf("[TIMING] Starting file read timing for: %s\n", cache.path)
		}
	}

	// Read file with temporary allocator
	if resolver.options.verbose {
		fmt.printf("[DEBUG] Reading entire file: %s\n", cache.path)
	}

	source_bytes, success := os.read_entire_file(cache.path, temp_allocator)
	if !success {
		if resolver.options.verbose {
			fmt.printf("[ERROR] Failed to read file: %s\n", cache.path)
		}
		cache.status = .Fresh
		return
	}

	// End file read timing
	if resolver.options.timing {
		file_read_duration := time.diff(file_read_start, time.now())
		sync.atomic_add(&timing_data.file_read_time, file_read_duration)
		if resolver.options.verbose {
			fmt.printf("[TIMING] File read time for %s: %v\n", cache.path, file_read_duration)
		}
	}

	if resolver.options.verbose {
		fmt.printf(
			"[DEBUG] Successfully read %d bytes from file: %s\n",
			len(source_bytes),
			cache.path,
		)
	}

	// Use cache arena allocator to store the source
	cache.source = string(source_bytes)

	// Start parsing timing
	parsing_start: time.Time
	if resolver.options.timing {
		parsing_start = time.now()
		if resolver.options.verbose {
			fmt.printf("[TIMING] Starting parsing timing for: %s\n", cache.path)
		}
	}

	// Parsing and analysis
	if resolver.options.verbose {
		fmt.printf("[DEBUG] Starting parsing for file: %s\n", cache.path)
	}

	cache.ast = parse(cache)
	cache.status = .Parsed
	// TODO: destroy temp arena and free all

	// End parsing timing
	if resolver.options.timing {
		parsing_duration := time.diff(parsing_start, time.now())
		sync.atomic_add(&timing_data.parsing_time, parsing_duration)
		if resolver.options.verbose {
			fmt.printf("[TIMING] Parsing time for %s: %v\n", cache.path, parsing_duration)
		}
	}

	if (resolver.options.print_ast) {
		print_ast(cache.ast, 0)
	}

	if resolver.options.verbose {
		fmt.printf(
			"[DEBUG] Parsing completed for file: %s, status updated to: %v\n",
			cache.path,
			cache.status,
		)
	}

	if !resolver.options.analyze_only {
		if resolver.options.verbose {
			fmt.printf("[DEBUG] Starting analysis for file: %s\n", cache.path)
		}

		// Start analysis timing
		analysis_start: time.Time
		if resolver.options.timing {
			analysis_start = time.now()
			if resolver.options.verbose {
				fmt.printf("[TIMING] Starting analysis timing for: %s\n", cache.path)
			}
		}

		cache.status = .Analyzing
		// analyze(cache)
		cache.status = .Analyzed

		// End analysis timing
		if resolver.options.timing {
			analysis_duration := time.diff(analysis_start, time.now())
			sync.atomic_add(&timing_data.analysis_time, analysis_duration)
			if resolver.options.verbose {
				fmt.printf("[TIMING] Analysis time for %s: %v\n", cache.path, analysis_duration)
			}
		}

		if resolver.options.verbose {
			fmt.printf(
				"[DEBUG] Analysis completed for file: %s, status updated to: %v\n",
				cache.path,
				cache.status,
			)
		}
	} else if resolver.options.verbose {
		fmt.printf("[DEBUG] Analysis skipped for file: %s (analyze_only option)\n", cache.path)
	}

	save_cache_to_disk(cache)
}

/*
 * process_filenode handles references to external files in the AST
 */
process_filenode :: proc(node: ^Node, ref: ^Node) {
	if resolver.options.verbose {
		fmt.printf("[DEBUG] process_filenode called for node %s\n", node)
	}

	// TODO(andrflor): implement node load from there
	// i := 0
	// for i < 240 {
	// compute_on_need("long.sc")
	// 	i += 1
	// }
}

/*
 * compute_on_need ensures a file is loaded and processed on demand
 */
compute_on_need :: proc(path: string) {
	sync.mutex_lock(&resolver.files_mutex)
	cache := resolver.files[path]
	if (cache == nil) {
		cache = create_cache(path)
		resolver.files[cache.path] = cache
		process_cache(cache)
	}
	sync.mutex_unlock(&resolver.files_mutex)
}

/*
 * create_cache initializes a new cache entry for a file
 * Returns nil if the file cannot be accessed
 */
create_cache :: proc(path: string) -> ^Cache {
	if resolver.options.verbose {
		fmt.printf("[DEBUG] Creating cache for file: %s\n", path)
	}

	cache := new(Cache)
	cache.path = path
	cache.status = .Fresh

	// Get file info
	if resolver.options.verbose {
		fmt.printf("[DEBUG] Getting file info for: %s\n", path)
	}

	file_info, err := os.stat(path)
	if err != os.ERROR_NONE {
		if resolver.options.verbose {
			fmt.printf("[ERROR] Failed to stat file: %s, error: %v\n", path, err)
		}
		free(cache)
		return nil
	}

	cache.last_modified = file_info.modification_time

	if resolver.options.verbose {
		fmt.printf("[DEBUG] File last modified: %v\n", cache.last_modified)
	}

	// Initialize arena with size based on file size
	// But at least one page (4KB)
	arena_size := max(int(file_info.size) * 2, 4 * 1024)

	if resolver.options.verbose {
		fmt.printf("[DEBUG] Initializing arena with size: %d bytes\n", arena_size)
	}

	err = vmem.arena_init_growing(&cache.arena, (uint)(arena_size))
	if (err != nil) {
		if resolver.options.verbose {
			fmt.printf("[ERROR] Failed to initialize arena for file: %s, error: %v\n", path, err)
		}
	}

	cache.allocator = vmem.arena_allocator(&cache.arena)

	if resolver.options.verbose {
		fmt.printf("[DEBUG] Cache created successfully for file: %s\n", path)
	}

	return cache
}

/*
 * free_cache releases resources associated with a cache
 */
free_cache :: proc(cache: ^Cache) {
	if resolver.options.verbose {
		fmt.printf("[DEBUG] Freeing cache for file: %s\n", cache.path)
	}

	vmem.arena_destroy(&cache.arena)
	free(cache)

	if resolver.options.verbose {
		fmt.println("[DEBUG] Cache freed successfully")
	}
}

/*
 * save_cache_to_disk persists a cache to the filesystem
 * Returns true on success, false on failure
 */
save_cache_to_disk :: proc(cache: ^Cache) -> bool {
	if resolver.options.verbose {
		fmt.printf("[DEBUG] Saving cache to disk for: %s\n", cache.path)
	}
	// Create cache directory if it doesn't exist
	cache_dir := filepath.join([]string{os.get_current_directory(), ".cache"})
	if !os.exists(cache_dir) {
		if err := os.make_directory(cache_dir); err != os.ERROR_NONE {
			fmt.printf("[ERROR] Failed to create cache directory: %v\n", err)
			return false
		}
	}

	// Generate unique filename based on path
	hash_value := hash.fnv64a(transmute([]byte)cache.path)
	cache_filename := fmt.aprintf("%x.cache", hash_value)
	cache_path := filepath.join([]string{cache_dir, cache_filename})

	// Remove existing file if it exists
	if os.exists(cache_path) {
		if err := os.remove(cache_path); err != os.ERROR_NONE {
			fmt.printf(
				"[ERROR] Failed to remove existing cache file: %s, error: %v\n",
				cache_path,
				err,
			)
			return false
		}
	}

	// Open file for writing
	cache_file, err := os.open(cache_path, os.O_WRONLY | os.O_CREATE, 0o755)
	if err != os.ERROR_NONE {
		fmt.printf("[ERROR] Failed to create cache file: %s, error: %v\n", cache_path, err)
		return false
	}
	defer os.close(cache_file)

	// Write basic data first (path, modification date)
	header := struct {
		path_len:      int,
		last_modified: time.Time,
		status:        Status,
	} {
		path_len      = len(cache.path),
		last_modified = cache.last_modified,
		status        = cache.status,
	}

	header_slice := make([]byte, size_of(header))
	mem.copy(&header_slice[0], &header, size_of(header))

	bytes_written, write_err := os.write(cache_file, header_slice)
	if write_err != os.ERROR_NONE {
		fmt.printf("[ERROR] Failed to write header: %v\n", write_err)
		return false
	}

	// Write the path
	path_slice := transmute([]byte)cache.path
	bytes_written, write_err = os.write(cache_file, path_slice)
	if write_err != os.ERROR_NONE {
		fmt.printf("[ERROR] Failed to write path: %v\n", write_err)
		return false
	}

	// Write the complete arena (including structure and data)
	arena_slice := make([]byte, size_of(vmem.Arena))
	mem.copy(&arena_slice[0], &cache.arena, size_of(vmem.Arena))

	bytes_written, write_err = os.write(cache_file, arena_slice)
	if write_err != os.ERROR_NONE {
		fmt.printf("[ERROR] Failed to write arena structure: %v\n", write_err)
		return false
	}

	if resolver.options.verbose {
		fmt.printf("[DEBUG] Cache saved to: %s\n", cache_path)
	}

	return true
}

/*
 * load_cache_from_disk loads a cache from the filesystem
 * Returns nil if the cache doesn't exist or is invalid
 */
load_cache_from_disk :: proc(path: string) -> ^Cache {
	if resolver.options.verbose {
		fmt.printf("[DEBUG] Trying to load cache for: %s\n", path)
	}

	// Generate the same filename as when saving
	hash_value := hash.fnv64a(transmute([]byte)path)
	cache_filename := fmt.aprintf("%x.cache", hash_value)
	cache_path := filepath.join([]string{cache_dir, cache_filename})

	// Check if cache file exists
	if !os.exists(cache_path) {
		if resolver.options.verbose {
			fmt.printf("[DEBUG] No cache file found at: %s\n", cache_path)
		}
		return nil
	}

	// Open file for reading
	cache_file, err := os.open(cache_path, os.O_RDONLY)
	if err != os.ERROR_NONE {
		fmt.printf("[ERROR] Failed to open cache file: %s, error: %v\n", cache_path, err)
		return nil
	}
	defer os.close(cache_file)

	// Read header
	header := struct {
		path_len:      int,
		last_modified: time.Time,
		status:        Status,
	}{}

	header_slice := make([]byte, size_of(header))
	bytes_read, read_err := os.read(cache_file, header_slice)
	if read_err != os.ERROR_NONE || bytes_read != size_of(header) {
		fmt.printf("[ERROR] Failed to read header: %v\n", read_err)
		return nil
	}
	mem.copy(&header, &header_slice[0], size_of(header))

	// Verify source file hasn't been modified
	file_info, stat_err := os.stat(path)
	if stat_err != os.ERROR_NONE {
		fmt.printf("[ERROR] Failed to stat file: %s, error: %v\n", path, stat_err)
		return nil
	}

	if file_info.modification_time != header.last_modified {
		if resolver.options.verbose {
			fmt.printf("[DEBUG] File modified since cache was created: %s\n", path)
		}
		return nil
	}

	// Create new Cache instance
	cache := new(Cache)

	// Read path
	path_data := make([]byte, header.path_len)
	bytes_read, read_err = os.read(cache_file, path_data)
	if read_err != os.ERROR_NONE || bytes_read != header.path_len {
		fmt.printf("[ERROR] Failed to read path from cache: %v\n", read_err)
		free(cache)
		return nil
	}

	cache.path = string(path_data)

	// Read Arena structure
	arena_slice := make([]byte, size_of(vmem.Arena))
	bytes_read, read_err = os.read(cache_file, arena_slice)
	if read_err != os.ERROR_NONE || bytes_read != size_of(vmem.Arena) {
		fmt.printf("[ERROR] Failed to read arena structure: %v\n", read_err)
		free(cache)
		return nil
	}

	// Copy Arena structure to cache
	mem.copy(&cache.arena, &arena_slice[0], size_of(vmem.Arena))

	// Set up rest of cache
	cache.allocator = vmem.arena_allocator(&cache.arena)
	cache.last_modified = header.last_modified
	cache.status = header.status

	if resolver.options.verbose {
		fmt.printf(
			"[DEBUG] Successfully loaded cache for: %s (status: %v)\n",
			cache.path,
			cache.status,
		)
	}

	return cache
}

cache_dir := filepath.join([]string{os.get_current_directory(), ".cache"})

/*
 * load_all_caches_from_disk loads all available caches from disk
 * Returns the number of caches loaded
 */
load_all_caches_from_disk :: proc() -> int {
	loaded_count := 0

	if resolver.options.verbose {
		fmt.println("[DEBUG] Loading all caches from disk")
	}

	// If cache directory doesn't exist, nothing to do
	if !os.exists(cache_dir) {
		if resolver.options.verbose {
			fmt.printf("[DEBUG] Cache directory does not exist: %s\n", cache_dir)
		}
		return 0
	}

	// Read all files from cache directory
	dir_handle, err := os.open(cache_dir, os.O_RDONLY)
	if err != os.ERROR_NONE {
		fmt.printf("[ERROR] Failed to open cache directory: %s, error: %v\n", cache_dir, err)
		return 0
	}
	defer os.close(dir_handle)

	dir_info, dir_err := os.read_dir(dir_handle, 0)
	if dir_err != os.ERROR_NONE {
		fmt.printf("[ERROR] Failed to read cache directory: %s, error: %v\n", cache_dir, dir_err)
		return 0
	}

	// For each cache file
	for file_info in dir_info {
		if !strings.has_suffix(file_info.name, ".cache") {
			continue
		}

		// Extract the original path from the cache file
		cache_path := filepath.join([]string{cache_dir, file_info.name})

		// Open file to read just the header and path
		cache_file, open_err := os.open(cache_path, os.O_RDONLY)
		if open_err != os.ERROR_NONE {
			continue
		}

		// Read header to get path length
		header := struct {
			path_len:      int,
			last_modified: time.Time,
			status:        Status,
		}{}

		header_slice := make([]byte, size_of(header))
		bytes_read, read_err := os.read(cache_file, header_slice)
		if read_err != os.ERROR_NONE || bytes_read != size_of(header) {
			os.close(cache_file)
			continue
		}
		mem.copy(&header, &header_slice[0], size_of(header))

		// Read original path
		orig_path := make([]byte, header.path_len)
		bytes_read, read_err = os.read(cache_file, orig_path)
		os.close(cache_file)

		if read_err != os.ERROR_NONE || bytes_read != header.path_len {
			delete(orig_path)
			continue
		}

		// Load cache for this path
		path_str := string(orig_path)
		if cache := load_cache_from_disk(path_str); cache != nil {
			resolver.files[cache.path] = cache
			loaded_count += 1
		}

		delete(orig_path)
	}

	if resolver.options.verbose {
		fmt.printf("[DEBUG] Loaded %d caches from disk\n", loaded_count)
	}

	return loaded_count
}

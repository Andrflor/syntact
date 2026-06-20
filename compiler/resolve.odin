package compiler
import x64 "backends/x64"
import "base:runtime"
import bc "bytecode"
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

// The resolver coordinates compilation of source files across a thread pool,
// caching per-file results.
Resolver :: struct {
	files:       map[string]^Cache,
	files_mutex: sync.Mutex,
	entry:       ^Cache,
	options:     Options,
	pool:        thread.Pool,
}

resolver: Resolver

Status :: enum {
	Fresh,
	Parsing,
	Parsed,
	Analyzing,
	Analyzed,
}

Cache :: struct {
	path:             string,
	scope:            ^Scope_Type,
	status:           Status,
	last_modified:    time.Time,
	arena:            vmem.Arena,
	allocator:        mem.Allocator,
	mutex:            sync.Mutex,
	parse_errors:     [dynamic]Parse_Error,
	analyze_errors:   [dynamic]Analyzer_Error,
	analyze_warnings: [dynamic]Analyzer_Error,
}

TimingInfo :: struct {
	total_time:       time.Duration,
	parsing_time:     time.Duration,
	analysis_time:    time.Duration,
	reduce_time:      time.Duration,
	codegen_time:     time.Duration,
	file_read_time:   time.Duration,
	thread_wait_time: time.Duration,
}

timing_data: TimingInfo

// resolve_entry is the main entry point; returns true on success.
resolve_entry :: proc() -> bool {
	resolver.options = parse_args()
	success := true

	total_start: time.Time
	if resolver.options.timing {
		total_start = time.now()
		if resolver.options.verbose {
			fmt.println("[TIMING] Starting overall timing measurement")
		}
	}

	absolute_path, abs_err := filepath.abs(resolver.options.input_path, context.allocator)

	if abs_err != nil {
		fmt.printf(
			"[ERROR]  Impossible to get absolute path for entrypoint %s\n",
			resolver.options.input_path,
		)
	}

	if resolver.options.verbose {
		fmt.println("[DEBUG] Starting resolve_entry procedure")
		fmt.printf("[DEBUG] Input path: %s\n", resolver.options.input_path)
	}

	num_threads := max(os.get_processor_core_count() - 1, 1)
	if resolver.options.verbose {
		fmt.printf("[DEBUG] Initializing thread pool with %d threads\n", num_threads)
	}

	thread.pool_init(&resolver.pool, context.allocator, num_threads)
	thread.pool_start(&resolver.pool)


	compute_on_need(absolute_path)
	resolver.entry = resolver.files[absolute_path]

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

	for _, cache in resolver.files {
		if len(cache.parse_errors) > 0 || len(cache.analyze_errors) > 0 {
			success = false
			break
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
			timing_data.file_read_time +
			timing_data.parsing_time +
			timing_data.analysis_time +
			timing_data.reduce_time +
			timing_data.codegen_time
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

		// Analysis runs whenever we are not parse-only — including --analyze-only,
		// where it is the LAST stage and thus the one most worth seeing.
		if !resolver.options.parse_only {
			fmt.printf(
				"  ├─ Analysis:     %v (%.2f%%)\n",
				timing_data.analysis_time,
				f64(timing_data.analysis_time) / f64(timing_data.total_time) * 100,
			)
		}
		// Reduce/Codegen only run when we go past analysis.
		if !resolver.options.parse_only && !resolver.options.analyze_only {
			fmt.printf(
				"  ├─ Reduce:       %v (%.2f%%)\n",
				timing_data.reduce_time,
				f64(timing_data.reduce_time) / f64(timing_data.total_time) * 100,
			)
			fmt.printf(
				"  └─ Codegen:      %v (%.2f%%)\n",
				timing_data.codegen_time,
				f64(timing_data.codegen_time) / f64(timing_data.total_time) * 100,
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

// process_cache_task compiles one file on a worker thread.
process_cache_task :: proc(task: thread.Task) {
	cache := cast(^Cache)task.data

	if resolver.options.verbose {
		fmt.printf("[DEBUG] Starting process_cache_task for file: %s\n", cache.path)
	}

	sync.mutex_lock(&cache.mutex)
	defer sync.mutex_unlock(&cache.mutex)

	if resolver.options.verbose {
		fmt.printf("[DEBUG] Mutex locked for file: %s\n", cache.path)
	}


	if resolver.options.verbose {
		fmt.printf("[DEBUG] Checking file modification time for: %s\n", cache.path)
	}

	file_info, err := os.stat(cache.path, context.allocator)
	if err != nil {
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

	file_size := int(file_info.size)

	temp_arena: mem.Arena
	mem.arena_init(&temp_arena, make([]byte, file_size))
	temp_allocator := mem.arena_allocator(&temp_arena)

	if resolver.options.verbose {
		fmt.printf("[DEBUG] Temporary arena initialized with size: %d bytes\n", file_size)
	}

	file_read_start: time.Time
	if resolver.options.timing {
		file_read_start = time.now()
		if resolver.options.verbose {
			fmt.printf("[TIMING] Starting file read timing for: %s\n", cache.path)
		}
	}

	if resolver.options.verbose {
		fmt.printf("[DEBUG] Reading entire file: %s\n", cache.path)
	}

	source_bytes, read_err := os.read_entire_file(cache.path, temp_allocator)
	if read_err != nil {
		if resolver.options.verbose {
			fmt.printf("[ERROR] Failed to read file: %s\n", cache.path)
		}
		cache.status = .Fresh
		return
	}

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

	source := string(source_bytes)

	parsing_start: time.Time
	if resolver.options.timing {
		parsing_start = time.now()
		if resolver.options.verbose {
			fmt.printf("[TIMING] Starting parsing timing for: %s\n", cache.path)
		}
	}

	if resolver.options.verbose {
		fmt.printf("[DEBUG] Starting parsing for file: %s\n", cache.path)
	}

	ast, parse_ok := parse(cache, source)
	cache.status = .Parsed

	if resolver.options.timing {
		parsing_duration := time.diff(parsing_start, time.now())
		sync.atomic_add(&timing_data.parsing_time, parsing_duration)
		if resolver.options.verbose {
			fmt.printf("[TIMING] Parsing time for %s: %v\n", cache.path, parsing_duration)
		}
	}

	if (resolver.options.print_ast) {
		print_ast(ast, ast_root(ast), 0)
	}

	if resolver.options.verbose {
		fmt.printf(
			"[DEBUG] Parsing completed for file: %s, status updated to: %v\n",
			cache.path,
			cache.status,
		)
	}

	if !resolver.options.parse_only {
		if resolver.options.verbose {
			fmt.printf("[DEBUG] Starting analysis for file: %s\n", cache.path)
		}

		analysis_start: time.Time
		if resolver.options.timing {
			analysis_start = time.now()
			if resolver.options.verbose {
				fmt.printf("[TIMING] Starting analysis timing for: %s\n", cache.path)
			}
		}

		cache.status = .Analyzing
		analyzer := create_analyzer(ast)
		prev_user_ptr := context.user_ptr
		context.user_ptr = &analyzer
		analyze_ok := analyze(cache)
		cache.status = .Analyzed

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
		if resolver.options.print_ir && cache.scope != nil {
			print_type_value(cache.scope^)
			fmt.println()
		}

		context.user_ptr = prev_user_ptr

		if !resolver.options.analyze_only && analyze_ok {
			reduce_start: time.Time
			if resolver.options.timing {
				reduce_start = time.now()
			}

			r := create_reducer()
			prev_user_ptr := context.user_ptr
			context.user_ptr = &r
			result := reduce(cache.scope)

			if resolver.options.timing {
				reduce_duration := time.diff(reduce_start, time.now())
				sync.atomic_add(&timing_data.reduce_time, reduce_duration)
				if resolver.options.verbose {
					fmt.printf("[TIMING] Reduce time for %s: %v\n", cache.path, reduce_duration)
				}
			}

			// --bc/--run/--regalloc/-o lower the reduced DAG to bytecode; otherwise
			// render the reduced VALUE.
			if resolver.options.print_bytecode ||
			   resolver.options.run_bytecode ||
			   resolver.options.print_regalloc ||
			   resolver.options.emit_exe {
				codegen_start: time.Time
				// user_ptr must stay the reducer `r`: lower_to_bytecode → fixedpoint_id
				// reads r.fixedpoint_index. Restored after lowering.
				if resolver.options.timing {
					codegen_start = time.now()
				}

				prog := lower_to_bytecode(result)
				if resolver.options.print_bytecode {
					fmt.print(bc.bytecode_to_string(prog))
				}
				if prog != nil && prog.error != "" && !resolver.options.print_bytecode {
					fmt.eprintln(prog.error)
				}
				if resolver.options.print_regalloc && (prog == nil || prog.error == "") {
					alloc := x64.allocate_registers(prog)
					fmt.print(x64.regalloc_to_string(prog, alloc))
				}
				if resolver.options.run_bytecode {
					r := bc.interp_bytecode(prog, resolver.options.run_args[:])
					if r.ok {
						bc.print_interp_result(r)
					} else {
						fmt.eprintln("runtime error:", r.error)
					}
				}
				if resolver.options.emit_exe {
					out_path := resolver.options.output_path
					if out_path == "" do out_path = "a.out"
					if msg := x64.emit_executable(prog, out_path); msg != "" {
						fmt.eprintln("emit error:", msg)
					} else {
						fmt.printf("wrote executable: %s\n", out_path)
					}
				}

				if resolver.options.timing {
					codegen_duration := time.diff(codegen_start, time.now())
					sync.atomic_add(&timing_data.codegen_time, codegen_duration)
					if resolver.options.verbose {
						fmt.printf(
							"[TIMING] Codegen time for %s: %v\n",
							cache.path,
							codegen_duration,
						)
					}
				}
				context.user_ptr = prev_user_ptr
			} else {
				fmt.println(value_to_string(result))
				context.user_ptr = prev_user_ptr
			}
		}
	} else if resolver.options.verbose {
		fmt.printf("[DEBUG] Analysis skipped for file: %s (analyze_only option)\n", cache.path)
	}

	if !resolver.options.no_cache {
		save_cache_to_disk(cache)
	}
}

process_filenode_flat :: proc(idx: Node_Index, parser: ^Parser) {
	if parser.file_cache == nil || parser.file_cache.path == "" do return
	dir_path := filepath.dir(parser.file_cache.path)
	if resolver.options.verbose {
		fmt.printf("[DEBUG] process_filenode called from %s\n", parser.file_cache.path)
	}
	segments := make([dynamic]string, 0, 4, context.temp_allocator)
	_process_node_flat(idx, parser, dir_path, &segments)
}

_process_node_flat :: proc(
	idx: Node_Index,
	parser: ^Parser,
	dir_path: string,
	segments: ^[dynamic]string,
) {
	if idx == INVALID_NODE do return
	n_kind := parser.node_kinds[idx]
	n_data := parser.node_data[idx]
	#partial switch n_kind {
	case .Property:
		right := n_data.binary.right
		if right != INVALID_NODE && parser.node_kinds[right] == .Identifier {
			s := parser.node_data[right].identifier.name
			append(segments, parser.source[s.start:s.end])
		}
		_process_node_flat(n_data.binary.left, parser, dir_path, segments)
	case .External:
		name_s := n_data.external.name
		name := parser.source[name_s.start:name_s.end]
		path, _ := filepath.join({dir_path, name}, context.temp_allocator)
		if os.is_dir(path) {
			current_path := path
			for i := len(segments) - 1; i >= 0; i -= 1 {
				segment := segments[i]
				path, _ := filepath.join({current_path, segment}, context.temp_allocator)
				if os.is_dir(path) {
					current_path = path
				} else {
					joined, _ := filepath.join({current_path, segment}, context.temp_allocator)
					st_path := fmt.tprintf("%s.st", joined)
					if os.exists(st_path) {
						compute_on_need(st_path)
						return
					} else {
						return
					}
				}
			}
		} else {
			file_path, _ := filepath.join(
				{dir_path, fmt.tprintf("%s.st", name)},
				context.temp_allocator,
			)
			if os.exists(file_path) {
				compute_on_need(file_path)
			}
		}
	case:
		return
	}
}

// compute_on_need ensures a file is loaded and processed on demand.
compute_on_need :: proc(path: string) {
	if resolver.options.verbose {
		fmt.printf("[DEBUG] Checking file for recompute: %s\n", path)
	}
	sync.mutex_lock(&resolver.files_mutex)
	cache := resolver.files[path]
	if (cache == nil) {
		if resolver.options.verbose {
			fmt.printf("[DEBUG] Live cache not found for: %s\n", path)
		}
		if (resolver.options.no_cache) {
			cache = create_cache(path)
		} else {
			cache = load_cache_from_disk(path)
			if (cache == nil) {
				if resolver.options.verbose {
					fmt.printf("[DEBUG] File cache not found for: %s\n", path)
				}
				cache = create_cache(path)
			}
		}
		if (cache != nil) {
			resolver.files[cache.path] = cache
			process_cache(cache)
		}
	}
	sync.mutex_unlock(&resolver.files_mutex)
}

// create_cache initializes a new cache entry; nil if the file is inaccessible.
create_cache :: proc(path: string) -> ^Cache {
	if resolver.options.verbose {
		fmt.printf("[DEBUG] Creating cache for file: %s\n", path)
	}

	cache := new(Cache)
	cache.path = path
	cache.status = .Fresh

	if resolver.options.verbose {
		fmt.printf("[DEBUG] Getting file info for: %s\n", path)
	}

	file_info, err := os.stat(path, context.allocator)
	if err != nil {
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

	arena_size := max(int(file_info.size) * 2, 4 * 1024) // at least one 4KB page

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

// save_cache_to_disk persists a cache; true on success.
save_cache_to_disk :: proc(cache: ^Cache) -> bool {
	if resolver.options.verbose {
		fmt.printf("[DEBUG] Saving cache to disk for: %s\n", cache.path)
	}
	if !os.exists(cache_dir) {
		if err := os.make_directory(cache_dir); err != nil {
			fmt.printf("[ERROR] Failed to create cache directory: %v\n", err)
			return false
		}
	}

	hash_value := hash.fnv64a(transmute([]byte)cache.path)
	cache_filename := fmt.aprintf("%x.cache", hash_value)
	cache_path, _ := filepath.join([]string{cache_dir, cache_filename}, context.allocator)

	if os.exists(cache_path) {
		if err := os.remove(cache_path); err != nil {
			fmt.printf(
				"[ERROR] Failed to remove existing cache file: %s, error: %v\n",
				cache_path,
				err,
			)
			return false
		}
	}

	cache_file, err := os.open(cache_path, os.O_WRONLY | os.O_CREATE, os.Permissions_Default_File)
	if err != nil {
		fmt.printf("[ERROR] Failed to create cache file: %s, error: %v\n", cache_path, err)
		return false
	}
	defer os.close(cache_file)

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
	if write_err != nil {
		fmt.printf("[ERROR] Failed to write header: %v\n", write_err)
		return false
	}

	path_slice := transmute([]byte)cache.path
	bytes_written, write_err = os.write(cache_file, path_slice)
	if write_err != nil {
		fmt.printf("[ERROR] Failed to write path: %v\n", write_err)
		return false
	}

	arena_slice := make([]byte, size_of(vmem.Arena))
	mem.copy(&arena_slice[0], &cache.arena, size_of(vmem.Arena))

	bytes_written, write_err = os.write(cache_file, arena_slice)
	if write_err != nil {
		fmt.printf("[ERROR] Failed to write arena structure: %v\n", write_err)
		return false
	}

	if resolver.options.verbose {
		fmt.printf("[DEBUG] Cache saved to: %s\n", cache_path)
	}

	return true
}

// load_cache_from_disk loads a cache; nil if missing or invalid.
load_cache_from_disk :: proc(path: string) -> ^Cache {
	if resolver.options.verbose {
		fmt.printf("[DEBUG] Trying to load cache for: %s\n", path)
	}

	hash_value := hash.fnv64a(transmute([]byte)path)
	cache_filename := fmt.aprintf("%x.cache", hash_value)
	cache_path, _ := filepath.join([]string{cache_dir, cache_filename}, context.allocator)

	if !os.exists(cache_path) {
		if resolver.options.verbose {
			fmt.printf("[DEBUG] No cache file found at: %s\n", cache_path)
		}
		return nil
	}

	cache_file, err := os.open(cache_path, os.O_RDONLY)
	if err != nil {
		fmt.printf("[ERROR] Failed to open cache file: %s, error: %v\n", cache_path, err)
		return nil
	}
	defer os.close(cache_file)

	header := struct {
		path_len:      int,
		last_modified: time.Time,
		status:        Status,
	}{}

	header_slice := make([]byte, size_of(header))
	bytes_read, read_err := os.read(cache_file, header_slice)
	if read_err != nil || bytes_read != size_of(header) {
		fmt.printf("[ERROR] Failed to read header: %v\n", read_err)
		return nil
	}
	mem.copy(&header, &header_slice[0], size_of(header))

	// Reject the cache if the source file changed since it was written.
	file_info, stat_err := os.stat(path, context.allocator)
	if stat_err != nil {
		fmt.printf("[ERROR] Failed to stat file: %s, error: %v\n", path, stat_err)
		return nil
	}

	if file_info.modification_time != header.last_modified {
		if resolver.options.verbose {
			fmt.printf("[DEBUG] File modified since cache was created: %s\n", path)
		}
		return nil
	}

	cache := new(Cache)

	path_data := make([]byte, header.path_len)
	bytes_read, read_err = os.read(cache_file, path_data)
	if read_err != nil || bytes_read != header.path_len {
		fmt.printf("[ERROR] Failed to read path from cache: %v\n", read_err)
		free(cache)
		return nil
	}

	cache.path = string(path_data)

	arena_slice := make([]byte, size_of(vmem.Arena))
	bytes_read, read_err = os.read(cache_file, arena_slice)
	if read_err != nil || bytes_read != size_of(vmem.Arena) {
		fmt.printf("[ERROR] Failed to read arena structure: %v\n", read_err)
		free(cache)
		return nil
	}

	mem.copy(&cache.arena, &arena_slice[0], size_of(vmem.Arena))

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

cache_dir: string

get_temp_directory :: proc() -> string {
	if temp, ok := os.lookup_env("TEMP", context.allocator); ok {
		return temp
	}

	if tmp, ok := os.lookup_env("TMP", context.allocator); ok {
		return tmp
	}

	when ODIN_OS == .Windows {
		return "C:\\Windows\\Temp"
	} else {
		return "/tmp"
	}
}

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

Resolver :: struct {
	files:       map[string]^Cache,
	files_mutex: sync.Mutex,
	entry:       ^Cache,
	options:     Options,
	pool:        thread.Pool,
}

resolver := Resolver{}

Status :: enum {
	Fresh,
	Parsing,
	Parsed,
	Analyzing,
	Analyzed,
}

Cache :: struct {
	path:          string,
	analyzer:      ^Analyzer,
	parser:        ^Parser,
	source:        string,
	status:        Status,
	last_modified: time.Time,
	arena:         vmem.Arena,
	allocator:     mem.Allocator,
	mutex:         sync.Mutex,
}

// Timing data structure to track execution times
TimingInfo :: struct {
	total_time:       time.Duration,
	parsing_time:     time.Duration,
	analysis_time:    time.Duration,
	file_read_time:   time.Duration,
	thread_wait_time: time.Duration,
}

// Global timing data
timing_data: TimingInfo

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

	// Debug start
	if resolver.options.verbose {
		fmt.println("[DEBUG] Starting resolve_entry procedure")
		fmt.printf("[DEBUG] Input path: %s\n", resolver.options.input_path)
	}

	// Nombre optimal de threads - un par cœur
	num_threads := max(os.processor_core_count() - 1, 1)
	if resolver.options.verbose {
		fmt.printf("[DEBUG] Initializing thread pool with %d threads\n", num_threads)
	}

	thread.pool_init(&resolver.pool, context.allocator, num_threads)
	thread.pool_start(&resolver.pool)

	resolver.files = make(map[string]^Cache, 16)
	if resolver.options.verbose {
		fmt.println("[DEBUG] Files map initialized with capacity 16")
	}

	// Fichier d'entrée
	if resolver.options.verbose {
		fmt.printf("[DEBUG] Creating cache for entry file: %s\n", resolver.options.input_path)
	}

	resolver.entry = create_cache(resolver.options.input_path)
	resolver.files[resolver.entry.path] = resolver.entry

	// Traiter l'entrée
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

	// Attendre la fin
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

	// At the end of resolve_entry, modify the timing output to be clearer:
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

process_cache_task :: proc(task: thread.Task) {
	cache := cast(^Cache)task.data

	if resolver.options.verbose {
		fmt.printf("[DEBUG] Starting process_cache_task for file: %s\n", cache.path)
	}

	// Verrouillage pour toute la tâche
	sync.mutex_lock(&cache.mutex)
	defer sync.mutex_unlock(&cache.mutex)

	if resolver.options.verbose {
		fmt.printf("[DEBUG] Mutex locked for file: %s\n", cache.path)
	}

	context.allocator = cache.allocator

	// Vérification de la date de modification
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
		return // Fichier inchangé, rien à faire
	}

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

	// Récupérer la taille du fichier à partir de file_info
	file_size := int(file_info.size)

	// Création d'un allocateur temporaire
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

	// Lecture du fichier avec un allocateur temporaire
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

	// Utiliser l'allocateur d'arena du cache pour stocker la source
	cache.source = string(source_bytes)

	// Start parsing timing
	parsing_start: time.Time
	if resolver.options.timing {
		parsing_start = time.now()
		if resolver.options.verbose {
			fmt.printf("[TIMING] Starting parsing timing for: %s\n", cache.path)
		}
	}

	// Parsing et analyse
	if resolver.options.verbose {
		fmt.printf("[DEBUG] Starting parsing for file: %s\n", cache.path)
	}

	ast := parse(cache)
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
		print_ast(ast, 0)
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
}


process_filenode :: proc(node: ^Node) {
	// TODO: implement that later
	if resolver.options.verbose {
		fmt.printf("[DEBUG] process_filenode called for node %s\n", node)
	}

	i := 0
	for i < 240 {
		sync.mutex_lock(&resolver.files_mutex)
		cache := create_cache("long.sc")
		resolver.files[cache.path] = cache
		sync.mutex_unlock(&resolver.files_mutex)
		process_cache(cache)
		i += 1
	}
}

// Fonction pour créer un nouveau cache avec arena appropriée
create_cache :: proc(path: string) -> ^Cache {
	if resolver.options.verbose {
		fmt.printf("[DEBUG] Creating cache for file: %s\n", path)
	}

	cache := new(Cache)
	cache.path = path
	cache.status = .Fresh

	// Obtenir les infos du fichier
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

	// Initialiser l'arena avec une taille basée sur la taille du fichier
	// Mais au moins une page (4KB)
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

// Fonction pour libérer un cache
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

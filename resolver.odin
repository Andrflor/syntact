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

	load_all_caches_from_disk()

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

	save_cache_to_disk(cache)
}


process_filenode :: proc(node: ^Node) {
	if resolver.options.verbose {
		fmt.printf("[DEBUG] process_filenode called for node %s\n", node)
	}

	i := 0
	for i < 240 {
		compute_on_need("long.sc")
		i += 1
	}
}

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


// Fonction pour sauvegarder un cache sur disque
save_cache_to_disk :: proc(cache: ^Cache) -> bool {
	if resolver.options.verbose {
		fmt.printf("[DEBUG] Saving cache to disk for: %s\n", cache.path)
	}
	// Créer un répertoire de cache s'il n'existe pas
	cache_dir := filepath.join([]string{os.get_current_directory(), ".cache"})
	if !os.exists(cache_dir) {
		if err := os.make_directory(cache_dir); err != os.ERROR_NONE {
			fmt.printf("[ERROR] Failed to create cache directory: %v\n", err)
			return false
		}
	}

	// Générer un nom de fichier unique basé sur le chemin
	hash_value := hash.fnv64a(transmute([]byte)cache.path)
	cache_filename := fmt.aprintf("%x.cache", hash_value)
	cache_path := filepath.join([]string{cache_dir, cache_filename})

	// Supprimer le fichier existant s'il existe
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

	// Ouvrir le fichier pour écriture
	cache_file, err := os.open(cache_path, os.O_WRONLY | os.O_CREATE)
	if err != os.ERROR_NONE {
		fmt.printf("[ERROR] Failed to create cache file: %s, error: %v\n", cache_path, err)
		return false
	}
	defer os.close(cache_file)

	// Écrire d'abord les données de base (chemin, date de modification)
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

	// Écrire le chemin
	path_slice := transmute([]byte)cache.path
	bytes_written, write_err = os.write(cache_file, path_slice)
	if write_err != os.ERROR_NONE {
		fmt.printf("[ERROR] Failed to write path: %v\n", write_err)
		return false
	}

	// Écrire l'arena complète (incluant la structure et les données)
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

// Fonction pour charger un cache depuis le disque
load_cache_from_disk :: proc(path: string) -> ^Cache {
	if resolver.options.verbose {
		fmt.printf("[DEBUG] Trying to load cache for: %s\n", path)
	}

	// Générer le même nom de fichier que lors de la sauvegarde
	hash_value := hash.fnv64a(transmute([]byte)path)
	cache_filename := fmt.aprintf("%x.cache", hash_value)
	cache_path := filepath.join([]string{cache_dir, cache_filename})

	// Vérifier si le fichier de cache existe
	if !os.exists(cache_path) {
		if resolver.options.verbose {
			fmt.printf("[DEBUG] No cache file found at: %s\n", cache_path)
		}
		return nil
	}

	// Ouvrir le fichier pour lecture
	cache_file, err := os.open(cache_path, os.O_RDONLY)
	if err != os.ERROR_NONE {
		fmt.printf("[ERROR] Failed to open cache file: %s, error: %v\n", cache_path, err)
		return nil
	}
	defer os.close(cache_file)

	// Lire l'en-tête
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

	// Vérifier que le fichier source n'a pas été modifié
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

	// Créer une nouvelle instance de Cache
	cache := new(Cache)

	// Lire le chemin
	path_data := make([]byte, header.path_len)
	bytes_read, read_err = os.read(cache_file, path_data)
	if read_err != os.ERROR_NONE || bytes_read != header.path_len {
		fmt.printf("[ERROR] Failed to read path from cache: %v\n", read_err)
		free(cache)
		return nil
	}

	cache.path = string(path_data)

	// Lire la structure Arena
	arena_slice := make([]byte, size_of(vmem.Arena))
	bytes_read, read_err = os.read(cache_file, arena_slice)
	if read_err != os.ERROR_NONE || bytes_read != size_of(vmem.Arena) {
		fmt.printf("[ERROR] Failed to read arena structure: %v\n", read_err)
		free(cache)
		return nil
	}

	// Copier la structure Arena dans le cache
	mem.copy(&cache.arena, &arena_slice[0], size_of(vmem.Arena))

	// Configurer le reste du cache
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

// Fonction pour charger tous les caches depuis le disque
load_all_caches_from_disk :: proc() -> int {
	loaded_count := 0

	if resolver.options.verbose {
		fmt.println("[DEBUG] Loading all caches from disk")
	}

	// Si le répertoire de cache n'existe pas, rien à faire
	if !os.exists(cache_dir) {
		if resolver.options.verbose {
			fmt.printf("[DEBUG] Cache directory does not exist: %s\n", cache_dir)
		}
		return 0
	}

	// Lire tous les fichiers du répertoire de cache
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

	// Pour chaque fichier de cache
	for file_info in dir_info {
		if !strings.has_suffix(file_info.name, ".cache") {
			continue
		}

		// Extract the original path from the cache file
		cache_path := filepath.join([]string{cache_dir, file_info.name})

		// Ouvrir le fichier pour lire juste l'en-tête et le chemin
		cache_file, open_err := os.open(cache_path, os.O_RDONLY)
		if open_err != os.ERROR_NONE {
			fmt.println("Error loading cache")
			continue
		}

		// Lire l'en-tête pour obtenir la longueur du chemin
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

		// Lire le chemin original
		orig_path := make([]byte, header.path_len)
		bytes_read, read_err = os.read(cache_file, orig_path)
		os.close(cache_file)

		if read_err != os.ERROR_NONE || bytes_read != header.path_len {
			delete(orig_path)
			continue
		}

		// Charger le cache pour ce chemin
		path_str := string(orig_path)
		if cache := load_cache_from_disk(path_str); cache != nil {
			resolver.files[path_str] = cache
			loaded_count += 1
		}

		delete(orig_path)
	}

	if resolver.options.verbose {
		fmt.printf("[DEBUG] Loaded %d caches from disk\n", loaded_count)
	}

	return loaded_count
}

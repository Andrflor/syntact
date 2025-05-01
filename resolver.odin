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

resolve_entry :: proc() -> bool {
	resolver.options = parse_args()
	success := true

	// Debug start
	if resolver.options.verbose {
		fmt.println("[DEBUG] Starting resolve_entry procedure")
		fmt.printf("[DEBUG] Input path: %s\n", resolver.options.input_path)
	}

	// Nombre optimal de threads - un par cœur
	num_threads := os.processor_core_count()
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

	// Attendre la fin
	if resolver.options.verbose {
		fmt.println("[DEBUG] Waiting for thread pool tasks to complete")
	}

	thread.pool_finish(&resolver.pool)
	thread.pool_destroy(&resolver.pool)

	if resolver.options.verbose {
		fmt.printf("[DEBUG] resolve_entry completed with success: %t\n", success)
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

	if resolver.options.verbose {
		fmt.printf(
			"[DEBUG] Successfully read %d bytes from file: %s\n",
			len(source_bytes),
			cache.path,
		)
	}

	// Utiliser l'allocateur d'arena du cache pour stocker la source
	cache.source = string(source_bytes)

	// Parsing et analyse
	if resolver.options.verbose {
		fmt.printf("[DEBUG] Starting parsing for file: %s\n", cache.path)
	}

	ast := parse(cache)
	cache.status = .Parsed
	// TODO: destrouy temp arena and free all

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

		cache.status = .Analyzing
		// analyze(cache)
		cache.status = .Analyzed

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
		fmt.printf("[DEBUG] process_filenode called for node at %p\n", node)
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

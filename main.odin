package compiler

import "core:fmt"
import vmem "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"

/*
 * ====================================================================
 * Compiler Main Function
 *
 * A flexible entry point for the compiler that:
 * 1. Parses command-line arguments
 * 2. Processes input files according to specified options
 * 3. Coordinates parsing and semantic analysis
 * 4. Produces output according to user preferences
 * ====================================================================
 */

/*
 * Compiler_Options holds all command-line options
 */
Compiler_Options :: struct {
	input_file:         string, // Files to compile
	output_file:        string, // Output file (if compilation enabled)
	print_ast:          bool, // Whether to print the AST
	print_symbol_table: bool, // Whether to print the symbol table
	print_scope_graph:  bool, // Whether to print the scope graph
	parse_only:         bool, // Whether to only parse, not analyze
	analyze_only:       bool, // Whether to only analyze, not generate code
	verbose:            bool, // Whether to print verbose output
	timing:             bool, // Whether to print timing information
}

/*
 * parse_args parses command-line arguments into Compiler_Options
 */
parse_args :: proc() -> Compiler_Options {
	options: Compiler_Options

	i := 1
	input_file_set := false

	for i < len(os.args) {
		arg := os.args[i]
		if arg[0] == '-' {
			// Handle options
			switch arg {
			case "-o", "--output":
				if i + 1 < len(os.args) {
					options.output_file = os.args[i + 1]
					i += 1
				} else {
					fmt.eprintln("Error: Missing output file after", arg)
					os.exit(1)
				}
			case "--ast":
				options.print_ast = true
			case "--symbols", "--symbol-table":
				options.print_symbol_table = true
			case "--scopes", "--scope-graph":
				options.print_scope_graph = true
			case "--parse-only":
				options.parse_only = true
			case "--analyze-only":
				options.analyze_only = true
			case "-v", "--verbose":
				options.verbose = true
			case "-t", "--timing":
				options.timing = true
			case "-h", "--help":
				print_usage()
				os.exit(0)
			case:
				if strings.has_prefix(arg, "-") {
					fmt.eprintln("Unknown option:", arg)
					print_usage()
					os.exit(1)
				}
			}
		} else {
			// Set input file
			if input_file_set {
				fmt.eprintln("Error: Only one input file can be specified")
				print_usage()
				os.exit(1)
			}
			options.input_file = arg
			input_file_set = true
		}
		i += 1
	}

	if !input_file_set {
		fmt.eprintln("Error: No input file specified")
		print_usage()
		os.exit(1)
	}

	return options
}

/*
 * print_usage prints usage instructions
 */
print_usage :: proc() {
	fmt.println("Usage: compiler [options] input_files...")
	fmt.println("")
	fmt.println("Options:")
	fmt.println("  -o, --output FILE       Specify output file")
	fmt.println("  --ast                   Print the AST")
	fmt.println("  --symbols               Print the symbol table")
	fmt.println("  --scopes                Print the scope graph")
	fmt.println("  --parse-only            Only parse, don't analyze")
	fmt.println("  --analyze-only          Only parse and analyze, don't generate code")
	fmt.println("  -v, --verbose           Print verbose output")
	fmt.println("  -t, --timing            Print timing information")
	fmt.println("  -h, --help              Print this help message")
}

/*
 * process_file processes a single input file
 */
process_file :: proc(filename: string, options: Compiler_Options) -> (^Node, ^Analyzer, bool) {
	if options.verbose {
		fmt.printf("Processing file: %s\n", filename)
	}

	// Initialize timing
	parse_start: time.Time
	parse_duration: time.Duration
	analysis_start: time.Time
	analysis_duration: time.Duration

	if options.timing {
		parse_start = time.now()
	}

	// Initialize memory arena for resolver
	arena: vmem.Arena
	RESOLVER_CHUNK_SIZE :: 8 * 1024 * 1024
	err := vmem.arena_init_growing(&arena, RESOLVER_CHUNK_SIZE)
	if err != nil {
		fmt.println("Failed to initialize memory arena for file resolution")
		return nil, nil, false
	}
	defer vmem.arena_destroy(&arena)

	// Initialize file resolver
	resolver: File_Resolver
	init_file_resolver(&resolver, filename, &arena, options)
	// defer destroy_file_resolver(&resolver)

	// Read the file
	source, read_ok := os.read_entire_file(filename)
	if !read_ok {
		fmt.eprintf("Error: Could not read file '%s'\n", filename)
		return nil, nil, false
	}
	defer delete(source)

	// Initialize lexer
	lexer: Lexer
	init_lexer(&lexer, string(source))

	// Parse the file with resolver integration
	ast, parse_success := parse_file(&lexer, &resolver, filename)

	if options.timing {
		parse_duration = time.diff(parse_start, time.now())
	}

	if ast == nil {
		fmt.eprintln("Parsing failed completely!")
		return nil, nil, false
	}

	if !parse_success {
		fmt.eprintln("Parsing completed with errors!")
	} else if options.verbose {
		fmt.println("Successfully parsed file!")
	}

	// Print AST if requested
	if options.print_ast {
		fmt.println("\n=== ABSTRACT SYNTAX TREE ===")
		print_ast(ast, 0)
		fmt.println("=== END AST ===\n")
	}

	// Wait for all referenced files to be processed
	sync.wait_group_wait(&resolver.thread_pool.wait_group)

	// If parse-only, we're done
	if options.parse_only {
		return ast, nil, parse_success
	}

	// Perform semantic analysis with imports
	if options.timing {
		analysis_start = time.now()
	}

	analyzer := analyze_ast(ast, &resolver, filename)
	semantic_success := len(analyzer.errors) == 0

	if options.timing {
		analysis_duration = time.diff(analysis_start, time.now())
	}


	// Print analysis results
	if len(analyzer.errors) > 0 {
		fmt.eprintf("\nSemantic analysis found %d errors:\n", len(analyzer.errors))
		for error in analyzer.errors {
			fmt.eprintln(error)
		}
	}

	if len(analyzer.warnings) > 0 {
		fmt.printf("\nSemantic analysis found %d warnings:\n", len(analyzer.warnings))
		for warning in analyzer.warnings {
			fmt.println(warning)
		}
	}

	// Print symbol table if requested
	if options.print_symbol_table {
		fmt.println("\n=== SYMBOL TABLE ===")
		// This function would be defined in your semantic analyzer
		print_symbol_table(analyzer)
		fmt.println("=== END SYMBOL TABLE ===\n")
	}

	// Print scope graph if requested
	if options.print_scope_graph {
		fmt.println("\n=== SCOPE GRAPH ===")
		print_scope_graph(analyzer)
		fmt.println("=== END SCOPE GRAPH ===\n")
	}

	if semantic_success {
		if options.verbose {
			fmt.println("Semantic analysis completed successfully!")
		}
	} else {
		fmt.eprintln("Semantic analysis failed - see errors above.")
	}

	// Print timing information if requested
	if options.timing {
		fmt.printf("\nTiming for %s:\n", filename)
		fmt.printf("  Parsing:   %.3fms\n", f64(time.duration_milliseconds(parse_duration)))
		fmt.printf("  Analysis:  %.3fms\n", f64(time.duration_milliseconds(analysis_duration)))
		fmt.printf(
			"  Total:     %.3fms\n",
			f64(time.duration_milliseconds(parse_duration + analysis_duration)),
		)
	}

	return ast, analyzer, parse_success && semantic_success
}

/*
 * print_symbol_table prints the symbol table in a readable format
 * This is a simplified version; expand it based on your actual symbol table structure
 */
print_symbol_table :: proc(analyzer: ^Analyzer) {
	if analyzer == nil || analyzer.global_scope == nil {
		fmt.println("  <No symbol table available>")
		return
	}

	// Print global scope symbols
	fmt.println("  Global Scope:")
	for name, symbol in analyzer.global_scope.symbols {
		fmt.printf("    %s\n", name)
	}

	// You would implement a more detailed traversal of your symbol table here
}

/*
 * main is the entry point for the compiler
 */
main :: proc() {
	// Initialize memory arena
	arena: vmem.Arena
	CHUNK_SIZE :: 8 * 1024 * 1024
	err := vmem.arena_init_growing(&arena, CHUNK_SIZE)
	if err != nil {
		panic("Cannot initialize memory arena")
	}
	arena_allocator := vmem.arena_allocator(&arena)
	context.allocator = arena_allocator
	defer free_all(arena_allocator)

	// Parse command-line arguments
	options := parse_args()

	total_start := time.now()
	all_success := true

	// Process each input file
	ast, analyzer, success := process_file(options.input_file, options)
	all_success = all_success && success

	// Generate output if not in parse-only or analyze-only mode
	if success && !options.parse_only && !options.analyze_only {
		// This would call your code generation function
		// generate_code(ast, analyzer, options.output_file)

		if options.verbose {
			fmt.println("Code generation completed.")
		}
	}

	if options.timing {
		total_duration := time.diff(total_start, time.now())
		fmt.printf(
			"\nTotal compilation time: %.3fms\n",
			f64(time.duration_milliseconds(total_duration)),
		)
	}

	// Exit with appropriate status
	if !all_success {
		os.exit(1)
	}
}

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
 * Entry point for the compiler that:
 * 1. Parses command-line arguments
 * 2. Sets up compilation options
 * 3. Delegates to the resolver for compilation
 * 4. Returns an appropriate exit code
 * ====================================================================
 */

/*
 * Options holds all command-line options for compilation
 */
Options :: struct {
	input_path:         string, // Path to input file
	output_path:        string, // Path to output file
	print_ast:          bool, // Toggle AST printing
	print_symbol_table: bool, // Toggle symbol table printing
	print_scope_graph:  bool, // Toggle scope graph printing
	parse_only:         bool, // Skip analysis and code generation
	analyze_only:       bool, // Skip code generation
	verbose:            bool, // Enable verbose logging
	timing:             bool, // Enable performance timing
	no_cache:           bool, // Disable caching during compilation
	evict_cache:        bool, // Clear cache before compilation
}
/*
 * parse_args extracts command-line options
 */
parse_args :: proc() -> Options {
	options: Options
	// Removing on disk cache for bootstrap odin compiler will implement it properly in self-hosted
	options.no_cache = true
	i := 1
	input_path_set := false
	for i < len(os.args) {
		arg := os.args[i]
		if arg[0] == '-' {
			// Handle options
			switch arg {
			case "-o", "--output":
				if i + 1 < len(os.args) {
					options.output_path = os.args[i + 1]
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
			// case "--no-cache":
			// 	options.no_cache = true
			// case "--evict-cache":
			// 	options.evict_cache = true
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
			if input_path_set {
				fmt.eprintln("Error: Only one input file can be specified")
				print_usage()
				os.exit(1)
			}
			options.input_path = arg
			input_path_set = true
		}
		i += 1
	}
	if !input_path_set {
		fmt.eprintln("Error: No input file specified")
		print_usage()
		os.exit(1)
	}
	return options
}

/*
 * print_usage displays help information
 */
print_usage :: proc() {
	fmt.println("Usage: compiler [options] input_paths...")
	fmt.println("")
	fmt.println("Options:")
	fmt.println("  -o, --output FILE       Specify output file")
	fmt.println("  --ast                   Print the AST")
	fmt.println("  --symbols               Print the symbol table")
	fmt.println("  --scopes                Print the scope graph")
	fmt.println("  --parse-only            Only parse, don't analyze")
	fmt.println("  --analyze-only          Only parse and analyze, don't generate code")
	// fmt.println("  --no-cache              Disable compilation cache")
	// fmt.println("  --evict-cache           Clear compilation cache before starting")
	fmt.println("  -v, --verbose           Print verbose output")
	fmt.println("  -t, --timing            Print timing information")
	fmt.println("  -h, --help              Print this help message")
}

/*
 * main delegates to the resolver and handles exit codes
 */
main :: proc() {
	success := resolve_entry()
	// Exit with appropriate status
	if !success {
		os.exit(1)
	}
}

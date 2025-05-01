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
 * Options holds all command-line options
 */
Options :: struct {
	input_path:         string, // Files to compile
	output_path:        string, // Output file (if compilation enabled)
	print_ast:          bool, // Whether to print the AST
	print_symbol_table: bool, // Whether to print the symbol table
	print_scope_graph:  bool, // Whether to print the scope graph
	parse_only:         bool, // Whether to only parse, not analyze
	analyze_only:       bool, // Whether to only analyze, not generate code
	verbose:            bool, // Whether to print verbose output
	timing:             bool, // Whether to print timing information
}


/*
 * parse_args parses command-line arguments into Options
 */
parse_args :: proc() -> Options {
	options: Options
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
 * print_usage prints usage instructions
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
	fmt.println("  -v, --verbose           Print verbose output")
	fmt.println("  -t, --timing            Print timing information")
	fmt.println("  -h, --help              Print this help message")
}

/*
 * process_file processes a single input file
 */

/*
 * main is the entry point for the compiler
 */
main :: proc() {
	success := resolve_entry()

	// Exit with appropriate status
	if !success {
		os.exit(1)
	}
}

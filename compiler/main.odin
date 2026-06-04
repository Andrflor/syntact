package compiler
import "core:fmt"
import vmem "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strconv"
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
	print_ir:           bool, // Toggle IR printing (analyzer output)
	parse_only:         bool, // Skip analysis and code generation
	analyze_only:       bool, // Skip code generation
	verbose:            bool, // Enable verbose logging
	timing:             bool, // Enable performance timing
	print_errors:       bool,
	no_cache:           bool,
	evict_cache:        bool,
	print_bytecode:     bool, // Toggle bytecode dump (--bc)
	run_bytecode:       bool, // Interpret the lowered bytecode (--run)
	run_args:           [dynamic]i64, // Positional ??N values fed to --run
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
			case "--ir":
				options.print_ir = true
			case "--parse-only":
				options.parse_only = true
			case "--analyze-only":
				options.analyze_only = true
			case "--print-errors":
				options.print_errors = true
			case "--bc":
				options.print_bytecode = true
			case "--run":
				options.run_bytecode = true
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
			if !input_path_set {
				// First positional is the input file.
				options.input_path = arg
				input_path_set = true
			} else {
				// Further positionals are runtime ??N values for --run, parsed
				// as integers (argv[slot]).
				val, ok := strconv.parse_i64(arg)
				if !ok {
					fmt.eprintln("Error: runtime argument is not an integer:", arg)
					os.exit(1)
				}
				append(&options.run_args, val)
			}
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
	fmt.println("Usage: compiler [options] input_path [args...]")
	fmt.println("")
	fmt.println("Options:")
	fmt.println("  -o, --output FILE       Specify output file")
	fmt.println("  --ast                   Print the AST")
	fmt.println("  --ir                    Print the IR (analyzer output)")
	fmt.println("  --parse-only            Only parse, don't analyze")
	fmt.println("  --analyze-only          Only parse and analyze, don't generate code")
	// fmt.println("  --no-cache              Disable compilation cache")
	// fmt.println("  --evict-cache           Clear compilation cache before starting")
	fmt.println("  --print-errors          Print parse/analysis errors")
	fmt.println("  --bc                    Lower the reduced result to bytecode and print it")
	fmt.println("  --run                   Interpret the lowered bytecode (args... feed ??0, ??1, …)")
	fmt.println("  -v, --verbose           Print verbose output")
	fmt.println("  -t, --timing            Print timing information")
	fmt.println("  -h, --help              Print this help message")
	fmt.println("")
	fmt.println("Trailing integer args are the runtime ??N fixed points for --run:")
	fmt.println("  compiler prog.syn --run 7 3     # ??0 = 7, ??1 = 3")
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

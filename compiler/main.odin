package compiler
import "core:fmt"
import vmem "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

Options :: struct {
	input_path:         string,
	output_path:        string,
	print_ast:          bool,
	print_ir:           bool,
	parse_only:         bool,
	analyze_only:       bool,
	verbose:            bool,
	timing:             bool,
	print_errors:       bool,
	no_cache:           bool,
	evict_cache:        bool,
	print_bytecode:     bool,
	print_regalloc:     bool,
	run_bytecode:       bool,
	emit_exe:           bool,
	run_args:           [dynamic]string, // Positional ??N values (argv strings) fed to --run
}

parse_args :: proc() -> Options {
	options: Options
	// On-disk cache is force-disabled in the bootstrap.
	options.no_cache = true
	i := 1
	input_path_set := false
	for i < len(os.args) {
		arg := os.args[i]
		if arg[0] == '-' {
			switch arg {
			case "-o", "--output":
				if i + 1 < len(os.args) {
					options.output_path = os.args[i + 1]
					options.emit_exe = true // -o implies --emit (gcc-style)
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
			case "--regalloc":
				options.print_regalloc = true
			case "--run":
				options.run_bytecode = true
			case "--emit":
				options.emit_exe = true
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
				options.input_path = arg
				input_path_set = true
			} else {
				// Further positionals are runtime ??N values for --run (argv strings).
				append(&options.run_args, arg)
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

print_usage :: proc() {
	fmt.println("Usage: compiler [options] input_path [args...]")
	fmt.println("")
	fmt.println("Options:")
	fmt.println("  -o, --output FILE       Emit an x64 ELF executable to FILE (implies --emit)")
	fmt.println("  --ast                   Print the AST")
	fmt.println("  --ir                    Print the IR (analyzer output)")
	fmt.println("  --parse-only            Only parse, don't analyze")
	fmt.println("  --analyze-only          Only parse and analyze, don't generate code")
	// fmt.println("  --no-cache              Disable compilation cache")
	// fmt.println("  --evict-cache           Clear compilation cache before starting")
	fmt.println("  --print-errors          Print parse/analysis errors")
	fmt.println("  --bc                    Lower the reduced result to bytecode and print it")
	fmt.println("  --regalloc              Print the bytecode annotated with register allocation")
	fmt.println("  --run                   Interpret the lowered bytecode (args... feed ??0, ??1, …)")
	fmt.println("  -v, --verbose           Print verbose output")
	fmt.println("  -t, --timing            Print timing information")
	fmt.println("  -h, --help              Print this help message")
	fmt.println("")
	fmt.println("Trailing integer args are the runtime ??N fixed points for --run:")
	fmt.println("  compiler prog.syn --run 7 3     # ??0 = 7, ??1 = 3")
}

main :: proc() {
	success := resolve_entry()
	if !success {
		os.exit(1)
	}
}

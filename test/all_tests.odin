// Aggregator package for the whole test suite.
//
// Each subdirectory under test/ is an independent Odin test package
// (parse, analyze, typecheck, reduce, default, codegen, pattern). This
// root package imports all of them so a single command runs everything:
//
//     odin test test -all-packages
//
// `-all-packages` tests every package transitively imported here. Note it
// also picks up the x64 instruction-encoding tests (package x64_assembler,
// imported by `compiler`); those need GNU `as` and are run separately with
// `odin test compiler/backends/x64`. The seven JSON-driven suites below are
// the canonical target.
//
// The blank imports (`import _`) pull each package in only for its @(test)
// procedures; this aggregator defines no tests of its own.
package all_test

import _ "./analyze"
import _ "./codegen"
import _ "./default"
import _ "./parse"
import _ "./pattern"
import _ "./reduce"
import _ "./typecheck"

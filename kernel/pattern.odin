package kernel

import syn "../compiler"
import "core:fmt"

// THE PATTERN
//
// `target ? {cover -> product …}` (specs/language/12). A cover is an expression
// typed like any other; a branch admits target when `target in cover` holds
// (in.odin): `0`, `=5`, `u8`, `>0`, `u8:` (the default of u8), `Circle:` (the
// shape Circle). The branch without a cover admits everything. The first branch
// that admits the value of target gives it.
//
// It is the value of target that is covered, not its color: a definition is
// checked with its values, and a carve that changes them is checked at the carve.
// To cover a whole color, the value is `??`.
//
// - A known value: a single branch fires, the others are not typed. None:
//   Non_Exhaustive_Pattern.
// - An unknown: each branch receives, of the values the previous ones did not
//   take, those for which `target in cover` holds; a branch that receives nothing
//   never fires. What remains at the end is covered by no branch:
//   Non_Exhaustive_Pattern. The branch knows `target in part`, part being what it
//   receives: a fact of its context (Scope.fact), not a rewriting. The result is
//   the type by cases (Cases) — one value per reached branch, never flattened.

type_match :: proc(k: ^Kernel, m: Match, env: ^Scope) -> ^Expr {
	t := type_of(k, m.target, env)
	if is_invalid(t) do return t
	ctx := context_of(env)
	#partial switch v in t^ {
	case Set:
		return match_value(k, m, t, ctx)
	case ^Scope:
		if !is_closed_type(t) do return report(k, .Unsupported, m.span, "not in the kernel yet: a pattern on a scope that depends on an unknown")
		return match_value(k, m, t, ctx)
	case Poly, Term, ^Var, Cases:
		return match_unknown(k, m, t, ctx)
	}
	return report(k, .Unsupported, m.span, fmt.tprintf("not in the kernel yet: a pattern on %s", brief(t)))
}

// cover_type: the type of the cover of a branch; nil for the default branch.
cover_type :: proc(k: ^Kernel, b: ^Scope) -> (cover: ^Expr, ok: bool) {
	if b.cover == nil do return nil, true
	t := type_of(k, b.cover, b)
	return t, !is_invalid(t)
}

// production: the type of the production of a branch.
production :: proc(k: ^Kernel, b: ^Scope) -> ^Expr {
	type_scope(k, b)
	return b.bindings[0].value_type
}

// match_value: target is known; the first branch that admits it gives it.
match_value :: proc(k: ^Kernel, m: Match, t: ^Expr, ctx: Context) -> ^Expr {
	for b in m.branches {
		cover, ok := cover_type(k, b)
		if !ok do return new_expr(Invalid{})
		if cover == nil do return production(k, b)
		switch decide(k, in_type(k, t, cover, ctx), ctx) {
		case .Proved:
			return production(k, b)
		case .Refuted:
		case .Undecided:
			return report(k, .Unproven, m.span, fmt.tprintf("we do not know whether %s is admitted by %s", brief(t), brief(b.cover)))
		}
	}
	return report(k, .Non_Exhaustive_Pattern, m.span, fmt.tprintf("no branch admits %s", brief(t)))
}

// match_unknown: target depends on unknowns. Its possible values, in the
// context, are shared among the branches, in order: each takes those for which
// `target in cover` holds — the solution of that truth for a variable y that
// stands for the value of target.
match_unknown :: proc(k: ^Kernel, m: Match, t: ^Expr, ctx: Context) -> ^Expr {
	rest, exact := envelope(k, t, ctx)
	y, single := lone_symbol(t)
	if !single {
		// bound to the values of target: not an unknown of the program
		y = new(Var)
		y^ = Var{-1, new_expr(rest)}
	}
	cases := make([dynamic]Case)
	for b in m.branches {
		if set_is_empty(rest) do break // the following branches never fire
		cover, ok := cover_type(k, b)
		if !ok do return new_expr(Invalid{})
		part := rest
		if cover != nil {
			admitted, solved := solution(k, in_type(k, var_value(k, y), cover, ctx), y)
			if !solved do return report(k, .Unsupported, b.span, fmt.tprintf("not in the kernel yet: a cover whose values are not known: %s", brief(cover)))
			part = set_intersect(rest, admitted)
		}
		rest = set_diff(rest, part)
		if set_is_empty(part) do continue
		b.fact = new_expr(Term{op = .In, args = pair(t, new_expr(part))}) // what the branch knows: target in part
		given := production(k, b)
		if is_invalid(given) do return given
		append(&cases, Case{b.fact, given})
	}
	if !set_is_empty(rest) {
		if exact do return report(k, .Non_Exhaustive_Pattern, m.span, fmt.tprintf("no branch admits %s", print_set(rest)))
		return report(k, .Unproven, m.span, fmt.tprintf("we cannot prove that the branches cover %s", print_set(rest)))
	}
	if len(cases) == 1 do return cases[0].value
	for c in cases do if _, is_scope := c.value^.(^Scope); is_scope do return report(k, .Unsupported, m.span, "not in the kernel yet: a pattern on an unknown where a branch gives a scope")
	return new_expr(Cases{cases[:]})
}

// lone_symbol: t is a lone unknown, which the branches can restrict.
lone_symbol :: proc(t: ^Expr) -> (^Var, bool) {
	#partial switch v in t^ {
	case Poly:
		if v.const == 0 && len(v.monos) == 1 && v.monos[0].coef == 1 && len(v.monos[0].vars) == 1 do return v.monos[0].vars[0], true
	case ^Var:
		return v, true
	}
	return nil, false
}

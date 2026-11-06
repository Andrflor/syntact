# Audit of the kernel against specs/types.md

Each mechanism: the law it implements (section of specs/types.md), or why it is not
algebra. Verdicts:

- **LAW**: implements a law the spec states.
- **GAP**: a guard: the law written only for a narrower shape than the spec states
  (a number of branches, of calls, of pieces, a family). A guard is a failure: the
  fix is the law in its generality, never a wider guard.
- **DUP**: a second reader or a second version of a mechanism that exists.
- **NOT ALGEBRA**: a fallback, a cap, a heuristic trigger, positional coupling;
  nothing in the spec states it.

## kernel/recursion.odin (2317 lines)

### Laws (kept)

| Procedure | Law |
|---|---|
| `recursive`, `names_scope`, `origin`, `solved`, `calls_in` | §5.6 a scope names itself in its productions |
| `generic_equation`, `call_equation` | §5.6 a call reads its equation where what it and its calls carve are unknowns of their colors |
| `reading`, `is_pending_call`, `call_family` | §5.6 the induction: the calls of an equation being read are the hypothesis |
| `Through`, `call_key` | §5.6 a field the call gives a call of another equation keeps it |
| `generic_solution`, `solved_once`, `substituted`, `at_values` | §5.6 a call of a solved equation substitutes its arguments into the solution |
| `iteration` (fold up from the base, window of states, affine maps composed, modulo m, runs composed) | §5.6 iteration |
| `orbit`, `orbit_index`, `orbit_length`, `least_law`, `continues` | §5.6 orbits and μ, the table of closed forms |
| `fold_law`, `simplified`, `without_state`, `fixed`, `closed`, `faulhaber`, `power_sums`, `series`, `series_law` | §5.6 laws of folds, Σ in closed form |
| `linear_states`, `characteristic`, `recurrent_law`, `algebraic_power` | §5.6 C-finite sequences (Cayley–Hamilton) |
| `tupled*`, `summed_*`, `bitwise_sum` | §5.6 tupling, the equation of a sum |
| `over_fold`, `built`, `carrying`, `run_reads` | §6 a recursion that cuts what another builds; §5.6 a run a fold builds |
| `calls_joined`, `cuts_head` | §6 first match and a pattern gives one of its products; §5.6 a run is the orbit of its positions |
| `affine_in`, `atomized`, `ring_at`, `ring_over` | §4.5 the ring |

### Problems

| Where | Verdict | What |
|---|---|---|
| `iteration`: `len(p.branches) != 2` after `calls_joined` | GAP | the base must be one branch; several base branches (a pattern with several solved products) are refused |
| `iteration` line 630: `len(calls) != 1` | GAP | a step with several calls (count = 1 + c(l) + c(r)) is refused even when the calls are equal: x + x = 2·x (§4.5) |
| `iteration` line 630: `family != .Int && !tail && !joins` | GAP | the composed maps only over integers; reals are a field (§4.5) |
| equal calls that differ by a field the equation does not read (`seed` in tree, interp) | GAP | the type of a call is its equation: a binding it does not read does not change its value |
| `orbit_step`: several calls only when each is `f{n -> m - j}`, j constant | GAP | the window of states is stated for calls further along the orbit; other shapes refused |
| `cuts_head`: `c != 1` for a union of covers | GAP | covers of several pieces are not combined |
| `built`: one shape of step (`{...z e₀ … }` with z first) | GAP | §5.6 "c bindings a step" is read only for a run placed first |
| `summed_fold` line 1845: `i != 4 + len(f.states) + x` | NOT ALGEBRA | positional coupling to the layout of `fold_parts` |
| `recursive_call`: the production read at the values only when a carved value `is_constant` | NOT ALGEBRA | a trigger; §7 states the law for any value |
| `keyed_equation`: through the calls of others, and if that gives no type, again without | DUP | two readings of one equation, one a fallback |
| `production_law`: an effectful equation typed again on a copy | DUP | a second typing of the same production |
| `effects_elsewhere`: the root read again at unknowns to find effects | DUP | a third reading of the equation |
| `production_known` / `production_at` used by `pattern_on`, `over_fold`, `recursive_call` | to check | §6 states the pattern on a call read on its production at the values; the uses must be exactly that law |

### Removed already

- the bounds of a call (`call_image`, `least_bounds`, `counter_bounds`, `linear_bounds`, caps 16 and 512): a solver beside the equations (f1c03a2).
- the night's second reader of recursions (`written_steps`, `field_bounds`) (76a026f, then the revert 90c505f).

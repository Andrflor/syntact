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

## kernel/rewrite.odin (981 lines)

The image of a term is the term with each unknown replaced by its layout, each
operator distributing over `|` (§7); §8: "Operators distribute over `|`: there is no
interval arithmetic". We compose in the types; we never unfold, never bound.

### Laws (kept)

| Procedure | Law |
|---|---|
| `rewrite`, `rewritten_term`, `rewrite_carve`, `rewrite_fold`, `bound_as`, `renamed`, `reads`, `node_of` | substitution; a fold binds its index and states |
| `layout_of`, `held` | §7 the layout of an unknown |
| `layout_image` for constants, unknowns, operations over constant images, `|`, `&`, `~`, `is`, a pattern (the images of its products, §6), a call giving scopes (the scope of its equation, §5.4) | §7 an operator distributes over `|` |
| `related_image` (a·u + r, u between l and h, between a·l + r and a·h + r) | §6, stated in the spec as the one reading of a layout that relates unknowns |
| `euclid_image` (n % b in 0..b − 1; n / c with n = c·q + r) | §4.5 Euclid |
| `field_color`, `produced_field`, `shape_field` | §5.4 a field of a shape has its color |

### Problems: interval arithmetic (§8 forbids it)

| Where | Verdict | What |
|---|---|---|
| `int_hull` (used by `layout_image` on `&`, `euclid_image`, `related_image`, `built_image`, `scope.odin`, `normal.odin`) | NOT ALGEBRA | replaces a set by the range from its least to its greatest: a type replaced by its hull |
| `hull_times`, `sum_image` | NOT ALGEBRA | the image of a fold or of a Σ as n·lo..n·hi: bounds of the steps multiplied by bounds of the count |
| `least_image` | NOT ALGEBRA | μ bounded by counting digits in a loop |
| `monotone_in`, `monotone_image` | NOT ALGEBRA | a term read at the bounds of an unknown; not in the spec (re-added today with the Euclid commit — my mistake) |
| `divided_by` with `term_bound` on R | NOT ALGEBRA | the rest bounded below to apply the quotient law |
| `term_bound` (pattern.odin), `outer_set` (pattern.odin) | NOT ALGEBRA | the least or greatest of a term over unknowns: bounds |
| `layout_image` on a Fold: `sum_image`, then `built_image`, then the value over its states | to rewrite | a fold is its law: solved, its closed form; not solved, a computation whose values are the type of its value, proven by induction (§5.6) |
| `layout_image` on a Series: split Σ(a + b), then `hull_times` | NOT ALGEBRA | the Σ law gives the closed form; otherwise the family |
| `Plain` / `plain_of` cache of images | to check | an image depends only on the node when the node holds no call: the law itself, not a context |

## kernel/scope.odin (1739 lines): runs

### Laws (kept)

| Procedure | Law |
|---|---|
| `scope_law`, `placed`, `access_law`, `collapse_law`, `product_of`, `carve`, `carve_at`, `carved_copy` | §5.1–§5.5 scopes, carving, productions |
| `admits`, `produced`, `match_shape`, `run_lengths`, `pieces_in`, `run_pieces` (Arden) | §5.3, §5.4 shapes and runs |
| `run_law`: a pattern gives one of its products; \|x from k\| = \|x\| − k; \|x{#k -> v}\| = \|x\|; (x from a).#b = x.#(a + b); x{#k -> v}.#j = j ? {=k -> v -> x.#j}; `by_place` | §5.3, §6 |
| `fold_length` | §5.3 \|{...P ...x ...Q}\| = \|x\| + \|P\| + \|Q\|, through the fold |

### Problems

| Where | Verdict | What |
|---|---|---|
| `run_law` on `.Item`/`.Put`: the place is proven by the length as a term, else by `length_image` and `term_bound`, else by "x from k is not {}" | NOT ALGEBRA | three strategies one after another, one of them bounds; the law is one: k in 0..\|x\| − 1, read in the algebra |
| `built_item`: at a place not known only when one binding a step (`c == 1`) | GAP | §5.6: the binding c·i + j is eⱼ at step i, for any c |
| `built_field`: `len(es) != 1` | GAP + DUP | the field of a binding is `access_law` on `built_item`; a second reader of the same binding |
| `length_image`: a run `...A * m` only when \|A\| is 1 (`!is_int(piece, 1)`) | GAP | \|A * m\| = \|A\|·m |
| `suffix`: a place after a run refused; pieces only of length 1; `int_hull` on the count left | GAP + NOT ALGEBRA | the suffix of a shape is a shape (§5.3); the count left is a type, m − c, not a hull |

## kernel/pattern.odin, normal.odin, lattice.odin, size.odin

| Where | Verdict | What |
|---|---|---|
| `and_law` (normal.odin): a set the laws keep written, u8 * u8, met through `int_hull` | NOT ALGEBRA | a type replaced by its hull to decide a meet (§8) |
| `bounded_preimage` (pattern.odin): a·u + t in S, a ≠ ±1, narrowed "at the bounds of t", the hull of the preimages | NOT ALGEBRA, but stated in §6 | the spec text itself says "otherwise its bounds at the bounds of t" |
| narrowing by a set over unknowns through `outer_set` / `inner_set` / `term_bound` (pattern.odin) | NOT ALGEBRA, but stated in §6 | the spec says "a set over unknowns narrows by its bounds" |
| `int_bounds` on a constant set (lattice.odin, size.odin) | LAW | the least and greatest of a constant set: computing on constants, not on types |

## The spec contradicts itself

§8 says "Operators distribute over `|`: there is no interval arithmetic". §6 says a
branch narrows `a·u + t in S`, a ≠ ±1, "at the bounds of t", and "a set over unknowns
narrows by its bounds". Those two §6 sentences are bounds. They need your decision
before the code that implements them is removed: the exact preimage of a set by
a·u + t, as a set (§4.6 sets of integers), or nothing.

## Summary: what goes, what is rewritten

1. Interval arithmetic: `int_hull`, `hull_times`, `sum_image`, `least_image`,
   `monotone_*`, `term_bound`, `outer_set`, `inner_set`, `divided_by`'s bound on R,
   the hull in `and_law`, the bound strategy of the place check in `run_law`. The
   image of a term is the term over the types of its unknowns (§7).
2. Guards: `iteration` (one base branch, one call, integers only), `orbit_step`,
   `cuts_head` (one piece), `built_item` / `built_field` (one binding a step),
   `length_image` (pieces of one binding), `suffix`. Each is rewritten as the law in
   its generality.
3. Duplicates: `keyed_equation`'s fallback reading, `production_law`'s second typing
   on a copy, `effects_elsewhere`'s third reading, `built_field` beside `built_item`.
4. Triggers: `recursive_call` reading the production only when a value `is_constant`;
   `summed_fold`'s positional index into `fold_parts`.

# The cases of the recursion code (kernel/recursion.odin), extracted

Every shape the code recognizes today, what it produces, and the general law of a
solver that covers it. Nothing here is kept as a case: each line is to be replaced
by the law in the last column.

## How a recursion is entered

| # | Where | Case recognized | Produces | General law |
|---|---|---|---|---|
| 1 | `recursive_call` | the equation is solved | the solution with the call's values substituted | substitution (a definition is an equality) |
| 2 | `recursive_call` | a carved value `is_constant` | the production read at the known values, kept if it calls nothing | congruence: a definition is unfolded only as an equality the solver uses, never as a trigger |
| 3 | `recursive_call`, `over_fold` | a field is given a fold | the recursion as a fold along the same orbit | composition of definitions (deforestation is equality of two definitions over the same orbit) |
| 4 | `solve`, `generic_solution`, `call_equation`, `keyed_equation` | solved at the defaults fails | read again where the fields are unknown; through the equation of another call, else without | one definition per function, universally quantified over its fields |
| 5 | `production_law`, `effects_elsewhere` | effects somewhere in the equation | typed again on a copy; read again at unknowns | effects are terms of the definition; no second typing |

## `iteration`: the catalogue

| # | Case recognized | Produces | General law |
|---|---|---|---|
| 6 | covered branches each calling with the same fields (`calls_joined`) | one call whose carves are patterns | case analysis: ite commutes with application |
| 7 | a pattern of exactly 2 branches, one base, one calling | stop = the base cover | case analysis over any number of branches |
| 8 | a base cover that cuts c pieces of a run (`cuts_head`), one cover or a union of one-piece covers | stop = runs of fewer than c pieces | the theory of sequences: the complement of the covers |
| 9 | effects before the call, one call with an answer (`at_calls`) | effects folded going down | effects are a sequence: the order of the definition |
| 10 | one call: its step on the target, other carves as carried states (`orbit_step`, `counter_next`) | the orbit's step, the carried states | the definition's argument map |
| 11 | several calls f(m − j), j constants | a window of states | linear recurrences over the integers |
| 12 | step affine α·x + β, α = 1 or α ≠ 1 constant; `x from c`; `x >> c`; `x / c` (`orbit`) | kᵢ in closed form | the closed form of an affine map's powers (integers), of `from` (sequences) |
| 13 | μ of an affine orbit crossing a half-line or a point; of a run cut by c (`least_law`) | the length n in closed form | μ = the least solution of an integer constraint |
| 14 | closed orbit, no carried state, value read from the base up (up-fold), window d | the fold from the base | the definition folded along the orbit: f(m) = v(k₀, v(k₁, … b(kₙ))) |
| 15 | down-fold: v = α·y + β (integers), modulo m, runs {...P ...y ...Q}, tail v = y, carried states | the composed map along the orbit | composition of maps in the theory of v's type: (ℤ, +, ·), ℤ/m, the free monoid |
| 16 | guards: `len(calls) != 1`, family ≠ Int unless tail or runs, `has_effect` after the call | refused: the call stays | none: any term of the theories |

## Folds, sums, sequences

| # | Case recognized | Produces | General law |
|---|---|---|---|
| 17 | a state whose update is itself; a state nothing reads | removed | dead state elimination: equality |
| 18 | a state x ↦ r·x + g(k), g polynomial, along a counter (`closed`, `faulhaber`, `power_sums`) | the closed form | sums of polynomials and geometric sums |
| 19 | states with a linear update with integer coefficients (`linear_states`, `characteristic`, `recurrent_law`, `algebraic_power`) | C-finite sequences | linear recurrences (Cayley–Hamilton) |
| 20 | calls along a counter read by a fold (`tupled*`) | one call returning a tuple | composition of definitions |
| 21 | Σ of an equation over a field (`summed_*`), Σ of a fold (`summed_fold`), Σ of what a fold carries (`carried_sum`) | an equation of the sum | linearity of Σ over the definition |
| 22 | Σ of a bitwise operation (`bitwise_sum`) | bit by bit | the theory of bit-vectors |
| 23 | a run a fold builds c bindings a step (`built`, `built_item`, `run_reads`) | its bindings read at a step | the theory of sequences: the run is the fold's concatenation |

## The type of a call that stays

| # | Case | Today | General law |
|---|---|---|---|
| 24 | `V in C` with V a call | `call_in` by induction; the bounds (`call_image`) were removed | the type of the call is its definition read on types, the least solution; `in` decided on it |

# Night log

The values a field takes across a recursion — an integer, a scope field by field,
a run carved to suffixes of itself (Suff(T)) — are what the call gives it closed
under what each call carves it to: §5.6's law, already in the spec, not a new one.
Integers are read so (one reading); scopes and runs are next. Still to be proposed
by the next round: the language the productions of a recursion build (Arden on the
run they place), the other half for sexp.

Each step: the law, the commit, the benchmarks' status. Every commit is green
(kernel corpus 581/5 unchanged, code tests, sum tree interp bintrees records push
identical to Goose) and can be reverted on its own.

## Goal for the morning
All 16 Goose benchmarks pass (kernel types them, they compile, outputs identical to
Goose), each failure fixed as the existing law of the algebra that covers it, at the
place it lives in the kernel. No blockers: what looks like a new law is an existing
one applied too narrowly — find which.

## At the end
The artifact (https://claude.ai/artifact/UZ83prVCcesGtNnHbmweyo) updated with all 16 Goose
benchmarks: each one's status and, where it runs, its times against Goose and C++.

## Steps
- 2026-11-05 evening: agent on six gaps (x & C in C; head of a concatenation;
  narrowing in nested branches; field of a call's result; call in a union of
  shapes; bounds as functions of what a call carves — strlist).
- 082af1b x & C lies in C (image of t & S).
- c236db9 head of a concatenation read by place ({...X rest}).
- 4e5588e narrowing kept in a branch nested in another branch's scope.
- e4c110d field of a recursive call's result, by induction on that field.
- container restarted; agent resumed on steps 5–6 (call in a union of shapes; bounds as functions of what a call carves).
- a897589 a call in a union of shapes (Parsed); exhaustiveness read as the target in the union of the covers.
- 7cfd7c2 bounds of a call as linear functions of the measures of what it carves (strlist's sum of word lengths).
- 55fa317 steps of a fold along any orbit; length of a run a fold builds.
- 23:20 check at 55fa317: kernel types sum tree interp bintrees records push strlist scene (outputs of the six identical to Goose);
  still failing in the kernel: respond (3 errors), sexp (22), calc (32), lru (3), graph (3), words (3), blur (18), particles (6).
  strlist and scene typed but not compiled yet (backend: layout of split's result; f32). Backend agent launched on them.
- kernel agent done (8 commits, green each): strlist types. Remaining: respond 1 error (buffer length; 60 s kernel time — regression),
  calc 32 / sexp 22 (fields read in their colour, not at the values the call gives: nodes + 1, v*10 + d), lru 3 ((a*a)/keys < keys),
  graph/words: my ports are incomplete (no main). Weak point to fix: linear bounds not re-proven by induction.

## Step: faithful ports (acc3391)
- graph, words, blur, particles rewritten as faithful ports; Python mirrors match Goose outputs at two sizes.
- None type yet. Kernel gaps (s % v symbolic, count-down run length, captured-unknown fold bound, expansion inclusion, narrow rest cover, product places, particles stack overflow, f32 laws) queued to kernel round 2.
- Linear bounds now proven by induction (2d8b71a).

## Step: backend round 1 (ea788a7, 6d0f699)
- strlist compiles, Goose output at N ≤ 3000; crashes at 400000 (split builds its run one level per word: O(N²), stack). 
- round32 lowered (f32); C calls foreign symbols as variadic.
- Found: 5 x64/c case failures (3 old; 2 from cf611be). Backend round 2 launched: those cases, item_image({}), split as a fold building its run, strlist compile time, scene port.

## Step: kernel round 2 (2d8b71a … f330f31)
- Linear bounds proven by induction; compile time memoised by the state of what is given (respond 47 s/OOM → 3.7 s, strlist 0.6 s).
- Euclid with a symbolic divisor (s % v); place carve in run shapes; particles stack overflow fixed; fold length through its step.
- Errors now: respond 3, sexp 22, calc 32, lru 7, graph 12, words ~32, blur 4, particles 7.
- Kernel round 3 launched: values of a field across a recursion as the image of its orbit (blur, calc, sexp, graph, lru); runs compose for call lengths (respond); reals in the ring (particles); words gaps.

## Check 01:22 UTC (master 398831f)
- Compile clean: sum, tree, interp, bintrees, records, push, strlist (7/16).
- Fail: scene (stub, real input), respond 4, sexp 18 (Product form), calc 33, lru 8, graph 13, words 33, blur 5, particles 8 (error lines).
- Running: backend round 2, kernel round 3.

## Step: backend round 2 (089ef45, 01b8603, 7c81868, 59fefb4, 946c9bf, 63954d7)
- Verified on clean master 63954d7: corpus 581/5, code + calc green, six outputs identical on x86 and C.
- x64/c cases: 3 of 5 fixed (hole items admit through their color; holes take no bits; tree layout). Left: "runs built at run time", "run carved by place" (zip in i64: moved fields read at their image = orbit narrowing, sent to kernel round 3).
- {} items none (workaround removed). strlist compile 25 s → 0.8 s (1 * 1 no longer gathers powers).
- scene: faithful port pushed, does not type (exponential node count, f32 ranges through the recursion); sent to kernel round 3.
- strlist at 400000 still crashes: split-as-fold agent launched (fold states bounded by the same induction as calls; backend loop writing at the run's end).

## Step: kernel round 3 (2228152, a4cbbaa)
- 2228152 (proposed law, top of this log): a field moved by every call from a constant
  default read in the image of its orbit. words: 2 ** μ(...) at 246/260 resolved, the
  downstream gaps (distinct, |split|, .#) surface: 31 → 50 errors, 4 s → 6 s.
- a4cbbaa runs compose for the length of a call (§5.6); a pattern's products affine with
  one α. respond 195:6 now reads the fold of lengths; still open: the image of
  |escape{s -> items.#x.sku}| (a field of a run a fold builds). respond 4 s → 17–21 s.
- Not done: kept fields in the image of the entry value (blur row y, lru keys), Task C
  (ring over rationals), Task D.

## Step: kernel round 3 (2228152, a4cbbaa) — 01:45 UTC
- Runs compose for call lengths (§5.6). respond still 3 errors; its compile time rose to ~19 s (to fix).
- 2228152 narrows fields to their orbit by a second reading. The law it implements is already in §5.6 (linear bounds: "a field every call keeps holds what the call gives it"; counters from max(c)) — not a new law. Round 4a rewrites it as one reading of the equation with the proven bounds.
- Launched 4a (field bounds: blur, lru, calc, graph, scene, zip cases; respond/words compile time) and 4b (reals in the ring: particles; sexp Product form; words gaps). Split-fold agent still running (strlist 400000).

## Step: kernel round 4b — reals, sexp reader, orbit points (7ed6368, b1d188b, 4800611, 2ab6976)
- 7ed6368 §4.5 the reals are a field: the ring reads real terms as monomials over a
  divisor and writes each coefficient as a real (x + 0.0 = x, 2.0 * y - y = y).
  Normal form of a real product is now coefficient first (2.0 * x).
- b1d188b §5.6 a fold whose value is x: c ↦ α·x + g, α ≥ 0 constant (integer or real),
  is bounded by its bound folds y ↦ α·y + max(g) from max(c), solved at the least and
  greatest count of steps; μ of the orbit of k >> a read as k / (2 ** a) ** i.
  particles: real_of's folds proven in f32 (90:16 gone).
- 4800611 parser: `x ? {{} -> a  -> b}`: a `{` glued to the braces of the branches
  opens the cover's scope (sexp "the form Product" was this).
- 2ab6976 §5.6 the points of an orbit before its μ are kᵢ & ~B, kₙ is kₙ & B (when n
  stays a μ); (t & S).#k holds what t holds within what S holds there; a run of values
  from an unknown place is any of its suffixes; a run is in a shape of runs when its
  length, as a term, is one the shape admits. A scan like number{t}'s step now reads
  ((t from i) & {(48..57): ...A:}).#0, a proven place.
- Errors: particles 8 → 5 (0.6 s), sexp 22 → 18 (1.9 s), words 49 → 50 (9 s; was 6.5 s).
- Open: particles round32(?.#0.vel.y - 0.0625) — f32 is unbounded in Real_Bounds and
  its greatest finite value (2^128 - 2^104) is beyond i128 rationals, so round32(f32 -
  0.0625) ∈ f32 cannot be computed; sexp number's v * 10 + d in i64 is not provable
  (digit runs are unbounded), its <invalid> step keeps the call and cascades;
  words: (a * a) / vocab in 0..vocab - 1 (a = s % vocab), count-down run length,
  captured-unknown fold bound, inclusion through expansions, narrower-rest cover.

## Step: kernel round 4b (7ed6368, b1d188b, 4800611, 2ab6976) — 02:45 UTC
- Reals are a field in the ring (§4.5); affine fold states bounded by their bound folds; parser fix for `{{} -> a -> b}`; orbit points before μ out of the base.
- particles 8 → 5, sexp 22 → 18, words 50.
- Round 5 launched: sexp's digit run bounded by the language of the text gen builds (Arden); f32 rounding bounds at format extremes (particles); words gaps and compile time.

## Found: 2ab6976 is unsound — 03:00 UTC
- `depths{max -> 8  d -> 4}!` (= 18) types as `⟳(…; y: 0 ↦ none)` from 2ab6976 on (18 at 4800611). bintrees still prints right on master, but the law is wrong.
- If the fix is not in by morning: `git revert 2ab6976` restores soundness (it only costs sexp/words `.#` places).
- Field-bounds agent (round 4a) is fixing that law, then landing its one-reading commits (blur 4→1, words 50→38, calc 32→29, but lru/graph/scene surface more checks and respond ran out of memory after rebase — must be fixed before push).

## Step: kernel round 5 (d254989, b3e80ed) — 03:20 UTC
- d254989 §4.10 a value of a format lies within its extremes: a real is num / den ·
  2^exp (the power of two carried apart, f32/f64 extremes exact); a format cell's
  absent bounds are ±greatest; a bound of a sum beyond the integers is moved outward
  (interval arithmetic: the set only grows). f32 - 0.0625 rounds into f32, f32 + f32
  does not, f16 65520.0 ties beyond. particles 109:33 vel.y - 0.0625 gone.
- b3e80ed euclid_image reads the first quotient it can, and the image of that
  reading reads the others (it read every order: k! readings). words 5.6 s / 4.8 GB
  → 1.0–1.7 s / 0.8–1 GB, same errors; other benches unchanged.
- particles: 5 errors, next `round32(?.#0.pos.x + ?.#0.vel.x)` in f32 — the bounds
  of the fields of the particles across the 200 steps (vel.x kept, vel.y moved by
  -0.0625 or halved, pos += vel), a field bound through a fold over a run: field-bounds
  topic.
- words (32 errors): 215:9 `(a * a) / vocab` in 0..vocab - 1 is proven in isolation
  by two laws (divided_by reads n over b = x + c, x one atom, by x = b - c; a quotient
  n / b with n growing in an unknown up to h lies in 0..Q + R, n(h) = b·Q + R), but on
  words the reading explodes in memory (> 10 GB): kept out, w/euclid3_quotient_bound.patch.
- sexp 18: needs the proposed law above.

## Step: kernel round 5 (d254989, b3e80ed) — 03:20 UTC
- Format values lie within their extremes (§4.10): f32 − 0.0625 rounds into f32. euclid_image reads one quotient at a time: words 5.6 s / 4.8 GB → ~1 s / 0.8 GB.
- particles 5, sexp 18, words 32 errors. The "proposed law" above for sexp is §5.6's field law applied to runs (a field carved to its own suffix holds the suffixes of what the call gives); assigned to the field-bounds agent with scopes (lru, particles) and runs (sexp, zip).
- Round 6 launched: words (inclusion through expansions, narrower-rest cover, dict fold bound, distinct, (a*a)/vocab).

## Step: soundness fixed, one reading landed (de9538c, 9ff6b55, 123d788, a39b450) — 03:50 UTC
- 2ab6976's bug: the image of ~S was the complement of what S *may* hold; now of what S holds for every value of its unknowns (§4.1). Also `>m` with m a single value no longer read as everything.
- Verified on clean master a39b450: corpus 583/5, code tests green, six outputs identical on x86 and C, bt2 x = y = z = 18.
- respond runs out of memory since 2ab6976 (runs_in's length clause); being fixed. Next for that agent: extra errors in lru/graph/scene/words/particles, the field law for scopes and runs, blur 72:10.

## Step: strlist at Goose's size (6f53047 … f7b92e1) — 04:20 UTC
- split is a fold building its run (§4.13/§5.6): one bound prover for calls and folds (`Recursion`), patterns distributed in the ring, a Σ over what a fold builds passed through the fold, runs grown in their own memory.
- Soundness fixes on the way: a place written with a value admits only it; a step reading a state the call changes is not an orbit.
- Verified on clean master f7b92e1: corpus 583/5, code tests, six outputs, bt2 = 18, strlist 400000 → 400000 368751732 (= Goose).
- strlist at 400000: C 27.8 ms, x86 42.7 ms, Goose 29.9 ms; 12.9 MB (= Goose).
- For the user to review: loop fusion along one orbit and loop-invariant hoisting are backend rules, not yet written as laws in specs/types.md. Hoisting must not run a trapping term when a loop has zero turns: being fixed (placement law).
- 8/16 compile now.

## Step: length of a run as the sum of its pieces (aa8cd77) — 04:40 UTC
- Verified on clean master aa8cd77: green, bt2 = 18.
- respond: 2 errors in 7.4 s with aa8cd77 on the base before 95260f7; out of memory again with 95260f7 (Σ through a fold).
- Launched: (A) respond memory + kernel compile time; (B) §5.6 field law for scopes, runs and fold states (lru, zip tests, sexp text, particles), extra errors, blur 72:10, calc/graph/scene. Running: words round, x86 code quality + hoisting soundness.

## Step: x86 quality, hoisting (955b160, db9ff0d) — 04:55 UTC
- Hoisting: a term hoisted before a fold reads no unknown the loop binds and is typed total for all values of its unknowns; test "loop invariant before zero turns" added.
- x86: branches on comparisons fused, decided branches threaded. strlist 8M: x86 630 ms, C 469 ms, Goose 622 ms. records x86 122 → 96 ms, push 180 → 152 ms.
- Proposed law, waiting for the user (§5.6): "A state read only through measures of it — its length, its first and last bindings — each of which its update gives in terms of those measures, m(u(x)) = h(m(x)), is the fold of those measures: x: c ↦ u(x) becomes m: m(c) ↦ h(m), and the run is never built." (would remove strlist's per-letter store). Not implemented.

## Step: words round 6 (b7fc637, f27a72e, 10bdfff, 3d31fc2, 88f9c29) — 05:30 UTC
- b7fc637 §5.3/§5.4 a run `...C:` of a shape C is the bindings of C placed (run_form,
  layout_pieces): {...Bytes8: ...Word:} in {...Bytes8: ...A:}, Bytes8 in
  {...A: ...Bytes8:}, {u8 ×16 ...Over8:} in {u8 ×8 ...Word:}. Also: a suffix of a
  shape is read only when it is not a value (no default of its runs computed), and the
  default of a meet the laws leave is unsupported, not an infinite recursion.
- f27a72e §4.6/§5.4/§5.6 runs of one piece meet and part by their lengths:
  P*M & Q*N = (P&Q)*(M&N), P*M & ~(Q*N) = P*(M&~N) (P within Q), P*M | P*N = P*(M|N);
  `x in S` atoms on such runs combine (computed_whole). Long8 & ~Bytes8 = u8 * 9..:
  a pattern `{Bytes8: -> …  {u8: ...Long8:} -> …}` on Long8 is exhaustive, its last
  cover taking every value left, so last8/last4 are folds. A suffix at an unknown
  place of a run of M pieces is a run of 0..max(M) pieces (was M: wrong).
- 10bdfff §5.6 the up-fold's base is read at kₙ & B when n stays a μ (as the down-fold
  did): last8{t}! is (t from μ) & Bytes8. hash types with no error alone.
- 3d31fc2 §4.5 x [&] m, x, m ≥ 0: read as an unknown in 0..m where the term relates it.
- 88f9c29 §4.5 (order of /) n / b ≤ n(h) / b ≤ Q + R, n(h) = b·Q + R (the euclid3 draft,
  ring-only), and two efficiency laws of the reading: a term is read where it relates
  (t reads beside d an unknown d reads; for n / c, not through layouts), and the unknown
  that reads a term is one for each node (plain: in every state). Without the quotient
  law words drops 1.9 s → 0.65 s.
- words: 37 errors at 1.9 s → 4 errors at ~7 s (user 4 s) / 7.6 GB: the time is the rest of
  the program typed for the first time (text, split, count, hash); the cost is readings
  of (r*r)/vocab for each new remainder unknown r, inside fold_induction and fold
  lengths (~1500 readings of terms holding |dict.#k|).
- Left: 260:20/246:20 nslots in u64 needs the image of μ(i: α·c**i + β in l..): a patch
  (scratchpad wd/least_growing.patch) proves it, but words then types count/put/hash and
  goes over 10 GB: not pushed. 283:8 |split| in i64 (a fold over a fold's length). The
  count-down run length (orbit going down) not done.

## Step: words gaps, respond and calc memory (b7fc637…88f9c29, e1a1668, 646014e) — 05:35 UTC
- words 37 → 4 errors: expansions are their bindings placed; runs of one piece meet by their lengths (also a soundness fix: a suffix at an unknown place has 0..M pieces); x [&] m in 0..m; n / b ≤ Q + R.
- respond: out of memory → 2 errors, 4.3 s / 2.9 GB (folds compared by what they bind, not by rewriting; |items.#x.sku| = 6; induction does not rewrite what it needs no hypothesis for). calc 8.7 GB → 2.2 GB, 29 errors.
- sexp now 4 errors; blur 7.

## Step: §5.6's field law for every kind of field (cea3cc3, f6e3790, 3dbc25f, 236bde0, 6fc34a9) — 05:45 UTC
- f6e3790 a run field every call keeps or carves to its own suffix `t from c` holds
  Suff(T): a run of the items of what the call gives it ({...{I:} * 0..} & its color).
  The written steps read a cover's pieces (`(t)` of `{u32(h) ...(t)}` on `a` is
  `a from 1`). zip types: "runs built at run time" and "run carved by place" pass on
  x86 and C (acc + h*g with h, g in 0..999: hi = acc + 998001·|b|).
- cea3cc3 lattice: (a & b) & a = a & b for meets kept written (was a growing chain of
  equations); {} is the run of no piece (Word & ~{} within Word); the default of a meet
  is the default of a term it holds (was an infinite recursion); a known place of a run
  lies within its items too; a run of a set kept written by its range.
- 3dbc25f a record field (Stats) holds, field by field, what each call's step gives
  it: the written steps read a binding by its value, a pattern as its products, a
  carve of a shape by name or place, `s.hits` as a part unknown. An integer field or
  part a call moves by y + g, g in gmin..gmax, along a field every call moves by u + δ
  (|δ| = 1), lies in y - δ·gmax·u ≤ max(y₀ - δ·gmax·u₀) (and the lower side): the
  linear bound over two measures, kept by every step, so the call the equation makes
  reads the same equation (no chain). A field read of a scope not known yet proves
  `run{…}!.hits in i64` by induction. lru 90–93 and 67:19 gone; scene 111:10 and
  131:65 (`build{…}!.nodes` expanded) gone; sexp 18 → 4.
- 236bde0 the colors of a shape over unknowns are rewritten with them (generic_equation
  read them over the written-step unknowns, never narrowed by a branch); a read a branch
  narrows, t & S, keeps its relation (runs_read). lru 70:16 size + 1 and 74:10 gone.
- 6fc34a9 runs of one piece meet whatever their lengths (f27a72e only met decided ones):
  Adj & runs of its items keeps |adj| = v; graph's `.#` place errors gone.
- Errors (kernel time): lru 8 (0.6 s), particles 8 (0.6 s), graph 22 (0.5 s), scene 13
  (0.2 s), words 4 (3.5 s), blur 7 (1.7 s), calc 29 (3.6 s), sexp 4 (1.9 s), strlist 0,
  respond 2 (4.2 s). Duplicates: one error per reading of an equation (particles 7 → 8
  and graph are the same kinds read once more).
- Open, each the law it needs:
  - lru 63:19 `?s.size - 1 in u32` (f.hit true): size = |recent| is a linear bound of
    a part over the length of another part, and `take{xs -> r}!.hit` true only when r
    is not {}: the call's value read per branch of its base. 67:26 `node.val + 1 in
    i32`: val ≤ 999 + n with n up to 2^32 - 1 can overflow i32 — a true error of the
    port's input range (Goose has N = 8000000); the items of `recent` would also need
    the field law on the items of a run field.
  - particles 109:33 `round32(?.#0.pos.x + ?.#0.vel.x) in f32`: the items of a run
    carried by a call of another equation (`ps -> step{ps -> ps}!`), each moved by
    move{} — the field law on items through a map, with real steps (α = -1 for the
    reflection, not covered by the orbit bound, which takes α = 1 and integer g).
  - graph 89:12 `total + dist.#u in i64`: the items of a run field moved by Put
    (`dist{#w -> d + 1}`); 107:12 and 127:8 the bfs total and the pool sum.
  - blur 72:10 `row{…}! in Img` and six `.#` places (`i - w - 1` with y, x ≥ 1):
    products of unknowns in the place proof.
  - sexp 279:8 |text| in i64 (a fold of gen texts), then 280–282 `.roots`/`.err` of
    parse_all (cascade).
- Wording for §5.6 (the law is there; this is its text for records and runs, for the
  user to confirm): "A field every call keeps, or carves to its own suffix m from c,
  holds what the call gives it, or one of its suffixes: a run of its bindings. A field
  holding a record holds, binding by binding, what the steps give each. A counter
  every call moves by y + g along a field every call moves by u + δ lies within
  y - δ·max(g)·u ≤ max(y₀ - δ·max(g)·u₀): the steps made so far."

## Step: words round 6b (2bc44da, c102767) — 06:30 UTC
- 2bc44da §5.6 a substituted solution renames only the bound unknowns its values hold or
  whose layouts follow them (renaming everything made every copy a new term, read again):
  words 3.06 s → 2.5 s at that base; strlist 3.7 → 1.9 s, respond 2 errors in 3.6 s
  (was over memory), sexp 2.9 → 2.1 s.
- c102767 a call whose equation has no type is in no set: put was "proven" in int, so
  `p.slots` / `p.new` were refused.
- words on master c102767: 4 errors, 3.5 s (user 2.0 s). With least_growing.patch
  (scratchpad wd/, μ of a growing power: nslots in u64) words types further and goes over
  12 GB. Bisected: `count` over an unknown list alone takes 7.7 s / 5 GB, and 1.5 s / 1.3 GB
  when hash{s -> w}! is replaced by size{s -> w}!: the cost is the hash closed form
  (65 KB printed, 20 folds) read again in recursive_call → effects_elsewhere →
  keyed_equation → call_equation for each call of count/put (the equation-reading code
  of the field-bounds agent). Not pushed until that is cheap.
- Still open: 283:8 |split| tally in i64, distinct + p.new in i64 (count's counter moved
  by 0..1 a step), the count-down run length.

## Check 06:00 UTC (master 6d1d99e) — artifact version 6 published
- Verified on clean master: corpus 589/5, code, calc, x64 and C all pass (the zip cases too), six outputs identical, bt2 = 18.
- REGRESSIONS found by bisect, agents on them:
  - c102767 breaks strlist in the kernel (`passes{…}!` not proven in i64) — words agent fixing.
  - f6e3790 slows strlist's compiled code (C at 8M 470 → 755 ms) — fresh agent fixing.
- Kernel status: 7 pass (sum tree interp bintrees records push strlist@6fc34a9); respond 2, words 4, sexp 4, blur 7, lru 8, particles 8, scene 13, graph 22, calc 29 error lines.
- respond: a9b102f keys an image by the hypotheses its calls reach (0 mismatches over 380k verified hits); respond 3.1 s / 1.9 GB.
- Running: words (fix c102767, then its bounds), respond (relates/counter_range cost, 195:6), strlist runtime + blur places, items of run fields (graph, particles, lru, scene).

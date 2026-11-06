# Night log

## Proposed law, waiting for the user
§5.6 reads a call's equation where every field its calls carve is an unknown of its
color. The values a field takes across a recursion are not stated. Proposed text,
after "A call reads its equation where what it carves …":

> A field the call leaves at its value, a constant a, and that every call of the
> equation carves by the same step s, is a state of the fold the equation is: its
> init a, its update s. In the equation it is an unknown in the image of its orbit
> — sⁱ(a) for i in 0..n, n = μ(i: sⁱ(a) in B), B the cover of the base case of a
> pattern on it, every i without one —, not of its color, when the orbit has a
> closed form; otherwise of its color. What a call proves holds for those values.

Implemented alone in one commit (call_equation, orbit_narrowings), easy to revert.
Not yet proposed: a field every call keeps read in the image of what the call
gives it (needed by blur's row y, lru's keys); see the round report.

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

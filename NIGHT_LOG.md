# Night log

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

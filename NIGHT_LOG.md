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

# Future work — the memory optimizer (a performance phase, sequel to Phase 3)

> A forward-looking design note, captured while the thinking is fresh. **Not a scoped phase yet.**
> This is the sequel to Phase 3 (which built `ir_opt` baseline + aggressive but deferred LICM,
> range-based bounds-check elimination, and pure-call CSE). It is **distinct from Phase 6's
> surface-completion work** (SIMD, the memory64 runtime, cross-module function linking) — this is a
> *speed* phase that attacks the memory-access **residual** left after Phase 4's `atomics` tier.

## The cost this attacks (post-`atomics`)
Phase 4 fixed the headline (`paged` O(page)/store → `atomics` O(1)). The residual per access is:
**fetch the memory handle from instance state** (pdict read in `cell`, record field in `threaded`)
→ **bounds-compare + branch** → the O(1) read/write → bit-syntax width/endian decode. The first two
are what a memory optimizer removes for redundant / provably-safe accesses. This is a **middle-end
(`ir_opt`) analysis+rewrite over the `MemLoad`/`MemStore` IR nodes** — it never touches the runtime
ABI, and because it runs upstream of tier + mode selection, **a sound pass speeds up every tier
(`paged`/`atomics`/`nif`) and both modes**.

## The framework
- **MemorySSA** (sparse memory def/use: each store = a memory version, each load points at its
  reaching store(s)) is the enabler for **store→load forwarding**, **redundant-load elimination**,
  and **dead-store elimination**. It replaces the current conservative placeholder in
  [`src/twocore/ir/effect.gleam`](../src/twocore/ir/effect.gleam) — which **deliberately never CSEs
  loads** ("strongest sound under-approximation") *because we had no memory-dependence analysis yet*.
- **Array-SSA-style linear-memory alias analysis** is the multiplier: WASM linear memory is one flat
  byte array, so coarse MemorySSA has every store kill every load. Element/offset disambiguation lets
  "store to `A`" not kill "load from `B`."
- **Range-based bounds-check elimination + LICM** are the concrete payoffs (both Phase-3-deferred):
  elide the per-access trap check when in-bounds is proven; hoist the loop-invariant handle fetch (in
  `atomics`, `grow` reallocates, so the handle is loop-invariant absent a `grow`).
- **Escape analysis is NOT the lever here** — our design (process-local, one-instance-one-process,
  threads a hard non-goal) already pre-satisfies its classic payoff for linear memory. Tag escape
  analysis for the **term/object value path** (a future JS/Gleam frontend: scalar-replace objects,
  avoid boxing closures) — that's object speed, not linear-memory speed.

## Load-bearing invariants to preserve (do NOT lose these)

1. **Trap-preservation is the soundness gate; the key lever is "a dominating successful access proves
   in-bounds."** A WASM load is *trap-or-read*, not a pure read. So forwarding/BCE are only sound if
   they preserve the observable trap behavior. The clean, Safe-legal case: after `store(a,v)`
   succeeds, `a` is in bounds, so `load(a)` is in bounds ⟹ forward `v` **and** drop its check.
   Reordering *across* a possibly-trapping access is **not** sound without a no-trap proof. Getting
   this right is what keeps the passes **trust-neutral so they run in Safe mode** — a memory speedup
   that does not weaken the sandbox is a core platform win; a version that changes when/whether a trap
   fires has broken the sandbox's observable semantics.
2. **Keep the IR analyzable.** Do NOT fold `addr` + `offset` early; keep `mem` and `offset` as
   distinct fields on `MemLoad`/`MemStore`; keep per-access IR nodes (do not lower memory ops to
   opaque runtime calls before the optimizer runs). General pointer aliasing is undecidable, but the
   access shapes compilers actually emit — `base + constant memarg offset`, loop induction variables
   with known ranges, GVN over the base — are tractable, *provided the IR still exposes them*.
3. **Exploit the tier asymmetry.** **DSE helps `paged`/`portable` most** (a redundant paged store is a
   whole O(page) rebuild — eliminating it is worth far more there); forwarding/BCE/LICM help all
   tiers. So the same pass disproportionately closes the gap on the slow runs-anywhere build.
4. **Honest ceiling.** The alias analysis works well on structured, compiler-emitted address patterns
   (Rust/Porffor output) and poorly on fully-dynamic address computation. State that when measuring —
   the win is real but pattern-dependent, and (as always) *measured*, not asserted.

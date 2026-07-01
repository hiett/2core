# Unit 09 — the tier differential (G4/G7)

> **1–2 owners · Wave B · depends on the freezes AND the landed tier work (02/03/04/05/06/07/08).**
> Read [`00-overview.md`](00-overview.md) (G1–G8) and [`01-interface-freeze.md`](01-interface-freeze.md)
> (the two frozen contracts you bind to), then Phase-3 [`11-capstone.md`](../phase-3/11-capstone.md)
> §A (the binding-parameterized differential seam you reuse **unchanged**). This unit owns a **test
> suite**, no production code. It proves the Phase-4 headline correctness bar (G7): for **every
> shipped `(state_strategy × mem_tier)` combination** the whole acceptance corpus produces
> **byte-identical results and identical traps** (compared by bit pattern, D7) **and each equals the
> spec-expected value**; it proves the G4 **constant-space-under-`threaded`** property; and it proves
> the **runs-anywhere** grep property (a `portable` build links no `atomics`/`ets`/`persistent_term`/
> `nif`/process-dictionary instance state). Spec-first, never a change-detector (D8).

Phase 4 is **conformance-neutral** (G7): no new IR node, no `TrapReason`, no `.ir` grammar change —
so the tiers change **which runtime module the seam calls** (a link-time module swap, §B.1 of the
keystone) and **whether generated functions thread a state record** (`state_strategy`, §A.3 of the
keystone), and **nothing else observable**. That is precisely a *differential* claim — hold the
program fixed, vary the `(strategy, tier)` axes, assert equivalence — so this unit owns the
whole-corpus wiring exactly as Phase-3's capstone owned the optimizer/mode differential. It reuses
`driver.pipeline_with(binding)` (Phase-3 §A) with **no edit**: the driver already composes
`decode → validate → lower → pipeline.ir_to_core(_, binding) → build → instantiate → invoke`, and
`ir_to_core` reads `binding.mem_module`/`table_module`/`state_strategy`, so varying the binding is the
whole mechanism.

---

## Deliverables & freeze milestones

**Consumes** (every Phase-4 freeze + the landed tier work): `«STATE-STRATEGY-FROZEN»`
(`instance.StateStrategy {Cell, Threaded}`, the threaded seam of 02, the tier-P `rt_state` bodies of
03), `«MEM-TIER-FROZEN»` (`instance.MemTier {Paged, Atomics, Nif}` / `instance.TableTier {TablePaged,
TableEts, TableAtomics}`, the uniform `rt_mem`/`rt_table` backend interface §B.2, the `o_*` rebuild
oracle §B.3, the Safe-forbids-nif rule §B.4); the landed `rt_mem_atomics` (04), `rt_mem_nif`
interface/reference (05), `rt_table` tiers (06), the `portable`/`ceiling` profiles +
`validate_binding` + the tier→module resolver (07), and the pipeline/CLI tier selection (08).

**Produces** (terminal for the differential axis — nothing downstream depends on it): the tier
differential suite under `test/twocore/tier/**`, the G4 constant-space-under-`threaded` proof, and the
runs-anywhere grep proof. This unit publishes **no** freeze milestone and emits no signature others
build on.

## Files owned

- `test/twocore/tier/combos.gleam` — the shipped `(state_strategy, mem_tier, table_tier)` combination
  matrix + the one `binding_for(...)` constructor that composes each coherent `Binding` through the
  unit-07 profile/linker surface (single source; never re-spells the tier→module table, D1).
- `test/twocore/tier/tier_differential_test.gleam` — the whole-acceptance-corpus tier differential
  (§B): every combination byte-identical to every other **and** to `.expected`.
- `test/twocore/tier/mem_oracle_differential_test.gleam` — the shared-trace cross-tier memory
  differential against the `o_*` rebuild oracle (§C): identical value, identical trap, identical
  `to_flat` byte image after every op.
- `test/twocore/tier/memgrow_fuel_parity_test.gleam` — the `memory.grow` fuel-charge trap parity
  (§B.1): a module grown past a tight `safe_metered` budget traps `FuelExhausted` at the byte-identical
  grow under `cell×paged`, `threaded×paged`, and the `atomics` rows — proving the threaded `t_grow`
  replicates Cell's per-actual-delta `rt_meter.charge` (keystone §B.2).
- `test/twocore/tier/constant_space_threaded_test.gleam` — the G4 proof (§D): `sum_to(100000)` and the
  `memloop` store-loop run in constant space under `threaded`, results byte-identical to `cell`.
- `test/twocore/tier/runs_anywhere_test.gleam` — the runs-anywhere grep proof (§E): a `portable`
  `.core` links none of `atomics`/`ets`/`persistent_term`/`nif`/`rt_state:seed`; non-vacuously, a
  `ceiling`/`atomics` `.core` *does* name the tier-O module.

> `test/twocore/tier/**` is a **fresh directory** — no ownership collision (mirrors Phase-3's
> `test/twocore/optimize/**` choice). The **focused per-tier** oracle differentials (atomics≡oracle,
> nif≡oracle, table-tier≡own) belong to units 04/05/06 under `test/twocore/runtime/**`, exactly as
> Phase-3's per-pass property tests belonged to units 02/03/04. This unit owns only the **cross-tier
> whole-corpus** proofs — the "tier-aware differential" acceptance row (overview §1). The full
> spec-suite run under each combination is the **capstone's** (11); this unit drives the
> value-oracle acceptance corpus.

---

## A. The differential seam — one binding, varied over the tier axes

Every proof holds the *program* fixed and varies the `Binding`. Reuse the Phase-3 seam verbatim:

```gleam
import twocore/conformance/driver          // pipeline_with(binding) — UNCHANGED
import twocore/runtime/instance.{type Binding, Cell, Threaded, Paged, Atomics, Nif}
import twocore/runtime/profiles

/// A shipped deployment point on the trust-tier lattice: a state strategy × memory tier × the
/// policy each tier is legal under (G3/G6 — `Nif` only under Unsafe). `label` names the point in
/// failure messages so a divergence pins the exact combination.
pub type Combo {
  Combo(label: String, strategy: StateStrategy, mem: MemTier, table: TableTier, policy: Mode)
}

/// The combinations Phase 4 SHIPS (overview §1 acceptance). The oracle reference is the
/// spec-sourced `.expected`, so all of these must equal it — hence each other.
pub const shipped: List(Combo) = [
  Combo("cell×paged",       Cell,     Paged,   TablePaged,   Safe),    // Phase-2/3 baseline
  Combo("threaded×paged",   Threaded, Paged,   TablePaged,   Safe),    // portable / runs-anywhere
  Combo("cell×atomics",     Cell,     Atomics, TableAtomics, Safe),    // tier-O O(1), node-safe
  Combo("threaded×atomics", Threaded, Atomics, TableAtomics, Safe),    // tier-O under threaded
  Combo("cell×nif",         Cell,     Nif,     TablePaged,   Unsafe),  // tier-N ceiling — WHERE IT SHIPS
]
```

**`binding_for` composes each `Combo` through the unit-07 surface, never re-spelling the tier→module
table (D1).** A tier is a **module swap the linker resolves** (keystone §B.1: `mem_tier` is the
*declared* tier the linker maps to `mem_module`), so constructing `Binding(..profiles.safe(),
mem_tier: Atomics)` alone is **incoherent** — it would leave `mem_module` pointing at the paged
module. The single seam that maps the declared tiers to a coherent binding is unit 07's
`profiles.resolve_tiers/1` (it sets `mem_module`/`table_module` from `mem_tier`/`table_tier` and runs
`validate_binding` fail-closed). `binding_for` is a thin wrapper:

```gleam
/// Build the coherent, policy-legal `Binding` for a `Combo` (D1: through the unit-07 resolver
/// ONLY — this suite never spells a `rt_mem_*` module name). Panics via `let assert` iff the
/// combination is policy-incoherent (e.g. Safe+Nif) — which `shipped` never lists, so the assert
/// is unreachable and documents the G6 invariant. `Nif` combos base on `profiles.ceiling()`
/// (Unsafe), every other on `profiles.safe()`; `resolve_tiers` then swaps the modules + sets the
/// strategy. The result feeds `driver.pipeline_with` unchanged.
pub fn binding_for(c: Combo) -> Binding
```

Each proof reduces every run to one **normalized `Outcome`** — the SAME type Phase-3's
`differential_test` uses (raw result bits per D7, or the raw `{wasm_trap,…}` reason) — so "did the
tier change anything?" is a single `==`. The comparison is **never** over `.core` text or the linked
module name (which the tier is *allowed* to change), only over spec-observable behaviour.

```gleam
/// The spec-observable outcome of compiling+running one program point under one `Combo`. Reused
/// verbatim from Phase-3 §A: `Value` carries the RAW bit pattern (D7 — NaN payloads / `-0.0` /
/// i32↔i64 wrap exact); `Trap`/`InstantiateTrap` carry the raw reason (stable across tiers — the
/// trap reason is not a tier property); `Rejected` = failed to build a runnable instance
/// (fail-closed, D4).
pub type Outcome { Value(bits: List(Int)) Trap(reason: String) InstantiateTrap(reason: String) Rejected }
```

---

## B. Proof 1 — the whole-corpus tier differential (G7 headline)

**The bar (G7).** For every program in the acceptance corpus (`corpus_programs` — the spec-`.expected`
bearing `corpus/*.wat`: `add`, `intops`, `sum_to`, `fib`, `fac`, `floatops`, `hostimport`, `mem`,
`callind`, `gvar`, `memgrow`, `trunc`, `trapstart`, `oobdata`), for every export point, **every
shipped `Combo` produces the same `Outcome`, and that shared `Outcome` equals `.expected`.** Two
load-bearing assertions, exactly as Phase-3 proof 1 (no change-detector, D8):

1. **spec-correctness** — each combination's `Outcome` matches the spec-sourced `.expected` (via
   `oracle.matches_all` for values, `runner.trap_matches` for traps). Sourced from the vendored
   `.wast`/wasmtime through `corpus.parse` — not "consistently wrong".
2. **cross-combination identity** — the raw `Outcome`s are byte-identical across every `Combo`.
   Identity alone could pass on a mutually-broken pair; `.expected` alone is the existing acceptance
   test; together they are G7.

```gleam
/// PROOF 1 (G7). Drive the whole acceptance corpus under EVERY shipped `Combo`; assert each point
/// (a) matches the spec `.expected` and (b) is byte-identical across all combinations. A single
/// tier bug — an off-by-one `atomics` bound, a `threaded` store that drops the rebound record, a
/// nif endianness slip — changes an `Outcome` and turns this red on the exact program+combo.
pub fn tier_differential_test() {
  let drivers = list.map(combos.shipped, fn(c) { #(c, driver.pipeline_with(combos.binding_for(c))) })
  let failures =
    list.flat_map(corpus_programs, fn(name) {
      // Evaluate under every combination; reuse Phase-3's `evaluate/2` (spec-correctness half).
      let runs = list.map(drivers, fn(cd) { let #(c, d) = cd  #(c.label, evaluate(d, name)) })
      list.flatten([
        list.flat_map(runs, fn(r) { { r.1 }.1 }),          // (a) each combo == .expected
        identity_across(name, list.map(runs, fn(r) { #(r.0, { r.1 }.0) })),  // (b) all combos equal
      ])
    })
  assert failures == []
}
```

- **Memory / table / globals are the tier-sensitive programs.** `mem`/`memgrow`/`oobdata` exercise
  `rt_mem` load/store/grow/init-data (so `paged`≡`atomics`≡`nif`); `callind` exercises the
  `rt_table` tiers (so `TablePaged`≡`TableEts`≡`TableAtomics`, incl. the 3-fault fail-closed dispatch,
  keystone §A.2); `gvar` exercises mutable globals (so `cell`'s pdict globals ≡ `threaded`'s
  record-threaded globals). The pure-numeric programs (`add`/`intops`/`fib`/`fac`/`floatops`/`trunc`)
  are tier-*insensitive* by construction (G5 — the IR carries no handle operand) and pin that the
  threaded seam adds **no** change to pure functions (keystone §A.3: a pure function keeps its Phase-1
  signature). Spec anchors: memory bounds/traps
  <https://webassembly.github.io/spec/core/exec/instructions.html>, numerics
  <https://webassembly.github.io/spec/core/exec/numerics.html> — cited per program inside each
  `.expected`.
- **`Nif` is compared where it ships (G8).** If unit 05's `rt_mem_nif` reference loads (a native
  toolchain is present), the `cell×nif` combo runs and must be byte-identical like the rest; if the C
  impl is documented-deferred, `binding_for` reports it and the `cell×nif` row is **skipped, not
  failed** — the interface is still held to the spec by the §C oracle trace against a nif *stub* where
  one exists. The skip is recorded honestly (D9), never silently dropped.
- **`atomics` under both strategies is the real payload.** `cell×atomics` vs `threaded×atomics`
  crosses the O(1) mutable backend (the returned handle is the *same* mutated ref, keystone §A.2's
  uniform-threading rule) with both calling conventions — the combination most likely to surface a
  threading bug, and the one that must stay byte-identical to the immutable `paged` oracle.

---

## B.1 Proof 1b — `memory.grow` fuel-charge trap parity (G7)

`memory.grow` is the **one runtime-side *dynamic* fuel charge** in the whole system. Every other cost
is a static IR `Charge` node the emitter plants at a known count, but grow fuel is **per-actual-delta**
(`delta × page_bytes` newly-committed bytes) and the delta is only known at run time — so the charge
lives in the runtime, not the emitter: the Cell `rt_mem.grow` charges `rt_meter.charge(delta *
page_bytes)` on the **success** path (`result != -1`, keystone §B.2). `emit_core` just calls
`grow`/`t_grow` and plants **no** grow-fuel node. Therefore the threaded `t_grow` (in `rt_mem.gleam`,
owned by unit 04) **must replicate that same charge** — otherwise `metered × threaded` out-runs
`metered × cell`, which (a) violates the G7 byte-identical-traps bar and (b) opens a resource-bound
hole: an untrusted `portable` module could allocate all the way to its page cap with **zero CPU
accounting**. This proof pins that `t_grow`'s charge equals Cell's.

```gleam
/// PROOF 1b (G7, keystone §B.2). `memory.grow` is the ONLY runtime-side DYNAMIC fuel charge:
/// `rt_mem.grow` / `t_grow` charge `rt_meter.charge(delta * page_bytes)` on success (result != -1),
/// because grow fuel is per-ACTUAL-delta and cannot be a static IR `Charge` node. A `growspin_metered`
/// module (grow one page per iteration, BOUNDED max so `atomics` engages) run under a tight
/// `safe_metered` budget must trap `FuelExhausted` at the SAME grow under every strategy. If the
/// threaded `t_grow` dropped the charge, `threaded×paged` would out-run `cell×paged` and this goes
/// red — proving the per-delta charge is byte-identical to Cell (and closing the zero-CPU-allocation
/// hole). `FuelExhausted` is a 2core Safe resource bound, not a WASM spec trap, so this is a pure
/// cross-strategy differential with no `.expected` — exactly what pins `t_grow == grow`.
pub fn memgrow_fuel_parity_test() {
  // The metered, non-nif shipped combos — each carries the SAME tight Safe fuel counter
  // (Safe ⇒ MeterFuel, kept — never MeterOff): cell/threaded × paged/atomics.
  let rows = list.filter(combos.shipped, fn(c) { c.mem != Nif })
  let outcomes =
    list.map(rows, fn(c) {
      let #(outcome, _spec) = evaluate(driver.pipeline_with(combos.binding_for(c)), "growspin_metered")
      #(c.label, outcome)
    })
  // (a) every strategy exhausts fuel ON THE GROW (not a silent over-allocation to the page cap) …
  assert list.all(outcomes, fn(pair) { pair.1 == Trap("FuelExhausted") })
  // (b) … and that trap is byte-identical across strategies (same reason, same grow).
  assert identity_across("growspin_metered", outcomes) == []
}
```

- **Why §B does not cover this.** §B runs the acceptance corpus under a *generous* Safe budget where
  nothing trips `FuelExhausted`; it proves the values/traps agree but never exercises the grow charge
  as an *observable*. This proof deliberately sets a **tight** `safe_metered` budget so the grow charge
  becomes the deciding trap — the only place `t_grow`'s per-delta accounting is proven equal to Cell's.
- **The `atomics` rows are included and non-vacuous.** `growspin_metered` carries a **bounded max** so
  `atomics` actually engages (keystone §B.2: `atomics` pre-allocates to the effective max; it is legal
  only for a bounded/capped memory). Both `cell×atomics` and `threaded×atomics` must trap at the
  identical grow, so the charge is proven independent of the memory backend as well as of the calling
  convention.
- **This is a G6 resource-bound claim, tested.** Fuel is the Safe CPU bound (F5, fail-closed); a
  `t_grow` that forgot to charge would let a portable module commit pages for free — a real
  denial-of-service hole, not a cosmetic divergence. The differential turns that into a red test.

---

## C. Proof 2 — the shared-trace oracle differential (G2/G6, §B.3 of the keystone)

The corpus differential (§B) proves the tiers agree *with each other*; this proves each memory tier
agrees *with the spec*, holding all tiers to the trivially-correct `o_*` rebuild oracle
(`rt_mem.{o_fresh, o_load, o_store, o_grow, o_init_data, o_size, o_flat}` over `OMem` — one contiguous
binary, store rebuilds the whole thing, keystone §B.3). One shared operation trace runs through the
`o_*` oracle **and** through each shipped memory tier's backend, asserting after **every** op:
identical returned value, identical trap (`Ok`/`Error(reason)`), and identical byte image
(`<tier>.to_flat(mem) == rt_mem.o_flat(oracle)`, keystone §B.2's differential hook).

```gleam
/// PROOF 2 (§B.3). A fixed sequence of in-bounds / out-of-bounds / grow / init-data ops driven
/// through the `o_*` oracle and every shipped memory tier (paged pure core, atomics, nif-where-it-
/// -ships), comparing value + trap + `to_flat` byte image after each step. Bit-pattern equality
/// (D7): a wrong/missing trap, a sub-word sign/zero-extension slip, a lost store, or a wrong-endian
/// write on ANY tier diverges the byte image and turns this red on the exact op.
pub fn mem_tier_oracle_differential_test() { … }
```

- **The trace hits the spec corners the oracle is itself pinned to (E4/keystone §B.3):** sub-word
  load sign/zero-extension (`i32.load8_s`/`load8_u`), the no-wrap effective address at
  `0xFFFF_FFFF + offset` (must trap `MemoryOutOfBounds`, never wrap — the paged/atomics/nif backends
  and the oracle all bounds-check `ea >= 0 && ea + bytes <= limit`), **trap-before-write** (a store
  that traps must leave the byte image unchanged on every tier), and `grow` caps (past
  `effective_max` returns `-1` and allocates nothing — the `atomics` pre-allocation watermark and the
  paged/oracle rebuild agree on `memory.size`/`memory.grow`, keystone §B.2). Spec:
  <https://webassembly.github.io/spec/core/exec/instructions.html#memory-instructions>.
- **This is the G6 security invariant, tested.** A bounds bug's worst case in tiers P/O is a
  wrong/missing trap or a node-safe crash — **never** a host escape (tiers P/O are memory-safe by
  construction); tier-N is the one native seam, gated to Unsafe (§B.4). The oracle is the reference
  that would catch a tier that silently read/wrote out of bounds.
- **Both the cell-backed and the threaded families are driven** (keystone §B.2): the trace runs the
  `store`/`load`/`grow` heads (for `cell`) and the `t_store`/`t_load`/`t_grow` heads (for `threaded`,
  threading the `InstanceState` record) against the same oracle, so the uniform-threading adapter
  (03) is held to the spec too — `t_store` returning the rebound record must produce the identical
  byte image the mutating `store` produces.

---

## D. Proof 3 — constant space under `threaded` (G4)

Threading a state record adds a **loop-carried leading parameter** and returns a **new record per
store** — the exact concern E1 flagged and G4 requires *proven*, not asserted. The `threaded`
instance-state record is a **fixed-size box** (a 3-tuple `InstanceState(mem, globals, table)` pointing
at immutable structures, keystone §A.2), so threading it through a loop does not grow the stack, and
each store **rebinds the box** (a new 3-tuple sharing two of three fields), never the loop frame. The
back-edge stays the tail `apply 'L'(St', vs…)` the Phase-1 template already emits (keystone §A.3). Two
programs, run under a `threaded` binding, measured with `ffi.gc_and_memory` — the same instrument the
Phase-2 `store_loop_constant_space_test` and Phase-3 `spin_traps_in_constant_space_test` use:

```gleam
/// PROOF 3a (G4). `sum_to(100000)` under `threaded×paged` (portable) is a PURE loop (no stateful
/// op → keystone §A.3 keeps its Phase-1 signature, no `St` threaded), so it must stay constant-
/// space AND byte-identical to `cell`: a pure function pays nothing for the threaded strategy.
pub fn sum_to_constant_space_threaded_test() {
  let mod = compile_load("sum_to", combos.binding_for(portable))
  // sum_to(100000) == 5000050000 (Σ 1..100000); 100× n stays under a small constant factor of live memory.
  …  assert mem_big < mem_small * 4
}

/// PROOF 3b (G4), the real property. The `memloop` store-loop (`i32.store` EVERY iteration for
/// 100k iterations) under `threaded×paged` threads `St` as a leading `LoopParam` and rebinds the
/// box each store; it must complete, return the byte-identical result to `cell` (`store_loop(100000)
/// == 99999`), and use live process memory bounded by a small constant (100× the iterations must
/// NOT mean ~100× the live memory — a per-iteration record leak WOULD blow this up).
pub fn store_loop_constant_space_threaded_test() {
  let mod = compile_load("memloop", combos.binding_for(portable))
  let assert Ok(small) = ffi.start_instance(mod)
  assert ffi.call_instance(small, atom.create("store_loop"), [1000]) == Ok(999)
  let mem_small = ffi.gc_and_memory(small)
  let assert Ok(big) = ffi.start_instance(mod)
  assert ffi.call_instance(big, atom.create("store_loop"), [100_000]) == Ok(99_999)
  let mem_big = ffi.gc_and_memory(big)
  assert mem_big < mem_small * 4          // constant space under the state-threaded loop
}
```

- **Byte-identical cross-check.** Both programs' results under `threaded` must equal the `cell` run
  (already covered transitively by §B, restated here as the local invariant): `store_loop(100000) ==
  99999` under `threaded×paged` and `cell×paged` alike. The constant-space bound is the *space*
  property; §B is the *value* property; together they are G4.
- **`threaded×atomics` also stays constant-space.** Under `atomics` the record's `mem` slot is the
  *same* mutable ref rebound to itself each store, so the box is truly fixed-size — an even tighter
  constant. The suite runs 3b under both `threaded×paged` and `threaded×atomics`.
- **Preemption is inherent (G4).** The threaded loop is ordinary BEAM code — a tail-`apply` back-edge
  under the runtime's reduction counter — so it is preemptible with no special handling; the test's
  *completion* of a 100k-iteration loop without unbounded growth is the evidence. No busy-wait, no
  disabled scheduling.

---

## E. Proof 4 — the runs-anywhere grep proof (G6, the "no OTP, no NIF" pitch)

The `portable` build is the platform's headline: **tier-P instance state + numerics** (`threaded`
state + `paged` memory + `bif` numerics, Safe policy) carrying only the node-safe, process-local
**tier-O policy overlays** Safe mandates (the `rt_meter` CPU-fuel counter + the `rt_host` policy cell;
Safe permits tier P or O, never N), running on a bare BEAM with **none of the native/unsafe primitives**
(`atomics`/`ets`/`persistent_term`/`nif`) **and no pdict instance-state cell**, provably unable to
crash the node. Proven **structurally** on the emitted `.core` — the one artifact
that names every runtime module the generated code links (D3a: the seam emits only fixed
`twocore@runtime@*` atoms), so a grep of it is an exhaustive audit of what a portable instance can
reach:

```gleam
/// PROOF 4 (G6). A `portable` (Threaded + Paged + Safe) `.core` links ZERO OTP-native / native
/// state: it names no module containing `atomics`/`ets`/`persistent_term`/`nif`, and — because
/// `Threaded` eliminates the pdict cell — no `rt_state:seed`/`get`/`put` (zero process-dictionary
/// INSTANCE state). NON-VACUOUS: a `ceiling`/`atomics` `.core` DOES name the tier-O module, proving
/// the grep can see what it forbids.
pub fn portable_links_no_native_state_test() {
  let assert Ok(m) = pipeline.source_to_ir(read_bytes("mem"))
  let assert Ok(portable_core) = pipeline.ir_to_core(m, combos.binding_for(portable))
  // (a) no OTP-native / native backend module is linked
  assert count_occurrences(portable_core, "atomics") == 0
  assert count_occurrences(portable_core, "ets") == 0
  assert count_occurrences(portable_core, "persistent_term") == 0
  assert count_occurrences(portable_core, "nif") == 0
  // (b) no process-dictionary INSTANCE state — Threaded replaces the rt_state cell with the record.
  // Absent set = the rt_state instance-cell seam ('seed'/'get'/'put'); we do NOT assert 0 pdict —
  // the Safe tier-O overlays (rt_meter fuel counter + rt_host policy cell) are node-safe pdict and
  // legitimately remain (Safe permits tier P or O, never N).
  assert count_occurrences(portable_core, "'seed'") == 0        // rt_state cell seed op, gone under Threaded
  assert count_occurrences(portable_core, "'t_store'") > 0      // threaded family IS present (non-vacuous)
  // (c) non-vacuity: the atomics build DOES name the tier-O module, so (a) is a real audit
  let assert Ok(atomics_core) = pipeline.ir_to_core(m, combos.binding_for(cell_atomics))
  assert count_occurrences(atomics_core, "rt_mem_atomics") > 0
}
```

- **What "runs-anywhere" honestly means here, and the decided scope.** The grep audits the generated
  `.core`; a portable build links only `rt_mem` (paged, immutable binaries), `rt_table` (paged sparse
  `Dict`), `rt_state` (the threaded record, **no** pdict instance cell), and `rt_num` (`bif`) — every
  one pure-BEAM, no NIF, no `ets`/`atomics`/`persistent_term` — **plus** the two node-safe **tier-O
  policy overlays** Safe mandates: the `rt_meter` CPU-fuel counter and the `rt_host` policy cell. **This
  is decided, not residual.** A Safe `portable` build **mandatorily keeps `MeterFuel`** (Safe ⇒
  `MeterFuel`, the F5 fail-closed CPU bound), so its `.core` DOES call `rt_meter:seed_fuel`/`charge` and
  seed the `rt_host` cell — each a single **process-local** pdict value: node-safe, cannot escape,
  cannot crash the node, available on every BEAM (so still "runs-anywhere"). `MeterOff`-under-Safe is
  **rejected** (it would break the CPU bound and let an untrusted module burn unbounded CPU) and
  threading the fuel counter through the state record is **also rejected** (it perturbs the E1
  constant-space back-edge for no security gain). The project taxonomy classifies pdict as **tier-O**
  (node-safe), and Safe permits **tier P or O, never N** — so the grep's zero-set is the native/unsafe
  primitives (`atomics`/`ets`/`persistent_term`/`nif`) **everywhere** plus the pdict **instance-state
  cell** (`rt_state` `'seed'`/`'get'`/`'put'`, which `Threaded` genuinely eliminates); it deliberately
  does **not** assert zero pdict, because the tier-O metering + host overlays legitimately use it.
- **D3a survives the audit.** The grep also confirms the portable `.core` performs no data-driven
  `apply(Mod, F, Args)` — every call target is a fixed `twocore@runtime@*` atom with a literal
  function name (the keystone §"effect note" invariant); the only runtime-data input reaching a
  control transfer remains the integer `call_indirect` index into the build-controlled table.
- **The grep is over emitted text, so it is exhaustive for what generated code reaches.** It cannot
  see *inside* a runtime module's compiled body (that is the module's own concern, tested at its
  unit), but it is a complete list of the module *boundary* a portable instance crosses — which is
  exactly the "no OTP, no NIF" claim's surface.

---

## Effect / soundness / security note

- **No ambient authority survives either new axis (D3a).** §E's grep is the structural enforcement:
  a portable/threaded `.core` names only fixed `twocore@runtime@*` atoms; the tier is a
  build-controlled module swap (never a program-derived module); the threaded table closure is a
  build-controlled capture (keystone §A.2). This unit adds no new codegen — it *audits* unit 02's.
- **Fail-closed defaults (D4/G6).** `binding_for` reaches an `Unsafe` base only for `Nif`; a
  `Safe + Nif` combination is unconstructible (keystone §B.4) and `shipped` never lists it — the
  `let assert` in `binding_for` documents the invariant as unreachable. No combination in this suite
  weakens the posture by omission.
- **The tiers cannot be unsound and pass (G2/G7).** An unsound tier (a lost store, a wrong trap, a
  bad bound) changes an `Outcome` (§B) or diverges the `to_flat` byte image (§C); "green" means
  *every observable was preserved across every tier*, not "it compiled." WASM has no undefined
  behaviour — every ill-defined op traps (spec §7 *Embedding*; every memory fault is
  `MemoryOutOfBounds`) — so a tier has no latitude to differ.
- **Floats-as-bits (D5/D7) throughout.** Every `Outcome` and every `.expected` carries the raw
  bit pattern; NaN payloads, `-0.0`, and i32↔i64 wrap are compared exactly, never via a BEAM-double
  round-trip. Memory is raw bytes over the IEEE bit pattern in every tier.
- **Threads / shared memory stay a hard non-goal (G8).** Every combination is single-threaded /
  process-local; `atomics`/`ets` are used process-locally, never shared. This suite never spawns a
  second process against one instance's memory — the isolation is one-instance-one-process (E5).

---

## Verification — Definition of Done (D8)

- **Proof 1 green:** every acceptance-corpus point yields one `Outcome` shared across all shipped
  `(strategy × mem_tier × table_tier)` combinations, and that outcome equals the spec-sourced
  `.expected` (cites the WASM spec per behaviour via the reused `corpus.parse` values). `cell×nif` is
  compared where the reference loads and honestly skipped (recorded) where the C impl is deferred.
- **Proof 1b green:** a `growspin_metered` module grown past a tight `safe_metered` budget traps
  `FuelExhausted` at the byte-identical grow under `cell×paged`, `threaded×paged`, and both `atomics`
  rows — proving the threaded `t_grow` replicates Cell's per-actual-delta `rt_meter.charge` (the one
  runtime-side dynamic charge, keystone §B.2).
- **Proof 2 green:** the shared memory trace agrees with the `o_*` oracle on value, trap, and
  `to_flat` byte image after every op, across every memory tier and both call families — including
  the sub-word extension / no-wrap-`0xFFFFFFFF` / trap-before-write / grow-cap corners.
- **Proof 3 green:** `sum_to(100000)` (`==5000050000`) and `store_loop(100000)` (`==99999`) run under
  `threaded` (paged and atomics) with live process memory bounded by a small constant across a 100×
  input spread, byte-identical to the `cell` run.
- **Proof 4 green:** a `portable` `.core` has zero `atomics`/`ets`/`persistent_term`/`nif` and zero
  `rt_state` instance-cell seam (`'seed'`) occurrences — but is **not** asserted zero-pdict (the tier-O
  `rt_meter`/`rt_host` overlays legitimately remain) — with a present threaded family; a
  `ceiling`/`atomics` `.core` non-vacuously names `rt_mem_atomics`.
- **`gleam format --check src test` clean; `gleam build` ZERO warnings; `gleam test` stays green
  (≥ the current 674, now higher).** Done = **the tier suite passes** under real backends, never
  "it compiles."

---

## What this unit leaves

The trust-tier axis is proven **correctness-neutral (G7):** every shipped `(state_strategy × mem_tier)`
combination gives byte-identical, spec-correct results and identical traps; the `threaded` build holds
constant space (G4) and links no native/unsafe primitive or NIF (G6, the runs-anywhere pitch),
carrying only the node-safe, process-local tier-O policy overlays (the `rt_meter` fuel counter +
`rt_host` policy cell) that Safe mandatorily keeps. This unit consumes every
Phase-4 freeze and emits nothing downstream. **Its sibling deliverables:** unit 10 re-measures the
honest benchmark with `atomics` (+ threaded) vs `paged` / hand-written Erlang / the native ceiling;
unit 11 (capstone) runs the **full spec suite** under each shipped combination at `fail=0` and
refreshes the conformance image. **Deferred (stated, not dropped):** the `nif` C impl where a native
toolchain is required (G8); and every Phase-5+ surface (SIMD / reference types / bulk memory /
multi-memory / `memory64` / the WAT parser / non-function imports; the Porffor bridge). A
strict-zero-pdict `portable` is **decided against**, not deferred: `MeterOff`-under-Safe is rejected
(it would break the F5 CPU bound), so Safe `portable` keeps `MeterFuel`.

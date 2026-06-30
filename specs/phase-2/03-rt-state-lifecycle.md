# Unit 03 — rt_state: the per-instance cell, globals & lifecycle

> **One owner · Wave A (parallel with 04/05/06/10) · gated on `«CELL-STATE-ABI-FROZEN»`.**
> This unit builds the **state substrate** that rt_mem (04) and rt_table (05) sit on top of.
> Publish the opaque-cell interface (the `mem`/`table` field accessors + `StateDecl`) on
> **day 1** so 04 and 05 proceed in parallel — they cannot start until they know how to
> read/write their field of the cell. Read [`00-overview.md`](00-overview.md) (E1, E3, E6,
> E8) and [`01-interface-freeze.md`](01-interface-freeze.md) §B first.

---

## Context

Phase 1 generated **pure** code: no memory, no tables, no mutable globals — functions
threaded no state (D3d). Phase 2's keystone (**E1**) is **mutable instance state**, and the
chosen strategy is the tier-O **`cell`**: an instance's `{mem, globals, table}` live in the
**process dictionary** of the instance's own process, under **one fixed namespaced key**,
holding a single opaque record. Generated function arities are **unchanged**; the stateful
runtime layers read/write the cell behind the binding chokepoint (D3b), so no handle is
threaded through generated code and the proven letrec/tail-loop machinery is byte-for-byte
untouched.

`rt_state` is that cell holder. It owns the pdict mechanism, the **mutable globals** (which
*are* instance state — there is no separate `rt_global` module and no extra `Binding` field),
and the **per-instance lifecycle** (seed/reset). It is deliberately **opaque** about the
memory and table value shapes: rt_mem (04) owns the page-map shape and rt_table (05) owns the
table shape, and rt_state stores each as an opaque term it never inspects. That opacity is
what lets 03/04/05 ship in parallel without entangling.

The empirical basis for `cell` (verified in-repo): `rt_meter` already does a process-dictionary
read-add-write on **every** `charge`, and `sum_to(100000)` — a 100k-iteration tail loop doing
that pdict mutation each iteration — was proven **constant-space** on OTP 29 (see `state.md`).
pdict `get` is **by-reference (no copy)**; put/get cost reductions like ordinary BIFs, so the
scheduler still preempts. A cell global/store is the identical pattern. **ETS is the wrong
tier-O cell** here: it deep-copies the whole term on *every* read and write and has no
auto-GC. Use pdict.

## Goal

Ship the tier-O per-instance state cell + mutable globals + the one-instance-one-process
lifecycle, **fail-closed**: an op on an un-seeded cell traps rather than reading garbage; a
(re)instantiation installs a **fresh** cell (memory = min pages of zeros, empty table, globals
from their constant inits) and two seed cycles in one process never observe each other's state.

## Files owned

- `src/twocore/runtime/rt_state.gleam` — **NEW** (unit 01 publishes the frozen stub
  signatures `seed`/`get`/`put`/`global_get`/`global_set`; this unit fills the bodies and adds
  the lifecycle + opaque-field-accessor surface below).
- `test/twocore/runtime/rt_state_test.gleam` — **NEW** (this unit's spec-grounded suite).
- *(Optional, project precedent)* `src/twocore_rt_state_ffi.erl` — a minimal hand-written
  `twocore_*`-namespaced shim **only if** needed for the sound pdict get-with-presence-check
  (mirrors `twocore_codegen_ffi`/`twocore_cli_ffi`). Keep it tier-O, node-safe, single-owner.

## Depends on

- **`«CELL-STATE-ABI-FROZEN»`** (P2-01) — the `rt_state` stub signatures, and the `Binding`
  `state_module = "twocore@runtime@rt_state"` field already wired into `instance.safe_default`
  / `profiles.safe`. Until it lands, stub against unit 01's strawman in
  [`01-interface-freeze.md`](01-interface-freeze.md) §B.
- `ir.TrapReason` (already exists; `MemoryOutOfBounds` etc. are sufficient — this unit needs
  **no** new TrapReason variant; the three new ones are for 04/05/06).
- `gleam/dict`, `gleam/dynamic` (+ `gleam/dynamic/decode`), and the `erlang:put/2`/`get/1`
  externals (copy the exact pattern from `rt_meter.gleam`). **No new Hex dependency.**

> **Publish day-1 (mini-freeze for 04/05):** the `StateDecl` type and the four opaque field
> accessors `mem`/`with_mem`/`table`/`with_table`. rt_mem and rt_table call these to read and
> rewrite their field of the cell; freeze the names/shapes before implementing globals so they
> are unblocked immediately.

## Scope — in / out for Phase 2

**In:** the pdict cell substrate (one fixed namespaced key, opaque `InstanceState`); mutable
globals as raw-bit-pattern `Int` cells (i32/i64/f32/f64 alike); `seed`/reset/`clear` lifecycle;
fail-closed reads on an un-seeded cell; the opaque `mem`/`table` field accessors for 04/05; and
documenting the one-instance-one-process contract the cell relies on.

**Out (cite the deferral):**
- **Imported globals** — deferred with non-function imports (**E7/E8**). Phase 2 has no
  imports, so a const-init expr reduces to a single `t.const` ⇒ rt_state receives an
  already-evaluated **raw-bits `Int`** per global (const-expr *evaluation* is unit 09's job).
- **The threaded tier-P state holder** — deferred to Phase 3 (**E1/E8**). Design the op shapes
  per the uniform-threading rule (each conceptually takes+returns a handle) so the future
  threaded build is an emit_core seam expansion, but **ship only `cell`**.
- The **memory page-map shape** (unit 04) and **table shape** (unit 05) — opaque here.
- The generated **`instantiate/N` entry** (unit 10) and the **one-instance-one-process
  harness** that spawns/owns the process and runs seed+invokes in it (unit 11). rt_state
  *uses* the current process pdict; it does not spawn processes.
- **Immutability enforcement** for `const` globals — done at **validation** (unit 08), not
  here. `rt_state.global_set` is a mechanical write; validation guarantees it is only emitted
  for mutable globals.
- CPU-fuel enforcement stays observe-only (**E8**).

## Deliverables

A single Gleam module. The opaque record and `StateDecl` are the new types; the rest are the
frozen stub signatures (bodies filled) plus the day-1 accessor mini-freeze.

```gleam
//// src/twocore/runtime/rt_state.gleam — the per-instance cell holder (tier-O, Safe).
//// One-instance-one-process: the instance's memory/globals/table live in THIS process's
//// dictionary under ONE fixed key. Fail-closed: ops on an un-seeded cell trap, never read
//// garbage. Opaque about mem/table shapes (rt_mem/rt_table own those).

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import twocore/ir.{type TrapReason}

/// The whole per-instance state, held as ONE opaque record under one pdict key.
/// `mem`/`table` are opaque terms (rt_mem / rt_table own their concrete shapes — rt_state
/// never inspects them). `globals` maps each global's name to its current RAW BIT PATTERN.
pub opaque type InstanceState {
  InstanceState(mem: Dynamic, globals: Dict(String, Int), table: Dynamic)
}

/// What `seed` installs at (re)instantiation. The instantiate entry (unit 10) assembles it:
/// `mem` = a fresh min-pages-of-zeros memory built by rt_mem; `table` = a fresh empty table
/// built by rt_table (both opaque here); `globals` = each declared global's name paired with
/// its already-evaluated constant init value as raw bits, in declaration order.
pub type StateDecl {
  StateDecl(mem: Dynamic, table: Dynamic, globals: List(#(String, Int)))
}

// ── lifecycle ────────────────────────────────────────────────────────────────
/// Install a FRESH cell from `decl`, overwriting any prior cell under the fixed key.
/// This IS the reset-on-(re)instantiation: replacing the single key's value atomically
/// discards all prior mem/table/globals. Returns `Nil`; total.
pub fn seed(decl: StateDecl) -> Nil

/// Remove the cell (→ un-seeded). For test isolation / teardown; not in the generated
/// calling convention. Returns `Nil`; total. (After `clear`, `get` fails closed.)
pub fn clear() -> Nil

// ── cell access (fail-closed) ─────────────────────────────────────────────────
/// The current process's cell. `Ok(state)` when seeded; `Error(reason)` when un-seeded —
/// the FAIL-CLOSED guard (never fabricates a zeroed `InstanceState`). Callers that return
/// `Result(_, TrapReason)` propagate the `Error`; emit_core's `case` raises it via rt_trap.
pub fn get() -> Result(InstanceState, TrapReason)

/// Replace the current process's cell with `state` (under the fixed key). Returns `Nil`;
/// total. The superseded `InstanceState` becomes garbage and is GC'd with the process.
pub fn put(state: InstanceState) -> Nil

// ── opaque field accessors (rt_mem / rt_table — MINI-FREEZE, publish day 1) ────
pub fn mem(state: InstanceState) -> Dynamic
pub fn with_mem(state: InstanceState, mem: Dynamic) -> InstanceState
pub fn table(state: InstanceState) -> Dynamic
pub fn with_table(state: InstanceState, table: Dynamic) -> InstanceState

// ── mutable globals (raw bit patterns; E6: side-effecting) ─────────────────────
/// Read global `name`'s current raw bit pattern from the current cell. Fails closed
/// (raises, node-safe) on an un-seeded cell or an unknown `name` — both unreachable under
/// validation + the harness contract; they are defensive guards, never a normal path.
pub fn global_get(name: String) -> Int

/// Write `value` (a raw bit pattern) into global `name` of the current cell (read-cell →
/// dict.insert → put-cell). Returns `Nil`. Fails closed (raises) on an un-seeded cell.
pub fn global_set(name: String, value: Int) -> Nil
```

**Algorithm shape (do not re-derive):**

- **The key.** A 0-field Gleam constructor `TwocoreRtState` → the unique hygienic atom
  `twocore_rt_state` (exactly the `rt_meter` `TwocoreRtMeterFuel → twocore_rt_meter_fuel`
  pattern). **One** key for the **whole** record ⇒ collision-free with `rt_meter`'s fuel key
  and any other pdict use, and reset is atomic (one `erlang:put` replaces everything).
- **`get`.** `erlang:get(TwocoreRtState)` returns the term **by reference** (no copy). If it
  is the atom `undefined` (never set) → `Error(..)` (fail-closed). Otherwise it is an
  `InstanceState` (rt_state is the *sole* writer of this key, so a coercion of the present
  term back to `InstanceState` is sound — a 1-line identity FFI or a `dynamic` presence check
  is fine; do **not** deep-copy). Never construct a zeroed cell to "recover".
- **`seed`/`put`/`clear`.** `seed` = `put(InstanceState(decl.mem, dict.from_list(decl.globals),
  decl.table))`. `put` = `erlang:put(TwocoreRtState, state)`. `clear` = erase the key.
- **`global_get`/`global_set`.** `get()` then `dict.get`/`dict.insert` on the `globals` field
  (within rt_state the record is not opaque, so construct/match freely), `put` back on set.
- **mem/table accessors.** `mem`/`table` project the field; `with_mem`/`with_table` rebuild
  the record with that field replaced. rt_mem does `get → mem(st) → coerce → … → put(with_mem(
  st, mem'))`; rt_table does the same for its field. rt_state never decodes mem/table.

## Grounded facts you MUST honor

Transcribe these verbatim into the code's intent (research topics 2 + 3; cite in tests):

- **pdict is the right tier-O cell; ETS is wrong.** `get` is a pointer read (no copy); `put`
  replaces a root (old term → garbage, GC'd with the process). ETS *"every object insert and
  look-up operation results in a copy of the object"* (O(state) per access) and has *no auto-GC*
  — fatal for a hot store loop. Use pdict only.
  (`https://www.erlang.org/doc/apps/stdlib/ets.html`)
- **Constant space + preemption preserved.** put/get do not push return addresses, do not grow
  the continuation, do not change tail-call structure; the loop back-edge `apply L(vars)` stays
  in tail position. *"The main (outer) loop for a process must be tail-recursive"* — that is
  about the call graph, which the cell leaves untouched. Empirically proven by `rt_meter` +
  `sum_to(100000)` on OTP 29 (`state.md`).
  (`https://www.erlang.org/doc/system/eff_guide_processes.html`)
- **Trust tier.** pdict is **tier-O** (OTP-native, memory-safe, cannot crash the node, no NIF).
  **Safe permits P or O, never N.** `rt_meter` already ships a tier-O pdict cell in Safe and was
  signed off — rt_state is the identical, already-accepted posture.
- **One-instance-one-process is what makes pdict sound.** pdict is strictly per-process: each
  instance's mem/globals/table live in its own process, unreadable by any other process, and
  die with it (auto-GC, no explicit cleanup). The harness (unit 11) runs **seed + every invoke
  of an instance in one owned process**, so rt_state always reads *that* process's cell.
- **Globals semantics (topic 2).** A global is a mutable (`mut=var`, byte `0x01`) or immutable
  (`mut=const`, `0x00`) cell of type i32/i64/f32/f64. `global.get` reads any global; `global.set`
  is valid **only on a mutable** global — and that is enforced at **validation**, not here.
  Inits are constant expressions (in MVP `t.const`, terminated by `End 0x0B`); with no imports
  in Phase 2 a const expr reduces to a single literal.
  (`https://webassembly.github.io/spec/core/valid/instructions.html`,
  `.../binary/types.html`)
- **Floats are raw bits (D5).** f32/f64 globals store the **raw IEEE-754 bit pattern** as an
  `Int` end-to-end — never a BEAM double (a double cannot hold NaN payloads / signaling bits
  and raises `badarith`). rt_state stores i32/i64/f32/f64 globals identically as `Int`; it does
  **no** float math and needs **no** per-global type tag.
- **Instantiation order (topic 2).** globals are evaluated/allocated **first**, then active
  element segments, then active data segments, then `start`. So `seed` installs globals (and the
  fresh mem/table) **before** unit 04/05's `init_data`/`init_elem` run, and all of it before any
  export. (`https://webassembly.github.io/spec/core/exec/modules.html`)
- **Effect note (E6).** `GlobalGet`/`GlobalSet` are **side-effecting, non-reorderable,
  non-CSE-able, non-DCE-able**. A future optimizer must treat them as barriers. Document it.

**Pitfalls — every one is a real escape or corruption:**

1. **pdict hard-requires one-instance-one-process.** If a host or another process calls an
   instance export directly, rt_state reads the *caller's* empty pdict → silent corruption /
   wrong results. The contract is: cross-process entry goes via the instance process. Document
   it loudly; the harness (11) enforces it.
2. **Key hygiene.** Use the unique 0-field-constructor atom `twocore_rt_state`. A non-hygienic
   key silently corrupts `rt_meter`'s fuel or another instance's memory. **One** key for the
   whole record (not three) ⇒ atomic reset and no intra-cell collisions.
3. **Fail-closed, never garbage.** An un-seeded `get` must return `Error` (and `global_get`/
   `global_set` must raise) — **never** fabricate a zeroed `InstanceState`. Reading garbage
   from an empty pdict is the bug this guard exists to prevent.
4. **Don't deep-copy on `get`.** The by-reference read is the whole performance argument; do
   not round-trip the term through a copying decode. A present cell coerces in O(1).
5. **Stay opaque about mem/table.** rt_state must not `import` rt_mem/rt_table or pattern-match
   their values — that would break the parallel build and re-entangle 03/04/05. They are
   `Dynamic` in and `Dynamic` out.
6. **Globals are raw bits, not doubles.** Never convert an f32/f64 global to a BEAM double in
   transit; store and return the `Int` bit pattern unchanged.

## Verification — Definition of Done (D8: assert the spec, not the impl)

Spec-grounded tests in `rt_state_test.gleam` (cite the section/URL in each test doc comment).
These assert behavior an external standard mandates, never "what the code currently emits."

1. **Global round-trip.** `seed` a decl with `globals = [#("g", 7)]`; `global_set("g", 42)`;
   `global_get("g")` == `42`. Then a second global `h` is unaffected by writes to `g`, and
   `global_set` overwrites only the named global. *(WASM global.set/global.get exec semantics.)*
2. **Float globals are bit-exact.** Seed an f32/f64 global whose init is a **NaN-payload**,
   **`-0.0`**, and **±Inf** bit pattern (as `Int`); `global_get` returns the identical `Int`.
   Asserts D5 (no BEAM-double round-trip ever mangles the bits).
3. **Fail-closed on un-seeded.** Without `seed` (or after `clear`), `get()` returns `Error`
   (`result.is_error` True), and `global_get`/`global_set` **raise** (catch via the test FFI
   shim, like `twocore_emit_test_ffi:catch_apply`). Asserts E3 fail-closed — never reads garbage.
4. **Reset clears prior state.** `seed(A)`, write globals, `seed(B)` (or `clear` then `seed`):
   `get()` reflects only B; none of A's mem/table/globals survive (atomic reset by construction).
   *(WASM instantiation installs fresh state — exec/modules.)*
5. **Isolation across two seed cycles in one process.** In a single process: `seed` cycle A with
   `globals=[#("g",1)]`, observe; `seed` cycle B with `globals=[#("g",2)]`; `global_get("g")`
   == `2`, never `1` — two instantiations never observe each other's globals (E3 per-instance
   isolation).
6. **Cell key is fixed & namespaced (objective, no atom-peeking).** In one process, interleave
   `rt_meter.charge(n)` with `seed`/`global_set`/`get`: assert global ops never change
   `rt_meter.fuel_consumed()` and `charge` never changes any global — proving rt_state's key is
   distinct/hygienic and the cells don't collide (D3a / key-hygiene).
7. **Opaque field round-trip.** `with_mem(state, m)` then `mem(_)` returns `m` unchanged (same
   for table); `seed` installs the decl's `mem`/`table`; they are opaque (rt_state never inspects
   them). Use a sentinel `Dynamic` to stand in for 04/05's real shapes.

**Gate:** `gleam format --check src test` clean; `gleam build` **zero warnings** (no leftover
`todo`); `gleam test` stays **green (≥313)** — no Phase-1 regression; every public function and
type carries a `///` contract doc (what / params+ranges / return + `Result`/`Option` meaning /
failure & raise modes). Update `state.md`: announce the field-accessor mini-freeze and the new
`StateDecl`/`InstanceState`/`clear` additions to the frozen stub.

> The **constant-space-under-a-real-store/set-loop** proof (~100k iterations, asserting constant
> process memory) needs the full `load→instantiate→invoke` pipeline and is owned by the
> **capstone (unit 11)**; at this unit level the property rests on the rt_meter precedent + the
> by-reference `get`/`put` mechanism. Note this hand-off in `state.md`.

## Concurrency

Small module; if split across agents, freeze the interface first:

- **03a — cell substrate (must land first).** `InstanceState` (opaque), `StateDecl`, the pdict
  key, `seed`/`put`/`get`/`clear`, the fail-closed guard, and the **`mem`/`with_mem`/`table`/
  `with_table`** accessors. **These accessor + `StateDecl` signatures are the mini-freeze that
  unblocks units 04 and 05** — publish them in `state.md` on day 1; 04/05 cannot read/write
  their field of the cell without them.
- **03b — globals.** `global_get`/`global_set` over the `globals` dict + their tests. Depends
  only on 03a's `get`/`put`.

Both sub-tasks need `«CELL-STATE-ABI-FROZEN»` (the stub signatures + the `state_module`
Binding field) frozen first. Nothing inside this unit depends on 04/05/06/10.

## What this leaves for others

- **rt_mem (04):** build the fresh min-pages memory; implement `load`/`store`/`size`/`grow`/
  `init_data` operating on `rt_state.mem(get())` / `with_mem`; expose a fresh-memory constructor
  the instantiate entry feeds into `StateDecl.mem`.
- **rt_table (05):** build the fresh empty table; implement `init_elem`/`call_indirect` over
  `rt_state.table(get())` / `with_table`; expose a fresh-table constructor for `StateDecl.table`.
- **emit_core (10):** lower `GlobalGet → call 'twocore@runtime@rt_state':'global_get'(Name)`
  (bare value) and `GlobalSet → … 'global_set'(Name, Val)` (sequenced `let _ = … in …`, E6);
  emit the `instantiate/N` entry that assembles `StateDecl` (fresh mem from 04, fresh table from
  05, globals from unit 09's evaluated const inits) and calls `rt_state:seed` **first**, before
  `init_data`/`init_elem`/`start`.
- **capstone (11):** the one-instance-one-process harness (spawn/own a process per instance, run
  seed + all invokes there), cross-instance isolation end-to-end, and the constant-space
  store/set-in-a-loop test.

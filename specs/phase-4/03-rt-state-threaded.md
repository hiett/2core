# Unit 03 — rt_state (tier-P): the threaded instance-state record

> **One owner (`src/twocore/runtime/rt_state.gleam`, additive) · Wave A (parallel with
> 04/05/06) · gated on `«STATE-STRATEGY-FROZEN»`.** This unit builds the **runs-anywhere**
> state layer: a **purely-functional instance-state record** (tier-P) that `emit_core` threads
> through generated code — **no process dictionary, no OTP-native state, no NIF**. It is the
> tier-P twin of the Phase-2 tier-O `cell` (which stays **untouched and parallel**). Read
> [`00-overview.md`](00-overview.md) (G1, G4, G5, G6) and [`01-interface-freeze.md`](01-interface-freeze.md)
> §A first — this unit fills the bodies the keystone froze there.

---

## Context

Phase 2's mutable-state keystone (E1) chose the tier-O **`cell`**: an instance's
`{mem, globals, table}` live in the **process dictionary** of the instance's own process, under
one fixed key, holding one opaque `InstanceState` record (`rt_state.seed`/`get`/`put`/
`global_get`/`global_set` — all shipped, green, and **not to be modified by this unit**).

Phase 4's keystone (G1) adds the second point on the `state_strategy` axis: **`Threaded`**
(tier-P). Instead of hiding the record in the pdict, generated code **threads the *same*
`InstanceState` record as an ordinary value** — every state-reaching function takes it as a
leading parameter and returns the (possibly updated) record (the uniform-threading rule §10;
[keystone §A.3](01-interface-freeze.md)). There is **no ambient location** the state lives in:
it is a Gleam value on the stack, passed call to call. That is the headline **"no OTP, no NIF,
runs-anywhere"** posture — a `portable` build (threaded state + paged memory + `bif` numerics,
Safe) links **zero** native/unsafe primitives (`atomics`/`ets`/`persistent_term`/NIF) and **zero
pdict instance-state cell** (`rt_state` `seed`/`get`/`put`), and is provably unable to crash the
node (G6, overview §1). A Safe `portable` build still carries the documented **node-safe,
process-local tier-O policy overlays** — the mandatory `rt_meter` fuel counter (`Safe ⇒ MeterFuel`,
the F5 fail-closed CPU bound) and the `rt_host` policy cell — BEAM built-ins that live in the
process dictionary but cannot crash the node and hold no *instance* state; the runs-anywhere bar is
*zero native/unsafe primitives + zero pdict instance-state cell*, never *zero pdict* (overview §1).

This unit owns the **tier-P surface of `rt_state`**: `fresh` (build the record from the declared
inits — the threaded analogue of `seed`, returning the record instead of writing the pdict), the
threaded global accessors (`t_global_get`/`t_global_set`), and the **record field seam** the
tier-P `rt_mem`/`rt_table` wrappers sit on (`mem`/`with_mem`/`table`/`with_table` — pure,
value-threaded, opacity-preserving). It reconciles with the **existing pure `mem_*` core**
(`mem_load`/`mem_store`/`mem_grow` returning `#(Int, Mem)` — already in `rt_mem`, tier-agnostic).

Where the cell needed a constant-space proof, tier-P is trivial: **immutable values cost nothing
extra to thread**, and the record is a **fixed-size 3-tuple pointing at immutable structures**
(G4). A `t_global_set`/`t_store` rebinds one field (the other two shared by reference — no copy),
so the loop-carried record does not grow the stack; the tail-`apply` back-edge stays constant-space
(proven end-to-end in unit 09).

## Goal

Ship the tier-P threaded instance-state surface, **fail-closed and byte-identical to the cell
strategy's state materialisation**: `fresh(decl)` builds the exact record `seed(decl)` would have
installed (so a `Threaded` build and a `Cell` build compute identical results — G7); global
get/set thread through the record purely; the mem/table field seam lets `rt_mem`/`rt_table` (04/06)
project and re-inject their opaque field without `rt_state` ever importing them; and the tier-P
surface reaches **none** of the module's three pdict externals — the runs-anywhere property, proven
by construction and by test.

## Deliverables & freeze milestones

A single additive expansion of `src/twocore/runtime/rt_state.gleam` (the cell surface unchanged)
plus its spec-grounded suite. No new milestone is *produced* here — this unit *consumes*
`«STATE-STRATEGY-FROZEN»` and fills the tier-P bodies the keystone froze ([§A.2](01-interface-freeze.md)).

| Deliverable | Frozen at (keystone) | This unit |
|---|---|---|
| `fresh(decl: StateDecl) -> InstanceState` | §A.2 | body + shared builder with `seed` |
| `t_global_get(st, name) -> Int` | §A.2 | body (fail-closed on undeclared) |
| `t_global_set(st, name, value) -> InstanceState` | §A.2 | body (rebind one field) |
| `mem`/`with_mem`/`table`/`with_table` (record field seam) | §A.2 (implied by the `rt_mem`/`rt_table` wrappers projecting `st.mem`) | pure accessors, opacity seam |
| runs-anywhere proof (tier-P links no pdict/atomics/ets/persistent_term) | G6 | grep + behavioural test |

## Files owned

- `src/twocore/runtime/rt_state.gleam` — **extend** (single-owner, additive). The Phase-2 cell
  surface (`seed`/`clear`/`get`-equivalents/`mem_get`/`mem_put`/`table_get`/`table_put`/
  `global_get`/`global_set` + the pdict externals + `require_cell`/`put_cell`) is **frozen — do
  not touch**. This unit adds the tier-P functions above.
- `test/twocore/runtime/rt_state_test.gleam` — **extend** with the tier-P suite (the cell tests
  stay green, unchanged).

## Depends on

- **`«STATE-STRATEGY-FROZEN»`** (unit 01) — the `StateStrategy { Cell Threaded }` enum +
  `Binding.state_strategy`, and the frozen tier-P signatures in [§A.2](01-interface-freeze.md).
  This unit needs only the **signatures** (already in the doc); it does not need the seam codegen
  (02) or the profiles (07).
- The **existing `InstanceState`/`StateDecl` types + the cell surface** (already in
  `rt_state.gleam`). `InstanceState(mem: Dynamic, globals: Dict(String, Int), table: Dynamic)` is a
  **public** record — reused verbatim as the threaded box (keystone §A.2).
- `gleam/dict`, `gleam/dynamic` (both already imported). **No new external, no new Hex
  dependency, no new pdict BIF** — that is the point.

## Scope — in / out for this unit

**In:** the tier-P `fresh`; `t_global_get`/`t_global_set` over the record's `globals` dict; the
pure record field seam `mem`/`with_mem`/`table`/`with_table`; the shared `build` helper that makes
`fresh` and `seed` materialise **byte-identical** records; the runs-anywhere structural proof
(tier-P reaches no pdict); doc comments on every public function.

**Out (cite the deferral):**
- **The threaded `rt_mem` wrappers** (`t_load`/`t_store`/`t_size`/`t_grow`/`t_init_data`) —
  **unit 04's** (they must coerce `Dynamic → rt_mem.Mem`, which would force `rt_state` to import
  `rt_mem` and break opacity). This unit ships only the *record seam* they stand on. See
  **[Reconciliation flag](#reconciliation-flagged-to-the-keystone--em)**.
- **The threaded `rt_table` wrappers** (`t_init_elem`/`t_call_indirect`) — **unit 06's**, same
  reason.
- **The `emit_core` seam expansion** that emits the threaded calls and threads the record through
  loops/`instantiate` — **unit 02's** (keystone §A.3).
- **The `portable`/`ceiling` profiles + the whole-build runs-anywhere grep proof** — units 07/11.
- **Metering**: `rt_meter`'s fuel counter stays a tier-O pdict **policy overlay** and is
  **orthogonal** to state threading (keystone §A.3 — `seed_fuel`/`seed_policy` are unchanged). A
  Safe `portable` build **mandatorily keeps** it (`Safe ⇒ MeterFuel`, the F5 fail-closed CPU
  bound — `MeterOff`-under-Safe is rejected, unit 07), so the *whole build* is **not** pdict-free;
  it carries exactly this node-safe fuel-counter overlay. Fuel is **never** threaded through the
  state record (that would perturb the E1 constant-space back-edge for no security gain). The
  runs-anywhere bar is *zero pdict instance-state cell*, not *zero pdict*; `rt_state`'s tier-P
  surface is pdict-free (touches no `seed`/`get`/`put`) regardless.
- **Constant-space-under-a-real-loop** (`sum_to(100000)` / a store-loop with the record threaded)
  — needs the full `instantiate → invoke` pipeline; owned by **unit 09**. At this unit the property
  rests on the fixed-size-box mechanism (§A) + the immutable-value argument.

---

## A. The threaded box (frozen — reuse the existing record)

The threaded record **is** `rt_state.InstanceState`, already defined and exactly the fixed-size
handle G1/G4 describe:

```gleam
/// The whole per-instance state as ONE record. Under `Cell` it lives in the pdict; under
/// `Threaded` the SAME record is threaded call-to-call as a value. A fixed-size 3-tuple
/// pointing at immutable structures — threading it never grows the stack (G4).
pub type InstanceState {
  InstanceState(mem: Dynamic, globals: Dict(String, Int), table: Dynamic)
}
```

- `mem`/`table` stay **`Dynamic`** (opaque). `rt_mem` owns the `mem` shape (under `paged` a `Mem`,
  under `atomics` the ref handle, under `nif` the resource handle) and `rt_table` owns the `table`
  shape; `rt_state` never inspects either. **This opacity is load-bearing** — it is what lets the
  record be *tier-orthogonal* (one threaded record serves every memory tier, §10, G2) **and** what
  keeps `rt_state` from importing `rt_mem`/`rt_table` (no circular import; the tier-P surface stays
  pure). `mem`/`table` are `Dynamic` **in** and `Dynamic` **out** of every function here.
- `globals` is `Dict(String, Int)` — each mutable global's **raw bit pattern** as an `Int`
  (i32/i64/f32/f64 alike). Floats are **never** round-tripped through a BEAM double (D5): a double
  cannot hold NaN payloads / signalling bits and raises `badarith`. `rt_state` does no float math
  and needs no per-global type tag.

`StateDecl` (unchanged, public) is what the generated `instantiate` assembles and feeds `fresh`:

```gleam
/// The fresh per-layer values `instantiate` installs: `mem` from `rt_mem.fresh`, `table` from
/// `rt_table.new` (both opaque here), `globals` as `#(name, raw_bits)` pairs in declaration
/// order (duplicate names keep the LAST — `dict.from_list` semantics; validation guarantees
/// uniqueness upstream).
pub type StateDecl {
  StateDecl(mem: Dynamic, globals: List(#(String, Int)), table: Dynamic)
}
```

## B. `fresh` — build the record (the threaded analogue of `seed`)

Under `Threaded`, the generated `instantiate/0` calls `fresh(Decl)` **instead of** `seed(Decl)`:
it builds the record and **returns it as a value** (no pdict write), then threads it through
element → data → start and returns the final `InstanceState` (keystone §A.3). `fresh` is the sole
tier-P constructor.

```gleam
/// Build the initial threaded instance-state record from the SAME `StateDecl` the cell strategy
/// passes to `seed` — but RETURN it as a value (no pdict write). Called once by the threaded
/// `instantiate/0` (unit 02). `decl.globals` is materialised into the `globals` `Dict`; `mem`/
/// `table` are stored opaquely as-is (already built by `rt_mem.fresh`/`rt_table.new`).
///
/// - Returns the fresh `InstanceState`. Total; never raises; touches NO process dictionary.
pub fn fresh(decl: StateDecl) -> InstanceState {
  build(decl)
}
```

**Byte-identical materialisation (G7 — refactor `seed` to share it).** The cell `seed` and the
threaded `fresh` **must** build the identical record, or a `Cell` build and a `Threaded` build
could diverge. Factor the constructor into one private helper and have both call it:

```gleam
/// The single record builder shared by `seed` (cell: installs it in the pdict) and `fresh`
/// (threaded: returns it). Sharing it guarantees the two strategies materialise BYTE-IDENTICAL
/// state (G7 — a `Threaded` build and a `Cell` build compute identical results).
fn build(decl: StateDecl) -> InstanceState {
  InstanceState(
    mem: decl.mem,
    globals: dict.from_list(decl.globals),
    table: decl.table,
  )
}

pub fn seed(decl: StateDecl) -> Nil {
  put_cell(build(decl))          // cell path unchanged in behaviour; now routed through `build`
}
```

This is the *only* edit to an existing function, and it is behaviour-preserving (the body of
`seed` was already exactly `put_cell(InstanceState(mem: decl.mem, globals:
dict.from_list(decl.globals), table: decl.table))`). Assert the parity in a test (§Verification 2).

## C. Threaded mutable globals (`t_global_get` / `t_global_set`)

The tier-P twins of the cell's `global_get`/`global_set`, but **pure and value-threaded** — they
take the record and (for the setter) return the updated record, never reading or writing the
pdict. Per the WebAssembly spec, `global.get` reads any global and `global.set` writes a mutable
global (mutability is enforced at validation, unit P2-08 — this is a mechanical write)
(<https://webassembly.github.io/spec/core/exec/instructions.html#variable-instructions>).

```gleam
/// Read mutable global `name`'s raw bit pattern from the threaded record. READ-ONLY — `st` is
/// returned unchanged by the seam (the caller keeps threading the same record). Fail-closed: an
/// undeclared `name` `panic`s a node-safe internal error (unreachable post-validation — a
/// defensive guard, never a normal path). Returns the bit pattern verbatim (never a BEAM double).
pub fn t_global_get(st: InstanceState, name: String) -> Int {
  case dict.get(st.globals, name) {
    Ok(value) -> value
    Error(Nil) ->
      panic as "rt_state.t_global_get: undeclared global (internal invariant violation)"
  }
}

/// Rebind mutable global `name` to `value`, RETURNING the updated record. A NEW 3-tuple whose
/// `mem`/`table` fields are shared by reference and whose `globals` is `dict.insert`ed (only the
/// named global changes) — not a deep copy (the §10 uniform-threading rule for a mutating op).
/// Total; never raises; touches NO process dictionary. Immutability of `const` globals is a
/// validation property, not enforced here.
pub fn t_global_set(st: InstanceState, name: String, value: Int) -> InstanceState {
  InstanceState(..st, globals: dict.insert(st.globals, name, value))
}
```

`emit_core` (unit 02) lowers `GlobalGet → V = '<state_module>':'t_global_get'(St, Name)` (read-
only; `St` threaded on unchanged) and `GlobalSet → St2 = '<state_module>':'t_global_set'(St, Name,
Val)` (ordered effect — the new record is bound and threaded forward) (keystone §A.3). Under `Cell`
the seam emits today's `global_get(Name)` / `global_set(Name, Val)` byte-for-byte — the strategy is
the only switch.

## D. The record field seam (`mem` / `with_mem` / `table` / `with_table`)

The tier-P `rt_mem`/`rt_table` threaded wrappers (units 04/06) need to **project their opaque
field out of the record, drive the pure core, and inject the result back** — without `rt_state`
knowing the field shapes and without the wrappers knowing the record layout. This unit provides
that seam as four pure functions (reviving the Phase-2 mini-freeze names `mem`/`with_mem`/`table`/
`with_table` as value-threaded record operations — the cell path uses the differently-named
pdict `mem_get`/`mem_put`/`table_get`/`table_put`, so there is no collision):

```gleam
/// Project the opaque memory value from the threaded record (for `rt_mem`'s tier-P wrappers).
/// Returns the `Dynamic` unchanged — `rt_state` never inspects it. Read-only; total.
pub fn mem(st: InstanceState) -> Dynamic {
  st.mem
}

/// Rebind the memory field, returning the updated record (for `rt_mem`'s `t_store`/`t_grow`/
/// `t_init_data`). A new 3-tuple sharing `globals`/`table` by reference — not a copy. Total.
pub fn with_mem(st: InstanceState, mem: Dynamic) -> InstanceState {
  InstanceState(..st, mem: mem)
}

/// Project the opaque table value from the threaded record (for `rt_table`'s tier-P wrappers).
pub fn table(st: InstanceState) -> Dynamic {
  st.table
}

/// Rebind the table field, returning the updated record (for `rt_table`'s `t_init_elem`/
/// `t_call_indirect`). A new 3-tuple sharing `mem`/`globals` by reference. Total.
pub fn with_table(st: InstanceState, table: Dynamic) -> InstanceState {
  InstanceState(..st, table: table)
}
```

### Reconciliation with the existing pure `mem_*` core (mandate)

`rt_mem` **already** ships a pure, value-threaded, tier-agnostic paged core over `Mem`:
`mem_load(m, …) -> Result(Int, TrapReason)`, `mem_store(m, …) -> Result(Mem, TrapReason)`,
`mem_size(m) -> Int`, `mem_grow(m, delta) -> #(Int, Mem)`, `mem_init_data(m, …) -> Result(Mem,
_)`. The tier-P `rt_mem` wrapper (unit 04) is a **thin adapter** composing this unit's field seam
with that core — it lives in `rt_mem` (which already imports `rt_state` and owns the `Mem` coercion
`dynamic_to_mem`/`mem_to_dynamic`); `rt_state` stays pure and importless. Schematically:

```gleam
// in rt_mem.gleam (unit 04's body; shown to prove the seam closes the loop)
pub fn t_store(st, bytes, addr, value, offset) -> Result(rt_state.InstanceState, TrapReason) {
  case mem_store(dynamic_to_mem(rt_state.mem(st)), bytes, addr, value, offset) {
    Ok(m2) -> Ok(rt_state.with_mem(st, mem_to_dynamic(m2)))   // rebind the box, thread it on
    Error(reason) -> Error(reason)                             // trap-before-write: st untouched
  }
}
pub fn t_grow(st, delta) -> #(Int, rt_state.InstanceState) {
  let #(prev, m2) = mem_grow(dynamic_to_mem(rt_state.mem(st)), delta)  // #(Int, Mem) -> rebind
  // charge grow fuel on the success path (prev != -1), byte-identically to the Cell `grow`:
  // grow fuel is per-actual-delta (not a static IR Charge), so metered+threaded would diverge
  // from metered+cell — and open a resource-bound hole — without this (P2).
  case prev != -1 {
    True -> rt_meter.charge(delta * page_bytes)
    False -> Nil
  }
  #(prev, rt_state.with_mem(st, mem_to_dynamic(m2)))
}
pub fn t_load(st, …) -> Result(Int, TrapReason) {                      // read-only: no rebind
  mem_load(dynamic_to_mem(rt_state.mem(st)), …)
}
```

The `#(Int, Mem)` shape of `mem_grow` maps cleanly to `#(Int, InstanceState)` by pairing the
returned page-count with `with_mem`; the immutable-backend `Mem` and a future mutable `atomics`
handle both flow through the identical `mem`/`with_mem` pair (the mutable backend returns the same
handle in `mem_to_dynamic`, so `with_mem` rebinds the same `Dynamic` — one seam, both backends,
§10, G2). `rt_table`'s `t_init_elem`/`t_call_indirect` (unit 06) use `table`/`with_table`
identically.

## E. Runs-anywhere: the tier-P surface links no ambient state (G6)

The whole point of tier-P is that it reaches **no** `atomics`/`ets`/`persistent_term`/NIF/process-
dictionary state. For `rt_state` specifically:

- **The module's only three externals** are `erlang:put/2`, `erlang:erase/1`, and
  `twocore_rt_state_ffi:read_cell/1` — **all three belong solely to the cell path** (`seed`/
  `clear`/`put_cell`/`require_cell`). The tier-P surface added here (`fresh`/`build`/`t_global_get`/
  `t_global_set`/`mem`/`with_mem`/`table`/`with_table`) calls **none** of them: it is pure Gleam
  over `dict.*` and record construction. So the tier-P sub-graph of `rt_state` is **pdict-free by
  construction** — provable by a call-graph read (no path from a tier-P function to any external).
- **There is no shared location at all.** Under `Threaded` the state is a value on the stack;
  there is nothing for a second process, a second instance, or a NIF to reach into. Two instances
  in the *same* process never share (each threads its own record — §Verification 5). This is the
  strongest form of the per-instance isolation invariant (E3/G6): not "isolated by process" but
  "no ambient state to isolate."
- **Tier P, memory-safe by construction.** No native code runs; a bug's worst case is a wrong
  result or a node-safe `panic`, never a host escape (G6). The `portable` profile (unit 07) is the
  maximally-safe posture built on exactly this. The **whole-build** grep proof is unit 11's; at
  this unit the property is the module-scoped one above, asserted in §Verification 6.

## F. The cell path stays untouched and parallel (D1)

`Cell` (Phase-2 tier-O) and `Threaded` (Phase-4 tier-P) are **two parallel surfaces on one
module**, selected by `binding.state_strategy` at the `emit_core` seam (keystone §A.3) — never at
run time (compile-time, B3). The cell functions (`seed`'s pdict write, `mem_get`/`mem_put`/
`table_get`/`table_put`, `global_get`/`global_set`, `require_cell`, the externals) are **frozen**:
this unit changes exactly one line of one of them (`seed` now calls `build`, behaviour-identical).
A `Threaded` build never seeds the cell; a `Cell` build never calls `fresh`. Both keep the corpus
+ spec suite green with byte-identical results (G7).

---

## Effect / soundness / security note

- **No ambient authority (D3a) survives tier-P.** The tier-P surface constructs no module/function
  atoms and calls no `apply`; it is pure data over an immutable record. The threaded `emit_core`
  seam (unit 02) still emits fixed `twocore@runtime@rt_state` atoms with literal function names.
- **Fail-closed (D4).** `t_global_get` on an undeclared name `panic`s a node-safe internal error
  (an internal-invariant violation, **not** a WASM `TrapReason`) — never fabricates a value.
  Unreachable post-validation; a defensive guard, exactly as the cell `global_get` is.
- **Floats-as-bits (D5).** Globals are raw-bit-pattern `Int`s in the record end-to-end; `mem` is
  raw bytes over the IEEE bit pattern (owned by `rt_mem`). No BEAM-double round-trip anywhere.
- **Effect note (E6).** `t_global_get`/`t_global_set` (and any `mem`/`table` mutation via the
  wrappers) are **side-effecting in the value-threading sense** — the record is a linear resource
  a future optimizer must not reorder, CSE, or eliminate across (the `St → St'` data dependency
  makes this explicit and *enforceable* in the IR, a strictly stronger position than the cell's
  hidden-effect barrier).
- **Threads / shared memory stay a hard non-goal (§12, G8).** The threaded record is process-local
  by being *stack-local*; it is never shared cross-process. Tier-P has no `atomics`/`ets` to share.
- **Constant space (G4).** The record is a fixed-size 3-tuple; each `t_global_set`/`with_mem`
  rebinds one field (two shared by reference), so threading it through a tail loop does not grow the
  stack. The end-to-end proof is unit 09's; the mechanism is asserted here (§Verification 4).

---

## Verification — Definition of Done (D8: assert the spec, not the impl)

Spec-grounded tests in `rt_state_test.gleam` (cite the section/URL in each doc comment). These
assert behaviour a standard mandates, never "what the code currently emits."

1. **`fresh`/thread round-trip.** `fresh(StateDecl(mem: sentinel_m, globals: [#("g", 7)], table:
   sentinel_t))` yields a record whose `t_global_get(_, "g") == 7`, `mem(_) == sentinel_m`,
   `table(_) == sentinel_t`. *(The threaded box holds exactly the declared inits.)*
2. **`fresh` ≡ `seed` materialisation (G7 parity).** For the same `StateDecl`, the record `fresh`
   returns equals the record the cell path builds and stores — assert field-by-field (`t_global_get`
   over each declared global == the cell `global_get` after `seed`; same `mem`/`table` sentinels).
   Pins that a `Threaded` build and a `Cell` build start from identical state.
3. **Global get/set through the record.** `st1 = fresh(…globals=[#("g",7),#("h",9)])`; `st2 =
   t_global_set(st1, "g", 42)`; then `t_global_get(st2, "g") == 42`, `t_global_get(st2, "h") == 9`
   (only `g` changed), **and** `t_global_get(st1, "g") == 7` (the ORIGINAL record is unchanged —
   immutability / value semantics). *(WASM global.set/global.get exec semantics + purity.)*
4. **Float globals are bit-exact (D5).** Seed a global whose init is a **NaN-payload**, **`-0.0`**,
   and **±Inf** bit pattern (as `Int`); `t_global_get` returns the identical `Int`; `t_global_set`
   with such a pattern round-trips it verbatim. Asserts no BEAM-double round-trip mangles the bits.
5. **Two threaded instances never share — no global state at all.** In a **single process**, build
   `a = fresh(…globals=[#("g",1)])` and `b = fresh(…globals=[#("g",2)])`; `a2 = t_global_set(a,
   "g", 99)`. Assert `t_global_get(b, "g") == 2` (untouched), `t_global_get(a, "g") == 1` (original
   untouched), `t_global_get(a2, "g") == 99`. Because the state is a value, one process holds two
   independent instances with **no cross-talk and no pdict** — the tier-P isolation property (E3/G6).
6. **Tier-P links no pdict (runs-anywhere, behavioural).** In a fresh process, run a sequence of
   tier-P ops (`fresh`, `t_global_set`, `mem`/`with_mem`) and assert the **cell is still un-seeded**
   afterwards — i.e. the Phase-2 cell `get()`-equivalent still reports absent (its fail-closed
   `Error`/`panic`), proving the tier-P surface wrote **nothing** to the process dictionary.
   Complement with a source-level assertion in the doc/test that no tier-P function reaches
   `erlang_put`/`erlang_erase`/`read_cell` (the module's only externals — all cell-path). *(G6.)*
7. **Record field seam round-trip (opacity).** `with_mem(st, m)` then `mem(_) == m`; `with_table(st,
   t)` then `table(_) == t`; and `with_mem` leaves `globals`/`table` unchanged (`table(with_mem(st,
   m)) == table(st)`). Use sentinel `Dynamic` values (standing in for 04/06's real shapes) — proving
   `rt_state` never inspects `mem`/`table`.

**Gate:** `gleam format --check src test` clean; `gleam build` **zero warnings** (no leftover
`todo`); `gleam test` stays **green (≥674)** — no Phase-1/2/3 regression, the cell suite unchanged;
every new public function and type carries a `///` contract doc (what / params + ranges / return +
`Result`/`Option`/`panic` meaning / failure & raise modes). "Done" is **the suite passes**, not "it
compiles." Update `state.md`: announce the tier-P `rt_state` surface (`fresh`/`t_global_get`/
`t_global_set`/`mem`/`with_mem`/`table`/`with_table`) and the `seed`→`build` refactor.

> The **constant-space-under-a-real-store/set-loop** proof (~100k iterations threading the record,
> asserting constant process memory + preemption) needs the full `instantiate → invoke` pipeline
> and is **unit 09's** (G4). At this unit the property rests on the fixed-size-box mechanism (§A)
> and the immutable-value argument. Note this hand-off in `state.md`.

---

## Reconciliation with the keystone (settled by the reconciled ownership decision)

The keystone §A.2 originally tagged the tier-P **`rt_mem` threaded wrappers** (`t_load`/`t_store`/
`t_size`/`t_grow`/`t_init_data`) and **`rt_table` threaded wrappers** (`t_init_elem`/
`t_call_indirect`) ambiguously ("owner unit 02/04" / "owner unit 02/06"). The reconciled ownership
decision **deletes those ambiguous tags** and fixes exactly one owner per file: these wrappers live
in `rt_mem.gleam` (**owner-additive to unit 04**) and `rt_table.gleam` (**owner-additive to unit
06**) — never in `rt_state.gleam` — because they coerce `Dynamic → rt_mem.Mem` / `rt_table.Table`,
which would force an import of `rt_mem`/`rt_table` into `rt_state` and **break the opacity /
no-circular-import invariant** this unit and the cell strategy both depend on. `rt_state.gleam`
stays unit 03's alone and imports neither. This unit therefore ships **only** the **record field
seam** (`mem`/`with_mem`/`table`/`with_table`, §D) those wrappers compose with the existing pure
`mem_*`/table core; the wrappers themselves are 04/06's. Every frozen contract is preserved.

## What this unit leaves

- **02** expands the `emit_core` seam to emit the threaded calls (`t_global_get`/`t_global_set` +
  the tier-P `rt_mem`/`rt_table` heads), threads the record through loops as a leading `LoopParam`
  (the G4 constant-space back-edge), and makes `instantiate/0` call `fresh` and return the record.
  Reads this unit's tier-P signatures, not internals.
- **04** builds the tier-P `rt_mem` threaded wrappers (`t_load`/`t_store`/`t_size`/`t_grow`/
  `t_init_data`) over the existing pure `mem_*` core using this unit's `mem`/`with_mem` seam, plus
  the `atomics` tier-O backend. **06** builds the tier-P `rt_table` wrappers over `table`/
  `with_table`, plus the `ets`/`atomics` table tiers.
- **07** composes the `portable` profile (`Threaded` + `Paged` + `bif` + Safe) on this surface and
  owns the whole-build linker rules.
- **09** proves the constant-space-under-threaded loop (G4) and the tier differential; **11** runs
  the whole-build runs-anywhere grep proof and conformance-green for every `(strategy × tier)`.

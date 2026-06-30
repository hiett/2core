# Unit 05 — rt_table + call_indirect (3-fault fail-closed dispatch)

> **One owner · Wave A (parallel with 03/04/06) · gated on `«CELL-STATE-ABI-FROZEN»`
> (incl. the rt_state cell + its opaque `table` field).** Read
> [`00-overview.md`](00-overview.md) (E1–E8) and
> [`01-interface-freeze.md`](01-interface-freeze.md) §B first. You own one new runtime
> module: the funcref **table value** and the **`call_indirect`** dispatcher. Your one job
> is to make indirect calls run **and** fail closed, with **no ambient authority**.

---

## Context

WebAssembly `call_indirect` is the type-safe dynamic-dispatch primitive: a function is
selected at run time by an `i32` index into a table of function references, and the
engine **dynamically type-checks** the selected function against the call site's expected
signature before invoking it (this runtime check is *the* type-safety guarantee of the
table mechanism — <https://webassembly.org/docs/security/>). Phase 1 rejected
`call_indirect` at validation/lowering (`lower.gleam:380 → Error(Unsupported)`;
`emit_core.gleam:333 → UnsupportedNode`). Phase 2 turns it on.

The table is the **first build-controlled call-graph edge that is selected by runtime
data**, so it is exactly where the D3a invariant ("**no ambient authority** — generated
code never does a data-driven `apply(Mod, Fun, Args)` where `Mod`/`Fun` come from program
data") is most at risk. Your dispatcher must keep the *index* as the only runtime-data
input and keep every module/function reference **compile-time-fixed**. The unit-10
structural security test is extended to assert this.

The table is **mutable instance state**, so it lives in the per-instance **cell** (E1):
the `{mem, globals, table}` record in the instance process's dictionary under one fixed
key, owned by `rt_state` (unit 03). `rt_table` owns the **shape** of the `table` field
(opaque to `rt_state`) and every operation on it.

---

## Goal

A funcref table plus a `call_indirect` that dispatches through **build-controlled
references** (never `apply` of a program-chosen module/atom), guarded by **three
fail-closed checks in spec order**:

1. **index in `[0, size)`** — else `UndefinedElement` ("undefined element");
2. **slot non-null** (filled by an element segment) — else `UninitializedElement`
   ("uninitialized element");
3. **exact structural `FuncType` match** — else `IndirectCallTypeMismatch` ("indirect
   call type mismatch");

then invoke the slot's build-controlled target with the call arguments. Plus
`init_elem`, the instantiation-time active-element writer (whole-range bounds-check →
trap, no partial write).

---

## Files owned

| File | Status |
|---|---|
| `src/twocore/runtime/rt_table.gleam` | **NEW** — you create it (fill the unit-01 frozen stub). |
| `test/twocore/runtime/rt_table_test.gleam` | **NEW** — your spec-cited test module. |

You do **not** edit `instance.gleam` (unit 01 adds `table_module`), `rt_state.gleam`
(unit 03), `emit_core.gleam` (unit 10), or the conformance allowlist (unit 11).

---

## Depends on

- **`«CELL-STATE-ABI-FROZEN»` (unit 01)** — the `rt_table` stub signatures, the `Binding`
  `table_module` field, and the instantiation contract. Unit 01 publishes
  `rt_table.gleam` with `todo` bodies:
  ```gleam
  pub fn init_elem(offset: Int, funcs: List(fn() -> Nil)) -> Result(Nil, TrapReason)
  pub fn call_indirect(index: Int, expected_type: a, args: List(b)) -> Result(c, TrapReason)
  ```
  These are deliberately loose placeholders; you concretise the value types (below) and
  **must coordinate the two refinements flagged in "Deliverables" back to unit 01/10**.
- **`rt_state` cell (unit 03)** — the opaque `table` field + the cell `get`/`put` (or a
  table accessor) and the **fail-closed-on-un-seeded-cell** contract. Until 03 lands,
  stub a trivial in-process cell behind the same call shape so you can build and test;
  re-sync when 03's real accessors land.
- **`ir.{FuncType, TrapReason}` (`«IR2-FROZEN»`)** — `FuncType(params, results)` is your
  structural type tag; `UndefinedElement`/`UninitializedElement`/`IndirectCallTypeMismatch`
  are the three trap reasons (and their `rt_trap.spec_trap_message` strings) frozen by
  unit 01.

---

## Scope — in / out for Phase 2

**In:** a single funcref table (table index 0); active flag-0 element segments at
instantiation; the 3-fault `call_indirect`; exact structural-`FuncType` runtime check.

**Out (deferred — do not build):**
- **Reference types** (E8 / topic 2): `externref`, `funcref` values in the value layer,
  `table.get`/`table.set`/`table.copy`/`table.fill`, `table.grow`/`table.size`, typed
  `select_t`, `ref.null`/`ref.func`, and element-segment flags 1–7 (passive/declarative,
  expr-list, reftype). The MVP table is **immutable after instantiation** (only
  `init_elem` writes it) — keep it so.
- **Multi-table `call_indirect`** with explicit table-index immediates (the reference-types
  `call_indirect.wast` multi-table module). MVP: validate exactly **one** table; the IR's
  `CallIndirect(table: String, …)` name field is forward-compat only.
- **GC** (`table_init.wast` array/arrayref) — Phase 3.

---

## Deliverables

### 1. The table value (`table` field of the cell)

An **immutable** map from slot index to `(structural type, build-controlled target)`,
sized at instantiation. Funcref tables are written only by `init_elem` (no runtime table
mutation in MVP), so structural sharing is free.

```gleam
/// A populated table slot: the target's structural type tag + its BUILD-CONTROLLED
/// closure. `target` is created by the generated `instantiate` entry (unit 10) with a
/// COMPILE-TIME-LITERAL `'twocore@wasm@<mod>':'f<idx>'/arity` reference captured inside
/// it; `rt_table` only stores and invokes it. `ty` is the IR structural `FuncType` of
/// the target (NOT a typeidx — see Grounded facts).
pub type TableEntry {
  TableEntry(ty: FuncType, target: fn(List(Int)) -> List(Int))
}

/// The funcref table. `size` is the number of slots (the declared `min`; MVP has no
/// `table.grow`, so it is fixed). `slots` is SPARSE: a present key = a filled slot, an
/// ABSENT key in `[0, size)` = a null/uninitialised slot (→ `UninitializedElement`).
pub opaque type Table {
  Table(size: Int, slots: Dict(Int, TableEntry))
}
```

All WASM values are raw-bit `Int`s (D5), so the closure interface is
`fn(List(Int)) -> List(Int)` (args in, results out — 0/1/N results as a list).

### 2. Functions

```gleam
/// Build a fresh size-`size` all-null table (every slot uninitialised). Pure.
/// Called by the instantiate sequence to seed the cell's `table` field.
pub fn new(size: Int) -> Table

/// Seed THIS process's cell with a fresh empty size-`size` table (resets any prior).
/// Effectful (writes the cell). Run by the generated `instantiate` entry before any
/// `init_elem`. (See the coordination note — this is an ADDITION to the unit-01 stub.)
pub fn seed_table(size: Int) -> Nil

/// Write an ACTIVE element segment into the table at instantiation: place `entries[k]`
/// into slot `offset + k`. Whole-range bounds-check FIRST: if `offset < 0` or
/// `offset + length(entries) > size`, return `Error(..)` and write NOTHING (all-or-
/// nothing — no partial table writes). On success returns `Ok(Nil)` and the cell's
/// table now holds the entries. Fail-closed: an un-seeded cell → `Error`.
pub fn init_elem(offset: Int, entries: List(TableEntry)) -> Result(Nil, TrapReason)

/// THE 3-fault fail-closed indirect dispatch. Reads the cell's table; applies the three
/// guards IN ORDER; on success invokes the slot's build-controlled `target` with `args`.
///
/// Returns `Ok(results)` (the target's result list), or `Error(reason)`:
///   - `UndefinedElement`         — `index < 0` or `index >= size`        (guard 1)
///   - `UninitializedElement`     — slot is null (absent)                  (guard 2)
///   - `IndirectCallTypeMismatch` — `entry.ty != expected_type`           (guard 3)
/// Fail-closed: an un-seeded cell → `Error`. `expected_type` is the call site's IR
/// `FuncType`; the match is exact STRUCTURAL equality (`==`).
pub fn call_indirect(
  index: Int,
  expected_type: FuncType,
  args: List(Int),
) -> Result(List(Int), TrapReason)
```

### 3. Algorithm shape

```
call_indirect(index, expected_type, args):
  state  <- rt_state.get()            // Error(_) if un-seeded → propagate (fail-closed)
  table  <- state.table               // coerce the opaque field to `Table`
  if index < 0 || index >= table.size            -> Error(UndefinedElement)      // guard 1
  case dict.get(table.slots, index):
    Error(_)                          -> Error(UninitializedElement)             // guard 2
    Ok(TableEntry(ty, target)):
      if ty != expected_type          -> Error(IndirectCallTypeMismatch)         // guard 3
      else                            -> Ok(target(args))                        // invoke
```

`init_elem` reads the cell's table, bounds-checks the **whole** range up front, folds the
entries into `slots`, writes the table back via the cell, returns `Ok(Nil)`.

> **The D3a-safe invocation.** `target(args)` is a **fun application of a closure value**
> that the build (unit 10's `instantiate`) constructed with a *literal* `f<idx>` target —
> it is **not** `apply(Mod, Fun, Args)` with `Mod`/`Fun` drawn from the table/runtime
> data. `rt_table` must **never** itself construct a module/function atom from data, never
> call `erlang:apply/3` on data-derived names. The only runtime-data input that reaches a
> control transfer is the integer `index`; everything dispatched is a build-controlled
> closure. This is what the unit-10 structural security test checks.

---

## Grounded facts you MUST honor

Transcribed from research topic 2 (verified against the WASM spec):

- **Opcode / immediates.** `call_indirect = 0x11`; binary immediates are **typeidx `y`
  first, then tableidx `x`** (`0x11 y x`) — the opposite of text-format order; the
  existing decoder already reads ty-then-table; **do not swap**. Operand: the `i32` index
  `i` is **on top** of the stack (popped first); the call args are beneath it.
  (Decoder/validator are units 07/08; you receive the lowered `ir.CallIndirect`.)
- **The three traps, distinct and ORDERED** (exec/instructions.html, MVP):
  | order | condition | reason | spec message |
  |---|---|---|---|
  | 1 | `i >= length(table.elem)` (index OOB) | `UndefinedElement` | `"undefined element"` |
  | 2 | `table.elem[i]` is null/uninitialised | `UninitializedElement` | `"uninitialized element"` |
  | 3 | target's actual type `≠` `C.types[y]` | `IndirectCallTypeMismatch` | `"indirect call type mismatch"` |
  The order is observable: an OOB index must trap `UndefinedElement` **before** any
  null/type check. (The three `spec_trap_message` strings are frozen by unit 01 in
  `rt_trap`; assert they read exactly as above.)
- **Validation is static-only; the type check is dynamic.** valid/instructions.html only
  requires the table is funcref and `C.types[y]` is a function type (units 08). The
  **per-call** type check is purely **runtime** — that is your guard 3.
- **Exact STRUCTURAL `FuncType` equality.** The dynamic check compares the *structural*
  function type, **not** the raw typeidx. The IR `FuncType(params, results)` is already a
  structural type, so Gleam `==` IS the correct comparison (topic 2: "the IR structural
  compare is correct for WASM 1.0"). Two structurally-equal types reaching the slot and
  the call site — even via different typeidx entries — **must match**; differing
  params/results **must mismatch**. Never key the check on typeidx.
- **Generated-function naming.** Defined functions are
  `'twocore@wasm@<mod>':'f<idx>'/<arity>` (`lower.gleam:160` module name, `:263`/`:477`
  `f<idx>`). The slot's closure targets that symbol; the closure is built by unit 10's
  `instantiate`.
- **Element section (id 9) — active flag 0 only** (binary/modules.html): `0x00
  offset-expr:expr vec(funcidx)` → write `funcidx`s into table 0 at the constant
  `offset`. Flags 1–7 (passive/declarative, expr-list, reftype) are out of scope —
  units 07/08 decode-reject them; you only ever receive flag-0 `ir.ElementSegment`s.
- **Instantiation order & OOB.** exec/modules.html: globals → **elements** → data →
  start. An active element segment whose range exceeds the table aborts instantiation
  (MVP frames it as an **unlinkable** link error; modern bulk-memory framing traps "out
  of bounds table access"). Bounds-check the **whole** range up front and write **nothing**
  on failure — never "write what fits then fail".
- **Const offset.** MVP const-exprs reduce to a single `t.const` (imports are Phase 3, so
  `global.get` has no valid referent). Lowering (unit 09) hands you a constant `offset`;
  you do not evaluate exprs.

**Pitfalls (do not trip):**
- **No data-driven `apply`.** The single sharpest constraint. Dispatch must be a closure
  the build created, or a `case` over a compile-time-closed set — never `apply` of a
  data-chosen module/atom. (Topic 2.)
- **Compare canonical structural types, not typeidx** — else duplicate-but-equal type
  entries produce false `IndirectCallTypeMismatch`.
- **Order the guards** bounds → null → type; do not reorder for convenience.
- **Whole-range element bounds**: no partial table writes.
- **Single table only**; the `table: String` IR field is forward-compat — validate one
  table, don't build multi-table machinery.
- **Fail-closed on an un-seeded cell** (E3 isolation): if `rt_state.get()` is `Error`,
  both ops return `Error` — never read garbage / a default-empty table that silently
  "succeeds".

---

## Verification — Definition of Done (D8: assert the spec, not the impl)

Write `test/twocore/runtime/rt_table_test.gleam` asserting the **WASM-spec** behavior
(cite exec/instructions.html, valid/instructions.html, webassembly.org/docs/security),
**not** whatever the code emits. Seed a cell (via `rt_state.seed`/`seed_table`) in each
test; use the `twocore_rt_test_ffi:trap_kind/1` helper (already present) to assert the
error class/shape where a generated-code path is exercised.

1. **Happy path.** Build a table with a slot holding `TableEntry(FuncType([TI32,TI32],
   [TI32]), fn(args){ [add(args)] })`; `call_indirect(slot, FuncType([TI32,TI32],[TI32]),
   [3,4])` returns `Ok([7])`. A 0-arg/0-result and a multi-result target also round-trip
   (closure list contract).
2. **Three faults, right reason.** (a) `index = size` and `index = -1` →
   `Error(UndefinedElement)`; (b) a present-but-absent slot (in `[0,size)`, never filled)
   → `Error(UninitializedElement)`; (c) a filled slot whose `ty` differs from
   `expected_type` (different params OR different results) → `Error(IndirectCallTypeMismatch)`.
3. **Guard ORDER.** An OOB index whose (hypothetical) slot would also be null/wrong-type
   still traps `UndefinedElement` first; a null slot at an in-range index traps
   `UninitializedElement` before any type comparison.
4. **Structural type equality.** Two distinct `FuncType` *values* that are structurally
   equal match (`Ok`); `FuncType([TI32],[TI32])` vs `FuncType([TI64],[TI32])` and vs
   `FuncType([TI32],[])` each mismatch. Proves `==` is structural, not identity/typeidx.
5. **`init_elem` bounds at instantiation.** `init_elem(offset, entries)` with
   `offset + len > size` (and `offset = size`, the exact off-by-one) → `Error(..)` **and**
   a subsequent `call_indirect` to any slot the segment would have filled still traps
   `UninitializedElement` (proves no partial write). An in-range segment fills exactly its
   slots.
6. **Fail-closed.** In a process with **no** seeded cell, `call_indirect` and `init_elem`
   return `Error` (not a wrong `Ok`/garbage). (Run in a fresh process or before seeding.)
7. **Structural security (coordinate with unit 10).** The unit-10 test asserts the
   generated `call_indirect` lowering contains **no** data-driven module `apply`; your
   contribution is to keep `rt_table` itself free of any `erlang:apply/3` on data-derived
   names and to invoke only the supplied closure — add a unit-05 note/assertion that
   `rt_table` never constructs a module/function atom from its inputs.
8. **Trap-message frozen mappings.** Assert `rt_trap.spec_trap_message(UndefinedElement)
   == "undefined element"`, `… (UninitializedElement) == "uninitialized element"`,
   `… (IndirectCallTypeMismatch) == "indirect call type mismatch"` (unit 01 owns the
   mapping; this guards against drift).
9. **Conformance (wired by unit 11, proven by you).** Your dispatch + traps are the engine
   under `call_indirect.wast` (topic 5): **114 `assert_return` + 18 `assert_trap`** in
   scope. The within-file SKIP list (honest skips, never silent passes): the **2
   `assert_exhaustion`** (`call stack exhausted`, lines 585–586 — out of Phase-2 scope) and
   the **reference-types multi-table module** (3 tables `$t1/$t2/$t3`, explicit table-index
   `call_indirect`, lines 625–630). Provide whatever the capstone harness needs; do not
   add the allowlist entry yourself.

**Gate:** `gleam format --check src test` clean; `gleam build` **zero warnings** (no
lingering `todo`); `gleam test` stays green (≥313 + your new tests); every public
function/type has a `///` contract doc (D8).

---

## Concurrency

Sub-tasks (one agent can do all; splittable):
- **05a — table value + guards:** `Table`/`TableEntry`, `new`, `init_elem`,
  `call_indirect` (the 3 guards + invoke), unit tests 1–6/8. Needs only `«IR2-FROZEN»`
  (`FuncType`/`TrapReason`) + a stub cell.
- **05b — cell seam + security:** wire `seed_table`/`init_elem`/`call_indirect` to the
  real `rt_state` accessors when unit 03 lands; the fail-closed-on-un-seeded test (6) and
  the security note (7).

**Must be frozen before you finish:** `«CELL-STATE-ABI-FROZEN»` (the `rt_table` stub
signatures and the rt_state cell get/put). You can **start** against a strawman in-process
cell, but re-sync to unit 03's accessors and confirm the two refinements with the planner
(below) before marking done.

---

## What this leaves for others

- **Unit 10 (emit_core + instantiate):** lowers `ir.CallIndirect` to
  `call '<table_module>':'call_indirect'(Idx, Type, Args)` and `case`s `{ok,V}/{error,R}`
  (raise on error) via the state-access seam; emits the `instantiate` entry that calls
  `seed_table(min)` then `init_elem(offset, entries)` per segment, **constructing each
  `TableEntry`'s closure** as a build-controlled wrapper over `'twocore@wasm@<mod>':
  'f<idx>'/arity` that unpacks `args` to the static arity and re-wraps results into a
  list (reconciling the function-boundary packager: 0→`[]`, 1→`[v]`, N→`[v1..vn]`). The
  closure interface `fn(List(Int)) -> List(Int)` is the contract you publish to unit 10.
- **Unit 11 (capstone):** adds `call_indirect.wast` to the allowlist with the two
  within-file skips above; acceptance corpus proves "right-type runs; wrong-type / OOB /
  null each trap distinctly — and never via a data-driven `apply`" end-to-end.

---

## ⚠ Two refinements to confirm with the planner (flag, then proceed)

1. **Stub signature concretisation.** The unit-01 frozen stub uses placeholder generics
   (`init_elem(offset, funcs: List(fn() -> Nil))`, `call_indirect(index, expected_type: a,
   args: List(b)) -> Result(c, _)`). This unit concretises them to `init_elem(offset,
   entries: List(TableEntry))` and `call_indirect(index, expected_type: FuncType, args:
   List(Int)) -> Result(List(Int), TrapReason)`, and **adds** `new`/`seed_table` (the cell
   can't be seeded with a `Table` by `rt_state` without a circular import, since
   `rt_table` imports `rt_state`). Unit 10 must emit against these concrete signatures.
2. **`init_elem` OOB trap reason.** The frozen `TrapReason` set has **no** "out of bounds
   table access" reason (only `UndefinedElement`/`UninitializedElement`/
   `IndirectCallTypeMismatch`), yet the spec frames an active-element-segment OOB at
   instantiation as **unlinkable** ("out of bounds table access"), distinct from
   `call_indirect`'s "undefined element". This unit uses `UndefinedElement` as the interim
   reason (no allowlisted Phase-2 file asserts the segment-init message — `elem.wast` is
   deferred); the capstone categorises it as an instantiation failure regardless of the
   exact kind. The planner may prefer to add a `TableOutOfBounds` reason in a freeze
   amendment for fidelity.

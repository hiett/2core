# Unit 01 — Interface Freeze (Phase-2 keystone)

> **One owner. Design + compiling stubs only. On the critical path of everything.** Read
> [`00-overview.md`](00-overview.md) (E1–E8) first. This unit freezes the three contracts the
> Phase-2 swarm binds to — the **IR2 extension**, the **cell state ABI + instantiation
> contract**, and the **rt_num float signatures** — and lands them GREEN (the build compiles,
> `gleam test` passes, zero warnings) before the parallel units begin.

The build is currently zero-warning with 313 passing tests. **It must stay that way after
this unit** — which means every exhaustive `case` (printer, parser, emit_core, rt_trap) that
matches the types you extend must be updated to compile, and every `Binding` constructor must
be updated to populate the new fields. That is why this is one coherent unit with a few
deliberate cross-file reaches.

---

## Deliverables & freeze milestones

1. `«IR2-FROZEN»` — the IR2 type extension (`ir.gleam`) + the new `TrapReason`s + the
   `.ir` grammar delta (`specs/phase-2/ir2-grammar-delta.md`). Unblocks 02, 08, 09, 10.
2. `«CELL-STATE-ABI-FROZEN»` — the `Binding` extension (`instance.gleam`), the cell ABI
   (stub modules `rt_state`/`rt_mem`/`rt_table` with frozen public signatures), the emit_core
   **state-access seam** convention, and the **instantiation contract** — all documented in
   this file's frozen contracts and the stub module docs. Unblocks 03, 04, 05, 10, 11.
3. `«RTNUM2-SIG-FROZEN»` — the new `rt_num` float/convert function heads (`todo` bodies).
   Unblocks 06, 10.

**Land green (the cross-file reaches — Gleam has no default field values, so every constructor
of a changed type must be updated to compile):**
- Extending `Binding` breaks `safe_default` (instance.gleam) **and** `profiles.safe`
  (profiles.gleam) **and** test constructors — reach into `profiles.gleam` and set the default
  Safe `mem`/`table`/`state` module names.
- Adding the `start`/`tables`/`elements` fields to `Module` and the `result` field to `MemLoad`
  breaks **every** `ir.Module(...)` / `MemLoad(...)` constructor across the tree — the
  strawman/golden tests, **`test/twocore/ir/roundtrip_test.gleam` (unit 02's)**, `lower.gleam`,
  `emit_core.gleam`. Minimally update them (empty `tables`/`elements`, `start: None`, a
  placeholder `result` ValType) so the build stays green; the owning unit then fleshes each out.
- Adding the four `TrapReason` variants breaks `rt_trap.spec_trap_message`'s exhaustive match —
  add the four new mappings.
- Adding IR `Expr`/`NumOp`/`ConvOp` variants breaks the printer/parser/emit_core exhaustive
  matches — make them compile (a temporary minimal arm unit 02/10 fills; no warnings).
- The `.ir` grammar delta: adopt unit-02's proposed spellings — `trunc_s.<fw>.<iw>` (kept
  distinct from saturating `trunc_sat_s`), `convert_s.<iw>.<fw>`, `f.<op>.<W>`,
  `mem.load <result-valtype> …`, `demote.f64`/`promote.f32`.
- Document every cross-file reach in `state.md`.

**Out of scope:** any runtime logic, decoding, lowering, or codegen — bodies are `todo`/stub.

---

## A. IR2 extension (additive to the existing `ir.gleam`)

The IR already has `Module.memory/globals/data_segments`, `MemLoad/MemStore/GlobalGet/
GlobalSet`, `CallIndirect`, `MemoryDecl/GlobalDecl/DataSegment`, `MemAccess(bytes,signed)`,
and `TrapReason{MemoryOutOfBounds, IndirectCallTypeMismatch}`. Add **only** the gaps:

```gleam
// ── Module: add tables + element segments ────────────────────────────────────
pub type Module {
  Module(
    // … existing fields …
    tables: List(TableDecl),          // NEW (funcref tables; MVP)
    elements: List(ElementSegment),   // NEW (active element segments)
    start: Option(String),            // NEW (start function name; run at instantiation)
  )
}

/// A funcref table (MVP: the only reftype is funcref). `max` is in entries.
pub type TableDecl {
  TableDecl(name: String, min: Int, max: Option(Int))
}

/// An ACTIVE element segment: write `funcs` (by IR function name) into `table`
/// starting at the (constant) `offset`, at instantiation. OOB → trap-at-instantiation.
pub type ElementSegment {
  ElementSegment(table: String, offset: Expr, funcs: List(String))
}

// ── Expr: add memory.size / memory.grow, and give loads a result type ─────────
pub type Expr {
  // … existing …
  /// memory.size → current size in 64KiB pages (i32).
  MemSize
  /// memory.grow(delta_pages) → previous size in pages, or -1 (i32) on failure
  /// (exceeds the Safe max-pages cap or the declared max). Effectful.
  MemGrow(delta: Value)
  // CHANGE MemLoad to carry the result type (MemAccess(bytes,signed) alone cannot
  // distinguish i32.load8_s from i64.load8_s — same bytes+sign, different result bits):
  MemLoad(op: MemAccess, addr: Value, offset: Int, result: ValType)   // result ADDED
  // MemStore unchanged in shape; `op.signed` is irrelevant for stores (document it):
  // MemStore(op: MemAccess, addr: Value, value: Value, offset: Int)
}

// ── NumOp: the remaining float ops (per FloatWidth) ──────────────────────────
pub type NumOp {
  // … existing FAdd/FSub/FMul/FDiv/FMin/FMax …
  FAbs(FloatWidth)  FNeg(FloatWidth)  FCeil(FloatWidth)  FFloor(FloatWidth)
  FTrunc(FloatWidth)  FNearest(FloatWidth)  FSqrt(FloatWidth)  FCopysign(FloatWidth)
  FEq(FloatWidth)  FNe(FloatWidth)  FLt(FloatWidth)  FGt(FloatWidth)
  FLe(FloatWidth)  FGe(FloatWidth)
}

// ── ConvOp: trapping float→int, int→float, demote/promote ────────────────────
pub type ConvOp {
  // … existing wrap/extend/trunc_sat/reinterpret/box/unbox …
  /// TRAPPING float→int (distinct from TruncSat*): traps InvalidConversionToInteger
  /// on NaN/±Inf, IntOverflow on out-of-range; else truncate toward zero.
  TruncS(from: FloatWidth, to: IntWidth)   TruncU(from: FloatWidth, to: IntWidth)
  /// int→float (round-to-nearest ties-to-even).
  ConvertS(from: IntWidth, to: FloatWidth)  ConvertU(from: IntWidth, to: FloatWidth)
  F32DemoteF64   F64PromoteF32
}

// ── TrapReason: 3 new reasons ────────────────────────────────────────────────
pub type TrapReason {
  // … existing IntDivByZero/IntOverflow/Unreachable/IndirectCallTypeMismatch/MemoryOutOfBounds …
  InvalidConversionToInteger   // trapping float→int on NaN/±Inf
  UndefinedElement             // call_indirect: table index out of bounds (runtime)
  UninitializedElement         // call_indirect: null/unfilled table slot
  TableOutOfBounds             // active element segment OOB at instantiation
}
```

`rt_trap.spec_trap_message/1` (reach into `rt_trap.gleam`) gains: `InvalidConversionToInteger
→ "invalid conversion to integer"`, `UndefinedElement → "undefined element"`,
`UninitializedElement → "uninitialized element"`, `TableOutOfBounds → "out of bounds table
access"`. (Active **data**-segment OOB at instantiation reuses the existing
`MemoryOutOfBounds → "out of bounds memory access"`.)

> **Open question to settle:** whether the load result is a full `ValType` or just
> `IntWidth`+sign (raw-bits rep means `f32.load` == `i32.load` byte-wise, so a load needs only
> width + sign — but a `ValType` is clearer and lets validate carry the value type through).
> Recommendation: `result: ValType`. Confirm `i32.load8_s` vs `i64.load8_s` lower to distinct
> sign-extensions by walking both through the types before freezing.

**Effect note (E6):** document in `ir.gleam` that `MemLoad/MemStore/MemGrow/GlobalGet/
GlobalSet/CallIndirect` are **side-effecting** — the future optimizer must not CSE/reorder/
DCE across them.

---

## B. The cell state ABI (`«CELL-STATE-ABI-FROZEN»`)

**E1: state lives in the instance process's dictionary, under one fixed namespaced key,
holding an opaque `{mem, globals, table}` record.** Freeze these as **stub modules** (public
signatures, `todo` bodies; units 03/04/05 fill them):

```gleam
//// src/twocore/runtime/rt_state.gleam — the per-instance cell holder (owner: unit 03).
//// One-instance-one-process: the instance's memory/globals/table live in THIS process's
//// dictionary under a single fixed key. The harness/linker (unit 11) runs instantiate +
//// every invoke of an instance in one owned process. Fail-closed: ops on an un-seeded cell
//// trap, never read garbage. State is opaque to rt_state (rt_mem owns the mem shape, etc.).
import gleam/dynamic.{type Dynamic}
// InstanceState holds the per-layer values OPAQUELY (as Dynamic) so rt_state does NOT import
// rt_mem/rt_table (no circular import). rt_mem/rt_table own their value shapes and coerce.
pub type InstanceState {
  InstanceState(mem: Dynamic, globals: Dict(String, Int), table: Dynamic)
}

/// What the generated instantiate entry passes to seed: the FRESH mem/table values (built by
/// rt_mem.fresh / rt_table.new — rt_state does not construct them, preserving opacity) plus the
/// initial globals (raw bits). seed seeds the single fixed namespaced cell for THIS process,
/// resetting any prior state (one-instance-one-process).
pub type StateDecl {
  StateDecl(mem: Dynamic, globals: List(#(String, Int)), table: Dynamic)
}

pub fn seed(decl: StateDecl) -> Nil { todo }   // fresh cell for this process (resets prior)
pub fn clear() -> Nil { todo }                 // drop the cell (between instances)
// Typed opaque accessors so rt_mem/rt_table read+write their field without importing rt_state's
// neighbours. Fail-closed: accessing an UN-SEEDED cell is an INTERNAL invariant violation (NOT a
// WASM TrapReason — it is unreachable under the one-instance-one-process harness contract); raise
// a distinct internal error (node-safe process crash), never read garbage.
pub fn mem_get() -> Dynamic { todo }
pub fn mem_put(mem: Dynamic) -> Nil { todo }
pub fn table_get() -> Dynamic { todo }
pub fn table_put(table: Dynamic) -> Nil { todo }
pub fn global_get(name: String) -> Int { todo }   // raw bit pattern
pub fn global_set(name: String, value: Int) -> Nil { todo }
```

```gleam
//// rt_mem.gleam (owner: unit 04) — the `paged` memory + the `rebuild` oracle. Operates on
//// the mem field of the process cell. ea = addr(unsigned) + offset as a BIGNUM (no wrap);
//// trap iff ea+bytes > byte_len; multi-byte store traps BEFORE any write.
/// Build a FRESH opaque Mem of `min_pages` zero-filled pages. `safe_cap` (a finite Safe
/// max-pages cap, single-sourced — see §E3) is baked into the Mem so `grow` enforces it
/// without threading a profile through generated code. Returned opaque (Dynamic) for the cell.
pub fn fresh(min_pages: Int, max_pages: Option(Int), safe_cap: Int) -> Dynamic { todo }
// load/store/size/grow/init_data operate on THIS process's cell (read via rt_state.mem_get,
// write the new Mem via rt_state.mem_put) — handle stays hidden in the cell:
pub fn load(bytes: Int, signed: Bool, result_width: Int, addr: Int, offset: Int)
  -> Result(Int, TrapReason) { todo }
pub fn store(bytes: Int, addr: Int, value: Int, offset: Int) -> Result(Nil, TrapReason) { todo }
pub fn size() -> Int { todo }                                 // pages
pub fn grow(delta: Int) -> Int { todo }                       // prev pages, or -1 past max/cap
pub fn init_data(offset: Int, bytes: BitArray) -> Result(Nil, TrapReason) { todo }  // at instantiate
```

```gleam
//// rt_table.gleam (owner: unit 05) — funcref table + the 3-fault fail-closed call_indirect.
//// Dispatch via BUILD-CONTROLLED closures populated from element segments — NEVER a
//// data-driven apply(Module,Fun,Args). Guards in order: bounds → null → exact type.
/// Build a FRESH opaque Table of `min` null slots (returned opaque for the cell). rt_state
/// cannot construct it (it does not import rt_table), so the instantiate entry calls this.
pub fn new(min: Int, max: Option(Int)) -> Dynamic { todo }
// Each entry is TYPE-TAGGED: a #(FuncType, closure) — the closure is build-controlled (emit_core
// passes each element function's IR FuncType + a closure over the generated function). The type
// tag is what call_indirect's guard 3 matches.
pub fn init_elem(offset: Int, entries: List(#(FuncType, fn(List(Int)) -> List(Int))))
  -> Result(Nil, TrapReason) { todo }   // OOB → TableOutOfBounds (at instantiation)
pub fn call_indirect(index: Int, expected_type: FuncType, args: List(Int))
  -> Result(List(Int), TrapReason) { todo }
```

Extend `Binding` (`instance.gleam`) with `mem_module`, `table_module`, `state_module` and
populate them in `safe_default` (and `profiles.safe`) with
`"twocore@runtime@rt_mem"`/`"…@rt_table"`/`"…@rt_state"`.

### The emit_core state-access seam (the convention unit 10 implements)

Every stateful op lowers through **one** emit_core helper (so the Phase-3 threaded retrofit is
a seam expansion, not a rewrite). For the cell strategy it emits a direct
`call '<binding.X_module>':'op'(args)`:

| IR node | Emitted call (cell) | Result handling |
|---|---|---|
| `MemLoad` | `call '<mem_module>':'load'(Bytes, Signed, W, Addr, Off)` | `{ok,V}`/`{error,R}` → `case`, raise on error |
| `MemStore` | `call '<mem_module>':'store'(Bytes, Addr, Val, Off)` | `{ok,_}`/`{error,R}`; sequenced `let _ = … in …` |
| `MemSize` | `call '<mem_module>':'size'()` | bare i32 |
| `MemGrow` | `call '<mem_module>':'grow'(Delta)` | bare i32 |
| `GlobalGet` | `call '<state_module>':'global_get'(Name)` | bare value |
| `GlobalSet` | `call '<state_module>':'global_set'(Name, Val)` | sequenced effect |
| `CallIndirect` | `call '<table_module>':'call_indirect'(Idx, Type, Args)` | `{ok,V}`/`{error,R}` → `case`, raise |
| trapping `Convert` (TruncS/U) | `call '<num_module>':'i32_trunc_f32_s'(A)` | **`{ok,_}`/`{error,R}` → `case`, raise** (NOT a bare call) |

**Effect sequencing (freeze it):** zero-result effects (`MemStore`, `GlobalSet`) lower to an
ordered `let _ = <effect> in <rest>` and must NOT be dead-code-eliminated or reordered; for
`MemStore` the evaluation order is **addr, then value, then store**. Generated code never does
a data-driven `apply` of a program-chosen module/atom (the D3a invariant extends to the new
ops; unit 10's structural security test checks it).

---

## C. The instantiation contract (E5 — freeze it; units 10 & 11 implement)

Phase-1's run-ABI is `load → apply`. Phase-2 is **`load → instantiate → invoke`**:

- The backend (unit 10) emits a generated **`instantiate/0`** function that runs, **in WASM
  spec order**, inside the instance's owned process: (1) **seed** the fresh cell —
  `rt_state:seed(StateDecl(mem, globals, table))` where `mem = rt_mem:fresh(min, max, safe_cap)`
  (declared `min` zero pages) and `table = rt_table:new(min, max)` (the entry builds them;
  rt_state just stores them — preserving opacity), and `globals` are the (constant) inits;
  (2) write each active **element** segment via `rt_table:init_elem` (bounds-check →
  `TableOutOfBounds` trap-at-instantiation); (3) write each active **data** segment via
  `rt_mem:init_data` (bounds-check → `MemoryOutOfBounds` trap); (4) run the **start** function
  (its trap fails instantiation). Returns `ok` or the instantiation trap. **(Order is element
  → data per the spec — observationally identical to data→element except which trap fires when
  both are OOB.)**
- Phase-2 const-init exprs are **constant literals** (`t.const`) — imported-global init is
  deferred with imports (E7). The lowering (unit 09) reduces init exprs to IR `Value`s.
- The run-ABI change (unit 11): `pipeline.gleam` and the conformance `Driver` do `load →
  instantiate → invoke`; the `Instance` carries the per-instance process context; **one
  instance = one process** (the harness spawns/owns a process per instance and runs
  instantiate + all its invokes there), so the cell is naturally isolated and reset per
  instantiation. Two instantiations must never observe each other's state (tested).

---

## D. `«RTNUM2-SIG-FROZEN»` — new `rt_num` signatures (`todo` bodies; unit 06 fills)

Freeze the names so unit 06 (bodies) and unit 10 (the `NumOp/ConvOp → fn-name` map) don't
race. Per width `w ∈ {f32, f64}` (operands & results are raw IEEE bit-pattern `Int`s):

- Unary → `Int`: `w_abs`, `w_neg`, `w_ceil`, `w_floor`, `w_trunc`, `w_nearest`, `w_sqrt`.
- `w_copysign(a, b) -> Int`.
- Comparisons → `Int` (i32 0/1): `w_eq`, `w_ne`, `w_lt`, `w_gt`, `w_le`, `w_ge`.
- **Trapping** float→int → `Result(Int, TrapReason)`: `i32_trunc_f32_s`, `i32_trunc_f32_u`,
  `i32_trunc_f64_s`, `i32_trunc_f64_u`, `i64_trunc_f32_s` … `i64_trunc_f64_u` (8).
- int→float → `Int`: `f32_convert_i32_s/u`, `f32_convert_i64_s/u`, `f64_convert_i32_s/u`,
  `f64_convert_i64_s/u` (8).
- `f32_demote_f64(a) -> Int`, `f64_promote_f32(a) -> Int`.

(The integer conversions `i32_wrap_i64`/`i64_extend_i32_s/u`/`*_reinterpret_*` already exist
in `rt_num`; E7's gap is that the **decoder** lacks their opcodes, not rt_num.)

---

## Verification (Definition of Done for unit 01)

- `gleam build` compiles with **zero warnings** (stub/`todo` bodies are fine for the new
  runtime fns and rt_num float fns; everything else — printer/parser/emit_core/rt_trap/
  profiles exhaustive matches, all Binding constructors — compiles green).
- `gleam format --check src test` clean; **`gleam test` stays green (≥313)** — the freeze must
  not break Phase-1 behavior.
- Hand-write (in a scratch test) one IR2 `Module` that uses `tables`/`elements`/`MemSize`/
  `MemGrow`/a sign-extending `MemLoad`/a float comparison/a trapping `TruncS`, and confirm it
  typechecks — proving the types express the Phase-2 surface before anyone builds on them.
- `ir2-grammar-delta.md` describes the textual spelling of every new variant (unit 02
  implements it).
- Announce `«IR2-FROZEN»` / `«CELL-STATE-ABI-FROZEN»` / `«RTNUM2-SIG-FROZEN»` in `state.md`
  with the cross-file reaches (rt_trap, profiles) listed.

## What this unit leaves

- 02 extends the `.ir` printer/parser; 06 fills rt_num float bodies; 03/04/05 implement the
  cell/mem/table runtime against the frozen stub signatures; 10 builds emit_core against the
  frozen IR2 + seam + instantiation contract (in parallel with 03–06); 07→08/09 build the
  frontend; 11 wires the run-ABI + Safe profile + conformance.

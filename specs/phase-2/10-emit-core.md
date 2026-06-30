# Unit 10 — `emit_core` extension + the `instantiate` entry

> **One owner. Wave B, runs IN PARALLEL with the runtime units 03–06.** Depends on
> **FREEZES ONLY** — `«IR2-FROZEN»` + `«CELL-STATE-ABI-FROZEN»` + `«RTNUM2-SIG-FROZEN»`
> (all from P2-01). You need the runtime *signatures*, not their bodies, so do not
> serialize behind 03/04/05/06. This is a long pole — start the day the freezes land.
> Read [`00-overview.md`](00-overview.md) (E1–E8) and [`01-interface-freeze.md`](01-interface-freeze.md) first.

---

## Context

`emit_core` is the backend and the **binding chokepoint** (D3b): it walks an `ir.Module`
and produces a `core_erlang.CModule`, resolving every runtime reference to a fixed
`call '<binding.X_module>':'<fn>'(...)`. Phase 1 left seven IR nodes as
`Error(UnsupportedNode(...))` (emit_core.gleam:333–338) — the stateful ops and table
dispatch — because the Phase-1 corpus is pure (D3d, no mutable instance state). Phase 2
introduces mutable instance state via the tier-O **cell** strategy (E1): generated
function *arities are unchanged*, but bodies that touch memory/globals/tables now
**read+write the per-instance process-dictionary cell** through the runtime layers. Your
job is to lower those nodes and the new float ops, and to emit the generated
**`instantiate/0`** entry that seeds and initializes the cell.

The cell handle never appears in the IR or in a generated function signature — it lives
behind the runtime modules. That is the whole point of routing every stateful op through
**one emit_core state-access seam**: the deferred Phase-3 `threaded` build is then a *seam
expansion*, not a scattered rewrite (E1).

## Goal

Lower `MemLoad`/`MemStore`/`MemSize`/`MemGrow`/`GlobalGet`/`GlobalSet`/`CallIndirect` and
the new float `NumOp`/`ConvOp` variants to Core Erlang through the frozen state-access
seam, and emit the generated `instantiate/0` entry per the frozen instantiation contract —
completing the backend for stateful WASM. Extend the structural codegen-security test so
the new authority is proven fail-closed and free of ambient authority.

## Files owned

- `src/twocore/backend/emit_core.gleam` — **EXTEND (single owner).** Replace the seven
  `UnsupportedNode` arms; add the new `NumOp`/`ConvOp` name mappings; add the
  `instantiate/0` emitter.
- `test/twocore/backend/emit_core_test.gleam` — golden/AST-shape tests (EXTEND).
- `test/twocore/backend/emit_core_security_test.gleam` — the structural security-invariant
  test (EXTEND; today its `call_indirect_does_not_lower_test` asserts the *old*
  `UnsupportedNode` behavior — rewrite it to assert the new dispatch is ambient-safe).
- `test/twocore/backend/emit_core_e2e_test.gleam` — hand-built IR2 → build → instantiate →
  run end-to-end tests (EXTEND; green only once 03–06 land — see Concurrency).

## Depends on (freeze milestones)

| Freeze | From | What you take | Stub against meanwhile |
|---|---|---|---|
| `«IR2-FROZEN»` | P2-01 | `tables`/`elements` on `Module`; `MemSize`/`MemGrow`; `MemLoad`'s `result: ValType`; the 14 float `NumOp`s; the 6 new `ConvOp`s; the 3 new `TrapReason`s. | The `01` types compile day 1 — build directly on them. |
| `«CELL-STATE-ABI-FROZEN»` | P2-01 | `Binding.mem_module`/`table_module`/`state_module`; the seam convention table; the `rt_state`/`rt_mem`/`rt_table` stub signatures; the instantiation contract. | The stub modules have `todo` bodies — emit the calls against their *signatures*; e2e waits on 03/04/05. |
| `«RTNUM2-SIG-FROZEN»` | P2-01 | The new `rt_num` float/convert function names. | `todo` bodies (unit 06) — your name map needs only the heads. |

## Scope — in / out for Phase 2

**In:** lowering the seven stateful/table nodes + the new float ops; the trapping-convert
`case`/`raise` wiring; the zero-result ordered-effect lowering; the `instantiate/0` entry;
the extended security test; hand-built-IR2 e2e.

**Out (do not build):**
- The **`threaded` tier-P calling convention** (E1/E8 — Phase 3). Your seam keeps function
  arities unchanged; do **not** thread a state param, do **not** add a loop-carried handle.
- `cerl_ast` emit format (still `core_text` via unit 03).
- The **run-ABI / harness / Safe-profile wiring** (unit 11 owns `pipeline.gleam`, the
  conformance `Driver`, the max-pages cap, one-instance-one-process spawning). You only
  *emit* `instantiate/0`; unit 11 calls it in the instance process.
- Decoding/validating/lowering the new ops (units 07/08/09). You consume IR2; you do not
  produce it. Imports, reftypes, bulk memory, multi-memory, SIMD, WAT, the optimizer, and
  Unsafe are **Phase-3 deferrals** (E8) — do not reach for them.

## Deliverables

### 1. The one state-access seam

All stateful lowering routes through a single helper so Phase-3 is a seam expansion:

```gleam
/// Emit a direct call to a fixed runtime module field of the Binding (the cell seam).
/// `module` is one of ctx.binding.{mem_module,table_module,state_module,num_module} —
/// always a build-controlled `twocore@runtime@*` atom (D3a). Never a program value.
fn seam_call(module: String, fn_name: String, args: List(CExpr)) -> CExpr {
  core_erlang.CCall(CAtom(module), CAtom(fn_name), args)
}
```

Dispose its result with one of three shared shapes (factor the trapping shape out of the
existing `emit_num` so MemLoad / trapping converts / CallIndirect reuse it):

- **bare value** → `apply_cont(cont, [seam_call(...)], …)`.
- **trapping `Result`, one value** → the verified `case`-and-`raise` already in `emit_num`:
  bind one fresh var to a `case` whose `{ok,X}` arm yields `X` and whose `{error,E}` arm
  yields `raise_trap(ctx, E)`, then thread that single var through `cont`. (Both arms must
  yield exactly one value or the Core compiler rejects "return count mismatch" — see the
  long comment at emit_core.gleam:495–503.)
- **zero-result ordered effect** → `let <g> = <effect> in <rest>`, `g` discarded, `<rest>`
  emitted under `cont` with **zero** values; **non-DCE, non-reorderable** (E6). For an
  effect that can also trap (`MemStore`), `<effect>` is the trapping `case` reduced to a
  single discardable value (`{ok,_}` → `'ok'`, `{error,E}` → `raise`).

### 2. The arm-by-arm lowering (the frozen convention table — §B of `01`)

`W(result)` = 32 for `TI32`/`TF32`, 64 for `TI64`/`TF64` (raw-bits rep: `f32.load` ==
`i32.load` byte-wise — a load needs only width+sign, not float-vs-int). `bytes` =
`op.bytes`; `Off` = `CInt(offset)`.

| IR node | Emitted (cell seam) | Disposition |
|---|---|---|
| `MemLoad(MemAccess(bytes,signed), addr, offset, result)` | `call '<mem_module>':'load'(bytes, signed, W(result), Addr, Off)` | trapping `Result` → 1 value |
| `MemStore(MemAccess(bytes,_), addr, value, offset)` | `call '<mem_module>':'store'(bytes, Addr, Val, Off)` | zero-result ordered effect (`{ok,_}`/`{error,R}`) |
| `MemSize` | `call '<mem_module>':'size'()` | bare i32 |
| `MemGrow(delta)` | `call '<mem_module>':'grow'(Delta)` | bare i32 |
| `GlobalGet(name)` | `call '<state_module>':'global_get'(NameBin)` | bare value |
| `GlobalSet(name, value)` | `call '<state_module>':'global_set'(NameBin, Val)` | zero-result ordered effect (pure — no trap) |
| `CallIndirect(table, index, ty, args)` | `call '<table_module>':'call_indirect'(Idx, TypeTag, ArgList)` | trapping `Result` → unpack `len(ty.results)` values |
| `Convert(TruncS/TruncU, a)` | `call '<num_module>':'<name>'(A)` | **trapping `Result` → 1 value** (NOT a bare call) |

- `op.signed` is **irrelevant for `MemStore`** — `storeN` writes only the low N bits
  (`<<V:(bytes*8)/little>>` wraps); document that you ignore it.
- `NameBin` = the global name as a **Core binary string literal** (`CBinary` of UTF-8
  segments, e.g. `<<"g0"/utf8>>`) — the frozen `rt_state.global_get(name: String)` takes a
  Gleam `String` (a BEAM binary), **not** an atom. The Phase-1 printer already prints
  `CBinary` (core_printer.gleam:160) — reuse it.
- **`MemStore` evaluation order is addr, then value, then store** (freeze it). Args are
  already atomic `Value`s in ANF, so order falls out of left-to-right `call` arg order;
  the store itself is the single effect and must be sequenced before `<rest>`.

### 3. `CallIndirect` — the 3-fault, ambient-free dispatch

The runtime type-check and the three traps live **inside `rt_table:call_indirect`** (unit
05), in spec order: index-in-bounds (else `UndefinedElement`), slot-non-null (else
`UninitializedElement`), exact structural `FuncType` match (else
`IndirectCallTypeMismatch`). emit_core emits only:
- at the **call site**: `seam_call(table_module, "call_indirect", [Idx, TypeTag, ArgList])`,
  where `TypeTag` is a **build-controlled, compile-time** structural encoding of `ty`
  (emit a canonical Core term — e.g. `{[paramtype-atoms…], [resulttype-atoms…]}`), and
  `ArgList` is `core_list(args)`. The success value is the callee's packaged return
  (`function_return` shape); unwrap `{ok,V}`→`V`, bind, then dispose via the
  multi-value-unpacking continuation (`apply_cont_call`-style with `r = len(ty.results)`).
- in the **`instantiate/0` entry** (below): each element-segment entry becomes a
  **build-controlled closure** `fun(A…) -> apply 'f<idx>'/arity(A…)` (a `CFun` wrapping a
  static `CApply` over a compile-time-fixed module-local name), passed to
  `rt_table:init_elem`. **The integer index is the only runtime data; the module/function
  names are compile-time literals** — this is the D3a invariant for the new authority.

> The slot's stored entry must carry its structural type so `rt_table` can do the step-3
> check. The frozen `init_elem(offset, funcs: List(fn() -> Nil))` stub shows only closures;
> emit_core must emit each entry **paired with its `TypeTag`** (co-design the entry shape
> with unit 05 — see "inconsistency" note at the end). Never store program-derived
> module/atom values.

### 4. The new `NumOp` / `ConvOp` name mappings

Extend `num_op_name/1` (all bare `Int`, route through `num_module`):
`FAbs`→`f{w}_abs`, `FNeg`→`_neg`, `FCeil`→`_ceil`, `FFloor`→`_floor`, `FTrunc`→`_trunc`,
`FNearest`→`_nearest`, `FSqrt`→`_sqrt`, `FCopysign`→`_copysign`, `FEq`→`_eq`, `FNe`→`_ne`,
`FLt`→`_lt`, `FGt`→`_gt`, `FLe`→`_le`, `FGe`→`_ge` (where `{w}` ∈ `f32`/`f64`). These stay
out of `is_trapping` (all total).

Extend the convert path. **Bare** (route through `num_module`, no trap):
`ConvertS(from,to)`→`f{to}_convert_i{from}_s`, `ConvertU`→`…_u`,
`F32DemoteF64`→`f32_demote_f64`, `F64PromoteF32`→`f64_promote_f32`.
**Trapping** (`TruncS`/`TruncU` — `Result(Int, TrapReason)`):
`TruncS(from,to)`→`i{to}_trunc_f{from}_s`, `TruncU`→`…_u`. Add a predicate
`is_trapping_conv(op)` and emit these through the trapping shape (like `IDivS`), **not** a
bare call. Every name must match `«RTNUM2-SIG-FROZEN»` exactly.

### 5. The `instantiate/0` entry (the frozen instantiation contract — §C of `01`)

Emit one extra top-level `FunDef` `'instantiate'/0` and **add it to the module export
list**, whose body runs, **in this spec order**, inside the instance's owned process:

1. `let <_> = call '<state_module>':'seed'(Decl) in …` — seed a **fresh** zeroed memory
   (`memory.min_pages`), empty table (`table.min`), and globals set from their **constant**
   inits. `Decl` is a build-controlled Core literal you construct from the IR `Module`
   (mem min/max, table min, and `[{NameBin, InitBits}…]` for globals). Phase-2 global
   inits are constant literals — constant-fold each `GlobalDecl.init` to a bit-pattern
   `Int`; reject a non-constant init with a typed `EmitError` (do not emit arbitrary code
   into the decl).
2. for each active **data** segment: `call '<mem_module>':'init_data'(Off, Bytes)` →
   trapping `Result` → `case`/`raise` (**trap at instantiation** on OOB). `Bytes` = the
   `BitArray` as a `CBinary` literal; `Off` = the constant-folded offset.
3. for each active **element** segment: `call '<table_module>':'init_elem'(Off, Entries)`
   → trapping `Result` → `case`/`raise`. `Entries` = the build-controlled
   `{TypeTag, Closure}` list (§3).
4. run the **start** function: `let <_> = apply 'f<start>'/0 () in 'ok'` — a trap inside
   propagates (raises) and **fails instantiation**.

Sequence steps 1–4 as ordered, non-DCE effects (each trapping step is a `case`/`raise`
reduced to one discardable value, then `let`-bound). The body returns `'ok'` on success;
any step's trap raises an error-class exception that unit 11's harness catches as an
instantiation trap. (`instantiate/N` with N>0 is the general form; **Phase 2 is N=0** —
imports deferred, E7.)

## Grounded facts you MUST honor

- **No-wrap effective address is the runtime's job, not yours.** You pass `(bytes, signed,
  W, addr, offset)` straight through; `rt_mem` computes `ea = unsigned(addr) + offset` as a
  bignum and traps iff `ea + bytes > byte_len` (spec: "out of bounds memory access",
  strictly greater; an access ending exactly at `byte_len` is in-bounds). Do **not**
  pre-mask, pre-add, or pre-check addresses in emit_core — that would duplicate (and could
  contradict) the security boundary. Multi-byte stores trap **before any write**
  (all-or-nothing) — which is why `MemStore` is a trapping `Result`, never a bare effect.
  (`exec/instructions.html`, `exec/memory`.)
- **The three `call_indirect` faults are distinct and ordered** (bounds → null → type) with
  spec messages "undefined element" / "uninitialized element" / "indirect call type
  mismatch" (`UndefinedElement` / `UninitializedElement` / `IndirectCallTypeMismatch`).
  emit_core does not order them — it emits one seam call and lets `rt_table` fault — but the
  TrapReasons must round-trip through `raise_trap`. (`exec/instructions.html`,
  webassembly.org/docs/security.)
- **`MemLoad` needs `result` to disambiguate `i32.load8_s` from `i64.load8_s`** — same
  `bytes`+`signed`, different result bit pattern; the sign-extension target width is
  `W(result)`. (E2; `01` §A open-question, resolved to `result: ValType`.) Confirm both walk
  to distinct `_s` widths in a test.
- **Trapping converts vs total converts** (`exec/numerics.html`): `trunc_f*_s/u` trap
  "invalid conversion to integer" (`InvalidConversionToInteger`) on NaN/±Inf and "integer
  overflow" (reuse `IntOverflow`) when the truncated value is out of the target range
  `[-2^(N-1), 2^(N-1)-1]` (signed) / `[0, 2^N-1]` (unsigned). `convert_i*_s/u`,
  `demote`, `promote` **never trap** (total → bare call). emit_core must encode this
  distinction in `is_trapping_conv`; getting it wrong either drops a mandated trap or wraps
  a total op in a spurious `case`.
- **Floats are raw bit patterns end-to-end** (D5). `f32/f64` constants, global inits, and
  data bytes are `Int` bit patterns; never emit a `CFloat`. `abs`/`neg`/`copysign` preserve
  NaN payloads (the rt_num bodies handle this — you only emit the call).
- **No ambient authority (D3a) extends to every new op.** Every emitted `CCall` targets a
  fixed `binding.*_module` atom with a literal function atom. `CallIndirect` dispatch is a
  closed compile-time set of `f<idx>` closures selected by a runtime integer — **never**
  `apply(Mod, Fun, Args)` with `Mod`/`Fun` from table/runtime data. (E3; high-level §5.)
- **Generated functions stay pure-arity but effectful** (E1/E6): the cell makes the bodies
  side-effecting, but you add **no** parameter and **no** loop param. pdict get/put are
  ordinary reduction-consuming ops, so the verified constant-space tail loop is unchanged
  (rt_meter already proved a per-iteration pdict mutation stays constant-space). The
  optimizer (Phase 3) must treat these ops as memory barriers — out of scope, but do not
  emit anything that assumes reorderability.

## Verification — Definition of Done (D8)

Tests assert **WASM-spec behavior**, not whatever the code emits — no change-detector
tests. Cite the spec section in each test.

1. **Golden AST-shape tests** (`emit_core_test`), one per new construct, asserting the
   *structure* (not a brittle string): `MemLoad` → a `case` over `call mem:load/5` raising
   on `{error,_}`; `MemStore` → an ordered `let`-discard wrapping a `case` over
   `call mem:store/4`; `MemSize`/`MemGrow` → bare `call mem:size/0` / `mem:grow/1`;
   `GlobalGet`/`GlobalSet` → `call state:global_get/1` (binary-name arg) / a `let`-discard
   over `state:global_set/2`; `CallIndirect` → a `case` over `call table:call_indirect/3`
   with a compile-time `TypeTag`; a trapping `TruncS` → the `case`/`raise` shape; a total
   `ConvertS`/`Demote`/`Promote` → a bare `num_module` call.
2. **The `instantiate/0` golden**: assert the emitted body sequences `seed` → `init_data*`
   → `init_elem*` → start-apply in order, that each init step is a `case`/`raise`
   (trap-at-instantiation), that element entries are `CFun`-wrapped static `f<idx>`
   `CApply`s (no dynamic apply), and that `instantiate/0` is exported.
3. **The structural security-invariant test extended & green** (`emit_core_security_test`):
   build a module exercising `call_indirect` + every memory/global/table op, then walk the
   emitted AST and assert (a) **every `CCall` module position is a fixed `Binding` runtime
   atom and every function position is a literal atom** — extend `runtime_modules` to
   include `mem_module`/`table_module`/`state_module`; (b) **no `CApply` targets a
   non-compile-time name** (every apply is an `FName` literal — `call_indirect`/mem/table
   never lower to a data-driven apply of a non-runtime module); (c) the three
   `call_indirect` fault TrapReasons each reach `rt_trap` via the emitted dispatch (assert
   the `TypeTag`/seam call is present and the faults are delegated to `table_module`).
   Replace the obsolete `call_indirect_does_not_lower_test` (it asserts the old
   `UnsupportedNode`).
4. **End-to-end** (`emit_core_e2e_test`; green once 03–06 land — see Concurrency): hand-build
   IR2 → `emit_module` → `build_beam` → call `instantiate/0` in a process → invoke an
   export, asserting spec-correct results:
   - a store-then-load round-trip (`i32.store` then `i32.load`; a `load8_s`/`load16_u`
     width with the right sign-extension per `exec/memory`);
   - a growable module: `memory.grow` returns the **old** size, then a load of the grown
     (zero-filled) region returns `0`; grow past the Safe cap returns `-1`
     (`memory.grow` semantics);
   - a mutable global round-trips `global.set`/`global.get`;
   - a `call_indirect` to the right type runs, and **each of the three faults traps** with
     the spec message (`UndefinedElement` for OOB index, `UninitializedElement` for a null
     slot, `IndirectCallTypeMismatch` for a wrong type) — never via a data-driven apply;
   - a trapping `i32.trunc_f32_s` traps "invalid conversion to integer" on NaN and "integer
     overflow" out of range, while the in-range case returns the truncated integer;
   - an out-of-bounds active **data** (and **element**) segment traps **at instantiation**.
5. **`gleam format --check src test` clean; `gleam build` ZERO warnings; `gleam test` stays
   green (≥313, none regressed).** Every new public/private function carries a doc comment
   stating its contract (D8).

**Proof of goal:** the e2e suite is the proof — a stateful WASM module hand-built as IR2
compiles, instantiates, and runs spec-correctly on the BEAM, with all the new traps
fail-closing and the security walk green.

## Concurrency

- **Sub-task A (no runtime needed):** the seam + arm lowerings + float name maps + the
  `instantiate/0` emitter + the AST-shape goldens + the security test. These build against
  the **frozen signatures alone** — start immediately, do not wait for 03/04/05/06.
- **Sub-task B (gated on 03+04+05+06 landing):** the e2e suite. Stub or `@pending` it until
  the runtime bodies exist; the moment they do, flip it on. Keep A's goldens passing
  meanwhile so a regression in your emission is caught without the runtime.
- **Must be frozen before you start:** `«IR2-FROZEN»`, `«CELL-STATE-ABI-FROZEN»` (esp. the
  `Binding` fields + the `rt_state`/`rt_mem`/`rt_table` stub signatures + the seam table +
  the instantiation contract), `«RTNUM2-SIG-FROZEN»`. If any is still a strawman, sync when
  the real freeze lands. Coordinate the **element-entry shape** (`{TypeTag, Closure}`) and
  the **`seed` `Decl` term shape** with unit 05 / unit 03 respectively, since you emit what
  they consume.

## What this leaves for others

- **Unit 11 (capstone):** the run-ABI (`load → instantiate → invoke`), the conformance
  `Driver`, one-instance-one-process spawning, the Safe-profile max-pages cap, and the
  Phase-2 `.wast` allowlist. You hand it an exported `instantiate/0`; it owns calling it in
  the instance process and the cross-invoke persistence/isolation tests.
- **Units 03/04/05/06:** the cell/mem/table/float **bodies** behind your seam calls — your
  e2e suite is their integration check.
- **Phase 3:** the `threaded` tier-P calling convention is a *seam expansion* of the helper
  you built — a new `state_strategy` config in this one chokepoint, IR unchanged.

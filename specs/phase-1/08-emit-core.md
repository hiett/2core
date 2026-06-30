# Unit 08 — `emit_core` — IR → Core Erlang (the backend & binding chokepoint)

> **One unit, splittable into ~2 agents. Wave B, but a *longest pole* — start the moment
> «IR-FROZEN» + «CORE-AST» land (against the strawman if needed).** Freeze deps:
> «IR-FROZEN», «CORE-AST» (unit 03), «ABI-FROZEN», «RTNUM-SIG-FROZEN». Read
> [`00-overview.md`](00-overview.md) first; this doc assumes D1–D10.

---

## Context

This is the **backend**: it lowers a shared-IR `Module` into a Core Erlang AST
(unit 03's types), which unit 04 (`build_beam`) compiles to a loadable `.beam`. It is
the proven structured-control → `letrec`-of-tail-recursive-functions machinery
(high-level §5), and it is **uniform across frontends because the IR is** — nothing here
knows about WASM. It is also **the binding chokepoint (D3b)**: *every* runtime reference
(numerics, traps, host, charge) resolves to a concrete `call` here and nowhere else. See
[`00-overview.md`](00-overview.md) §4 for file ownership and D3 for the binding rules; do
not re-derive them.

## Goal

Implement `emit_module(ir.Module, Binding) -> Result(core_erlang.CModule, EmitError)`
such that the three acceptance programs (`add`, `sum_to`, `fib`) and a `div`-by-zero trap
compile, load, and run on the BEAM with **spec-correct results**, and `sum_to` runs in
**constant space** (a tail-recursive `letrec` loop). Measurable: golden `.core` per
control construct + end-to-end run via `build_beam` + the codegen security-invariant test
all green.

## Files owned

- `src/twocore/backend/emit_core.gleam` — the lowering + the binding chokepoint.
- `test/twocore/backend/emit_core_test.gleam` — golden `.core` tests + the
  PascalCase→snake_case wrapper golden + the Gleam-mangling golden.
- `test/twocore/backend/emit_core_security_test.gleam` — the codegen security-invariant
  test (structural assertion over the emitted AST).
- `test/twocore/backend/emit_core_e2e_test.gleam` — end-to-end via unit 04's `build_beam`.

No "freeze day 1" stub is required *from* this unit; you consume others' frozen stubs.

## Depends on

| Milestone / unit | What it gives you | Stub against meanwhile |
|---|---|---|
| `«IR-FROZEN»` (`ir.gleam`) | the `Module`/`Expr`/`NumOp`/… you pattern-match | the §"IR strawman" in [`01`](01-interface-freeze.md) |
| `«CORE-AST»` (unit 03, `backend/core_erlang.gleam`) | the target AST node types (`CModule`, `CExpr`, …) | published **day 1 of 03** |
| `«ABI-FROZEN»` (`instance.gleam`) | the `Binding` record (module-name strings) + the calling convention table | `safe_default()` in [`01`](01-interface-freeze.md) |
| `«RTNUM-SIG-FROZEN»` (`rt_num.gleam`) | the exact `i32_add`/`i32_div_s`/… names + Result-vs-Int shape | the signature list in [`01`](01-interface-freeze.md) |
| unit 04 (`build_beam` + `«FFI-SHIM»`) | compile + `code:load_binary` for e2e tests | needed only for the e2e suite, not for golden `.core` tests |

You can build and golden-test the **entire IR→`.core` boundary** with only «IR-FROZEN» +
«CORE-AST» + «ABI-FROZEN» + «RTNUM-SIG-FROZEN». The e2e suite waits on 04/06/09.

## Scope — in / out for Phase 1

**In:**
- Lower every `Expr` the Phase-1 corpus exercises: `Let`, `Values`, `Num` (pure +
  trapping), `Block`/`Break`, `Loop`/`Continue`, `If`, `Switch`, `Return`, `CallDirect`,
  `CallHost`, `Trap`, `Charge`.
- The binding chokepoint: one mapping table from IR runtime ops → concrete
  `call 'twocore@runtime@*':'fn'(...)`, driven by the `Binding`.
- The `NumOp → rt_num` function-name table (must match the frozen `rt_num` names).
- An alpha-rename/gensym pass producing Core-legal, per-scope-unique variable names.
- The PascalCase→snake_case constructor-atom wrapper (for `TrapReason` and any 0-field
  constructor literal you must emit).

**Out (Phase 1 — keep deferred):**
- The `cerl_ast` emitter format (D9 / high-level §5) — emit `core_text` AST only.
- `state_strategy = cell` — there is **no mutable instance state** in Phase 1 (D3d);
  generated functions are **pure** and thread **no runtime record**.
- `MemLoad`/`MemStore`/`GlobalGet`/`GlobalSet`/`Convert`(memory)/`TermOp` lowering — no
  such IR nodes are exercised (the corpus uses **no memory**); `Error(EmitError)` is the
  correct response if one appears, not a panic.
- `CallIndirect` lowering — **may be stubbed** (no Phase-1 corpus uses it); return a typed
  `Error`. **`CallHost` MUST be fully lowered** (the capability boundary is exercised
  end-to-end, D9).
- Metering may lower to a **no-op-ish `charge` call**, but **the seam MUST exist** (D9):
  `Charge` lowers to a real `call '<meter_module>':'charge'(Cost)`; the *impl* being a
  fuel counter is unit 09's job.

## Deliverables

```gleam
/// Lower a shared-IR module to a Core Erlang module AST (unit 03's CModule), resolving
/// every runtime reference through `binding` (D3b). Returns Error(EmitError) for any IR
/// node outside the Phase-1 lowering surface (e.g. CallIndirect, memory ops) — never a
/// panic. `binding` carries the Gleam→Erlang-mangled runtime module-name strings.
pub fn emit_module(module: ir.Module, binding: Binding) -> Result(CModule, EmitError)
```

`EmitError` is **this stage's own error type (D4)** — not a shared enum. Suggested
variants: `UnsupportedNode(node: String)` (call_indirect / memory / term ops),
`ArityMismatch(expected: Int, got: Int)` (a `Let`/value-list width clash),
`UnboundLabel(String)`, `UnknownFunction(String)`.

### Per-construct lowering (the algorithm shape — do not re-derive the design)

A `Function(name, FuncType(params, results), locals, body)` emits a top-level Core
definition `'name'/arity = fun (P0, …) -> <emit body>`. Module exports come from
`ir.Module.exports` (`ExportFn(export_name, fn_name)`).

| IR `Expr` | Core Erlang (schematic) |
|---|---|
| `Values([v…])` | the value list `<V…>` (a `Return` of a fall-through tail) |
| `Return([v…])` | the value list `<V…>` |
| `Let(names, rhs, body)` | `let <Names> = <emit rhs> in <emit body>` — **value-list arity must equal `length(names)`** (else `ArityMismatch`). A single binding may print `let X = … in …` or `let <X> = … in …`. |
| `If(cond, _, t, e)` | `case call 'erlang':'/=' (Cond, 0) of <'true'> when 'true' -> <emit t> <'false'> when 'true' -> <emit e> end`. Both arms yield the **merged live-value list**. |
| `Switch(sel, _, arms, default)` | `case Sel of` one clause per arm selecting that arm's continuation + a default clause. |
| `Block(label, _, body)` | a **forward continuation**: wrap in `letrec 'K'/n = fun(<result-vars>) -> <continuation-after-block> in <emit body>`; the block's tail value flows into `apply 'K'/n(...)`, and `Break(label, vs)` → `apply 'K'/n(Vs)`. |
| `Loop(label, params, _, body)` | `letrec 'L'/arity = fun (Params) -> <emit body, Continue(label,vs) → apply 'L'/arity(Vs)> in apply 'L'/arity(Inits)`. Tail self-call ⇒ constant-space, preemptible loop. |
| `Break(label, vs)` | `apply '<K-for-label>'/n (Vs)` |
| `Continue(label, vs)` | `apply '<L-for-label>'/arity (Vs)` |

> **EVERY `case` clause needs a `when 'true'` guard** — Core Erlang requires the guard
> position to be present; emit the literal `'true'` guard. (See the validated template.)

Maintain a **compile-time label → continuation stack**: entering a `Block`/`Loop` pushes
`(label, fun-name, arity)`; `Break`/`Continue`/falling-through resolve against it. An
unknown label is `Error(UnboundLabel)`.

### The binding chokepoint (D3) — route EVERY runtime op through ONE table

```
Num(IAdd(W32), [a,b])  →  call '<binding.num_module>':'i32_add' (A, B)
Num(IDivS(W32),[a,b])  →  let <R> = call '<binding.num_module>':'i32_div_s' (A, B)
                          in case R of
                               <{'ok',   X}> when 'true' -> X
                               <{'error',E}> when 'true' -> call '<binding.trap_module>':'raise' (E)
                             end
Trap(IntDivByZero)     →  call '<binding.trap_module>':'raise' ('int_div_by_zero')
CallHost(cap,name,as)  →  call '<binding.host_module>':'call_host' (Cap, Name, [A…])
Charge(cost, body)     →  let <_> = call '<binding.meter_module>':'charge' (Cost) in <emit body>
CallDirect(fn, args)   →  apply 'fn'/<arity(args)> (A…)
```

- **D3a — no ambient authority.** Never emit a data-driven `apply(Mod, F, Args)` where
  `Mod`/`F` come from program data. Every runtime call targets a **fixed**
  `'twocore@runtime@*'` module taken from a `binding.*_module` field. `CallDirect` targets
  the program's own functions by *static* name `'fn'/N` (an `apply` of a known local
  function), which is fine; `CallHost` goes through the **runtime** dispatcher, never a
  direct apply of an attacker atom.
- **D3d — no threaded record.** Phase-1 functions are pure; thread nothing.
- The **`NumOp → rt_num` function-name table lives here** and **MUST match the frozen
  `rt_num` signatures**. The mapping is deterministic: `IAdd(W32)→"i32_add"`,
  `IAdd(W64)→"i64_add"`, `IDivS(W32)→"i32_div_s"`, `IShrU(W64)→"i64_shr_u"`,
  `FAdd(FW32)→"f32_add"`, … i.e. `i{32|64}_<op>` / `f{32|64}_<op>` where `<op>` is the
  snake_case suffix (`add`/`sub`/`mul`/`div_s`/`div_u`/`rem_s`/`rem_u`/`and`/`or`/`xor`/
  `shl`/`shr_s`/`shr_u`/`rotl`/`rotr`/`clz`/`ctz`/`popcnt`/`eqz`/`eq`/`ne`/`lt_s`/`lt_u`/
  `gt_s`/`gt_u`/`le_s`/`le_u`/`ge_s`/`ge_u`). Trapping ops (`IDivS/IDivU/IRemS/IRemU`)
  use the Result-returning + `case`-and-raise shape above; all others are bare-`Int`.

### Name mangling (alpha-rename / gensym pass)

The IR/frontend produce names that are **illegal in Core Erlang** (variables must start
`A-Z` or `_`; IR uses `%x`, `$go`, etc.). **`emit_core` must run an alpha-rename/gensym
pass** so every emitted *variable* token starts with `A-Z`/`_` and is **unique per scope**.
Do **not** assume IR names are Core-legal (you may *also* rely on unit 03's printer
quoting guarantee for atoms/function names, but variables are emit_core's responsibility —
the printer cannot invent a binding). Keep an IR-name → Core-var map per scope.

## Grounded facts you MUST honor

These were **verified against the real toolchain/spec**. Getting them wrong fails
*silently* (non-matching clauses), so honor them exactly and add the named golden tests.

**1. Gleam→Erlang module/function mangling (VERIFIED — Gleam 1.17 *implementation
detail*).** A Gleam module `twocore/runtime/rt_num` compiles to Erlang module
`twocore@runtime@rt_num` — path `/` → `@`. Public function names are emitted **verbatim**
in snake_case; arity = parameter count. So `rt_num.i32_add(a, b)` is called as
`'twocore@runtime@rt_num':'i32_add'/2`. **The `Binding` fields already *are* these mangled
strings** (e.g. `"twocore@runtime@rt_num"`), so emit `call '<binding.num_module>':'i32_add'(...)`
directly — do not re-mangle.
**PITFALL → required golden test:** because this is an *implementation detail* of Gleam,
a compiler upgrade that changes mangling would silently corrupt every call target. Add a
golden that **compiles a known Gleam runtime module and asserts its artefact module name +
one function's arity**, so an upgrade is caught before it poisons codegen.

**2. Gleam value shapes the emitted code must construct/destructure (VERIFIED).** When you
call `rt_num` and match its result, or emit a `TrapReason`, you are interoperating with
Gleam-compiled code, whose runtime representation is fixed:
- `Result(a, e)` is `{'ok', V}` / `{'error', E}`.
- `Bool` is `true` / `false` (atoms).
- A **0-field constructor is a snake_case ATOM**: `TrapReason` `IntDivByZero` →
  `'int_div_by_zero'`, `IntOverflow` → `'int_overflow'`, `Unreachable` → `'unreachable'`
  (PascalCase → snake_case).
- An **N-field constructor is a tuple `{snake_tag, F1, …, Fn}`** — the snake_case tag at
  element 1, fields in **declaration order**.
- **Match by the FULL constructor pattern**, never by raw element index / arity. Match
  `<{'ok', X}>`, not "a 2-tuple whose first element is `'ok'`" by position alone.
**PITFALL → required golden test:** write the **PascalCase→snake_case wrapper** (used for
`TrapReason` atoms and the `'ok'`/`'error'` match) **early**, and golden-test it. A wrong
spelling produces a `case` clause that *never matches* and fails silently at run time.

**3. The VALIDATED loop template — mirror this exact shape.** This compiled and ran
**100k iterations in constant space on OTP 29**. `Loop` lowering must produce this
structure (tail self-`apply` inside a `letrec`):

```erlang
'sum_to'/1 = fun (N) ->
  letrec 'go'/2 = fun (I, Acc) ->
    case call 'erlang':'=<' (I, N) of
      <'true'> when 'true' ->
        let <Acc1> = call 'erlang':'+' (Acc, I)
        in let <I1> = call 'erlang':'+' (I, 1)
           in apply 'go'/2 (I1, Acc1)
      <'false'> when 'true' -> Acc
    end
  in apply 'go'/2 (1, 0)
```

(In real lowering the numeric ops route through `'<num_module>':'i64_add'` etc., not
`'erlang':'+'`; the template shows the *control* shape — `letrec` head, tail `apply`,
`when 'true'` guards, value-list binding.)

## Verification — Definition of Done (D8)

Tests assert **spec behavior / the §5 structure**, never "whatever the code emits" (no
change-detector goldens). Cite the standard in each test.

1. **Golden `.core` at the IR→`.core` boundary, one per control construct** —
   `block`, `loop`, `if`, `switch`, `return`, `call` (direct), `call_host`, `trap`.
   Assert the emitted **structure maps per high-level §5 / this doc's table** (e.g. a
   `Loop` produces a `letrec` whose body tail-`apply`s the same function; an `If` produces
   a `case` with `when 'true'` on every clause; `Num(IDivS)` produces the
   Result-`case`-and-`raise`). Goldens are **hand-checked against §5**, not regenerated.
2. **PascalCase→snake_case wrapper golden** (fact 2) + **Gleam-mangling golden** (fact 1).
3. **Codegen security-invariant test (high-level §5 / D3a) — STRUCTURAL, not by string
   inspection.** Walk the emitted Core AST and assert: `call_host`/`call_indirect`/(any
   future memory/table op) **never** lower to a bare `apply` of a non-runtime module atom;
   **every** runtime `call` targets a fixed `'twocore@runtime@*'` module name drawn from
   the `Binding`. No node introduces a data-driven `apply(Mod, …)`.
4. **End-to-end via `build_beam` (unit 04).** Emit → compile → `code:load_binary` → `apply`
   the export, for the acceptance programs and assert **spec results** against the WASM
   spec (<https://webassembly.github.io/spec/core/>):
   - `add(7, 35) == 42`; two's-complement wrap holds through codegen.
   - `sum_to(n)` correct **and runs in constant space** (drive a large `n`, e.g. 100k —
     the `letrec` tail loop must not grow the stack; mirrors the validated template).
   - `fib`/`fac` (if/self-`call`/recursion) correct.
   - `div_s(INT_MIN, -1)` and `div_u(x, 0)` **trap** (raise via `rt_trap`), surfaced as a
     typed error/exception — not a wrong value, not a silent `badarith`.
5. **`gleam format --check src test` clean; `gleam build` no warnings.** **Every public
   function carries a doc comment** stating contract / params / `Result` semantics /
   failure modes (D8).

> Note: the e2e suite (4) depends on units 04/06/09 being wired. The boundary goldens
> (1–3) do **not** — land them first; they are how you prove the lowering against the
> strawman before the runtime exists.

## Concurrency

Splittable along a clean seam once «CORE-AST» is published:

- **Sub-task A — control lowering:** `Function`/`Let`/`Values`/`Return`/`If`/`Switch`/
  `Block`/`Loop`/`Break`/`Continue` + the label→continuation stack + the gensym pass +
  goldens 1. Needs «IR-FROZEN» + «CORE-AST».
- **Sub-task B — the binding chokepoint + numerics/traps/host/charge:** the `Binding`
  routing, the `NumOp → rt_num` name table, the trapping Result-`case`-raise, the
  PascalCase→snake_case wrapper, the security-invariant test (3), the mangling golden.
  Needs «ABI-FROZEN» + «RTNUM-SIG-FROZEN».

The seam between them is the AST-construction helpers from unit 03 plus a tiny shared
`EmitState` (gensym counter + label stack). **Freeze first:** `EmitError`, the `EmitState`
shape, and the `NumOp → rt_num` name table — agree these three before both agents start,
then A and B proceed in parallel and meet at `emit_module`. The e2e suite (4) is a third,
later slice once 04/06/09 land.

## What this leaves for others

- **The backend exists.** With **04** (`build_beam` + FFI), **06** (`rt_num` bodies), and
  **09** (`rt_trap`/`rt_host`/`rt_meter`/`rt_stdlib`) wired, the **hand-written-`.ir` →
  `.beam`** slice runs — the **first end-to-end target** (overview §3), proving the backend
  spine *before* the WASM frontend exists.
- **11** (capstone) can run differential acceptance through `emit_core`.
- **10** (lower) gains a concrete, tested IR→`.core` target to lower *toward*.

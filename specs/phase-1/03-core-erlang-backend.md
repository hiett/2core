# Unit 03 — Core Erlang AST & pretty-printer

> **One owner (splittable into ~3 sub-tasks). Wave A — self-frozen, no upstream
> freeze deps. Publish `«CORE-AST»` on day 1 to unblock unit 08.** Read
> [`00-overview.md`](00-overview.md) first; this doc assumes D1–D10.

## Context

This unit owns the **backend's output representation**: a Gleam-native Core Erlang
AST and a correct pretty-printer that turns it into `.core` text. It sits between
`emit_core` (unit 08, which *builds* these nodes from the IR — the binding
chokepoint D3b) and `build_beam` (unit 04, which feeds the printed `.core` to the
Erlang compiler). Per high-level §5 we deliberately build a **Gleam-native AST and
print to text**, *not* the Erlang `cerl` record API over FFI (awkward over FFI,
loses Gleam's type safety). The printer is small, fiddly, and lexically exacting —
so it gets its **own** unit tests for the lexical rules. This unit has **no IR
dependency**: Core Erlang is defined by its own grammar, independent of our IR.

## Goal

Model the subset of Core Erlang we emit as Gleam custom types, and write a
**provably-correct** pretty-printer `print_module(CModule) -> String` whose output
the Erlang compiler accepts via `compile:from_core` (equivalently:
`core_scan` → `core_parse` → `core_lint` succeed, then `compile`). Measurable:
the validated minimal module (below) prints, compiles, loads, and runs to the
right answer; and a suite of lexical-rule tests asserts the produced text against
the Core Erlang grammar.

## Files owned

| File | Role |
|---|---|
| `src/twocore/backend/core_erlang.gleam` | The Gleam-native Core Erlang AST node types. **FREEZE THESE TYPES DAY 1 → milestone `«CORE-AST»`** (unblocks unit 08). |
| `src/twocore/backend/core_printer.gleam` | `print_module(CModule) -> String` + atom-escaping + the variable name-mangling/gensym layer. |
| `test/twocore/backend/core_printer_test.gleam` | Lexical-rule unit tests + (once `«FFI-SHIM»` lands) a compile-and-run integration test. |

## Depends on

- **Nothing to start.** Core Erlang's grammar is fixed and external; design the AST
  and printer from the grammar + OTP's reference printer (`core_pp.erl`) directly.
- **`«FFI-SHIM»` (unit 04)** — needed only to *prove* the printed text actually
  compiles+loads+runs. Until it lands, verify by eye and with `erlc`
  (`core_lint`/`compile:file` on a `.core` file). Do not block AST/printer work on
  it; build the integration test last.

You produce `«CORE-AST»` day 1; nobody produces anything you must wait on.

## Scope — in / out for Phase 1

**In:**
- AST nodes for: module, function defs, fnames, funs, `let`/`letrec`/`case`/
  clauses, `apply`/`call`/`primop`, value-lists, and literals (int, float, atom,
  nil, cons, tuple, binary), variables.
- A correct printer for all of the above, including **atom quoting/escaping**,
  **variable legalization**, **fname form**, and **mandatory case guards**.
- The variable name-mangling/gensym layer (legality is the printer's guarantee).

**Out (Phase 1 — per the brief & D9):**
- **Annotations** (`-| [...]`). Phase 1 omits them entirely — a zero-annotation
  module compiles fine on OTP 29. Do not emit any.
- The **`cerl_ast`** alternative emitter format (high-level §4 B1) — deferred.
- `try` / `catch` / `receive` / `after` — not needed for the Phase-1 op set.
- Full binary-segment exercising — keep the `CBinary` node (lock-now) but the
  Phase-1 integer corpus does not need it; leave it minimally printed and untested
  until a binary-using corpus exists.

## Deliverables

### `core_erlang.gleam` — the AST (freeze day 1)

Concrete shape to build (refine names, keep the structure):

```gleam
//// src/twocore/backend/core_erlang.gleam
//// A Gleam-native Core Erlang AST (high-level §5: build an AST, then print —
//// NOT the Erlang cerl record API over FFI). Phase 1 omits annotations entirely.

/// A Core Erlang compilation unit. Prints as:
///   module 'Name' [Exports] attributes [Attrs] Defs end
pub type CModule {
  CModule(
    name: String,                          // module atom (printed quoted)
    exports: List(FName),                  // the export list
    attributes: List(#(String, CExpr)),    // 'key' = value pairs; Phase 1 = []
    defs: List(FunDef),                    // top-level function definitions
  )
}

/// A function name: an atom + arity, printed `'atom'/arity` (e.g. 'fact'/1).
/// Used in the export list, on the LHS of a def, and as the operand of `apply`.
pub type FName {
  FName(name: String, arity: Int)
}

/// A top-level (or letrec) definition: `'name'/arity = fun (...) -> body`.
/// Invariant: `value` is always a `CFun` (Core requires a fun on a def RHS).
pub type FunDef {
  FunDef(name: FName, value: CExpr)
}

pub type CExpr {
  // variables & literals
  CVar(name: String)                       // legalized at print time
  CInt(value: Int)
  CFloat(value: Float)                     // see D5 pitfall below — NOT for WASM floats
  CAtom(name: String)                      // ALWAYS printed single-quoted + escaped
  CNil                                     // []
  CCons(head: CExpr, tail: CExpr)          // [H|T]
  CTuple(elements: List(CExpr))            // {E1, E2, …}
  CBinary(segments: List(CBitSeg))         // #{ … }# (lock-now; minimal in Phase 1)
  CValues(values: List(CExpr))             // <E1, E2, …>  (value list)
  // funs, binding & control
  CFun(vars: List(String), body: CExpr)    // fun (V1, V2) -> Body
  CLet(vars: List(String), arg: CExpr, body: CExpr)   // let <V…> = Arg in Body
  CLetrec(defs: List(FunDef), body: CExpr)            // letrec … in Body
  CCase(arg: CExpr, clauses: List(CClause))           // case Arg of … end
  // calls
  CApply(name: FName, args: List(CExpr))              // apply 'f'/N (Args)
  CCall(module: CExpr, function: CExpr, args: List(CExpr)) // call 'M':'F' (Args)
  CPrimop(name: String, args: List(CExpr))            // primop 'Name' (Args)
}

/// A case clause. `guard` is MANDATORY (use `CAtom("true")` for an unconditional
/// arm — a guardless clause is a syntax error). `pats` is the clause's pattern
/// list; the printer wraps it in a value-list `<P…>` to match the scrutinee.
pub type CClause {
  CClause(pats: List(CPat), guard: CExpr, body: CExpr)
}

/// Patterns (Phase-1 subset: enough for `if` and `switch` lowering).
pub type CPat {
  PVar(name: String)
  PInt(value: Int)
  PAtom(name: String)
  PTuple(elements: List(CPat))
  PCons(head: CPat, tail: CPat)
  PNil
}

/// A binary segment (lock-now; Phase-1 integer corpus does not exercise this).
pub type CBitSeg {
  CBitSeg(value: CExpr, size: CExpr, unit: Int, segtype: String, flags: List(String))
}
```

Notes the implementer must honor:
- `CCall.module` / `CCall.function` are `CExpr` for grammar fidelity (Core allows a
  computed module/fun), but in Phase 1 they are **always `CAtom(...)`** — the
  binding chokepoint (D3a/D3b) emits fixed `call 'twocore@runtime@…':'fn'(…)`,
  never a data-driven module.
- `FunDef.value` must be a `CFun`. Document the invariant; `emit_core` always
  satisfies it.

### `core_printer.gleam` — the printer + name-mangling

```gleam
/// Render a Core Erlang module to `.core` text accepted by `compile:from_core`.
/// Total; never panics. Assembles with a `gleam/string_tree` builder.
pub fn print_module(m: CModule) -> String

/// Escape an atom EXACTLY as `io_lib:write_string(Chars, $')` does and wrap in
/// single quotes. There is NO unquoted-atom path. Used for every atom token.
fn print_atom(name: String) -> StringTree

/// Map a raw IR/WASM variable name to a Core-Erlang-legal variable token.
/// CONTRACT: (a) result starts with `A`–`Z` or `_`; (b) result contains only
/// legal variable characters; (c) the function is INJECTIVE — distinct inputs
/// give distinct outputs — so if upstream names are unique within a scope, the
/// printed tokens are too. Apply the SAME function to every binder AND every
/// reference so bindings still resolve. Total; never panics.
pub fn legalize_var(raw: String) -> String
```

**Algorithm shape.** `print_module` is a straightforward recursive walk emitting a
`StringTree`, with one helper per node kind. The fiddly parts are all *lexical* and
are fully pinned down by the Grounded Facts below — there is no algorithmic
cleverness, only exactness. Print order for the module:

```
module <atom name> [<export, …>]
    attributes [<'k' = v, …>]
<fname> = fun (<vars>) -> <body>
…
end
```

**Name-mangling / gensym.** WASM/IR names (`%p0`, `$loop0`, arbitrary UTF-8) violate
Core's variable rules, so legalization is part of codegen, not an afterthought.
Phase-1 strategy: upstream (`emit_core`/stack-elim, unit 08/10) emits
**per-function-unique** names (SSA); the printer's **injective** `legalize_var`
preserves that uniqueness while guaranteeing the leading-char/charset rules. A
simple injective scheme: prefix a fixed uppercase letter (e.g. `V`) and reversibly
escape every non-`[A-Za-z0-9_]` byte (and the escape char itself) — e.g.
`%p0` → `V_25p0`. If a future frontend introduces *shadowing* (same name, nested
scopes), add a scope-aware rename pass at the 08↔printer seam; do not build it now.
This layer may live here or in 08, **but the printer must guarantee the output is
legal regardless of input.**

## Grounded facts you MUST honor

Verified on **OTP 29 / compiler 10.0.1**. Honor exactly; each prevents a real
hand-rolled-printer break.

1. **Atoms are ALWAYS single-quoted.** There is **no unquoted atom** in Core Erlang
   text. A bare lowercase word scans as a **keyword**; if it is not a reserved
   keyword the parser errors. So `'true'`, `'false'`, `'ok'`, `'+'`, `'erlang'`
   **all** need quotes. **This is the #1 way a hand-rolled printer breaks — do NOT
   implement Erlang-style "quote only when needed".**

2. **The keyword set** (never emit these as bare atoms — but since *all* atoms are
   quoted, this is automatic if rule 1 is followed):
   `module attributes do let in letrec apply call primop case of end when fun try
   catch receive after`.

3. **Variables** must start with **uppercase `A`–`Z` or underscore `_`** and be
   **unique per scope**. A lowercase-leading variable is impossible (it scans as a
   keyword/atom). Leading `_` is fine (`_A`, `_B`).

4. **Atom escaping inside the quotes** = `io_lib:write_string(Chars, $')`:
   `'` → `\'`, `\` → `\\`, tab/newline/carriage-return → `\t`/`\n`/`\r`, other
   control chars → **octal** `\NNN`, printable Unicode passes through unchanged.
   Export / import / host names can contain arbitrary bytes — escape correctly. The
   authoritative implementation is OTP's `core_pp.erl` (`core_atom/1 =
   io_lib:write_string(..., $')`).

5. **Function names (`FName`)** print as `'atom'/arity`, e.g. `'fact'/1`. Used in
   the export list, on the LHS of defs, and as the operand of `apply`. Inter-module
   / BIF calls: `call 'Mod':'Fun'(Args)`. Primop: `primop 'Name'(Args)`.

6. **Every case clause has a MANDATORY guard.** Emit `when 'true'` for an
   unconditional arm — a guardless clause is a **syntax error**. A single-value
   scrutinee typically uses a **1-element value-list pattern** `<P>`.

7. **`let` arity.** `let` binds a single var `let X = …` or a value list
   `let <V1,V2> = …`. **Get the value-list arity right** (multi-result runtime calls
   bind `<…>`; a single-value result binds a bare `X`) or `core_lint` rejects it.
   Encode: `vars` length `1` → bare var; length `≠ 1` → angle-bracketed list.

8. **Validated minimal module** (compiles + loads + runs, zero annotations) — use
   this as the first golden output and the integration-test fixture:

   ```
   module 'hand' ['add'/2]
       attributes []
   'add'/2 = fun (_A, _B) -> call 'erlang':'+' (_A, _B)
   end
   ```

9. **Reference style.** `erlc +to_core demo.erl` emits canonical `.core` — use it to
   copy OTP's exact spacing/style. The authoritative printer is OTP's `core_pp.erl`.

**D5 pitfall — do NOT route WASM floats through `CFloat`.** Per D5, WASM `f32`/`f64`
values travel as **raw IEEE-754 bit patterns stored in integers** (`CInt`), never as
BEAM doubles (BEAM doubles cannot represent NaN/Infinity). `CFloat` exists only for a
genuine Erlang-double literal a future term frontend might need; emitting one
losslessly as a decimal is itself hard, which is another reason WASM floats never use
this path. Keep the node, but document the caveat so unit 08 does not misuse it.

## Verification — Definition of Done (per D8)

**Assert the produced TEXT against the Core Erlang grammar / OTP's reference, never
against itself** (no change-detector tests). Reference oracle: the Core Erlang
language spec and OTP's `core_pp.erl` / `core_lint.erl`
(<https://www.it.uu.se/research/group/hipe/cerl/> ; OTP `compiler` app:
`core_scan`/`core_parse`/`core_lint`). Required lexical-rule unit tests:

- **Atoms always quoted, incl. keywords.** `print_atom("true")` ⇒ `'true'`;
  `print_atom("module")` ⇒ `'module'`; `print_atom("+")` ⇒ `'+'`. Assert the
  quotes are present (grammar rule 1), not "what the code emits."
- **Atom escaping.** `'` → `\'`; `\` → `\\`; tab/nl/cr → `\t`/`\n`/`\r`; a NUL byte
  → octal `\000`; a printable Unicode char passes through. Assert byte-for-byte
  against the `io_lib:write_string(_, $')` rule (fact 4).
- **Variable legalization.** Output starts with `A`–`Z` or `_`; contains only legal
  chars; **injectivity** — a property test over many distinct raw names asserts
  `legalize_var(a) == legalize_var(b) ⟹ a == b` (so upstream uniqueness survives).
- **FName form.** `FName("fact", 1)` ⇒ `'fact'/1` everywhere it appears (export,
  def LHS, `apply` operand).
- **Mandatory guard.** A clause built with `guard = CAtom("true")` prints
  `… when 'true' -> …`; assert the `when 'true'` is present.
- **`let` value-list arity.** 1 var ⇒ `let X = …`; 2 vars ⇒ `let <X,Y> = …`.

**Grammar-level proof (no FFI needed):** write the minimal module (fact 8) and any
hand-built fixtures to a `.core` file and run `erlc` / `core_lint` on it; it must
parse and lint cleanly. This proves the printer's output is *grammatically* valid
before the shim exists.

**Integration test (once `«FFI-SHIM»` from unit 04 lands):** build the minimal
`add` AST in Gleam → `print_module` → compile via the shim → `code:load_binary` →
`apply('hand', 'add', [2, 3])` and assert `== 5`. This is the end-to-end proof the
emitted text is compiler-accepted (D10).

**Hygiene (D8):** `gleam format --check src test` clean; `gleam build` with **no
warnings**; **every public function/type has a `///` doc comment** stating its
contract (what / params / return / failure & panic modes — printer functions are
total and panic-free, say so).

## Concurrency

Splittable into ~3 parallel sub-tasks once the AST is frozen:

1. **`core_erlang.gleam` AST types — do this FIRST, alone, publish `«CORE-AST»`
   day 1.** Everything else (the printer, the tests, and *unit 08*) keys off the
   frozen node shapes. This is the single serialization point.
2. **The atom-escaping + `legalize_var` helpers** are entirely self-contained and
   spec-defined (`io_lib:write_string`, the variable lexical rules). One agent can
   build and exhaustively test these in isolation, independent of the AST walk.
3. **The structural printer** (module / def / `let` / `letrec` / `case` / clause /
   call walk) + the integration test. Depends on (1) frozen and consumes (2).

Freeze the `CExpr`/`CModule` shapes before anyone writes (2)/(3) or unit 08 starts.

## What this leaves for others

- **`«CORE-AST»` published (day 1):** unit 08 (`emit_core`) builds these nodes as
  the IR→Core lowering target (the binding chokepoint, D3b).
- **A printer whose output `compile:from_core` accepts:** unblocks unit 04's
  build/load integration and the smartest first end-to-end (overview §3:
  hand-written `.ir` → 08 → 03 → 04 build → run), de-risking the backend slice
  before the WASM frontend exists.

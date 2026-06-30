# Unit 02 — The `.ir` printer & parser

> **1–2 owners. Wave A, starts the moment «IR-FROZEN» lands.** Hard freeze deps:
> `src/twocore/ir.gleam` (the IR types) + `specs/phase-1/ir-grammar.md` (the grammar).
> Until those freeze, work against the strawman types and grammar in
> [`01-interface-freeze.md`](01-interface-freeze.md) and [`ir-grammar.md`](ir-grammar.md).

## Context

This unit builds the **inter-stage contract** of the whole compiler (decision **D7** in
[`00-overview.md`](00-overview.md)). The IR (`src/twocore/ir.gleam`) is the keystone every
stage targets; the `.ir` textual form is how any stage **dumps** its IR and any stage
**loads** it back, so that each stage (frontend lower, `ir_lower`, the emitter) can be
golden-file-tested in isolation against a hand-written `.ir` fixture. Read
`00-overview.md` (esp. D5, D6, D7) and skim high-level §3 first — do not re-derive those
decisions here. You are downstream of unit `01` only; everyone else is downstream of you.

## Goal

Deliver a **canonical, lossless, round-trippable** textual form for the IR: a single
deterministic printer and a total parser such that **`parse(print(m)) == m`** for every
module `m` (numeric literals compared **by bit pattern**), and such that the
**hand-authored** golden `.ir` files parse to the expected `Module` values *and* print
back to their canonical text. Measurable done = the round-trip property passes on a
full-IR-surface corpus, every golden round-trips stably, and every malformed input
returns a typed `ParseError` (never a panic).

## Files owned

| Path | Role |
|---|---|
| `src/twocore/ir/printer.gleam` | IR value → `.ir` text. `pub fn print_module`. |
| `src/twocore/ir/parser.gleam` | `.ir` text → IR value. `pub fn parse_module`, owns `ParseError`. |
| `test/twocore/ir/roundtrip_test.gleam` | Round-trip property + golden suite (single owner). |

You **read** `src/twocore/ir.gleam` and `specs/phase-1/ir-grammar.md`; you never edit
them. The hand-authored goldens under `test/twocore/ir/golden/` are **authored by unit
`01`** (deliverable 6) against the grammar; you consume them and may add more *by hand*
(never printer-generated — see Verification).

## Depends on

- **«IR-FROZEN»** — `ir.gleam` types + finalized `ir-grammar.md`. This is your only hard
  gate. The exact `NumOp`/`ConvOp`/`TrapReason` textual spellings, the sigils
  (`%local`, `$label`, `@func/@global`, `"host-name"`), and the param-naming convention
  are fixed by `01` at freeze; **follow whatever `01` finalized**, not the strawman, once
  it lands.
- **Meanwhile (before freeze):** build against the strawman `ir.gleam` and the seeded
  `ir-grammar.md`. Structure your code so the op-spelling tables (`NumOp ↔ string`, etc.)
  are *centralized* and trivially re-synced when the freeze moves a spelling.
- You depend on **nothing downstream** and **no runtime/ABI** milestones — this is plain
  text I/O over Gleam strings.

## Scope — in / out for Phase 1

**In (lock-now completeness — print/parse the *full* IR surface, not the integer
subset):**
- Every `Module` field: `name`, `uses_numerics`, `memory` (`none`/`min`/`max`),
  `globals`, `imports`, `functions`, `exports`, `data_segments`.
- Every `Expr` variant: `Values`, `Num`, `Convert`, `TermOp`, `MemLoad`, `MemStore`,
  `GlobalGet`, `GlobalSet`, `CallDirect`, `CallIndirect`, `CallHost`, `Let`, `Block`,
  `Loop`, `If`, `Switch`, `Break`, `Continue`, `Return`, `Trap`, `Charge`.
- Every `Value` variant incl. all four const widths; every `NumOp`, `ConvOp`, `TermOp`,
  `MemAccess`, `TrapReason`, `ValType`, `FuncType`, `LoopParam`, `SwitchArm`.
- Comments (`;` to end of line) accepted by the parser and skipped.

**Out (Phase 1):**
- Performance tuning — **nothing here is hot-path; correctness first.** (Use a
  `string_tree` for the printer because it is trivially correct + linear, not for speed.)
- Semantic validation of the IR (type-checking, label scoping, arity vs `FuncType`). The
  parser checks *syntax* and produces a well-formed `Module`; it is **not** a validator.
  Deep semantic checks belong to later stages. (Cite **D9** deferrals: memory/table
  *runtimes* are deferred, but the IR still *models* them, so you must still print/parse
  `MemLoad`/`MemStore`/`MemAccess`/`DataSegment`/`CallIndirect` — they are lock-now.)
- WAT/`.wast`/Core-Erlang text — different units.

## Deliverables

### `printer.gleam`

```gleam
/// Render an IR module to its canonical `.ir` text (D7). Deterministic: the same
/// `Module` always produces byte-identical output, and it is the ONE canonical form
/// (so a golden's text is unambiguous). Float constants are printed as RAW IEEE-754
/// bit patterns in `0x`-hex (D5) — NEVER decimals (decimals lose f32 rounding and NaN
/// payloads). Integer constants are printed in canonical decimal.
///
/// Returns the full module text, ending in a trailing newline. Total — every value of
/// type `Module` has a printable form (the type system guarantees the variants).
pub fn print_module(module: ir.Module) -> String
```

Build output with `gleam/string_tree` (`StringTree`): `string_tree.new()` →
`append`/`append_tree`/`join` → `to_string`. Sketch the layering:

- `print_module` → header lines (`module @name {`, `numerics …`, `memory …`), then
  globals, imports, exports, data, functions, `}`.
- `print_func`, `print_expr(indent, expr)`, `print_value`, `print_valtype`,
  `print_functype`, `print_numop`, `print_convop`, `print_trapreason`, `print_memaccess`.
- **Canonical-form rules to fix and document:**
  - Indentation: a fixed unit (e.g. 2 spaces) per nesting level; deterministic.
  - One canonical spelling per enum constructor (the table from `ir-grammar.md` / `01`).
  - Float consts: `f32.const 0x<8 hex digits>`, `f64.const 0x<16 hex digits>`,
    lower-case hex, **zero-padded to width** (so the form is unique). Integer consts:
    `i32.const <decimal>` / `i64.const <decimal>` of the stored **unsigned** value.
  - Param names: the strawman `Function` carries `ty.params: List(ValType)` with **no
    names**, yet bodies reference params (`%p0`, `%p1`). Print params positionally as
    `%p0..%p{n-1}` and let the parser reconstruct them from `FuncType` arity. **Confirm
    this convention against the frozen `ir.gleam`** — if `01` adds named params, follow
    that instead. (This is the one place the strawman is underspecified; see the return
    note to the planner.)

### `parser.gleam`

```gleam
/// This stage's OWN error type (D4 — no shared StageError). Carries enough position
/// info to locate the fault. `line`/`col` are 1-based; `found` echoes the offending
/// token/text for diagnostics.
pub type ParseError {
  UnexpectedToken(line: Int, col: Int, expected: String, found: String)
  UnexpectedEnd(expected: String)        // truncated input
  UnknownOp(line: Int, col: Int, op: String)        // bad numop/convop/trapreason
  BadSigil(line: Int, col: Int, found: String)       // e.g. %x where @x expected
  BadNumberLiteral(line: Int, col: Int, lexeme: String)
  // … extend as the grammar requires; every variant carries position.
}

/// Parse `.ir` source text into a `Module`. TOTAL — never panics on malformed input
/// (no `let assert`/`panic` reachable from untrusted text; an untrusted-input panic is
/// a sandbox hole per the totality convention). Gleam strings are UTF-8; the lexer
/// operates on graphemes/codepoints, not Erlang bit-syntax (no bit-syntax needed here).
///
/// Returns `Ok(module)` on a syntactically valid module, or `Error(ParseError)` with
/// position info on the first fault. Accepts both `0x`-hex and decimal integer literals
/// (grammar `int := decimal | 0x-hex`); the parser does NOT validate IR semantics.
pub fn parse_module(source: String) -> Result(ir.Module, ParseError)
```

Algorithm shape (keep it simple — a small hand-written recursive-descent parser):
1. **Lex** into a token stream (idents with sigil, keywords, punctuation `(){}:,=`,
   string literals, int/hex/float-bits literals), tracking `line`/`col`, **skipping `;`
   comments and whitespace**. Strings use standard escapes.
2. **Recursive descent** mirroring the grammar's `expr := …` productions. One parse
   function per production (`parse_expr`, `parse_value`, `parse_func`, `parse_numop`, …).
3. On any mismatch return `Error(ParseError(pos, …))` — propagate with `use`/`result.try`;
   never panic, never `let assert`.

### `roundtrip_test.gleam`

```gleam
/// Bit-pattern numeric equality for IR. Because D5 stores float constants as raw Int
/// bit patterns (`ConstF32(bits)`/`ConstF64(bits)`), comparing the stored Int bits IS
/// the correct, exact comparison (NaN payloads and -0.0 preserved). Use THIS — never a
/// float `==` that would make NaN ≠ NaN — anywhere two IR modules are compared.
pub fn module_equal(a: ir.Module, b: ir.Module) -> Bool
```

- **Round-trip property:** for a corpus of modules covering the *full* surface, assert
  `module_equal(parse_module(print_module(m)) |> result.unwrap, m)`.
- **Golden parse:** each hand-authored `test/twocore/ir/golden/*.ir` parses
  (`Ok(_)`) to the **expected `Module` value** written out in the test.
- **Golden print:** `print_module(expected) == <canonical text of that golden>` —
  proving the printer reproduces the hand-authored canonical text.
- **Negative corpus:** truncated input, wrong sigil, unknown op, wrong arity/punctuation
  each return a `ParseError` (assert the variant + that it does not panic).

## Grounded facts you MUST honor

These were checked against the toolchain/spec; ignoring them forces an expensive
retrofit. Each is a hard requirement.

- **D7 contract (verbatim):** one canonical printer; `parse(print(m)) == m` under
  **bit-pattern numeric equality**; lossless float encoding; **hand-authored** goldens to
  prevent printer/parser collusion. A printer+parser that share the *same wrong* grammar
  will pass a `parse(print(m))` test while both being wrong — the **hand-written goldens
  are the independent oracle** that catches this. Treat "all goldens authored by reading
  `ir-grammar.md`, never emitted by the printer" as non-negotiable.
- **Floats are bit patterns, not BEAM doubles (D5).** Print `f32.const`/`f64.const` as
  raw `0x`-hex bits. **PITFALL:** a decimal like `3.14` cannot represent NaN/Infinity and
  silently re-rounds f32 — it is *lossless-looking but lossy*. BEAM doubles raise
  `badarith` on NaN/Inf and `<<F:64/float>>` fails to match NaN/Inf bits, which is the
  whole reason D5 stores bits. Never round-trip a float through a native double.
- **Bit-pattern equality / the NaN trap.** `NaN != NaN` under normal float `==`, and
  `-0.0 == 0.0` — so a *native-float* comparison is wrong. **Because the frozen IR stores
  floats as `Int` bits, plain structural `==` on `Module` already compares them
  bit-exactly.** Still provide `module_equal` per the brief: it documents the contract,
  gives a readable diff on failure, and stays correct if the encoding ever changes. (See
  the return note — this is the one spot where the brief's "structural `==` is WRONG"
  framing is about *native* floats and does not bite the Int-encoded IR.)
- **Plain-text I/O, no Erlang bit-syntax.** Gleam strings are UTF-8; lex over the string
  directly. You do **not** need `<<…>>` bit-syntax anywhere in this unit.
- **Sigils & comments (from `ir-grammar.md`).** `%name` = locals/let-bindings/loop vars;
  `$name` = labels; `@name` = functions/globals; `"…"` = host/export/capability names;
  comments start with `;` to end of line. **Follow whatever `01` finalized** if it
  diverges from the strawman — the strawman marks these "suggested."
- **Neutral, width-tagged op spellings (D6).** Op text is a 1:1 rendering of the
  `NumOp`/`ConvOp` constructors and must read *neutral* (e.g. the strawman grammar's
  `i.add.32`, `i.le_u.64`, `f.add.64`), **never** the WASM opcode string `i32.add`. The
  value *type* is `i32`; the *operation spelling* is "integer add, width 32." Keep a
  single source-of-truth mapping table so printer and parser agree by construction.
- **Per-stage error type (D4).** `ParseError` is *yours*; do not reach for a shared
  `StageError`. `pipeline.gleam` (`11`) wraps it later. Every variant carries position.
- **Totality (D4 / convention).** `parse_module` is total — a malformed-input panic
  would be a hole. No `let assert`/`panic` on the untrusted-text path.
- **Worked examples are the first goldens.** The `add` and `sum_to` modules in
  `ir-grammar.md` (lines for `module @add` and `module @loop`) are `01`'s first
  hand-authored fixtures — your golden-parse and golden-print tests must cover them
  exactly as written.

## Verification — Definition of Done (per D8)

Tests assert the **D7 contract and the grammar**, not "whatever the printer currently
emits" (no change-detector tests):

1. **Round-trip property** holds on a full-surface corpus (hand-build IR `Module` values
   exercising *every* `Expr`/`Value`/`NumOp`/`ConvOp`/`TermOp`/`TrapReason`/memory/global
   variant), via `module_equal`. This is the D7 invariant `parse(print(m)) == m`.
2. **Golden suite** (the independent oracle): every `test/twocore/ir/golden/*.ir`
   - parses to the expected `Module` (caught by hand, asserted with `module_equal`), and
   - `print_module(expected)` reproduces that golden's canonical bytes.
   Include the `add` and `sum_to` worked examples and at least one golden per axis
   (float consts with NaN/`-0.0` bits, `call_host`, `charge`, `mem.load`/`mem.store`,
   `global.get`/`global.set`, `switch`, `term`, `convert`).
3. **Negative corpus**: truncated module, bad sigil (`@x` where `%x` required), unknown
   op spelling, wrong arity/missing punctuation → each returns the expected `ParseError`
   variant; **no input panics**. (D4 fail-closed: malformed → typed `Error`.)
4. **Float fidelity** explicitly tested: a module whose const is a signaling/quiet NaN
   bit pattern and one whose const is `-0.0` round-trip with their exact bits (proves the
   D5 lossless-encoding requirement, not just "some float survives").
5. `gleam format --check src test` is clean; `gleam build` has **no warnings**;
   `gleam test` green.
6. **Every public function documented** (D8): `print_module`, `parse_module`,
   `ParseError`, `module_equal` — contract, params/ranges, `Result`/`Ok`/`Error`
   semantics, and failure/panic modes (state explicitly that `parse_module` cannot
   panic on malformed input).

**Proving the goal:** the goal is "the inter-stage contract works." Prove it by (a) the
round-trip property green on the full surface, (b) the hand-authored goldens parsing
*and* re-printing stably, and (c) the negative corpus returning typed errors. (a)+(b)
together defeat collusion; (c) proves totality.

## Concurrency

This unit splits cleanly along the **printer / parser seam** once the op-spelling table
and `ParseError` shape are agreed (a ~30-minute mini-freeze you do first):

- **Sub-task A — printer** (`printer.gleam`): owns `print_module` + the canonical-form
  rules. Can proceed against a shared op-spelling table immediately.
- **Sub-task B — parser** (`parser.gleam`): owns the lexer, recursive descent, and
  `ParseError`. Largest piece; needs the same op-spelling table.
- **Shared, frozen first:** the `NumOp/ConvOp/TermOp/TrapReason ↔ string` mapping table
  and the sigil/punctuation set. Freeze these two between A and B before either codes;
  then they parallelize. `roundtrip_test.gleam` is **single-owner** (per the ownership
  map) and is written last, by whoever finishes second, since it needs both halves +
  `module_equal`.

If a single agent takes the whole unit, do A and B together and keep the op-table in one
module-level constant so they cannot drift.

## What this leaves for others

Once `.ir` round-trips, **every other stage gets a golden-file boundary**:
- `10` (lower) can golden-test "WASM AST → IR" by emitting `.ir` and diffing against a
  hand-written expected `.ir`.
- `08` (emit_core) can be driven from a hand-written `.ir` fixture (the smartest first
  end-to-end is hand-`.ir` → `08` → `03` → `04 build` → run; see overview §3).
- `11` (ir_lower) can golden-test `charge`-insertion / capability resolution as
  `.ir`-in → `.ir`-out.
- `07` (conformance) can dump/load IR at any stage seam for differential tests.

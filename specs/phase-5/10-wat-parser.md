# Unit P5-10 — The WAT text parser (`frontend/wasm/wat.gleam`)

> **One owner. Wave A. Depends only on `«WASM-AST3»`** (unit 03's extended
> `frontend/wasm/ast.gleam`) — *not* on the IR, runtime, or `emit_core`. It is a pure
> `text → ast.Module` frontend that sits **beside** the binary decoder and hands the same AST
> to the *unchanged* `validate`/`lower`. Read [`00-overview.md`](00-overview.md) (H1–H8, esp.
> **H5**), the provisional surface (`scratchpad/provisional-surface.md`), and the two template
> unit docs ([`phase-1/05-wasm-decoder.md`](../phase-1/05-wasm-decoder.md),
> [`phase-2/07-decode.md`](../phase-2/07-decode.md)) before this one.

---

## Context

The engine has exactly one WASM frontend mouth today: the **binary decoder**
(`frontend/wasm/decode.gleam`), which turns `.wasm` bytes into an `ast.Module`. Everything
downstream — `validate.gleam` (the security boundary) and `lower.gleam` (AST → IR) — consumes
that `ast.Module` and knows nothing about where it came from. The conformance harness therefore
depends on an **external** toolchain (`wat2wasm`/`wast2json`, wabt) to turn the spec suite's
`.wast` text files into the `.wasm` binaries + JSON fixtures we can actually feed. That external
dependency is the reason the runner *skips* two whole categories today:

- **`assert_invalid`/`assert_malformed` with `module_type: "text"`** — the malformation lives in
  the *text* form (a `.wat` with no binary counterpart, because a malformed text can't be
  assembled to bytes). `runner.run_frontend_reject` skips every one of these with the literal
  reason `"text module_type (no WAT parser)"` (`runner.gleam:322-324`).
- **`.wast` files wabt can't convert at the vendored pin** — every un-`wast2json`-able suite file
  is invisible to us. And the fixture layer's `Get` action / typed reftype values are stubbed
  because they never reach a real engine.

Phase-5 **H5** makes the WAT parser a *first-class frontend*, not a fixture crutch:
`frontend/wasm/wat.gleam` produces the **same `ast.Module` the binary decoder produces**, so
`validate`/`lower` serve both unchanged. Once it exists, the text `assert_malformed`/
`assert_invalid` cases stop skipping, the un-convertible suite files run **from our own parser**,
and the acceptance corpus stops needing `wat2wasm` at build time. This is the single largest
tooling unlock in the phase, and it is **conformance-facing**: its correctness is proven
*differentially* against wabt over the whole fixture corpus (H5's DoD), never by locking in
whatever our parser happens to emit.

This unit is analogous to unit 05/07 (the binary decoder) but for the **text** grammar
(<https://webassembly.github.io/spec/core/text/>). It is a much larger *surface* than the binary
decoder because the text format is redundant: two spellings of every instruction (folded
S-expression **and** flat), a dense set of **abbreviations** (inline `import`/`export`, inline
`(func)`/`(table)`/`(memory)`/`(global)`/`(elem)`/`(data)`, the `(type)` dedup), and a
**symbolic identifier** layer (`$name → index`) over *eight* index spaces that the binary format
never has. On top of the module grammar sits the **`.wast` script** grammar (the reference
interpreter's command language: `assert_return`, `assert_trap`, `register`, …) that the
conformance harness drives.

---

## Goal

Given an arbitrary `String`, produce:

1. `parse_module(text) -> Result(ast.Module, WatError)` — an `ast.Module` **structurally
   equal to `decode(wat2wasm(text))`** for every well-formed Phase-5-scope module text, and a
   **typed `WatError`** (never a panic / `let assert` / silent truncation) for every malformed
   one. Total (D4).
2. `parse_script(text) -> Result(Script, WatError)` — the `.wast` command list (`module`
   text/binary/quote, `assert_return`, `assert_trap`, `assert_invalid`, `assert_malformed`,
   `assert_exhaustion`, `assert_unlinkable`, `assert_uninstantiable`, `register`, `invoke`,
   `get`) — **equal to what `wast2json` emits** for the same file (differentially checked against
   `fixture.parse(wast2json(text))`).

Proven by the differential corpus (`wat_parse ≡ decode ∘ wat2wasm` over `test/.../fixtures/*.wat`
and every inline module in the vendored `.wast`s), plus spec-cited unit tests for the lexer,
number literals, abbreviations, identifier resolution, folded expansion, type dedup, and the
script layer. Out-of-scope text (SIMD `v128.*`, GC `struct`/`array`/`ref $t`) is an **explicit,
categorized parse-skip** (`WatError.Unsupported` at module level → `CmdSkipped` at script level),
**never a silent mis-parse** (H5 scope-honesty).

---

## Files owned

| File | Role |
|---|---|
| `src/twocore/frontend/wasm/wat.gleam` | **NEW.** The lexer, the module recursive-descent parser (folded + flat, abbreviations, `$id` resolution, `(type)` dedup), and the `.wast` script parser. Produces `ast.Module` (`«WASM-AST3»`) + a neutral `Script` command list. |
| `test/twocore/frontend/wasm/wat_test.gleam` | **NEW.** Lexer/number/abbreviation/resolution/folded/type-dedup unit tests + the differential harness (`parse_module ≡ decode∘wat2wasm`) over the fixture corpus. |
| `test/twocore/frontend/wasm/wat_script_test.gleam` | **NEW.** `parse_script ≡ wast2json` differential + out-of-scope categorization tests. |

**Single-owner reaches I do NOT make (seams, not claims):** I do **not** edit `ast.gleam` (owned by
03), `validate.gleam`/`lower.gleam` (04/05), `fixture.gleam`/`runner.gleam`/`driver.gleam`
(conformance, 11/12). The conformance runner's adoption of my `Script`/`parse_module` is a **seam**
described in "What this unit leaves" and owned by unit 11.

---

## Deliverables & freeze milestones

- **`«WAT-API»` (day-1 publish).** The public signatures + the `WatError` / `Token` / `Script` /
  `WastValue` types, compiling with stub bodies, announced in `state.md`. This unblocks unit 11
  (conformance) from writing its adapter against my types in parallel. No downstream unit depends
  on my *implementation*, only these types.
- **Module parser** (`parse_module`) reaching full Phase-5 module surface.
- **Script parser** (`parse_script`) reaching the full command set.
- **The differential suite green** over the fixture corpus (the real DoD — see Verification).

This unit **produces no IR/runtime freeze**; it is a leaf of the DAG on the AST side. It only
*consumes* `«WASM-AST3»`.

---

## Depends on (freeze milestones)

| Milestone | From | Why |
|---|---|---|
| **`«WASM-AST3»`** | **03** (decode ext) | The *only* upstream dependency. I emit `ast.Module` and every `ast.Instr`/segment/import/export/valtype constructor unit 03 adds for Phase-5 (reftypes, bulk/table/ref instrs, passive/declarative segments, non-function imports/exports, multi-memory memidx, memory64 limits). I must use unit 03's **exact** AST3 names. Where AST3's final import/export/segment shape is still provisional, I scope against the provisional surface and flag the seam in Open questions. |

I do **not** depend on `«IR3»`, `«RT3-SIG»`, or `«INSTANTIATE3»`. I can start the lexer + number
layer immediately against the *current* `ast.gleam` and grow into AST3 as unit 03 publishes it.

---

## Scope — in / out

**In (parse to `ast.Module` / `Script`):**

- **Lexer:** parens, keywords (bare atoms incl. dotted mnemonics `i32.load8_u`), `$identifiers`,
  string literals (byte strings with `\XX`/`\u{…}`/`\t\n\r\"\\\'` escapes), integer literals
  (dec/hex, `_` separators, optional sign), float literals (dec float, **hex float** `0x1.8p3`,
  `inf`, `nan`, `nan:0x…` payloads), line comments `;; …`, **nesting** block comments `(; … ;)`,
  reserved tokens (for precise malformed-detection).
- **Module grammar:** the S-expression form *and* the flat instruction form; **folded**
  expressions; the full standard **abbreviations** (inline export/import; inline
  `(func)`/`(table)`/`(memory)`/`(global)`/`(elem)`/`(data)`; the active-`elem`/`data`
  abbreviations; the `(type)` use with inline `(param)`/`(result)` and **type dedup**); `$id →
  index` resolution across all eight index spaces; scoped label resolution `$l → relative depth`.
- **Every instruction mnemonic in Phase-5 scope** (§4-slice through reftypes/bulk/table/multi-mem/
  memory64), each mapped to its `ast.Instr` constructor.
- **`.wast` script grammar:** `(module …)` in **text / `binary` / `quote`** forms, `assert_return`,
  `assert_trap`, `assert_invalid`, `assert_malformed`, `assert_exhaustion`, `assert_unlinkable`,
  `assert_uninstantiable`, `register`, `invoke`, `get`, and the const/`ref.null`/`ref.extern`
  result values assertions carry.

**Out (deferred; categorized, never silently mis-parsed):**

- **SIMD text** (`v128`, `v128.const`, `i8x16.*`, lane immediates) → **Phase 6**. Encountering a
  `v128*` token inside a module returns `WatError.Unsupported(Simd, …)`; at script level the whole
  `(module …)` command becomes `CmdSkipped("simd")`. Never half-parse a lane immediate.
- **GC / typed-function-references text** (`(ref $t)`, `struct`/`array`/`i31`, `ref.cast`, …) →
  later. Same categorized skip (`Unsupported(Gc, …)`).
- **Custom-section text / annotations** `(@name …)` → skipped structurally (a WAT annotation is a
  no-op; drop it, don't error), matching wabt.
- **Semantic validity** — const-expr restriction, type-well-formedness, limit bounds, funcidx
  range, `global.set` on a const, etc. are **validate's** (unit 04), exactly as for the binary
  decoder. `parse_module` is the *malformed* boundary (lexically/grammatically ill-formed →
  `WatError`); `validate` is the *invalid* boundary (well-formed text that is ill-typed →
  `ValidateError`). Keeping this split is what makes `assert_malformed` (text) route to the parser
  and `assert_invalid` (text) route through the parser into `validate`. **Do not** typecheck in the
  parser.

---

## A. The lexer — token grammar

Spec: <https://webassembly.github.io/spec/core/text/lexical.html>. The text format is tokenized
into a flat token stream; whitespace and comments separate tokens and are otherwise insignificant.
The parser is a recursive-descent consumer of this stream.

```gleam
/// A source position, for error messages and for the `.wast` command `line` field
/// (the conformance runner keys skips/fails on line numbers). `line`/`col` are 1-based.
pub type Pos { Pos(line: Int, col: Int) }

/// A lexical token. `Keyword` covers every bare atom — a "keyword" in the spec's sense —
/// including dotted mnemonics (`i32.load8_u`), type keywords (`funcref`), and the module
/// field heads (`func`, `param`, `module`, `assert_return`). Numbers are kept as their RAW
/// lexeme (sans `_` separators) and interpreted by the parser at the point of use, because
/// the same lexeme means different bits at different widths (`i32.const 1` vs `i64.const 1`)
/// and some lexemes are float-only (`0x1p3`, `nan:0x…`). `Str` holds the DECODED bytes.
pub type Token {
  LParen(Pos)
  RParen(Pos)
  Keyword(Pos, text: String)
  Id(Pos, name: String)        // a `$name` identifier — `name` excludes the leading `$`
  Num(Pos, lexeme: String)     // an integer OR float lexeme; sign folded in; `_` stripped
  Str(Pos, bytes: BitArray)    // a string literal, escapes already resolved to bytes
  Reserved(Pos, text: String)  // an idchar run that is not a valid number/id — for malformed
}
```

### Lexical rules (cite `text/lexical.html` in tests)

| Class | Grammar | Notes |
|---|---|---|
| whitespace | `' '` `\t` `\n` `\r` | separators; `\n` bumps `Pos.line`. |
| line comment | `;;` … end-of-line | dropped. |
| block comment | `(;` … `;)` | **nests** — track depth; unterminated → `LexError(UnterminatedComment)`. This is a classic trap: `(; a (; b ;) c ;)` is one comment. |
| paren | `(` `)` | `LParen`/`RParen`. But `(;` is a comment open, not `(` then `;` — **peek two chars**. |
| id | `$` then ≥1 `idchar` | `idchar = [0-9A-Za-z!#$%&'*+\-./:<=>?@\\^_`|~]`. `$` alone → `Reserved`/error. |
| string | `"` … `"` with escapes | see below; a string may contain arbitrary bytes via `\XX`. |
| keyword | starts with a lowercase letter, then `idchar*` | `module`, `i32.add`, `funcref`, … |
| number | integer or float (§B), optional leading `+`/`-` | kept as `Num` lexeme. |
| reserved | any other maximal `idchar` run | e.g. a bare `123abc`; the parser rejects where a value/keyword was required. Modeling it (rather than erroring in the lexer) lets malformed cases produce a *grammatical* `WatError` at the parser, matching the spec's "reserved token" concept. |

### String escapes (`text/values.html#strings`)

Decode into a `BitArray` (byte string — WAT strings are **byte** strings, not necessarily UTF-8):
`\t \n \r \" \' \\` → the obvious bytes; `\XX` (two hex digits) → that raw byte; `\u{ H+ }` → the
UTF-8 encoding of that scalar (reject `> 0x10FFFF` / surrogates → `BadEscape`). Any other `\c` →
`BadEscape`. Module/export/import **names** are these byte strings validated as UTF-8 by the
parser only where the AST demands a `String` (export names); a `\u{…}` weird-name (`names.wast`)
must round-trip identically to `decode(wat2wasm)`.

```gleam
pub fn lex(source: String) -> Result(List(Token), WatError)
```

Total: any malformed lexeme (unterminated string/comment, bad escape, stray char) → a typed
`WatError` with a `Pos`, never a panic.

---

## B. Number literals → bits (the D5 discipline)

This is the load-bearing correctness surface of the lexer/parser boundary, and the one most likely
to diverge from wabt in the last bit. The parser interprets a `Num` lexeme **at the point of use**,
because width and int-vs-float are context-determined:

| Context | Accepts | Produces (into the AST) |
|---|---|---|
| `i32.const` | `sN`(32) ∪ `uN`(32): dec/hex integer in `[-2³¹, 2³²)` | the **raw 32-bit pattern** as an `Int` in `[0, 2³²)` — `I32Const(bits)`. Spec: text/instructions, integer literals fold both signed & unsigned range then take the two's-complement bits. |
| `i64.const` | `sN`(64) ∪ `uN`(64) | raw 64-bit pattern, `I64Const(bits)`. |
| `f32.const` | dec float, hex float, `inf`, `nan`, `nan:0xH…`, or an **integer** lexeme (e.g. `1`) | raw **binary32** bits, `F32Const(bits)`. |
| `f64.const` | same float forms | raw **binary64** bits, `F64Const(bits)`. |
| index/offset/align (e.g. `memory 1`, `offset=4`, `align=8`) | `uN`(32)/`uN`(64) | the integer value (align is `log2`-encoded per the memarg rules — a WAT `align=8` means the raw exponent `3`; **the parser converts `align=N` to `log2(N)`**, rejecting non-powers-of-two → `BadAlign`). |

**Integer literals** (`text/values.html#integers`): `0x`-prefixed hex or decimal; `_` digit
separators allowed *between* digits (`1_000`, `0xff_ff`); optional leading `+`/`-`. Compute the
mathematical value with BEAM bignums (no overflow), check it is in `sN ∪ uN` for the width, then
mask to the width's raw bits (`value band (2^w − 1)`). Out of range → `NumberOutOfRange`.

**Float literals** (`text/values.html#floating-point`):

- **Decimal float** `[+-]? d(_?d)* (. (d(_?d)*)?)? ([eE][+-]?d(_?d)*)?` → binary32/64 with
  **round-to-nearest-ties-to-even** (the spec's `float_N`). ⚠️ This is the hard case:
  BEAM's `erlang:list_to_float/1` is **not** a safe path (it rejects integer-looking forms, no hex,
  and its rounding for extreme magnitudes is not guaranteed to match). See Open questions for the
  recommended exact-decimal→float routine.
- **Hex float** `0x h(_?h)* (. (h(_?h)*)?)? ([pP][+-]?d(_?d)*)?` → **exact** (a hex float names a
  dyadic rational; build mantissa + binary exponent and pack the bits directly, rounding only on
  the low mantissa bits). This path is exact and should be implemented first.
- `inf` → `0x7F800000` (f32) / `0x7FF0000000000000` (f64); `[+-]inf` sets the sign bit.
- `nan` → the **canonical** NaN (`0x7FC00000` f32 / `0x7FF8000000000000` f64).
- `nan:0xH…` → a NaN with that **payload** in the mantissa (payload must be non-zero and fit the
  mantissa width; `0` or overflow → `BadNanPayload`). Sign from an optional leading `-`.

**Grounded vectors** (verified against `wat2wasm`; assert these):

| Lexeme (context) | Bits |
|---|---|
| `i32.const -1` | `0xFFFFFFFF` |
| `i32.const 0xffffffff` | `0xFFFFFFFF` (u32 range accepted) |
| `f32.const 0x1p+0` | `0x3F800000` |
| `f32.const nan:0x200000` | `0x7FA00000` |
| `f32.const inf` | `0x7F800000` |
| `f64.const -inf` | `0xFFF0000000000000` |

Floats are **never** carried as BEAM doubles anywhere in this path (overview D5): a BEAM double
cannot represent a NaN payload or a signaling NaN, so `f32.const nan:0x200000` would be destroyed.
Extract/construct raw bits only, exactly as the binary decoder does with `<<bits:32-little>>`.

---

## C. The module parser — index spaces & identifier resolution

Spec: <https://webassembly.github.io/spec/core/text/modules.html>. The binary decoder never sees a
name — the text format has **eight** identifier contexts, each its own `$id → Int` map, and the
parser must resolve every `$id` to the exact numeric index the binary form would carry (so the AST
is structurally equal to `decode(wat2wasm)`).

```gleam
/// The per-module symbol environment: one `$name → index` map per index space, built as
/// definitions are encountered. `locals`/`labels` are function-scoped (pushed/popped);
/// the rest are module-scoped.
pub type Env {
  Env(
    types: NameMap, funcs: NameMap, tables: NameMap, mems: NameMap,
    globals: NameMap, elems: NameMap, datas: NameMap,
    // function scope:
    locals: NameMap, labels: List(Option(String)),
  )
}
type NameMap = dict.Dict(String, Int)
```

### The index-space rules that MUST match the binary form

1. **Imports come first in every index space they touch.** An imported function occupies
   funcidx `0..k-1` *before* any defined function; likewise imported tables/memories/globals
   precede defined ones. So `imported_func_count` (and the analogous table/mem/global import
   counts) are assigned during a **first pass** that walks module fields in source order and
   allocates indices, honoring the imports-first rule. `wat2wasm` does exactly this; matching it is
   mandatory for differential equality.
2. **Forward references are legal.** `call $f` / `ref.func $g` / `(elem … $h)` may name a function
   defined later; a global's index may be used before its definition only where the const-expr
   rules allow. Therefore parsing is **two-pass**: pass 1 assigns every definition its index and
   records `$id → index` (also materializing implicit type definitions from inline type-uses and
   implicit definitions from inline imports/exports — §D/§E); pass 2 parses bodies and **resolves**
   every `$id` use against the completed `Env`.
3. **Locals share one space with params.** Params occupy local indices `0..p-1`, declared locals
   follow at `p..`. `local.get $x` resolves in that combined space. (Matches `Func.locals` being
   declared-only while indices count params first — the same convention the decoder uses.)
4. **Labels are a *scoped, relative* space.** `block $l … br $l` resolves `$l` to the **relative
   depth** from the `br` to the labelled construct (0 = innermost). The parser keeps a `labels`
   stack (push on entering `block`/`loop`/`if`, pop on `end`); `br $l` = the position of `$l`
   counted from the top. An unlabelled `br 2` passes through as the literal depth. This converts
   named labels to the exact `Br(label: Int)`/`BrIf`/`BrTable` relative indices the decoder emits.
5. **Duplicate `$id` in one space → `DuplicateIdentifier`.** (Two `$x` funcs, two `$l` at the same
   nesting, …) The spec forbids it; wabt errors; we must too (it is a `malformed` case).
6. **Unbound `$id` → `UnboundIdentifier(space, name)`.** A `malformed`/`unbound` case.

### Resolution examples

| Text | Resolves to |
|---|---|
| `(func $a) (func $b …) (call $a)` inside `$b` | `Call(func: 0)` (a = funcidx 0). |
| `(import "m" "f" (func $imp …)) (func $d) (call $d)` | `$imp`=0, `$d`=1 → `Call(1)`; `imported_func_count = 1`. |
| `(block $outer (loop $inner (br $outer)))` | `Br(label: 1)` (outer is 1 out from inside the loop). |
| `(func (param $p i32) (local $t i32) (local.set $t (local.get $p)))` | `LocalSet(1)`/`LocalGet(0)`. |

---

## D. Abbreviations & inline forms (desugaring table)

Spec: <https://webassembly.github.io/spec/core/text/modules.html> (the "Abbreviations" boxes).
The text format's redundancy is almost entirely here. The parser **desugars** each to the same
canonical module fields the binary form encodes, so the resulting `ast.Module` is identical to
`decode(wat2wasm)`. Each row is a spec-cited rewrite the parser applies:

| Abbreviation (text) | Desugars to |
|---|---|
| **inline export** `(func $f (export "e") …)` | the func definition **plus** an `Export("e", ExportFunc, idx($f))`. Same for `(table …)`/`(memory …)`/`(global …)`. Multiple `(export …)` on one item are all emitted. |
| **inline import** `(func $f (import "m" "n") (param …)(result …))` | an **import** entry (`ImportFn`/…), *not* a defined function. Consumes a func-index slot in imports-first order. Combined with `(export …)` → both an import and an export of the imported item. |
| **inline table + elem** `(table $t funcref (elem $a $b))` | `(table $t <n> <n> funcref)` where `n = 2` **plus** an active `(elem (table $t)(i32.const 0) func $a $b)`. |
| **inline memory + data** `(memory $m (data "…"))` | `(memory $m <pages> <pages>)` sized to `ceil(len/65536)` **plus** an active `(data (memory $m)(i32.const 0) "…")`. |
| **inline global** `(global $g (mut i32) (i32.const 0))` | a `Global` with `mutable: True`. |
| **active elem abbrev** `(elem (i32.const 0) $a $b)` | `ElementSegment` active, table 0, `func` reftype, `init = [RefFunc $a, RefFunc $b]`. The bare-funcidx list form and the `(elem … funcref (item …))` expression form both land in the AST3 `init: List(Expr)`. |
| **active data abbrev** `(data (i32.const 0) "…")` | active `DataSegment`, mem 0. |
| **`offset` shorthand** `(elem (offset (i32.const 0)) …)` and the bare `(i32.const 0)` | both → the offset const-expr. |
| **start** `(start $f)` | `Module.start = Some(idx($f))`. |
| **type-use** `(type $t)` / inline `(param)(result)` | see §E. |
| **memarg defaults** `i32.load` (no `offset=`/`align=`) | `MemArg(offset: 0, align: <natural log2>)` — natural alignment is the access width's log2 (`i32.load`→2). Explicit `offset=`/`align=` override; order is `offset` then `align` but both optional and either order accepted per spec. |
| **`funcref`/`externref` keyword** in `table`/`elem`/`select`/`ref.null` | maps to the AST3 `RefType` tag (`funcref`→`FuncRef`, `externref`→`ExternRef`; legacy `anyfunc` = `funcref`). |

**Worked desugaring** (assert the after-form parses identically to the explicit spelling):

```
(module (func $f (export "sq") (param $x i32) (result i32)
          (i32.mul (local.get $x) (local.get $x))))
```
desugars to a module with `funcs = [Func(type_idx: 0, locals: [], body: [LocalGet(0),
LocalGet(0), I32Mul, End])]`, `types = [FuncType([I32],[I32])]`, `exports = [Export("sq",
ExportFunc, 0)]` — **byte-for-byte the `decode(wat2wasm(...))` AST**.

---

## E. Type uses & the `(type)` dedup

Spec: <https://webassembly.github.io/spec/core/text/modules.html#type-uses>. A *type use* is how a
`func`/`import`/`call_indirect`/`block` references a function type: either `(type $t)`, or inline
`(param …)*(result …)*`, or both. The resolution algorithm (which the parser must reproduce to
match wabt's type-section indices):

1. If `(type x)` is present → the type index is `x` (resolved through the `types` map). If inline
   `(param)/(result)` are *also* present, they must be **structurally equal** to type `x`'s
   signature, else `InlineTypeMismatch`.
2. If only inline `(param)/(result)` are present → search the *existing* `types` for the first that
   is structurally equal; if found, reuse its index (**dedup**); else **append** a new type and use
   the new index.
3. A bare `call_indirect` with no type use is a shorthand for the empty type; a `block`/`loop`/`if`
   with a single `(result t)` and no params is the `BlockVal(t)` shorthand (no type appended); any
   params or ≥2 results → a type-use (append/dedup) → `BlockTypeIdx`.

**Grounded** (`wat2wasm` verified): `(type (func (param i32)(result i32))) (func (param i32)(result
i32) …)` produces **one** type (index 0, reused), not two. `(func (param i32 i32)(result i32) …)
(func (param i32)(result i32) …)` produces two types (0 and 1) in first-appearance order. The
parser's dedup + append order must be identical.

The one place this can silently diverge is **implicit type ordering**: when several functions
introduce inline types, wabt appends them in the order they're *first* needed. Pass 1 must walk
fields in source order and append implicit types exactly then (not in a later batch), or the
indices shift. This is the single most fragile equality; the differential corpus is what proves it.

---

## F. Instructions — folded & flat, blocktypes, labels, the mnemonic map

Spec: <https://webassembly.github.io/spec/core/text/instructions.html>. A function body is a
sequence of instructions in **either** notation, freely mixed:

- **Flat (plain):** `local.get 0` `i32.const 2` `i32.mul` — one instruction per token-run, operands
  implied by the stack. Each maps 1:1 to an `ast.Instr` (appended in order).
- **Folded (S-expression):** `(i32.mul (local.get 0) (i32.const 2))` — a parenthesized instruction
  whose *operand* sub-expressions are emitted **first**, then the head instruction. Desugaring is a
  post-order flatten: `[LocalGet(0), I32Const(2), I32Mul]`. **Grounded:** `wasm-tools print` of both
  spellings yields the identical flat stream — assert equality.

### Structured control (block/loop/if) — labels + blocktype + `end`

- `block <label>? <blocktype> <instr>* end <label>?` → push `<label>` on the label stack, parse the
  blocktype (§E shorthand → `BlockEmpty`/`BlockVal`/`BlockTypeIdx`), emit `Block(bt)`, parse the
  body, emit `End`, pop. A trailing `end $l`/`else $l` must match the opening label or
  `MismatchedLabel`.
- **Folded `if`:** `(if <bt> (<cond>) (then <instr>*) (else <instr>*)?)` desugars to `<cond>` `If(bt)`
  `<then>*` `Else` `<else>*` `End`. The plain `if … else … end` form is parsed directly. The
  `else` is emitted **even when absent in the folded `then`-only form**? No — per spec the `else` /
  `Else` marker is present iff there is an else-branch or the block has results; match the decoder's
  behavior (the decoder emits an `Else` only when the binary has one). **Match `decode(wat2wasm)`
  exactly** — the differential test governs this edge.
- **Folded `block`/`loop`:** `(block <label>? <bt> <instr>*)` → `Block(bt)` `<instr>*` `End`.

### The mnemonic map

Every mnemonic maps to exactly one `ast.Instr` constructor (`«WASM-AST3»`). Rather than restate the
~450-row table (it is the inverse of the binary opcode tables in units 05/07 + the Phase-5 additions
in unit 03), the parser holds a single `keyword → decoder` dispatch that:

- **no-immediate leaves** (`i32.add`, `f64.sqrt`, `drop`, `unreachable`, `nop`, `return`,
  `memory.size`/`memory.grow`, all compares/numeric/conversions) → the bare constructor;
- **`t.const`** → parse the number at the right width (§B);
- **`local.*`/`global.*`/`call`** → parse one `$id`/index → resolve;
- **`call_indirect`** → a type-use (§E) **and** an optional table `$id`/index (default 0) → `CallIndirect(type_idx, table)`. ⚠️ order in text is `call_indirect <tableidx>? (type …)` — the AST field order is `(type_idx, table)`; do not swap;
- **`br`/`br_if`** → one label → relative depth; **`br_table`** → a list of labels + the default label;
- **loads/stores** → an optional `memidx`? (multi-memory, §G) + `offset=`/`align=` memarg → the width-specific constructor;
- **`select`** → bare `Select`, or `select (result t)` typed-select (AST3);
- **`block`/`loop`/`if`/`else`/`end`** → the structured handling above;
- **reftype/bulk/table** (§G) → their AST3 constructors;
- **unknown keyword** → `UnknownMnemonic(kw)`; **`v128.*`/GC** → `Unsupported(Simd|Gc, kw)`.

An `UnknownMnemonic` and an `Unsupported` are **distinct** on purpose: the former is a genuine
malformed input (should never appear in a valid `.wat`), the latter is a deliberate, categorized
out-of-scope skip that the differential harness counts separately.

---

## G. Reference / table / bulk / multi-memory / memory64 text surface (Phase-5)

These are the mnemonics unit 03 adds to `ast.Instr` / the AST3 segment & import/export shapes; the
parser maps the text spellings to them. Spec: reference types & bulk memory are in the living
standard (`text/instructions.html`, `text/modules.html`); cite the WASM-2.0 text grammar.

| Text | `ast.Instr` (AST3) | Notes |
|---|---|---|
| `ref.null func` / `ref.null extern` | `RefNull(FuncRef)` / `RefNull(ExternRef)` | the keyword after `ref.null` is a heaptype. |
| `ref.func $f` | `RefFunc(funcidx)` | forward ref allowed; also legal only if `$f` is declared (validate's rule). |
| `ref.is_null` | `RefIsNull` | leaf. |
| `table.get $t?` / `table.set $t?` | `TableGet(tableidx)` / `TableSet(tableidx)` | table `$id`/index optional (default 0). |
| `table.size $t?` / `table.grow $t?` / `table.fill $t?` | `TableSize`/`TableGrow`/`TableFill` | |
| `table.init $t? $e` / `elem.drop $e` | `TableInit(tableidx, elemidx)` / `ElemDrop(elemidx)` | elem segment `$id`/index. |
| `table.copy $d? $s?` | `TableCopy(dst, src)` | two optional table refs (default 0,0). |
| `memory.fill $m?` | `MemFill(memidx)` | multi-mem index optional (default 0). |
| `memory.copy $d? $s?` | `MemCopy(dst_mem, src_mem)` | |
| `memory.init $m? $d` / `data.drop $d` | `MemInit(memidx, dataidx)` / `DataDrop(dataidx)` | data segment `$id`/index. |
| `select (result t)` | typed select | lowers to `If`-merge downstream (H2); at AST level it is the typed-`select` constructor unit 03 defines. |

### Segments, tables, imports/exports of state, memory64

- **Element segments** (`text/modules.html#element-segments`): active `(elem $id? (table $t)?
  (offset …) funcref? (item …)|$funcidx*)`, **passive** `(elem $id? funcref (item …))`,
  **declarative** `(elem $id? declare func $f*)`. Map to AST3 `ElementSegment(mode, ref_ty, init)`
  with `ElemActive`/`ElemPassive`/`ElemDeclarative`. `init` items are `RefFunc`/`RefNull`
  const-exprs (the bare funcidx list is the `func $f*` abbreviation → `[RefFunc $f, …]`).
- **Data segments:** active `(data $id? (memory $m)? (offset …) "…")` and **passive** `(data $id?
  "…")` → AST3 `DataSegment(DataActive(mem, offset) | DataPassive, bytes)`.
- **Non-function imports** `(import "m" "n" (global $g i32))` / `(table …)` / `(memory …)` and their
  inline forms → AST3's `ImportGlobal`/`ImportTable`/`ImportMemory` (unit 03/keystone shape). **Exports
  of state** `(export "g" (global $g))` / `(table …)` / `(memory …)` → AST3 `ExportGlobal`/
  `ExportTable`/`ExportMemory`. (These are exactly what the suite's `(get "m" "g")` and the
  `spectest` module need — H4.)
- **Table reftype:** `(table $t 1 10 externref)` → `TableDecl(ref_ty: ExternRef, …)`; the element
  type keyword is required in the reftypes form (default `funcref` in the legacy 1-arg form).
- **memory64:** `(memory $m i64 1 2)` — the `i64`/`i32` index-type keyword before the limits →
  AST3 `MemoryDecl(idx_type: Idx64|Idx32)`. Absent → `Idx32`. A memory64 memarg may carry a `u64`
  offset (parse the offset as `uN(64)` when the target memory is `i64`). *(Deferrable half — if
  unit 08 cuts memory64, the parser still parses the syntax and lets validate reject it; flag in
  Open questions.)*

**Conformance-neutral defaults (H7):** a module with one 32-bit memory, funcref-only active elems,
function-only imports, and no ref/bulk ops must parse to the **identical** `ast.Module`
Phase-4/`decode` produces — the AST3 defaults (`Idx32`, `FuncRef`, `ElemActive`, `DataActive(0,_)`,
memidx 0) fall away and the differential equality still holds over the whole existing corpus.

---

## H. The `.wast` script command layer

Spec: the reference-interpreter **script** grammar (WebAssembly/spec `interpreter/README.md`,
`test/core/`). This is *not* in the core spec document proper — it is the harness language wabt's
`wast2json` consumes. I parse it into a neutral `Script` the conformance runner drives (via unit
11's adapter). Every command carries its source `line` (from the head token's `Pos.line`) so the
runner's `at(src, line)` reporting is unchanged.

```gleam
pub type Script = List(ScriptCommand)

pub type ScriptCommand {
  CmdModule(mod: ScriptModule)
  CmdRegister(line: Int, as_name: String, module: Option(String))
  CmdAction(line: Int, action: ScriptAction)                       // bare (invoke …)/(get …)
  CmdAssertReturn(line: Int, action: ScriptAction, expected: List(WastValue))
  CmdAssertTrap(line: Int, action: ScriptAction, text: String)
  CmdAssertExhaustion(line: Int, action: ScriptAction, text: String)  // "call stack exhausted"
  CmdAssertInvalid(line: Int, mod: ScriptModule, text: String)
  CmdAssertMalformed(line: Int, mod: ScriptModule, text: String)
  CmdAssertUnlinkable(line: Int, mod: ScriptModule, text: String)
  CmdAssertUninstantiable(line: Int, mod: ScriptModule, text: String)
  CmdSkipped(line: Int, kind: String)   // an out-of-scope command (SIMD/GC/thread) — categorized
}

/// A module in a script: parsed text, a quoted text to (re)parse, or raw bytes.
pub type ScriptModule {
  ModText(name: Option(String), module: ast.Module)
  ModQuote(name: Option(String), source: String)   // (module quote "…") — re-parse the string
  ModBinary(name: Option(String), bytes: BitArray)  // (module binary "…") — feed decode directly
}

pub type ScriptAction {
  ActInvoke(field: String, args: List(WastValue), module: Option(String))
  ActGet(field: String, module: Option(String))
}

/// A value in an assertion. Numeric values carry RAW bits (D5); NaN carries only a class;
/// reference values carry the reftype + a null flag / an extern payload int.
pub type WastValue {
  WI32(bits: Int)  WI64(bits: Int)  WF32(bits: Int)  WF64(bits: Int)
  WF32Nan(canonical: Bool)  WF64Nan(canonical: Bool)
  WRefNull(ty: RefType)  WRefFunc  WRefExtern(payload: Int)
}
```

### Command semantics (each a spec-cited rewrite)

- **`(module …)`** → `ModText` (parse the fields with `parse_module`), keeping an optional `$name`.
  **`(module $n? binary "…"*)`** → `ModBinary` (concatenate the byte-string literals; this is how
  the suite injects hand-crafted malformed binaries — they go straight to `decode`, **not** the
  text parser). **`(module $n? quote "…"*)`** → `ModQuote` (the concatenated string is WAT text to
  be parsed when the command runs — used by `assert_malformed (module quote …)`).
- **`(assert_return <action> <result>*)`** — the results are the `WastValue`s above; `ref.null`,
  `ref.func` (any non-null funcref), `ref.extern n`, and the `nan:canonical`/`nan:arithmetic`
  classes are all parsed. This is what lets the reftype suite files assert against real reference
  values (which today's JSON path stubs).
- **`(assert_trap <action> "<text>")`** / **`(assert_exhaustion <action> "<text>")`** — the
  expected trap-message substring; exhaustion is `"call stack exhausted"`.
- **`(assert_invalid <module> "<text>")`** — the module must **parse** but fail **validate**
  (routed to `check_frontend`). **`(assert_malformed <module> "<text>")`** — the module (usually a
  `quote` or `binary`) must fail at **parse/decode**. Keeping the parse-vs-validate split from §Scope
  is exactly what makes these two route correctly.
- **`(assert_unlinkable <module> "<text>")`** / **`(assert_uninstantiable <module> "<text>")`** —
  well-formed + valid, must fail at **link/instantiate** (the import/`spectest` machinery, unit 09).
- **`(register "name" $mod?)`** → `CmdRegister` (H4's multi-module registry substrate).
- **bare `(invoke …)` / `(get …)`** → `CmdAction` (side-effecting setup / a global read).
- **any other head** (`assert_return_canonical_nan` legacy, thread commands, SIMD-only asserts) →
  `CmdSkipped(kind)`. Never dropped silently.

**Differential DoD for the script layer:** `parse_script(text)` must be *equivalent* to
`fixture.parse(wast2json(text))` — same command sequence, same line numbers, same action fields,
same expected values (modulo the JSON path's stubbing of reftype values, which our path fills in).
This is a clean end-to-end check that the whole script grammar is covered.

---

## I. Error model & totality

```gleam
/// Every reason WAT text is rejected. UNTRUSTED input → exactly one of these, never a panic
/// (D4). Each carries a `Pos` where sensible. `Unsupported` is the categorized out-of-scope
/// skip (SIMD/GC) — DISTINCT from `UnknownMnemonic` (a genuine malformation).
pub type WatError {
  LexError(pos: Pos, kind: LexErrorKind)          // UnterminatedString/Comment, BadEscape, StrayChar
  UnexpectedToken(pos: Pos, want: String, got: String)
  UnexpectedEof(want: String)
  UnknownMnemonic(pos: Pos, keyword: String)
  UnboundIdentifier(pos: Pos, space: String, name: String)
  DuplicateIdentifier(pos: Pos, space: String, name: String)
  MismatchedLabel(pos: Pos, open: Option(String), close: Option(String))
  InlineTypeMismatch(pos: Pos)                    // (type x) inline (param/result) disagree
  NumberOutOfRange(pos: Pos, lexeme: String)
  BadNanPayload(pos: Pos, lexeme: String)
  BadAlign(pos: Pos, value: Int)                  // align= not a power of two
  Unsupported(pos: Pos, category: Category, detail: String)  // Simd | Gc | Thread
}
```

Public surface:

```gleam
pub fn lex(source: String) -> Result(List(Token), WatError)
pub fn parse_module(source: String) -> Result(ast.Module, WatError)
pub fn parse_script(source: String) -> Result(Script, WatError)
/// Resolve a ScriptModule to what the runner feeds a stage: text/quote → ast.Module (parse),
/// binary → bytes (for decode). A convenience the unit-11 adapter can use or reimplement.
pub fn script_module_ast(m: ScriptModule) -> Result(ScriptModuleResolved, WatError)
```

**Totality (D4).** No `let assert`, `panic`, `todo`, or partial pattern is reachable from input
text. The lexer and both parsers thread a token cursor and return `Result` at every step; malformed
input always lands on a typed `WatError`. A byte-mutation/truncation fuzz over the fixtures must
yield only `Ok(_) | Error(WatError)` — never a crash (the same *totality* property the binary
decoder proves in unit 05).

---

## Effect / soundness / security note

The WAT parser is **tooling/test input**, not a runtime capability boundary — but it is still
**untrusted input** and inherits the fail-closed discipline: (a) it is **total** (no panic on any
string); (b) it does **not** widen the validation boundary — a parsed module is *not* trusted-valid;
it flows through the **unchanged `validate`** exactly like a decoded module, so the security
properties of the pipeline (D3a no-ambient-authority, fail-closed traps, `externref` opacity) are
untouched. Critically, the **parse-vs-validate split** is a soundness obligation: `parse_module`
must *accept* well-formed-but-ill-typed text (so `assert_invalid` text cases reach `validate` and
are rejected there) and *reject* only genuinely malformed text (so `assert_malformed` text cases
are rejected here). Collapsing the two — e.g. typechecking in the parser — would make `assert_invalid`
text cases fail at the wrong stage and mask real validator bugs. The out-of-scope categorization
(SIMD/GC → `Unsupported`/`CmdSkipped`) is also a soundness property: a silently mis-parsed SIMD
instruction could produce a wrong-but-runnable module, so it must be an *explicit* skip, never a
best-effort parse (H5/H8 scope-honesty).

---

## Verification — Definition of Done (D8)

Tests assert **spec behavior** and **differential equivalence to wabt**, never change-detector
equality with our own output. Cite the `text/*.html` spec URLs and the fixture files.

1. **The differential module corpus (the real DoD).** For every `.wat` in the fixture tree and
   every inline text `(module …)` in the vendored `.wast`s: assert
   `parse_module(text) == decode(wat2wasm(text))` as `ast.Module` (**structural AST equality** — the
   strongest check; it catches type-dedup/index/label divergences). Where structural equality is
   legitimately infeasible (custom `name` sections wabt injects, field-ordering wabt normalizes),
   fall back to a **behavioral** check: run *both* ASTs through `validate → lower →
   pipeline.ir_to_core` and assert identical `.core` text (or run the file's assertions through both
   and assert identical pass/fail). Report the count of files proven by each level.
2. **Lexer unit tests** (cite `text/lexical.html`): nesting block comments `(; a (; b ;) c ;)` = one
   comment; unterminated comment/string → typed error; `;;`-to-EOL; string escapes `\t\n\r\"\'\\`,
   `\41`→`A`, `\u{1F600}`→4 UTF-8 bytes, bad `\q`→`BadEscape`; `$weird!id` idchars; a reserved run
   `1$foo` rejected where a value is required.
3. **Number literals** (cite `text/values.html`): the §B grounded vectors; the `float_literals.wast`
   / `const.wast` values decoded to exact bits (round-trip against `wat2wasm`); `nan:0x…` payloads;
   hex floats `0x1.8p3`, `0x1p-149` (f32 min subnormal); `i32.const 0xffffffff` = `i32.const -1`;
   `_` separators; out-of-range → `NumberOutOfRange`.
4. **Abbreviations** (cite `text/modules.html`): each row of §D — assert the abbreviated spelling
   parses to the identical `ast.Module` as its explicit desugaring **and** as `decode(wat2wasm)`.
   Inline import/export, inline `table+elem`, inline `memory+data`, inline global, `start`.
5. **Identifier resolution** (§C): forward `call $f`; imports-first funcidx offset; scoped/relative
   labels (`br $outer` from inside a nested loop → the right depth); param/local shared space;
   `DuplicateIdentifier`; `UnboundIdentifier`.
6. **Type dedup** (§E): inline-type reuse vs append order matches `wat2wasm` (the grounded cases);
   `call_indirect (type $t)` and inline `(param)(result)`; the block-type shorthand
   (`BlockVal` vs appended `BlockTypeIdx`).
7. **Folded ↔ flat** (§F): `(i32.mul (local.get 0)(i32.const 2))` ≡ the flat stream; folded `if
   (then)(else)`; folded `block`/`loop`; mixed notation in one body — all equal to
   `decode(wat2wasm)`.
8. **Phase-5 surface** (§G): `ref.null func/extern`, `ref.func`, `ref.is_null`; `table.get/set/
   size/grow/fill`; `table.init/copy`, `elem.drop`; `memory.fill/copy/init`, `data.drop`; passive &
   declarative `elem`; passive `data`; `select (result …)`; non-function imports/exports;
   `externref` tables; multi-memory memidx; `(memory i64 …)` — each equal to the reftypes/bulk
   `decode(wat2wasm)` AST. Spec files: `reftype.wast`, `ref_null.wast`, `ref_func.wast`,
   `ref_is_null.wast`, `table_get.wast`, `table_set.wast`, `table_grow.wast`, `table_size.wast`,
   `table_fill.wast`, `table_copy.wast`, `table_init.wast`, `elem.wast`, `bulk.wast`,
   `memory_fill.wast`, `memory_copy.wast`, `memory_init.wast`, `select.wast`.
9. **Script layer** (§H): `parse_script(text)` ≡ `fixture.parse(wast2json(text))` over the vendored
   `.wast`s — same command sequence, line numbers, actions, and (numeric) expected values. Assert a
   `(module quote …)`/`(module binary …)` command carries the right `ScriptModule` variant; assert
   `assert_malformed (module quote …)` text cases now **reject at parse** (they skipped before);
   assert `assert_invalid (module …)` text cases **parse then fail validate**.
10. **Out-of-scope categorization** (H8): a `v128.const`/`i8x16.add` inside a module →
    `Unsupported(Simd, _)`; a GC `(ref $t)` → `Unsupported(Gc, _)`; the script command becomes
    `CmdSkipped("simd")`. Assert the harness **counts** these skips, and that no SIMD/GC token is
    ever silently accepted (feed a SIMD `.wat` and assert an error, not an `Ok`).
11. **Totality (D4):** grep `wat.gleam` for `let assert`/`panic`/`todo` (none reachable from input);
    a byte-mutation/truncation fuzz over the fixtures yields only `Ok | Error(WatError)`.
12. **Clean build:** `gleam format --check src test` clean; `gleam build` **zero warnings**; `///`
    contract docs (what / params / `Result` semantics / failure modes) on every public type &
    function; `////` module doc citing the `text/*` spec URLs.

The DoD is **the differential suite passes**, not "it compiles" (D8). When the parser and wabt
disagree on a corpus file, the parser is presumed wrong (the spec/wabt wins) until proven otherwise.

---

## What this unit leaves

- **`wat.gleam` (`«WAT-API»`)** — `parse_module`/`parse_script`/`lex` + the `WatError`/`Token`/
  `Script`/`ScriptModule`/`ScriptAction`/`WastValue` types. A reusable text frontend for any future
  consumer (a WAT-based fixture author, a REPL).
- **The conformance seam (owned by unit 11).** Unit 11 writes a thin adapter mapping my `Script` →
  the runner's command drive: `ModText`→`instantiate(lower∘validate∘parse)`, `ModBinary`→
  `instantiate(decode bytes)`, `ModQuote`→re-parse, `WastValue`→`fixture.SpecValue`, and the text
  `assert_malformed`/`assert_invalid` cases into `check_frontend`. The runner's current
  `"no WAT parser"` skip branch (`runner.gleam:322`) is deleted by unit 11 once the adapter lands —
  **I do not touch `runner.gleam`/`fixture.gleam`.**
- **The un-`wast2json`-able suite files** become runnable **from our own parser** — the headline
  H5 unlock feeding unit 11's conformance expansion + the capstone's skip-count-drop.

---

## Open questions (for the planner / cross-unit sync)

1. **Split this unit?** It is two loosely-coupled halves: the **module parser** (lexer + grammar +
   abbreviations + resolution — the large, self-contained frontend) and the **`.wast` script layer**
   (a thin command grammar over it, conformance-facing). They share only the lexer. I recommend
   **splitting P5-10 into P5-10a (module parser, `parse_module`+`lex`) and P5-10b (`.wast` script,
   `parse_script`+`Script`)**, with 10a publishing `«WAT-API-CORE»` (the lexer + `parse_module` +
   `WatError`) that 10b builds on. 10a is the critical mass; 10b is small once 10a exists. Kept as
   one unit here per the brief, but flagged.

2. **Where does the `.wast` script layer live, and who owns the `Script→Command` adapter?** I place
   `Script`/`parse_script` in `wat.gleam` (a `src/` module — reusable, no test-tree dependency). But
   `Script` deliberately mirrors `fixture.Command`/`Action`/`SpecValue` (owned by conformance). Two
   options: (a) I define the neutral `Script`/`WastValue` and unit 11 adapts (my recommendation —
   clean single-owner); (b) conformance's `fixture.gleam` is *extended* to parse `.wast` directly
   using my `parse_module`, and I expose only `parse_module`. The provisional surface doesn't pin
   this — needs a reconcile-pass decision so `WastValue`↔`SpecValue` isn't double-modeled.

3. **`«WASM-AST3»` import/export/segment shape.** My §G maps rely on unit 03's *final* AST3 names for
   non-function imports/exports, passive/declarative element `init: List(Expr)`, typed `select`, and
   the `MemoryDecl.idx_type`/`TableDecl.ref_ty` tags. The provisional surface gives IR3 names; the
   **AST3** counterparts (in `ast.gleam`, owned by 03) may differ (e.g. `ast.Module` currently has
   no `imports` field at all — only `imported_func_count`). I scope against the provisional shapes;
   **03 must publish the AST3 import/export representation** before I can finish §G. Flagged as the
   one true blocking dependency.

4. **Decimal-float rounding.** Producing the *exact* IEEE-754 bits for an arbitrary decimal float
   with round-to-nearest-ties-to-even is the single hardest numeric task here, and `float_literals.
   wast` stresses it. BEAM's `list_to_float` is not a safe path (§B). Options: (a) reuse an existing
   proven big-integer decimal→float routine (implement the "scale by powers of ten in bignums, then
   round the quotient" algorithm — total, exact); (b) restrict the parser to **hex floats + the
   decimal subset the fixtures actually use** and skip the pathological decimals with a categorized
   note. The differential corpus (compare bits against `wat2wasm`) is the arbiter. Recommend (a);
   flag the effort. Hex floats are exact and land first regardless.

5. **memory64 syntax vs. the deferrable half (H8).** The parser can *parse* `(memory i64 …)` and
   `u64` memargs cheaply even if unit 08 cuts memory64 execution to Phase 6. Recommendation: **parse
   the syntax unconditionally** (so the AST is complete and `validate` decides), rather than gate the
   grammar on whether memory64 ships. Confirm with 08's owner so a memory64 `.wat` yields a
   `validate` rejection (in scope) rather than a `parse` rejection (wrong stage).

6. **Line-number fidelity for `.wast` commands.** The conformance runner reports `src:line`. wabt's
   `wast2json` emits the `line` of each command's head. I take `Pos.line` of the command's opening
   token — but multi-line folded commands and `;;`-comment lines must not shift the count. The §H
   differential (`parse_script ≡ wast2json`) includes line-number equality; if wabt's line semantics
   differ subtly (e.g. it reports the `assert_*` keyword's line, not the `(`), the differential will
   surface it and I match wabt.

# Unit 02 — The `.ir` printer/parser extension (IR2 variants)

> **1 owner. Wave A, fast-follow OFF the freeze critical path.** Hard freeze dep:
> `«IR2-FROZEN»` (P2-01 — `ir.gleam` tables/elem + MemSize/MemGrow + load result-width +
> float NumOp/ConvOp + 3 TrapReasons, and the spellings in
> `specs/phase-2/ir2-grammar-delta.md`). You gate nothing downstream — the round-trip test
> is a property, not an interface anyone binds to. Read [`00-overview.md`](00-overview.md)
> (E1/E2/E6) and [`01-interface-freeze.md`](01-interface-freeze.md) §A first.

## Context

`.ir` is the compiler's inter-stage contract (decision **D7**): any stage dumps its IR with
`twocore/ir/printer.print_module` and reloads it with `twocore/ir/parser.parse_module`, and
the two satisfy `parse(print(m)) == m` for every module `m`. Phase 1 made this green over the
whole Phase-1 IR surface (237 tests in `roundtrip_test`). Phase 2 **adds variants** to the IR
(`ir.gleam`, owned by P2-01) — tables, element segments, `memory.size`/`memory.grow`, a result
type on loads, the remaining float ops, the trapping/converting `ConvOp`s, and three new
`TrapReason`s. Every new variant must print **and** parse losslessly or the dump/load boundary
silently drops Phase-2 features. You **extend** the Phase-1 printer/parser/test — you do not
rewrite them; their structure (centralized op-spelling tables, two-phase recursive-descent
parser, hand-authored goldens) is the template.

## Goal

Keep `parse(print(m)) == m` **GREEN over the extended IR2 surface.** Every new variant prints
in one canonical spelling and parses back to the identical `Module` (numeric literals compared
by bit pattern — exact, since floats are stored as `Int` bits). The parser stays **total** (no
`let assert`/`panic`/`todo` on any path from untrusted text; malformed → typed `ParseError`).
Measurable done = the round-trip property passes on a corpus that exercises every new variant,
the new hand-authored golden(s) parse to their expected `Module` and re-print stably, and the
negative corpus returns typed errors for the new malformed forms.

## Files owned

| Path | Role |
|---|---|
| `src/twocore/ir/printer.gleam` | IR → `.ir` text. **Extend** `print_module`, `print_expr`, `numop_to_string`, `convop_to_string`, `trapreason_to_string`; add `print_table`/`print_elem`. |
| `src/twocore/ir/parser.gleam` | `.ir` text → IR. **Extend** `ModuleAcc`/`build_module`/`parse_module_items`/`parse_expr`/`parse_mem_load`/`float_mnemonic`/`string_to_convop`/`string_to_trapreason`; add `parse_table`/`parse_elem`. |
| `test/twocore/ir/roundtrip_test.gleam` | **Extend** the corpora + add the new golden(s). |
| `test/twocore/ir/golden/*.ir` | **Add** at least one hand-authored Phase-2 golden (you may add goldens *by hand*; never printer-generated). |

You **read** `src/twocore/ir.gleam` and `specs/phase-2/ir2-grammar-delta.md`; you never edit
them.

## Depends on

- **`«IR2-FROZEN»`** — the only hard gate. By the time you start, P2-01 has landed the IR
  type changes GREEN, which (Gleam has no default fields) means it has already minimally
  updated every `ir.Module(...)` constructor in `roundtrip_test.gleam` to pass empty
  `tables: []`/`elements: []`, and made the printer/parser exhaustive matches **compile** —
  possibly with placeholder arms (an ignored `result`, a `todo`/`Unsupported` stub) that
  *compile but don't yet round-trip*. **Your job is to replace those placeholders with the
  real lossless spellings and extend the corpus to exercise them.** Confirm the freeze is in:
  `MemLoad` is now 4-ary (`MemLoad(op, addr, offset, result)`), `Module` has `tables`/
  `elements`, and the new `NumOp`/`ConvOp`/`TrapReason` constructors exist.
- **The spellings in `specs/phase-2/ir2-grammar-delta.md` WIN** over the proposals in this
  doc. **If that file does not exist yet** (P2-01 in flight): use the proposals below — they
  follow the existing neutral, width-suffixed style — and get P2-01 to record them verbatim,
  so printer, parser, and the grammar doc share one source of truth. Flag any divergence.
- You depend on **nothing downstream** and **no runtime/ABI** milestone — this is plain text
  I/O over Gleam strings.

## Scope — in / out for Phase 2

**In** (print + parse, lossless, both directions):
- **Module declarations:** `TableDecl` (funcref table) and `ElementSegment` (active element
  segment) — the two new `Module` list fields.
- **Expr:** `MemSize`, `MemGrow(delta)`, and the **changed** `MemLoad` carrying a result
  `ValType`.
- **NumOp (float):** `FAbs FNeg FCeil FFloor FTrunc FNearest FSqrt FCopysign` and the six
  comparisons `FEq FNe FLt FGt FLe FGe`, each per `FloatWidth`.
- **ConvOp:** trapping `TruncS`/`TruncU` (f→i), `ConvertS`/`ConvertU` (i→f),
  `F32DemoteF64`, `F64PromoteF32`.
- **TrapReason:** `InvalidConversionToInteger`, `UndefinedElement`, `UninitializedElement`.

**Out** (per the E-decisions — keep deferred):
- Any **semantics** of the new ops (bounds-checks, trap behaviour, the cell ABI, instantiation
  order). The parser checks *syntax* and builds a well-formed `Module`; it is **not** a
  validator and does **not** resolve table/func references (E2/E5 — those live in
  validate/lower/emit). Effect-ordering (E6) is a codegen concern, not a text concern.
- **Imports / reftypes / bulk-memory / multi-memory / SIMD / WAT** (Phase 3, E8). You print the
  funcref `TableDecl` only; there is no reftype token to round-trip (MVP funcref is implicit).

## Deliverables

### Proposed spellings (coordinate with `ir2-grammar-delta.md`)

All spellings are **neutral and width-suffixed** (D6) and a 1:1 rendering of the constructors,
matching the Phase-1 conventions already in the printer/parser. Lexer note: `.` and digits are
word-continuation chars, so every dotted spelling below is a **single `TWord` token** — the
existing lexer needs no change.

**Module items** (new `parse_module_items` keyword branches + `ModuleAcc`/`build_module`
fields, mirroring `data`):
```
table @<name> ( min <int> [ max <int> ] )          ; TableDecl(name, min, max:Option)
elem  @<table> ( <offset-expr> ) = ( @<func>,* )    ; ElementSegment(table, offset, funcs)
```
- `TableDecl` mirrors `memory`’s `(min N [max M])` sizing; it is **named** (`@`) because
  `call_indirect`/`elem` reference it by name.
- `elem` mirrors `data ( <offset-expr> ) = …`; the payload is a parenthesised list of
  function names (`@name`), reusing `parse_at_name` / `parse_paren_list`. Empty list = `()`.

**Expr:**
```
mem.size                                            ; MemSize
mem.grow <value>                                    ; MemGrow(delta)
mem.load <result-valtype> <memaccess> <value> offset=<int>   ; MemLoad(op, addr, offset, RESULT)
```
- The result `ValType` is the **only** change to the load (it disambiguates `i32.load8_s`
  from `i64.load8_s` — same `bytes`+`signed`, different result bits — E2). Print it
  immediately after the `mem.load` keyword and parse it with the existing `print_valtype` /
  `parse_valtype`. Recommended placement is **before** the `<memaccess>` so the line reads
  “load *into* `<ty>`”.
- **`mem.store` is unchanged** — it keeps `MemAccess(bytes, signed)`. `signed` is semantically
  irrelevant for stores (lower emits `signed: False`), but the printer/parser must still
  round-trip whatever bool the `MemAccess` carries; the existing `print_memaccess`/
  `parse_memaccess` already do, so leave `mem.store` alone. Document the irrelevance.

**NumOp** (extend `numop_to_string` and the parser’s `float_mnemonic`; `W ∈ {32,64}`):
```
f.abs.W  f.neg.W  f.ceil.W  f.floor.W  f.trunc.W  f.nearest.W  f.sqrt.W  f.copysign.W
f.eq.W   f.ne.W   f.lt.W    f.gt.W     f.le.W     f.ge.W
```
Float comparisons are sign-agnostic, so `f.lt.W` (not `f.lt_s`); no collision with the
integer `i.lt_s`/`i.lt_u`.

**ConvOp** (extend `convop_to_string` and `string_to_convop`):
```
trunc_s.<fw>.<iw>    trunc_u.<fw>.<iw>     ; TruncS/TruncU  (from:FloatWidth, to:IntWidth)
convert_s.<iw>.<fw>  convert_u.<iw>.<fw>   ; ConvertS/ConvertU (from:IntWidth, to:FloatWidth)
f32.demote_f64       f64.promote_f32       ; fixed spellings (like i32.wrap_i64)
```
- The trapping `trunc_s`/`trunc_u` are **distinct** from the saturating
  `trunc_sat_s`/`trunc_sat_u` (`string.split(_, ".")` heads differ: `"trunc_s"` vs
  `"trunc_sat_s"` — no prefix collision). Add new parametric arms next to the existing
  trunc_sat arms; do **not** reuse them.
- `convert_s`/`convert_u` carry **int-width-then-float-width** (the op is i→f): parse the
  first segment with `ty_iwidth`, the second with `ty_fwidth`.
- `f32.demote_f64`/`f64.promote_f32` are fixed strings — add them to the leading fixed-match
  block before the `string.split` fallback (alongside `i32.wrap_i64`, `i64.extend_i32_s`, …).

**TrapReason** (extend `trapreason_to_string` and `string_to_trapreason` — uniform snake_case
of the constructor, matching the Phase-1 rule and the unit-09 `rt_trap` atoms):
```
invalid_conversion_to_integer    undefined_element    uninitialized_element
```

### Printer / parser wiring (concrete)

- **`print_module`** — fold `tables` and `elements` into the existing `list.flatten` in a
  **fixed, deterministic** order. Recommended: `… globals, tables, imports, exports, data,
  elements, funcs …` (tables next to globals, `elem` next to `data` — the mnemonic
  `data:memory :: elem:table`). Order is free *for correctness* (the parser is order-
  independent via keyword dispatch + the reversed-accumulator `build_module`), but the
  printer must be deterministic.
- **`parse_module_items`** — add `"table"` and `"elem"` arms calling `parse_table`/
  `parse_elem`; thread the results into the two new `ModuleAcc` fields (built reversed,
  flipped in `build_module`, exactly like `data`/`globals`).
- **`parse_expr`** — add `"mem.size" -> Ok(MemSize)`, `"mem.grow" -> parse_value`, and route
  `"mem.load"` through the updated `parse_mem_load` (which now parses the result valtype
  first). `mem.store` already dispatches correctly.

### `roundtrip_test.gleam` (extend, do not rewrite)

- Add the 14 new float ops to `float_ops` (so `all_numops` covers them at both widths).
- Add `TruncS`/`TruncU`/`ConvertS`/`ConvertU` (representative from/to combinations, both
  signs, both widths each) and `F32DemoteF64`/`F64PromoteF32` to `all_convops`.
- Add the 3 new reasons to `all_trapreasons`.
- Add to `expr_corpus`: `MemSize`, `MemGrow(<value>)`, and a **sign-extending** `MemLoad`
  with an i64 result, e.g. `ir.MemLoad(ir.MemAccess(1, True), ir.Var("a"), 8, ir.TI64)`
  (proves the result type round-trips and `i32.load8_s` ≠ `i64.load8_s`).
- Extend the module-level corpus so at least one `ir.Module(...)` carries non-empty `tables`
  and `elements` (extend `kitchen_sink_module` or add a sibling builder).
- **Add ≥1 hand-authored golden** `test/twocore/ir/golden/<name>.ir` (e.g. `mem_table.ir`)
  that uses, in one module: a `table` decl, an active `elem` segment, a `mem.grow`, a
  sign-extending `mem.load`, a float comparison (e.g. `f.lt.64`), and a **trapping** convert
  (`trunc_s.f64.i32`). Write its expected `Module` **by hand** in the test (independent of the
  printer) and assert `parse_module(read_golden(...)) == Ok(expected)` plus
  `check_roundtrip(expected)`.
- Add negative-corpus entries: `mem.load` missing the result valtype, a malformed `elem`
  (e.g. missing `=`), an unknown float op `f.bogus.32` (→ `UnknownOp`), and an unknown trap
  reason (→ `UnknownOp`). Fold them into `negative_garbage_inputs_never_panic_test` and/or a
  named test asserting the variant.

## Grounded facts you MUST honor

- **D7 contract.** One canonical printer; `parse(print(m)) == m` under **bit-pattern**
  numeric equality. Because the frozen IR stores float constants as raw `Int` bits, plain
  structural `==` on `ir.Module` already compares them bit-exactly (NaN payloads and `-0.0`
  distinguished) — reuse the existing `module_equal`. Float consts print as raw `0x`-hex bits
  (`f32.const 0x<8>`, `f64.const 0x<16>`), never decimals.
- **Hand-authored goldens defeat collusion.** A printer + parser that share the *same wrong*
  grammar pass `parse(print(m))` while both being wrong. The hand-written golden — authored by
  reading the grammar, with an independently hand-built expected `Module` — is the independent
  oracle that catches it. The new Phase-2 golden is **non-negotiably** hand-authored, never
  emitted by the printer.
- **The parser stays TOTAL.** No `let assert`/`panic`/`todo` reachable from the source text;
  every fault is a typed `ParseError` propagated with `result.try`. All new branches reuse the
  existing total helpers (`parse_valtype`, `parse_value`, `parse_at_name`, `parse_paren_list`,
  `expect_number`, …), each of which already returns `Error` (never panics) on the empty/wrong
  token. Adding variants must not introduce a partial path.
- **Single source-of-truth spelling tables.** The printer’s `*_to_string` and the parser’s
  `string_to_*` are mirrors; the full-surface round-trip is what proves they agree. Add each
  new spelling to **both** sides in the same commit, or the round-trip catches the mismatch.
- **Pitfalls:**
  - `f.trunc.W` (the float→float `FTrunc` NumOp, under `num`) is **not** the trapping
    float→int `trunc_s`/`trunc_u` (ConvOp, under `convert`) and **not** `trunc_sat_*`. Three
    different spellings, three different keywords/heads — keep them distinct.
  - `trunc_s` vs `trunc_sat_s`: split heads differ — fine, but place the new arms so neither
    shadows the other.
  - `MemLoad` is now **4-ary**. The Phase-1 corpus’s 3-ary `MemLoad(...)` calls were updated
    by P2-01 to compile; make sure the result type is actually *printed and parsed* (a
    placeholder that ignores `result` compiles but silently breaks round-trip — that is the
    bug to kill).
  - `mem.store` `signed` is irrelevant semantically but must still round-trip the stored bool.
- **Per-stage error type (D4).** `ParseError` is yours; reuse the existing variants
  (`UnexpectedToken`/`UnexpectedEnd`/`UnknownOp`/`BadSigil`/`BadNumberLiteral`/`BadString`) —
  the new surface needs no new variant. Bad float/convop/trap spellings surface as `UnknownOp`
  (they flow through `string_to_*` returning `Error(Nil)`), exactly like Phase 1.

## Verification — Definition of Done (per D8)

Tests assert the **D7 contract and the grammar**, not whatever the printer happens to emit
(no change-detector tests):

1. **Round-trip property** holds on the extended full-surface corpus via `module_equal` —
   every new `NumOp`/`ConvOp`/`TrapReason`, `MemSize`/`MemGrow`, the result-typed `MemLoad`,
   and a module carrying `tables`+`elements`. This is the D7 invariant `parse(print(m)) == m`.
2. **Golden suite** (independent oracle): the new hand-authored Phase-2 `.ir` parses to its
   hand-built expected `Module`, and that value re-prints + re-parses stably
   (`check_roundtrip`). The Phase-1 goldens (`add`/`sum_to`/`fib`) still parse unchanged.
3. **Result-type discrimination** explicitly tested: a module containing `i32.load8_s`-shaped
   and `i64.load8_s`-shaped loads (same `MemAccess(1, True)`, different result `ValType`)
   round-trips to **distinct** `Module`s — proving the result type is not dropped.
4. **Negative corpus**: each new malformed form returns the expected `ParseError` variant and
   **none panics** (totality). Reaching the end of the garbage battery without crashing the
   runner is the totality proof.
5. `gleam format --check src test` clean; `gleam build` has **ZERO warnings** (the freeze
   removed the exhaustive-match gaps — no `todo` arm may remain in printer/parser);
   `gleam test` green (≥ the current Phase-2 count; the Phase-1 237 round-trip tests stay
   green).
6. **Every new/changed function documented** (D8): `print_table`, `print_elem`, `parse_table`,
   `parse_elem`, and the doc comments on the touched dispatch functions updated to mention the
   new arms (contract / inputs / `Ok`-`Error` semantics / why the parser cannot panic).

**Proving the goal:** (a) round-trip green on the extended surface + (b) the hand-authored
Phase-2 golden parsing *and* re-printing stably together defeat printer/parser collusion; (c)
the negative corpus returning typed errors proves totality held across the extension.

## Concurrency

Small unit; one owner is natural. If split, keep the **printer / parser seam** as in Phase 1:
agree the proposed spelling table above **first** (a 15-minute mini-freeze — ideally just
adopt `ir2-grammar-delta.md` verbatim), then sub-task A extends `printer.gleam` and sub-task B
extends `parser.gleam` against that table; `roundtrip_test.gleam` is single-owner and written
by whoever finishes second (it needs both halves). **What must be frozen first:** `«IR2-FROZEN»`
(the types) and the spelling table (the grammar delta). Until the grammar delta lands, code
against the proposals here and re-sync when it lands.

## What this leaves for others

Once `.ir` round-trips the IR2 surface, every Phase-2 stage regains its golden-file boundary:
- **09 (lower)** can golden-test “WASM AST → IR2” by emitting `.ir` and diffing against a
  hand-written expected `.ir` (memory/table/global/float/convert/select lowering, active
  data/element/global-init).
- **10 (emit_core)** can be driven from a hand-written IR2 `.ir` fixture (a stateful op /
  `instantiate` slice) — the smartest first end-to-end for the backend, no frontend needed.
- **11 (capstone/conformance)** can dump/load IR2 at any seam for differential tests.

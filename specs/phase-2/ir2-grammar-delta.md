# `.ir` grammar delta — Phase-2 (`«IR2-FROZEN»`)

> The **additions** to the canonical `.ir` textual form (`specs/phase-1/ir-grammar.md`) made
> by the Phase-2 interface freeze (unit 01). This file freezes the *spelling* of every new
> IR2 variant; the printer/parser **implementation** of these spellings is unit 02's job.
> Phase-1 spellings are unchanged. Conventions (sigils `%`/`$`/`@`, `"…"` strings, raw-hex
> float constants, neutral width-tagged op names, 2-space indentation) are inherited
> verbatim from the Phase-1 grammar.
>
> **Status in this freeze:** the `mem.load` result-valtype spelling and the four new
> trap-reason spellings are *implemented* by unit 01 (they were needed to keep the existing
> round-trip green). Every other spelling below is *reserved* — unit 01 leaves the printer
> arm as a transitional `todo` and unit 02 fills it. Where a recommended spelling is given,
> unit 02 should adopt it unless it finds a concrete conflict (and then update this doc).

---

## 1. Module-level declarations

Three new top-level items join `numerics`/`memory`/`global`/`import`/`export`/`data`/`func`.
They may appear in any order among the other module items (the parser accumulates them).

### 1.1 `table` — a funcref table declaration (`TableDecl`)

```
table @<name> min <int> [max <int>]
```

- `@<name>` — the table's name (referenced by `call_indirect` and `elem`).
- `min <int>` — initial size in entries.
- `max <int>` — optional maximum in entries (omit for unbounded).

Example: `table @t0 min 2 max 8`

### 1.2 `elem` — an active element segment (`ElementSegment`)

```
elem @<table> ( <offset-expr> ) [ @<fn0>, @<fn1>, … ]
```

- `@<table>` — the target table's name.
- `( <offset-expr> )` — a constant offset expression (the first entry index written), in
  parentheses (mirroring `data`'s offset form).
- `[ @<fn>, … ]` — the IR function names placed into consecutive entries from the offset
  (a bracketed, comma-separated `@`-name list; `[]` for an empty segment).

Example: `elem @t0 ( values (i32.const 0) ) [ @worker, @init ]`

### 1.3 `start` — the start function (`Module.start`)

```
start @<fn>
```

Names the function run once at instantiation. Absent line ⇒ `start: None`.

Example: `start @init`

---

## 2. Expression additions

### 2.1 `mem.size` / `mem.grow` (`MemSize` / `MemGrow`) — IMPLEMENTED arm pending (unit 02)

```
mem.size
mem.grow <value>
```

- `mem.size` — yields the current memory size in pages (i32). No operands.
- `mem.grow <value>` — grows memory by the `<value>` page delta; yields the previous size
  in pages, or `-1` (i32).

Example: `mem.grow i32.const 1`

### 2.2 `mem.load` gains a leading result valtype (`MemLoad.result`) — **IMPLEMENTED (unit 01)**

The Phase-1 form `mem.load <memaccess> <addr> offset=<int>` becomes:

```
mem.load <result-valtype> <memaccess> <addr> offset=<int>
```

where `<result-valtype>` is one of `i32`/`i64`/`f32`/`f64`/`term` and `<memaccess>` is the
existing `<bytes> [signed]` form. The result valtype is REQUIRED because `<memaccess>` alone
cannot distinguish e.g. `i32.load8_s` from `i64.load8_s` (identical bytes + sign, different
result bit pattern).

Examples:
- `mem.load i32 4 %a offset=0`     (a plain `i32.load`)
- `mem.load i64 1 signed %a offset=8`  (an `i64.load8_s`)

`mem.store` is UNCHANGED: `mem.store <memaccess> <addr> <value> offset=<int>`. A store needs
only the byte width — `op.signed` is irrelevant for stores and is not spelled.

---

## 3. Numeric op additions (`num <op> (args)`)

New float `NumOp`s, spelled with the existing `f.<mnemonic>.<W>` scheme (`W ∈ {32, 64}`):

| `NumOp`              | spelling          | arity |
|----------------------|-------------------|-------|
| `FAbs(w)`            | `f.abs.<W>`       | 1     |
| `FNeg(w)`            | `f.neg.<W>`       | 1     |
| `FCeil(w)`           | `f.ceil.<W>`      | 1     |
| `FFloor(w)`          | `f.floor.<W>`     | 1     |
| `FTrunc(w)`          | `f.trunc.<W>`     | 1     |
| `FNearest(w)`        | `f.nearest.<W>`   | 1     |
| `FSqrt(w)`           | `f.sqrt.<W>`      | 1     |
| `FCopysign(w)`       | `f.copysign.<W>`  | 2     |
| `FEq(w)`             | `f.eq.<W>`        | 2     |
| `FNe(w)`             | `f.ne.<W>`        | 2     |
| `FLt(w)`             | `f.lt.<W>`        | 2     |
| `FGt(w)`             | `f.gt.<W>`        | 2     |
| `FLe(w)`             | `f.le.<W>`        | 2     |
| `FGe(w)`             | `f.ge.<W>`        | 2     |

Examples: `num f.sqrt.64 (%x)`, `num f.lt.32 (%a, %b)`.

---

## 4. Conversion op additions (`convert <op> <value>`)

New `ConvOp`s. The **trapping** truncation is kept textually DISTINCT from the saturating
`trunc_sat_s`/`trunc_sat_u` (which keep their Phase-1 spellings) — drop the `_sat`:

| `ConvOp`              | spelling                    |
|-----------------------|-----------------------------|
| `TruncS(fw, iw)`      | `trunc_s.<fw>.<iw>`         |
| `TruncU(fw, iw)`      | `trunc_u.<fw>.<iw>`         |
| `ConvertS(iw, fw)`    | `convert_s.<iw>.<fw>`       |
| `ConvertU(iw, fw)`    | `convert_u.<iw>.<fw>`       |
| `F32DemoteF64`        | `demote.f64`                |
| `F64PromoteF32`       | `promote.f32`               |

where `<fw> ∈ {f32, f64}` and `<iw> ∈ {i32, i64}` (the value-type token spelling, matching
`trunc_sat_*`). Note the operand-order convention: trapping truncation is `<from-float>.<to-int>`;
integer→float convert is `<from-int>.<to-float>`.

Examples: `convert trunc_s.f32.i32 %x`, `convert convert_u.i64.f64 %n`, `convert demote.f64 %d`.

---

## 5. Trap-reason additions (`trap <reason>`) — **IMPLEMENTED (unit 01)**

The four new `TrapReason`s spell as the snake_case of their constructor (matching the
Phase-1 convention):

| `TrapReason`                  | `.ir` spelling                    | WASM-spec `assert_trap` substring  |
|-------------------------------|-----------------------------------|------------------------------------|
| `InvalidConversionToInteger`  | `invalid_conversion_to_integer`   | `invalid conversion to integer`    |
| `UndefinedElement`            | `undefined_element`               | `undefined element`                |
| `UninitializedElement`        | `uninitialized_element`           | `uninitialized element`            |
| `TableOutOfBounds`            | `table_out_of_bounds`             | `out of bounds table access`       |

(The `.ir` spelling is the printer/parser token; the spec substring is what
`rt_trap.spec_trap_message/1` returns for the conformance harness. Active **data**-segment
OOB at instantiation reuses the existing `memory_out_of_bounds`.)

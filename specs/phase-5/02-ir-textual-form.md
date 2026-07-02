# Unit P5-02 — The `.ir` printer/parser extension (IR3 surface)

> **1 owner. Wave A, fast-follow OFF the freeze critical path.** Hard freeze dep:
> `«IR3-FROZEN»` (P5-01 — `ir.gleam` reftype `ValType`s + `RefType`, the H2/H3 `Expr`
> nodes, `Module.memories`, `IdxType`, the memory index on memory ops, the import/export
> state variants, `TableDecl.ref_ty`, the passive/declarative `ElementSegment` + passive
> `DataSegment` model, and any new `TrapReason` — plus the spellings recorded in
> `specs/phase-5/ir-grammar-delta.md`). You gate **nothing downstream** — the round-trip
> property is a property, not an interface anyone binds to. Read
> [`00-overview.md`](00-overview.md) (H1/H2/H3/H4/H7) and the EM's provisional surface
> first, then this doc.

## Context

`.ir` is the compiler's inter-stage contract (decision **D7**): any stage dumps its IR with
`twocore/ir/printer.print_module` and reloads it with `twocore/ir/parser.parse_module`, and
the two satisfy `parse(print(m)) == m` for every module `m`. Phase 1 made this green over the
whole Phase-1 IR surface (237 round-trip tests); Phase 2 (unit `P2-02`) extended it to the
IR2 surface (tables, active elements, `mem.size`/`mem.grow`, result-typed `mem.load`, the
float ops, the trapping/converting `ConvOp`s, three new `TrapReason`s). Phase 3 and Phase 4
added **no** IR node types, so the `.ir` grammar was untouched since Phase 2.

Phase 5 is **the first phase since Phase 2 to grow the IR** (H7). The keystone (`P5-01`)
adds, all at once: two reference `ValType`s (`TFuncRef`/`TExternRef`) + a `RefType`
(`FuncRef`/`ExternRef`); the reference `Expr` nodes (`RefNull`/`RefFunc`/`RefIsNull`); the
table `Expr` nodes (`TableGet`/`TableSet`/`TableSize`/`TableGrow`/`TableFill`/`TableInit`/
`TableCopy`/`ElemDrop`); the bulk-memory `Expr` nodes (`MemFill`/`MemCopy`/`MemInit`/
`DataDrop`); a **memory index** on the existing memory nodes (`MemSize`/`MemGrow`/`MemLoad`/
`MemStore`); `Module.memories: List(MemoryDecl)` (was `memory: Option`); `IdxType`
(`Idx32`/`Idx64`) on `MemoryDecl`; the `ImportDecl` state variants
(`ImportGlobal`/`ImportTable`/`ImportMemory`); the `ExportDecl` state variants
(`ExportGlobal`/`ExportTable`/`ExportMemory`); `TableDecl.ref_ty`; and the new
`ElementSegment(mode, ref_ty, init)` / `DataSegment(mode, bytes)` shapes with
active/passive/declarative element modes, active/passive data modes, and **init
expressions** in place of the old `funcs: List(String)`.

Every one of these must **print and parse losslessly** or the dump/load boundary silently
drops a Phase-5 feature. You **extend** the Phase-1/2 printer/parser/test — you do not
rewrite them; their structure (centralized `*_to_string` / `string_to_*` spelling tables, a
two-phase recursive-descent parser, hand-authored goldens) is the template.

## Goal

Keep `parse(print(m)) == m` **GREEN over the full IR3 surface.** Every new variant prints in
one canonical spelling and parses back to the identical `Module` (numeric literals compared
by **bit pattern** — exact, since floats are stored as raw `Int` bits, so NaN payloads,
`-0.0`, and ±Inf survive). The parser stays **total** — no `let assert`/`panic`/`todo` on any
path reachable from untrusted text; every fault is a typed `ParseError`. Measurable done: the
round-trip property passes on a corpus that exercises every new variant (reftype value types,
reference/table/bulk expressions at memory index 0 **and** non-zero, multi-memory modules,
a 64-bit memory, the import/export state variants, passive/declarative elements with
`ref.func`/`ref.null` init expressions, passive data), the new hand-authored Phase-5
golden parses to its independently-built expected `Module` and re-prints stably, the four
existing goldens (`add`/`sum_to`/`fib`/`mem_table`) **still parse**, and the negative/fuzz
corpus returns typed errors for the new malformed forms without panicking.

## Files owned

| Path | Role |
|---|---|
| `src/twocore/ir/printer.gleam` | IR → `.ir` text. **Extend** `print_module`, `print_valtype`, `print_expr`, `print_table`, `print_elem`, `print_import`, `print_export`, `print_data`, `memory_str`; add `print_reftype`, `print_memidx`, `print_idxtype`, `print_ref_init`. |
| `src/twocore/ir/parser.gleam` | `.ir` text → IR. **Extend** `ModuleAcc`/`build_module`/`parse_module_items`/`parse_valtype`/`parse_expr`/`parse_table`/`parse_elem`/`parse_import`/`parse_export`/`parse_data`/`parse_memory`; add `parse_reftype`, `parse_opt_memidx`, `parse_ref_init_list`, `parse_import_kind`, `parse_export_kind`. |
| `test/twocore/ir/roundtrip_test.gleam` | **Extend** the corpora + add the new golden(s). (Minimally touched by `P5-01` to keep the tree compiling; you fill in the real coverage.) |
| `test/twocore/ir/golden/*.ir` | **Add** ≥1 hand-authored Phase-5 golden (`refs_bulk.ir`). Hand-authored — never printer-generated. |
| `specs/phase-5/ir-grammar-delta.md` | **Add** the frozen grammar delta (mirrors `specs/phase-2/ir2-grammar-delta.md`); §A of this doc is its authoritative source. |

You **read** `src/twocore/ir.gleam` (the IR3 types), `specs/phase-1/ir-grammar.md`, and
`specs/phase-2/ir2-grammar-delta.md`; you never edit `ir.gleam` or the Phase-1/2 grammar.

## Deliverables & freeze milestones

- **No freeze milestone is owned by this unit** — it publishes no interface anyone downstream
  binds to. The round-trip property is an internal correctness invariant.
- Deliverable 1: the extended printer, deterministic and total (one canonical spelling per
  IR3 construct).
- Deliverable 2: the extended parser, total, mirroring every spelling.
- Deliverable 3: `specs/phase-5/ir-grammar-delta.md` — the written grammar the two target
  (defeats printer/parser collusion; §A here is its content).
- Deliverable 4: the extended `roundtrip_test.gleam` corpora + the hand-authored `refs_bulk.ir`
  golden with its by-hand expected `Module`.

## Depends on (freeze milestones)

- **`«IR3-FROZEN»`** — the only hard gate. By the time you start, `P5-01` has landed the IR
  type changes GREEN, which (Gleam has no default fields) means it has already minimally
  updated every `ir.Module(...)` / `ir.TableDecl(...)` / `ir.ElementSegment(...)` /
  `ir.DataSegment(...)` constructor in `roundtrip_test.gleam` to pass the new fields, and made
  the printer/parser exhaustive matches **compile** — possibly with placeholder arms (a `todo`,
  an `Unsupported`, or a lossy stub) that *compile but don't yet round-trip*. **Your job is to
  replace those placeholders with the real lossless spellings and extend the corpus to
  exercise them.** Confirm the freeze is in: `Module.memories` is a `List(MemoryDecl)`,
  `MemoryDecl` is 3-ary (`MemoryDecl(min_pages, max_pages, idx_type)`), `TableDecl` is 4-ary
  (`TableDecl(name, ref_ty, min, max)`), `ElementSegment` is `ElementSegment(mode, ref_ty,
  init)`, `DataSegment` is `DataSegment(mode, bytes)`, the reference/table/bulk `Expr`
  constructors exist, and `MemSize`/`MemGrow`/`MemLoad`/`MemStore` each carry a leading
  `mem: Int`.
- **The spellings in `specs/phase-5/ir-grammar-delta.md` WIN** over the proposals in this doc.
  If that file does not exist yet (`P5-01` in flight), author §A below as its content, get
  `P5-01` to record it verbatim, and flag any divergence — printer, parser, and grammar doc
  share one source of truth.
- You depend on **nothing downstream** and **no runtime/ABI** milestone — this is plain text
  I/O over Gleam strings.

## Scope — in / out for Phase 5

**In** (print + parse, lossless, both directions):

- **Value types:** `TFuncRef` → `funcref`, `TExternRef` → `externref` (everywhere a `ValType`
  appears: params, locals, globals, `FuncType`, `mem.load` result — the last cannot actually
  produce a reference, but the token must be legal in every valtype position).
- **Reference types (`RefType`):** `funcref`/`externref` in `TableDecl`, `ElementSegment`,
  `ImportTable`, and `ref.null`.
- **Module memories:** `Module.memories: List(MemoryDecl)` (zero, one, or many); the
  per-memory `IdxType` (`Idx32` default / `Idx64` = memory64).
- **Reference expressions:** `RefNull`, `RefFunc`, `RefIsNull`.
- **Table expressions:** `TableGet`/`TableSet`/`TableSize`/`TableGrow`/`TableFill`/
  `TableInit`/`TableCopy`/`ElemDrop`.
- **Bulk-memory expressions:** `MemFill`/`MemCopy`/`MemInit`/`DataDrop`.
- **The memory index** on `MemSize`/`MemGrow`/`MemLoad`/`MemStore` (default 0, omitted).
- **Import state variants:** `ImportGlobal`/`ImportTable`/`ImportMemory`.
- **Export state variants:** `ExportGlobal`/`ExportTable`/`ExportMemory`.
- **Segment shapes:** `ElementSegment(mode, ref_ty, init)` — active/passive/declarative, with
  `init` a list of ref-producing expressions; `DataSegment(mode, bytes)` — active (with a
  memory index) / passive.
- Whatever **new `TrapReason`** (if any) `P5-01` adds — a snake_case arm on both sides.

**Out** (per the H-decisions — keep deferred):

- Any **semantics** of the new ops (bounds checks, trap-before-write, memmove overlap,
  passive-segment drop state, the instantiation/link contract, memory-index routing). The
  parser checks *syntax* and builds a well-formed `Module`; it is **not** a validator and does
  **not** resolve table/func/segment references or check reftype compatibility (those live in
  `validate` (04) / `lower` (05) / `emit_core` (06) / the runtime). Effect ordering (H2) is a
  codegen concern, not a text concern.
- **SIMD** (`v128` + lane ops) — Phase 6. No `v128` valtype token, no SIMD expression spelling.
- The **binary opcode bytes** (the `0xFC`-prefix bulk/table opcodes, the reftype value-type
  bytes, the memory64 limits flag) — those are the WASM binary encoding, owned by `decode`
  (03). The `.ir` spellings here are **neutral names** (D6), independent of the WASM byte
  encoding.
- The **WAT text format** (`frontend/wasm/wat.gleam`, unit 10) — a different, WASM-specific
  parser producing the WASM AST, not the IR. Do not confuse it with this IR `.ir` parser.

---

## A. The grammar delta (EBNF) — the authoritative spelling table

> This section IS the content of `specs/phase-5/ir-grammar-delta.md`. It **adds** to the
> Phase-1 grammar (`specs/phase-1/ir-grammar.md`) and the Phase-2 delta
> (`specs/phase-2/ir2-grammar-delta.md`); every Phase-1/2 spelling is unchanged. Conventions
> (sigils `%`/`$`/`@`, `"…"` strings, raw-hex float constants, neutral width-tagged op names,
> 2-space indentation, `;`-to-end-of-line comments, whitespace-insensitive parsing) are
> inherited verbatim. The lexer needs **no change**: every new keyword (`funcref`,
> `externref`, `ref.null`, `ref.func`, `ref.is_null`, `table.get`, `mem.fill`, `data.drop`,
> `passive`, `declare`, …) is a single `TWord` — `.` and digits are word-continuation chars,
> so all dotted mnemonics tokenise as one word, and `@name` init items are ordinary `TAt`
> tokens.

### A.1 Value types and reference types

```
valtype := i32 | i64 | f32 | f64 | term
         | funcref | externref              ; NEW (P5) — TFuncRef / TExternRef
reftype := funcref | externref              ; NEW (P5) — RefType (subset of valtype)
```

`funcref`/`externref` are the WASM 2.0 spellings ([spec: Types — Reference
types](https://webassembly.github.io/spec/core/syntax/types.html#reference-types)) and read
neutrally (a `funcref` is "a reference to a function", a first-class term-layer value — H1).
`parse_valtype` gains the two arms; a **new** `parse_reftype` accepts only these two
(rejecting `i32`/`term`/… with `UnexpectedToken`, `expected: "reftype"`).

### A.2 Module declarations

#### A.2.1 `memory` — multiple memories + the memory64 index type

```
memory := memory none                                     ; LEGACY (accepted, not emitted): contributes no memory
        | memory [ i64 ] ( min <int> [ max <int> ] )      ; one MemoryDecl; `i64` marks Idx64 (memory64)
```

- `Module.memories` is a **list**. The printer emits **one `memory` line per element, in list
  order** (list position = memory index), and **no line at all** for the empty list. The old
  `memory none` sentinel is **still accepted** by the parser (it contributes no memory, so an
  old golden with `memory none` parses to `memories: []`) but is **never emitted** — a
  documented backward-compat alias.
- The index-type token is **omitted for `Idx32`** (the default, so a single 32-bit memory
  prints byte-identically to Phase-4) and spelled **`i64` before the sizing** for `Idx64`
  ([memory64 proposal](https://github.com/WebAssembly/memory64) — the limits flag selects the
  index type). The parser accepts an explicit `i32` too (→ `Idx32`), but `Idx32` is canonical
  as *omitted*.

| `MemoryDecl` | canonical spelling |
|---|---|
| `MemoryDecl(1, None, Idx32)` | `memory (min 1)` |
| `MemoryDecl(1, Some(4), Idx32)` | `memory (min 1 max 4)` |
| `MemoryDecl(2, None, Idx64)` | `memory i64 (min 2)` |

A two-memory module prints two `memory` lines; parsing them re-accumulates the list in order.

#### A.2.2 `table` — reference type on the table declaration

```
table := table @<name> <reftype> min <int> [ max <int> ]      ; canonical (P5)
       | table @<name> min <int> [ max <int> ]                 ; LEGACY (accepted): reftype defaults to funcref
```

`TableDecl` is now `TableDecl(name, ref_ty, min, max)`. The printer **always emits the
reftype token** (`table @t0 funcref min 2 max 8`) so a `funcref` table and an `externref`
table are unambiguous ([reference-types proposal — tables of any reftype](https://webassembly.github.io/spec/core/syntax/modules.html#tables)).
The parser **also accepts** the Phase-2 legacy form with no reftype (defaulting to `FuncRef`)
so the frozen `mem_table.ir` golden still parses.

#### A.2.3 `import` — non-function imports (state)

```
import := import "<module>" "<name>" : <functype>                       ; ImportFn (unchanged)
        | import "<module>" "<name>" global <valtype> [ mut ]            ; ImportGlobal
        | import "<module>" "<name>" table <reftype> min <int> [max <int>]   ; ImportTable
        | import "<module>" "<name>" memory [ i64 ] ( min <int> [max <int>] ) ; ImportMemory
```

Two strings then a **kind clause** disambiguate the four `ImportDecl` variants. `ImportFn`
keeps its exact Phase-1 spelling (the kind clause `:` starts it), so existing modules are
byte-identical. The kind keyword (`global`/`table`/`memory`) selects the state variant; `:`
selects the function variant ([reference-types & multi-memory: importing globals/tables/
memories](https://webassembly.github.io/spec/core/syntax/modules.html#imports)). The
`global` mutability flag reuses the `mut` keyword from `GlobalDecl`; the `memory` `i64`
marker and `table` reftype reuse A.2.1/A.2.2.

#### A.2.4 `export` — non-function exports (state)

```
export := export "<name>" = @<fn>              ; ExportFn (unchanged)
        | export "<name>" = global @<global>    ; ExportGlobal
        | export "<name>" = table @<table>      ; ExportTable
        | export "<name>" = memory <int>        ; ExportMemory (by memory index)
```

After `=`, a bare `@name` is `ExportFn` (byte-identical to Phase-1/2); a leading
`global`/`table`/`memory` keyword selects the state variant. `ExportMemory` names a memory by
**index** (an `int`, matching `Module.memories` positions), the others by `@name`
([exports of globals/tables/memories](https://webassembly.github.io/spec/core/syntax/modules.html#exports)).

#### A.2.5 `data` — passive data + the memory index

```
data := data [ mem=<int> ] ( <offset-expr> ) = 0x<hexbytes>   ; DataActive(mem, offset)  — `mem=` omitted when 0
      | data passive = 0x<hexbytes>                            ; DataPassive
```

`DataSegment(mode, bytes)` with `mode = DataActive(mem, offset) | DataPassive`. The active
form keeps the Phase-2 `( <offset-expr> ) = 0x<hex>` shape and adds an optional `mem=<int>`
decorator **omitted when 0** (so a single-memory active data segment is byte-identical). The
passive form drops the offset entirely ([bulk-memory proposal — passive data
segments](https://webassembly.github.io/spec/core/syntax/modules.html#data-segments)).

#### A.2.6 `elem` — active / passive / declarative + reftype + init expressions

```
elem     := elem <reftype> <elemmode> [ <initexpr>,* ]          ; canonical (P5)
          | elem @<table> ( <offset-expr> ) [ <initexpr>,* ]    ; LEGACY (accepted): reftype=funcref, active
elemmode := @<table> ( <offset-expr> )        ; ElemActive(table, offset)
          | passive                            ; ElemPassive
          | declare                            ; ElemDeclarative
initexpr := <expr>                              ; a ref-producing expression (ref.func @f / ref.null t)
          | @<name>                             ; ABBREVIATION for `ref.func @<name>`  (WAT-style funcidx shorthand)
```

`ElementSegment(mode, ref_ty, init)` with `mode = ElemActive(table, offset) | ElemPassive |
ElemDeclarative` and `init: List(Expr)` (each item a `RefFunc`/`RefNull` expression). The
printer **always emits the reftype** and the **explicit `initexpr` form** — `[ ref.func @a,
ref.null funcref ]`. The parser additionally accepts the **`@name` abbreviation** for
`ref.func @name` (spec-precedented: WAT `(elem (i32.const 0) $f $g)` desugars to
`funcref (ref.func $f) (ref.func $g)` — [elem abbreviations](https://webassembly.github.io/spec/core/text/modules.html#element-segments))
and the legacy no-reftype active form, so `mem_table.ir` (`elem @t0 ( … ) [ @worker, @setup ]`)
still parses to `ElementSegment(ElemActive("t0", …), FuncRef, [RefFunc("worker"),
RefFunc("setup")])`.

Canonical examples:
```
elem funcref @t0 ( values (i32.const 0) ) [ ref.func @a, ref.func @b ]
elem funcref passive [ ref.func @a, ref.null funcref ]
elem externref declare [ ref.null externref ]
```

### A.3 Reference expressions

```
expr += ref.null <reftype>          ; RefNull(ty)      — the NULL-REF spelling
      | ref.func @<name>            ; RefFunc(fn_name)
      | ref.is_null <value>         ; RefIsNull(arg)   -> i32 bool
```

| `Expr` | spelling | spec |
|---|---|---|
| `RefNull(FuncRef)` | `ref.null funcref` | [ref.null](https://webassembly.github.io/spec/core/syntax/instructions.html#reference-instructions) |
| `RefNull(ExternRef)` | `ref.null externref` | ″ |
| `RefFunc("f")` | `ref.func @f` | [ref.func](https://webassembly.github.io/spec/core/syntax/instructions.html#reference-instructions) |
| `RefIsNull(Var("x"))` | `ref.is_null %x` | [ref.is_null](https://webassembly.github.io/spec/core/syntax/instructions.html#reference-instructions) |

`ref.null <reftype>` is the **canonical textual spelling of a null reference** (the brief's
"null-ref textual spelling"). Per the provisional surface there is **no `null` `Value`
literal** — a null reference flows as a `Var` bound to a `RefNull` expression — so `ref.null`
appears only in expression position (global init, element init, or a `let` rhs), never inside
a `value`. (If `P5-01` adds a `ConstNull(RefType)` `Value`, see Open Question 1 for the
`value`-position spelling.)

### A.4 Table expressions

All reference a table by `@name` (like `call_indirect`). Value operands are atomic ANF
`value`s. `seg=<int>` (the passive-segment index into `Module.elements`) is always spelled.

```
expr += table.get  @<table> <index>                                  ; TableGet
      | table.set  @<table> <index> <value>                          ; TableSet
      | table.size @<table>                                          ; TableSize -> i32
      | table.grow @<table> <delta> <init>                           ; TableGrow -> i32 (old size | -1)
      | table.fill @<table> <offset> <value> <count>                 ; TableFill
      | table.init @<table> <dst> <src> <count> seg=<int>            ; TableInit(table, seg, …)
      | table.copy @<dsttable> @<srctable> <dst> <src> <count>       ; TableCopy
      | elem.drop  seg=<int>                                          ; ElemDrop(seg)
```

Spec: [table.get/set/size/grow/fill](https://webassembly.github.io/spec/core/syntax/instructions.html#table-instructions);
[table.init/table.copy/elem.drop (bulk-memory proposal)](https://webassembly.github.io/spec/core/syntax/instructions.html#table-instructions).
`TableInit(table, seg, dst, src, count)` prints the three value operands positionally then the
`seg=<int>` decorator. `TableCopy` names two tables positionally (`@dst @src`).

### A.5 Bulk-memory expressions

New ops; a Phase-4 module has none, so any spelling is conformance-neutral by construction.
The memory index follows the **omit-when-zero** rule (A.6) as a `key=<int>` decorator; `seg=`
is always spelled.

```
expr += mem.fill <dest> <value> <count> [ mem=<int> ]                    ; MemFill
      | mem.copy <dst> <src> <count> [ dst_mem=<int> ] [ src_mem=<int> ] ; MemCopy (memmove)
      | mem.init <dst> <src> <count> seg=<int> [ mem=<int> ]             ; MemInit(mem, seg, …)
      | data.drop seg=<int>                                               ; DataDrop(seg)
```

Spec: [memory.fill/copy/init, data.drop (bulk-memory proposal)](https://webassembly.github.io/spec/core/syntax/instructions.html#memory-instructions).
Positional value operands first, then the `key=<int>` decorators in the fixed order shown.
`data.drop`/`elem.drop` take only a `seg=<int>` (the index into `Module.data_segments` /
`Module.elements` respectively).

### A.6 The memory-index decorator on existing memory ops

`MemSize`/`MemGrow`/`MemLoad`/`MemStore` each gain a leading `mem: Int` field (H3). The index
is spelled as a **trailing `mem=<int>` decorator, omitted when it equals `0`** — so a
single-memory (index-0) module prints byte-identically to Phase-4 (the H7 conformance-neutral
default, at the `.ir` level).

```
mem.size [ mem=<int> ]
mem.grow <value> [ mem=<int> ]
mem.load  <result-valtype> <memaccess> <addr> offset=<int> [ mem=<int> ]
mem.store <memaccess> <addr> <value> offset=<int> [ mem=<int> ]
```

| `Expr` | spelling |
|---|---|
| `MemSize(0)` | `mem.size` |
| `MemSize(1)` | `mem.size mem=1` |
| `MemGrow(0, Var("d"))` | `mem.grow %d` |
| `MemGrow(2, Var("d"))` | `mem.grow %d mem=2` |
| `MemLoad(0, MemAccess(4, False), Var("a"), 0, TI32)` | `mem.load i32 4 %a offset=0` |
| `MemLoad(1, MemAccess(1, True), Var("a"), 8, TI64)` | `mem.load i64 1 signed %a offset=8 mem=1` |
| `MemStore(3, MemAccess(4, False), Var("a"), Var("v"), 0)` | `mem.store 4 %a %v offset=0 mem=3` |

**Decorator lexical rule (parser).** The decorator keywords `offset`, `mem`, `seg`,
`dst_mem`, `src_mem` are recognised **only when immediately followed by `=`**. None is an
expression keyword (every real expr keyword is dotted — `mem.size`, `mem.grow`, `mem.fill`, …
— or otherwise distinct), so **no statement can begin with a bare `mem`/`seg`/`dst_mem`/
`src_mem` word**; the trailing peek for a decorator is therefore unambiguous and cannot
swallow a following statement in a `let`/`charge` continuation. `offset` already works this
way in Phase 2 — the new decorators follow the same precedent.

---

## B. Printer wiring (concrete Gleam sketches)

The printer's `*_to_string` tables remain the single source of truth for spellings; the
parser's `string_to_*` / keyword dispatch mirror them, and the full-surface round-trip proves
they agree. Concrete sketches (illustrative — final names per the frozen types):

**Value / reference types** — extend `print_valtype`, add `print_reftype`:
```gleam
fn print_valtype(t: ValType) -> String {
  case t {
    TI32 -> "i32"  TI64 -> "i64"  TF32 -> "f32"  TF64 -> "f64"  TTerm -> "term"
    TFuncRef -> "funcref"  TExternRef -> "externref"        // NEW
  }
}
/// Renders a reference type token (`funcref`/`externref`) for table/elem/import decls
/// and `ref.null`. A `RefType` is a subset of `ValType`; this is its dedicated renderer.
fn print_reftype(r: RefType) -> String {
  case r { FuncRef -> "funcref"  ExternRef -> "externref" }
}
```

**Memories** — `print_module` maps `module.memories` to one line each (empty list ⇒ no
line); `memory_str` renders one decl with the idx-type prefix:
```gleam
fn print_memory_decl(m: MemoryDecl) -> String {
  let idx = case m.idx_type { Idx32 -> ""  Idx64 -> "i64 " }
  let max = case m.max_pages { Some(x) -> " max " <> int.to_string(x)  None -> "" }
  "  memory " <> idx <> "(min " <> int.to_string(m.min_pages) <> max <> ")\n"
}
```

**The memory-index decorator** — a shared helper printed only when non-zero:
```gleam
/// ` mem=<n>` when `mem` ≠ 0, else "" — the omit-when-zero memory-index decorator (A.6).
fn print_memidx(mem: Int) -> String {
  case mem { 0 -> ""  n -> " mem=" <> int.to_string(n) }
}
```
Used by `MemSize`/`MemGrow`/`MemLoad`/`MemStore`/`MemFill`/`MemInit` (and the `dst_mem`/
`src_mem` analogues for `MemCopy`); appended after the positional operands / after `offset=`.

**New expression arms** in `print_expr` — e.g.:
```gleam
RefNull(ty) -> "ref.null " <> print_reftype(ty)
RefFunc(name) -> "ref.func @" <> name
RefIsNull(arg) -> "ref.is_null " <> print_value(arg)
TableGet(t, i) -> "table.get @" <> t <> " " <> print_value(i)
TableCopy(dt, st, d, s, c) ->
  "table.copy @" <> dt <> " @" <> st <> " " <> value3(d, s, c)
MemFill(mem, d, v, c) -> "mem.fill " <> value3(d, v, c) <> print_memidx(mem)
MemCopy(dm, sm, d, s, c) ->
  "mem.copy " <> value3(d, s, c) <> mem_kv("dst_mem", dm) <> mem_kv("src_mem", sm)
DataDrop(seg) -> "data.drop seg=" <> int.to_string(seg)
```
(`value3`/`mem_kv` are trivial local helpers; `mem_kv` is `print_memidx` generalised to any
key.)

**Declarations** — `print_table` prepends `print_reftype(t.ref_ty)`; `print_elem` renders the
mode (`@table ( offset )` / `passive` / `declare`), the reftype, and the init list via a new
`print_ref_init` per item (`ref.func @f` / `ref.null t` — i.e. reuse `print_expr` at module
indent); `print_import`/`print_export` gain the kind-clause arms; `print_data` renders the
`DataMode` (active with `print_memidx`, or `passive`).

## C. Parser wiring (concrete Gleam sketches)

**`ModuleAcc`/`build_module`** — change `memory: Option(MemoryDecl)` to
`memories: List(MemoryDecl)` (built reversed, flipped in `build_module`); the `"memory"`
keyword arm **prepends** to the list (or, for `memory none`, leaves it untouched).

**`parse_module_items`** — the `"memory"`/`"table"`/`"elem"`/`"import"`/`"export"`/`"data"`
arms route to the extended `parse_*`; no new top-level keyword is required (all new module
syntax is a variant of an existing keyword).

**`parse_valtype`** — two new arms (`"funcref"`/`"externref"`). **`parse_reftype`** — a new
total helper accepting only those two, else `UnexpectedToken(l, c, "reftype", w)`.

**`parse_expr`** — new keyword arms, each delegating to a small total helper, e.g.:
```gleam
"ref.null" -> { use #(rt, r) <- result.try(parse_reftype(rest)); Ok(#(RefNull(rt), r)) }
"ref.func" -> { use #(n, r) <- result.try(parse_at_name(rest)); Ok(#(RefFunc(n), r)) }
"ref.is_null" -> { use #(v, r) <- result.try(parse_value(rest)); Ok(#(RefIsNull(v), r)) }
"table.get" -> parse_table_get(rest)
...
"mem.fill" -> parse_mem_fill(rest)
"mem.copy" -> parse_mem_copy(rest)
"mem.init" -> parse_mem_init(rest)
"data.drop" -> { use #(s, r) <- result.try(parse_seg(rest)); Ok(#(DataDrop(s), r)) }
"elem.drop" -> { use #(s, r) <- result.try(parse_seg(rest)); Ok(#(ElemDrop(s), r)) }
```

**`parse_opt_memidx`** — the mirror of `print_memidx`: peeks for `TWord("mem")` (or any given
key) immediately followed by `TEquals`, consumes `mem=<int>`, else returns `#(0, toks)`:
```gleam
/// Peek-parses an optional `<key>=<int>` decorator (A.6). Returns `#(0, toks)` (the default)
/// when the next tokens are not `key =`. Total — never consumes a following statement,
/// because no expression begins with a bare decorator keyword.
fn parse_opt_kv(toks, key: String) -> #(Int, List(PToken)) { … }
```

**`parse_seg`** — a mandatory `seg=<int>` (`expect_word "seg"` + `=` + `expect_number`).

**Declarations** — `parse_table` reads an **optional** reftype (peek a reftype token; default
`FuncRef`) then the `min`/`max`; `parse_elem` reads optional reftype, then dispatches the mode
on the next token (`@name` → active, `passive`, `declare`), then a **`parse_ref_init_list`**
that reads each bracketed item as either an `@name` abbreviation (→ `RefFunc`) or a full
`parse_expr`; `parse_import`/`parse_export` peek the kind keyword after the strings / after
`=`; `parse_data` peeks `passive` vs an optional `mem=<int>` + `( offset )`.

**`parse_memory`** — after `memory`: `none` → contribute nothing; optional `i32`/`i64` idx
token (default `Idx32`); then `( min N [max M] )`.

**Totality (unchanged invariant).** Every new branch reuses the existing total helpers
(`parse_valtype`, `parse_value`, `parse_at_name`, `parse_expr`, `expect_number`,
`expect_word`, `parse_paren_list`, the bracket-list helper) — each returns `Error` (never
panics) on the empty/wrong token. Unknown reftype/kind tokens surface as `UnexpectedToken`;
unknown bulk/ref/table mnemonics fall through `parse_expr`'s final `_ -> UnexpectedToken(…,
"expression", kw)`. **No new `ParseError` variant is needed** — the existing six suffice.

---

## D. Backward-compat & conformance-neutrality (the H7 story for `.ir`)

The `.ir` text is an internal, debugging/inter-stage artifact; H7's *byte-identical* headline
is about the **emitted Core Erlang** (`emit_core`, unit 06), not this text. But keeping the
`.ir` neutral-by-default is still valuable (it keeps golden `.ir` diffs small and the existing
goldens parsing), so the printer is designed so that a **Phase-4-shaped module** — one 32-bit
memory (or none), all `FuncRef` tables, all `ElemActive`, all `DataActive(0, _)`,
function-only imports/exports, memory index 0 everywhere, no ref/table/bulk ops — prints with
**no new tokens** except the now-explicit `table`/`elem` reftype:

| Construct | Phase-4-shaped module prints as | Neutral? |
|---|---|---|
| single 32-bit memory | `memory (min N [max M])` | byte-identical |
| memory index 0 on load/store/size/grow | `mem=` omitted | byte-identical |
| active data, memory 0 | `data ( off ) = 0x…` | byte-identical |
| function import/export | `import "…" "…" : …` / `export "…" = @f` | byte-identical |
| funcref table | `table @t funcref min N` | **+`funcref`** token (see OQ 4) |
| active funcref elem | `elem funcref @t ( off ) [ ref.func @f ]` | **+reftype, +`ref.func`** (see OQ 5) |

The two non-byte-identical rows (`table`/`elem`) are a deliberate choice for
unambiguous canonical form; the **parser accepts the legacy Phase-2 spellings** (no reftype,
bare `@name` funcidx list, `memory none`) so **all four existing goldens
(`add`/`sum_to`/`fib`/`mem_table`) parse unchanged** — the DoD requirement "existing goldens
still parse". If reconciliation prefers strict byte-identity for `table`/`elem` too, flip the
printer to omit the reftype for `FuncRef` and emit the bare `@name` list for all-`RefFunc`
active segments (OQ 4/5); the parser already accepts both.

---

## E. Worked example — the hand-authored Phase-5 golden (`refs_bulk.ir`)

A single module exercising, by hand, the full IR3 surface. Written by **reading §A** (never
printer-generated — D7), with an independently hand-built expected `Module` in the test.

```
; refs_bulk — a hand-authored Phase-5 golden. Exercises, in one module: two memories (one
; 32-bit, one memory64), a funcref table and an externref table, non-function imports and
; exports, a passive data segment, an active + a passive + a declarative element segment
; with ref.func / ref.null init exprs, and the reference / table / bulk-memory / multi-memory
; expression forms. Independent oracle against printer/parser collusion.
module @refs_bulk {
  numerics true
  memory (min 1 max 4)
  memory i64 (min 2)
  table @funcs funcref min 2 max 8
  table @hosts externref min 1
  import "spectest" "global_i32" global i32
  import "spectest" "table" table funcref min 10 max 20
  import "spectest" "memory" memory (min 1 max 2)
  export "funcs" = table @funcs
  export "mem2" = memory 1
  data ( values (i32.const 0) ) = 0xdeadbeef
  data passive = 0x0102
  elem funcref @funcs ( values (i32.const 0) ) [ ref.func @worker, ref.func @worker ]
  elem funcref passive [ ref.func @worker, ref.null funcref ]
  elem externref declare [ ref.null externref ]
  func @worker ( %t:i32 ) -> (funcref) {
    let (%r0) = ref.func @worker ;
    let (%isn) = ref.is_null %r0 ;
    table.set @funcs %t %r0 ;
    let (%g) = table.get @funcs %t ;
    let (%sz) = table.size @funcs ;
    let (%null) = ref.null externref ;
    let (%grew) = table.grow @hosts i32.const 1 %null ;
    table.fill @hosts i32.const 0 %null i32.const 1 ;
    table.init @funcs i32.const 0 i32.const 0 i32.const 2 seg=0 ;
    table.copy @funcs @funcs i32.const 0 i32.const 0 i32.const 1 ;
    elem.drop seg=1 ;
    mem.fill i32.const 0 i32.const 0 i32.const 4 ;
    mem.copy i32.const 0 i32.const 0 i32.const 4 ;
    mem.init i32.const 0 i32.const 0 i32.const 2 seg=1 ;
    data.drop seg=1 ;
    let (%big) = mem.load i64 8 %t offset=0 mem=1 ;
    mem.store 4 %t i32.const 7 offset=0 mem=1 ;
    let (%pages) = mem.size mem=1 ;
    return (%g)
  }
}
```

The expected `Module` is built by hand in `roundtrip_test.gleam` (a `refs_bulk_module()`
builder), and the test asserts `parse_module(read_golden("refs_bulk.ir")) ==
Ok(refs_bulk_module())` **plus** `check_roundtrip(refs_bulk_module())` (print then re-parse
stable). Two independently authored artifacts agreeing is what defeats collusion.

---

## Effect / soundness / security note

- **Totality is the security property.** `parse_module` runs on **untrusted text** (a dumped
  `.ir` from any stage, a fixture, a fuzz input). A panic on malformed input is a
  denial-of-service / sandbox concern, so the parser must stay total across the entire IR3
  extension: every new branch reuses helpers that return typed `ParseError`, never
  `let assert`/`panic`/`todo`. The negative/fuzz corpus (below) proves it.
- **No new capability surface.** The printer/parser are pure `String ↔ Module` functions with
  no I/O, no ambient authority, and no evaluation. They do not link a runtime, resolve an
  import, or execute a `start` — the reference opacity (`externref` cannot be forged/inspected)
  and the import fail-closed contract (H4/H6) live in `emit_core`/the runtime, not here. This
  unit only *renders and re-reads names and shapes*.
- **Bit-exact numerics carry over unchanged.** The new surface adds reference/table/bulk
  nodes, **not** new numeric encodings; `ConstF32`/`ConstF64` still print as raw
  zero-padded `0x`-hex bits, so NaN payloads, `-0.0`, and ±Inf remain lossless (D5). The
  round-trip corpus keeps the existing NaN/`-0.0`/±Inf cases green.
- **Syntax, not semantics.** The parser does **not** validate reftype compatibility, memory-
  index bounds, segment-index existence, or active-segment offsets — it builds a well-formed
  `Module` and defers all meaning to `validate`/`lower`/`emit_core`/runtime. A syntactically
  valid but semantically nonsensical `.ir` (e.g. `table.get` on an undeclared table) parses
  fine and is rejected later; that separation is intentional (D4/D7).

---

## Verification — Definition of Done (D8)

Tests assert the **D7 contract and the §A grammar**, not whatever the printer happens to emit
(no change-detector tests). Spec-objective: the corpus is derived from the WASM reference-
types / bulk-memory / multi-memory / memory64 **constructs** (what forms must exist), and the
round-trip property `parse(print(m)) == m` is the algebraic invariant asserted.

1. **Round-trip property** holds via `module_equal` on the extended full-surface corpus:
   - both reftype `ValType`s in every valtype position (param/local/global/functype);
   - each `RefType` in `TableDecl`, `ImportTable`, `ElementSegment`, and `ref.null`;
   - every reference expr (`RefNull` at both reftypes, `RefFunc`, `RefIsNull`);
   - every table expr (`get/set/size/grow/fill/init/copy`, `elem.drop`), including
     `table.copy` with two distinct table names and `table.init` with a `seg=`;
   - every bulk-mem expr (`mem.fill/copy/init`, `data.drop`), including `mem.copy` with
     **distinct `dst_mem`/`src_mem`** and both-zero (decorators omitted);
   - the memory index on `mem.size/grow/load/store` at **index 0 (omitted) and non-zero**;
   - `Module.memories` with **zero, one, and two** memories, and an `Idx64` (memory64) memory;
   - every import state variant (`global` mut/immut, `table` funcref/externref, `memory`
     i32/i64) and every export state variant (`global`/`table`/`memory`-by-index);
   - `ElementSegment` in all three modes (active/passive/declarative) with `init` lists of
     `RefFunc` and `RefNull` items; `DataSegment` active (mem 0 and non-0) and passive.
2. **Golden suite (independent oracle).** The hand-authored `refs_bulk.ir` parses to its
   by-hand expected `Module` and re-prints + re-parses stably (`check_roundtrip`). The four
   existing goldens `add`/`sum_to`/`fib`/`mem_table` **still parse** — `mem_table.ir` via the
   legacy funcref-default `table`, the `@name`-abbreviation `elem` init list, and the single-
   line `memory` form (proving backward-compat, §D).
3. **Discrimination tests** (prove no field is dropped):
   - a `funcref` vs an `externref` table (same name/min/max) round-trip to **distinct**
     `Module`s;
   - a memory-index-0 vs memory-index-1 `mem.load` (same access/addr/offset/result) round-trip
     to **distinct** `Module`s (the `mem=` decorator is not dropped);
   - an `Idx32` vs `Idx64` `MemoryDecl` (same min/max) round-trip to distinct `Module`s;
   - an `ElemActive` vs `ElemPassive` vs `ElemDeclarative` segment (same reftype/init) round-
     trip to distinct `Module`s;
   - a `RefNull(FuncRef)` vs `RefNull(ExternRef)` round-trip to distinct `Module`s.
4. **NaN / `-0.0` / ±Inf still bit-exact** — the existing `float_bit_fidelity` /
   `nan_payloads_are_distinct` tests stay green (the new surface does not touch float
   encoding); add a reftype-typed global with a `ref.null` init alongside them to prove
   coexistence.
5. **Negative / fuzz corpus** returns the expected typed `ParseError` and **none panics**
   (totality): `ref.null i32` (bad reftype → `UnexpectedToken`), `table @t bogus min 1`
   (unknown reftype), `import "m" "n" widget …` (unknown import kind), `export "e" = frob @x`
   (unknown export kind), `mem.init %d %s %c` (missing `seg=` → `UnexpectedEnd`/`Unexpected
   Token`), `elem funcref @t` (missing offset/list), `memory i128 (min 1)` (bad idx token),
   and a `data.drop` / `elem.drop` with a non-number `seg=`. Reaching the end of the garbage
   battery without crashing the runner is the totality proof; fold them into
   `negative_garbage_inputs_never_panic_test` and/or named per-variant tests.
6. **Build hygiene.** `gleam format --check src test` clean; `gleam build` has **ZERO
   warnings** (no `todo` / placeholder arm may remain in printer or parser — every exhaustive
   match is fully implemented); `gleam test` green (≥ the current count; the Phase-1 237 +
   Phase-2 round-trip tests stay green).
7. **Docs (D8).** Every new/changed public and private function documented: the new
   `parse_reftype`/`print_reftype`, `parse_opt_kv`/`print_memidx`, `parse_seg`,
   `parse_ref_init_list`/`print_ref_init`, `parse_import_kind`/`parse_export_kind`, and the
   updated doc comments on `print_module`/`print_expr`/`parse_expr`/`parse_module_items`/
   `parse_memory`/`parse_table`/`parse_elem`/`parse_data`/`build_module`/`ModuleAcc` — each
   stating the contract, the `Ok`/`Error` semantics, and (for the parser) why it cannot panic.
8. **Grammar reconciled.** `specs/phase-5/ir-grammar-delta.md` exists and matches the
   implementation exactly (§A is its content), cross-linked from `ir-grammar.md` like the
   Phase-2 delta.

**Proving the goal:** (a) full-surface round-trip green + (b) the hand-authored `refs_bulk.ir`
parsing *and* re-printing stably defeat printer/parser collusion; (c) the discrimination tests
prove no new field is silently dropped; (d) the negative corpus returning typed errors proves
totality held across the extension.

## What this unit leaves

Once `.ir` round-trips the IR3 surface, every Phase-5 stage regains its golden-file boundary
for the new surface:

- **05 (lower)** can golden-test "WASM AST3 → IR3" by emitting `.ir` and diffing against a
  hand-written expected `.ir` (reftype lowering, table/bulk ops, multi-memory index threading,
  passive-segment lowering, memory64 address width).
- **06 (emit_core)** can be driven from a hand-written IR3 `.ir` fixture (a ref/table/bulk
  slice, or a multi-memory module) — an end-to-end backend test with no frontend needed.
- **11 (conformance)** can dump/load IR3 at any seam for differential tests and to snapshot the
  IR of a spec-suite module.

This unit gates none of them (the round-trip is a property, not a bound interface), so it can
land any time after `«IR3-FROZEN»`.

## Open questions (for the planner / cross-unit sync)

1. **`ConstNull` `Value`?** The provisional surface says references likely need **no new
   `Value` constructor** (a null ref flows as a `Var` bound to `RefNull`). If `P5-01` instead
   adds `ConstNull(RefType)` (or a `RefValue`) — e.g. because element/global constant-init
   expressions want a literal null in `value` position — then `print_value`/`parse_value` need
   an arm. Proposed `value`-position spelling: **`null funcref` / `null externref`** (a bare
   `null` keyword + reftype, distinct from the `ref.null` *expression*). Flagged so the
   spelling is ready either way; keystone decides.
2. **New `TrapReason`?** The provisional says likely **none** (reuse `UninitializedElement`/
   `TableOutOfBounds`/`MemoryOutOfBounds`/`IndirectCallTypeMismatch`). If `P5-01` adds one
   (e.g. for bulk-init-from-a-dropped-segment or a memory64-specific message), add exactly one
   snake_case arm to `trapreason_to_string`/`string_to_trapreason` — no design impact.
3. **Memory-index decorator placement/omission.** I chose a trailing `mem=<int>` /
   `dst_mem=`/`src_mem=` decorator, **omitted when 0**, so single-memory `.ir` is byte-
   identical to Phase-4. Confirm with the `emit_core` (06) owner that omit-zero `.ir` is fine
   (it is pure text; no `.core` impact). Alternative if reconciliation prefers always-explicit:
   drop the omit-when-zero rule (costs `.ir` byte-identity but is simpler).
4. **Explicit vs omitted `table` reftype.** The printer emits `table @t funcref min N`
   (explicit) for unambiguity; a `FuncRef`-only Phase-4 module is therefore **not** byte-
   identical `.ir` (one extra token). If strict `.ir` neutrality is wanted, omit the reftype
   for `FuncRef` (the parser already defaults to it). Same choice for `elem` (OQ 5). I lean
   explicit; flag for reconcile.
5. **`elem` init: explicit exprs vs `@name` abbreviation as canonical.** The printer emits the
   explicit `[ ref.func @f, ref.null t ]` form; the parser also accepts the `@name` funcidx
   abbreviation (so `mem_table.ir` parses). If reconciliation wants the abbreviated `[ @f ]`
   form to be *canonical* for all-`RefFunc` active segments (byte-identical to Phase-2), the
   printer can special-case it. I lean explicit-canonical (uniform, handles `ref.null`/
   externref); flag.
6. **`memory none` / empty-list rendering.** An empty `Module.memories` prints **no** `memory`
   line (the printer never emits `memory none`); the parser still **accepts** `memory none` as
   a zero-contribution legacy alias so old goldens parse. Confirm the keystone is content that
   `memory none` is accepted-but-not-emitted (vs. removing it entirely, which would break
   `add.ir`/`sum_to.ir`/`fib.ir`).
7. **Ownership of `roundtrip_test.gleam` between `P5-01` and `P5-02`.** As in Phase 2,
   `P5-01` minimally updates the constructors to compile; `P5-02` owns the real corpus + the
   new golden. Confirm this split so the test file is not double-owned.
8. **`IdxType` token reuse.** I reuse the valtype tokens `i32`/`i64` to mark the memory index
   type (`i64` = memory64). This is natural (a memory64 address *is* an `i64`) but overloads
   the token. Alternative if the overload is undesirable: dedicated `idx32`/`idx64` tokens.
   Flag for the grammar reconcile.

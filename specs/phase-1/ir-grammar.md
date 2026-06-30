# The `.ir` textual form — grammar (seeded strawman)

> Owned by **unit 01** (frozen *with* the IR types). Implemented by **unit 02**
> (printer + parser). This is a **seeded strawman**; unit 01 finalizes it to match the
> frozen `ir.gleam`. It exists so the printer and parser target a *written grammar*
> rather than each other (D7 — prevents printer/parser collusion).

## Design rules (from D7)

- **One canonical form.** The printer is deterministic; for any module `m`,
  `parse(print(m)) == m`, where equality compares **numeric literals by bit pattern**
  (NaN payloads and `-0.0` are significant).
- **Floats are lossless.** Print float constants as their raw bit pattern (the form
  below uses `f64.const 0x<hex-bits>`), never a decimal that can lose precision.
- **Human-readable**, LLVM-`.ll`-flavoured. Comments start with `;` to end of line.
- **Golden `.ir` files are authored by hand** against this grammar (unit 01 deliverable
  6), so the printer and parser are validated against an independent source of truth,
  not just each other.

## Lexical

```
ident   := name of a local/label/function/global, e.g. %x, %loop0, @add   ; see note
int     := decimal or 0x-hex (the stored UNSIGNED bit pattern)
fbits   := 0x-hex (raw IEEE-754 bits)
string  := "…" with the usual escapes (export/import/capability names)
comment := ';' … end-of-line
```

> **Sigil convention (frozen by unit 01):** `%name` for locals/let-bindings/loop vars,
> `$name` for labels, `@name` for functions/globals, `"…"` for host/export names. These
> are the frozen sigils; they make the textual form unambiguous and easy to parse.

## Module

```
module @<name> {
  ; capability axes (D5)
  numerics <true|false>
  memory <none | (min <int> [max <int>])>

  global @<name> : <valtype> [mut] = <expr>
  import "<capability>" "<name>" : <functype>          ; reached only via call_host
  export "<export-name>" = @<fnname>
  data @<offset-expr> = <hexbytes>                       ; Phase-2

  func @<name> ( <param>,* ) -> ( <valtype>* ) {        ; params are NAMED slots
    local %<name> : <valtype>
    <expr>                                               ; the body
  }
}
```

```
valtype  := i32 | i64 | f32 | f64 | term
functype := ( <valtype>* ) -> ( <valtype>* )             ; nameless; for imports/call_indirect
param    := %<name> : <valtype>                          ; a named param slot (Function.params)
```

## Values

```
value := %<name>                  ; a binding reference
       | i32.const <int>          ; raw unsigned bits in [0, 2^32)
       | i64.const <int>
       | f32.const <fbits>        ; raw binary32 bits
       | f64.const <fbits>        ; raw binary64 bits
```

## Expressions (ANF with structured control)

> **Strict ANF (frozen by unit 01).** Every *operand* position holds an atomic
> `<value>` — including an `if`/`switch` selector and the operands of
> `return`/`break`/`continue`. Computations are therefore named by `let` before being
> used; the canonical printer never nests a computation in an operand position. This is
> what makes the round-trip canonical and the 1:1 lowering to Core Erlang clean.

```
expr :=
    ; sequencing
    let ( %<name>,* ) = <expr> ; <expr>          ; bind rhs results, then continue
  | values ( <value>,* )                          ; forward values (tail of a block)

    ; ops
  | num <numop> ( <value>,* )
  | convert <convop> <value>
  | term <termop> ( <value>,* )                   ; Phase-2

    ; memory (Phase-2)
  | mem.load  <memaccess> <value> offset=<int>
  | mem.store <memaccess> <value> <value> offset=<int>
  | global.get @<name>
  | global.set @<name> <value>

    ; calls
  | call @<fnname> ( <value>,* )
  | call_indirect @<table> [<value>] : <functype> ( <value>,* )
  | call_host "<capability>" "<name>" ( <value>,* )

    ; structured control (NAMED labels only — D6)
  | block $<label> : ( <valtype>* ) { <expr> }
  | loop  $<label> ( <loopparam>,* ) : ( <valtype>* ) { <expr> }
  | if <value> : ( <valtype>* ) { <expr> } else { <expr> }
  | switch <value> : ( <valtype>* ) { <arm>* default { <expr> } }

    ; control transfers (do not fall through)
  | break    $<label> ( <value>,* )
  | continue $<label> ( <value>,* )
  | return ( <value>,* )

    ; effects
  | trap <trapreason>
  | charge <int> ; <expr>

loopparam := %<name> : <valtype> = <value>          ; name : type = initial value
arm       := case <int> { <expr> }
```

```
numop      := i.add.32 | i.sub.32 | … | f.add.64 | …   ; a neutral, width-suffixed spelling
convop     := i32.wrap_i64 | i64.extend_i32_s | trunc_sat_s.f64.i32 | box.i32 | …
memaccess  := <bytes> [signed]
trapreason := int_div_by_zero | int_overflow | unreachable | indirect_type_mismatch | mem_oob
```

> The textual spellings of `numop`/`convop`/`trapreason` are a 1:1 rendering of the
> `NumOp`/`ConvOp`/`TrapReason` constructors in `ir.gleam`. Keep them **neutral** (no
> `i32.add`-as-the-canonical-op-name; the *value type* is i32 but the *operation
> spelling* should read as "integer add, width 32"). Unit 01 fixes the exact spellings
> when it freezes the enums.

## Worked example — `add(i32,i32) -> i32`

```
module @add {
  numerics true
  memory none
  export "add" = @add
  func @add ( %p0:i32, %p1:i32 ) -> (i32) {
    let (%r) = num i.add.32 (%p0, %p1) ;     ; ANF: bind the op, then return the value
    return (%r)
  }
}
```

## Worked example — `sum_to(n) -> i64` (loop = constant-space tail recursion)

```
module @loop {
  numerics true
  memory none
  export "sum_to" = @sum_to
  func @sum_to ( %p0:i64 ) -> (i64) {
    loop $go ( %i : i64 = i64.const 1, %acc : i64 = i64.const 0 ) : (i64) {
      let (%cond) = num i.le_u.64 (%i, %p0) ;  ; ANF: the if-selector is an atomic value
      if %cond : (i64) {
        let (%acc1) = num i.add.64 (%acc, %i) ;
        let (%i1)   = num i.add.64 (%i, i64.const 1) ;
        continue $go (%i1, %acc1)
      } else {
        break $go (%acc)
      }
    }
  }
}
```

> These two examples are also unit 01's first hand-authored golden `.ir` fixtures.
> Walking them through the `ir.gleam` types by hand (open question 4 in unit 01) is how
> you confirm the types can express the Phase-1 slice *before* freezing.

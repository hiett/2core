//// The canonical `.ir` printer (Unit 02).
////
//// Renders a `twocore/ir` `Module` to its **canonical, lossless, deterministic**
//// textual form — the inter-stage contract of the compiler (decision **D7** in
//// `specs/phase-1/00-overview.md`). Any stage can dump its IR with `print_module`
//// and reload it with `twocore/ir/parser.parse_module`; the two satisfy the D7
//// round-trip property `parse(print(m)) == m` for every module `m`.
////
//// ## Canonical-form rules (fixed and deterministic)
////
//// - **One spelling per construct.** The grammar is `specs/phase-1/ir-grammar.md`.
////   Sigils: `%name` locals/let-binders/loop-vars, `$name` labels,
////   `@name` functions/globals/module, `"…"` host/export/capability names.
//// - **Indentation** is a fixed 2 spaces per nesting level (whitespace is not
////   semantically significant — the parser ignores it — but the printer is still
////   deterministic so a given `Module` always prints byte-identically).
//// - **Floats are raw IEEE-754 bit patterns in lower-case, zero-padded `0x`-hex**
////   (`f32.const 0x<8 digits>`, `f64.const 0x<16 digits>`) — NEVER decimals, which
////   would lose f32 rounding and NaN payloads (D5). **Integer** constants print as
////   the stored **unsigned** value in canonical decimal.
//// - **Strict ANF.** Every operand position is an atomic `Value`; computations are
////   named by `let` before use. The printer never nests a computation in an operand.
//// - **Neutral, width-tagged op spellings** (D6): `i.add.32`, `f.add.64`,
////   `i.le_u.64` — never the WASM opcode string `i32.add`. The spelling tables here
////   are the single source of truth shared (by construction) with the parser.
////
//// Every function is total: the type system guarantees the `Module`/`Expr`/… variants,
//// so there is no unprintable value and nothing here panics.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/string_tree
import twocore/ir.{
  type ConvOp, type Expr, type FloatWidth, type FuncType, type Function,
  type IntWidth, type Local, type LoopParam, type MemAccess, type Module,
  type NumOp, type SwitchArm, type TermOp, type TrapReason, type ValType,
  type Value, Block, BoxFloat, BoxInt, Break, CallDirect, CallHost, CallIndirect,
  Charge, ConstF32, ConstF64, ConstI32, ConstI64, Continue, Convert, FAdd, FDiv,
  FMax, FMin, FMul, FSub, FW32, FW64, FuncType, Function, GlobalGet, GlobalSet,
  I32Extend16S, I32Extend8S, I32WrapI64, I64Extend16S, I64Extend32S, I64Extend8S,
  I64ExtendI32S, I64ExtendI32U, IAdd, IAnd, IClz, ICtz, IDivS, IDivU, IEq, IEqz,
  IGeS, IGeU, IGtS, IGtU, ILeS, ILeU, ILtS, ILtU, IMul, INe, IOr, IPopcnt, IRemS,
  IRemU, IRotl, IRotr, IShl, IShrS, IShrU, ISub, IXor, If,
  IndirectCallTypeMismatch, IntDivByZero, IntOverflow, Let, Loop, LoopParam,
  MakeCons, MakeTuple, MemAccess, MemLoad, MemStore, MemoryDecl,
  MemoryOutOfBounds, Num, ReinterpretFToI, ReinterpretIToF, Return, Switch,
  SwitchArm, TF32, TF64, TI32, TI64, TTerm, TermOp, Trap, TruncSatS, TruncSatU,
  TupleGet, UnboxFloat, UnboxInt, Unreachable, Values, Var, W32, W64,
}

// ───────────────────────────── public entry point ─────────────────────────────

/// Render an IR module to its canonical `.ir` text (D7).
///
/// Deterministic: the same `Module` always produces byte-identical output, and it
/// is the ONE canonical form (so a golden's text is unambiguous). Float constants
/// are printed as RAW IEEE-754 bit patterns in lower-case zero-padded `0x`-hex (D5)
/// — NEVER decimals (decimals lose f32 rounding and NaN payloads). Integer constants
/// are printed as their stored **unsigned** value in canonical decimal.
///
/// Parameters:
/// - `module`: any value of type `ir.Module`. All three capability axes (numerics,
///   memory, term) and every declaration/expression variant are handled.
///
/// Returns the full module text, terminated by a trailing newline. Total — every
/// value of type `Module` has a printable form (the type system guarantees the
/// variants), so this never fails and never panics.
pub fn print_module(module: Module) -> String {
  let header = [
    "module @" <> module.name <> " {\n",
    "  numerics " <> bool_str(module.uses_numerics) <> "\n",
    "  memory " <> memory_str(module.memory) <> "\n",
  ]
  let globals = list.map(module.globals, print_global)
  let imports = list.map(module.imports, print_import)
  let exports = list.map(module.exports, print_export)
  let data = list.map(module.data_segments, print_data)
  let funcs = list.map(module.functions, fn(f) { print_func(f) <> "\n" })

  string_tree.from_strings(
    list.flatten([header, globals, imports, exports, data, funcs, ["}\n"]]),
  )
  |> string_tree.to_string
}

// ───────────────────────────── module declarations ─────────────────────────────

/// Renders the `numerics` capability flag as the keyword `true`/`false`.
fn bool_str(b: Bool) -> String {
  case b {
    True -> "true"
    False -> "false"
  }
}

/// Renders the optional linear-memory declaration (D5): `none`, `(min N)`, or
/// `(min N max M)` (page counts as decimals).
fn memory_str(mem: option.Option(ir.MemoryDecl)) -> String {
  case mem {
    None -> "none"
    Some(MemoryDecl(min, None)) -> "(min " <> int.to_string(min) <> ")"
    Some(MemoryDecl(min, Some(max))) ->
      "(min " <> int.to_string(min) <> " max " <> int.to_string(max) <> ")"
  }
}

/// Renders one global slot: `  global @name : ty [mut] = <init-expr>`. The init is
/// a full expression printed at module indentation (2).
fn print_global(g: ir.GlobalDecl) -> String {
  let mut = case g.mutable {
    True -> " mut"
    False -> ""
  }
  "  global @"
  <> g.name
  <> " : "
  <> print_valtype(g.ty)
  <> mut
  <> " = "
  <> print_expr(2, g.init)
  <> "\n"
}

/// Renders one host import: `  import "cap" "name" : <functype>`.
fn print_import(i: ir.ImportDecl) -> String {
  let ir.ImportFn(capability, name, ty) = i
  "  import \""
  <> escape(capability)
  <> "\" \""
  <> escape(name)
  <> "\" : "
  <> print_functype(ty)
  <> "\n"
}

/// Renders one export: `  export "export-name" = @fn-name`.
fn print_export(e: ir.ExportDecl) -> String {
  let ir.ExportFn(export_name, fn_name) = e
  "  export \"" <> escape(export_name) <> "\" = @" <> fn_name <> "\n"
}

/// Renders one data segment (Phase-2 lock-now): `  data ( <offset-expr> ) = 0x<hex>`.
/// The offset is a full constant expression; the bytes are lower-case hex pairs.
fn print_data(d: ir.DataSegment) -> String {
  "  data ("
  <> print_expr(2, d.offset)
  <> ") = "
  <> print_hexbytes(d.bytes)
  <> "\n"
}

/// Renders a whole function with its named-param header (`func @add (%p0:i32) -> (i32)`),
/// any `local` slots, and the body indented at level 4.
fn print_func(f: Function) -> String {
  let Function(name, params, result, locals, body) = f
  let header =
    "  func @"
    <> name
    <> " ("
    <> string.join(list.map(params, print_param), ", ")
    <> ") -> ("
    <> string.join(list.map(result, print_valtype), ", ")
    <> ") {\n"
  let local_lines =
    list.map(locals, fn(l) {
      "    local %" <> l.name <> " : " <> print_valtype(l.ty) <> "\n"
    })
  header <> string.concat(local_lines) <> stmt(4, body) <> "\n  }"
}

/// Renders a named param slot as `%name:ty`.
fn print_param(l: Local) -> String {
  "%" <> l.name <> ":" <> print_valtype(l.ty)
}

// ───────────────────────────── types & values ─────────────────────────────

/// Renders a value type: `i32`/`i64`/`f32`/`f64`/`term`.
fn print_valtype(t: ValType) -> String {
  case t {
    TI32 -> "i32"
    TI64 -> "i64"
    TF32 -> "f32"
    TF64 -> "f64"
    TTerm -> "term"
  }
}

/// Renders a nameless `(params) -> (results)` signature (imports / call_indirect).
fn print_functype(ft: FuncType) -> String {
  let FuncType(params, results) = ft
  "("
  <> string.join(list.map(params, print_valtype), ", ")
  <> ") -> ("
  <> string.join(list.map(results, print_valtype), ", ")
  <> ")"
}

/// Renders an atomic value operand.
///
/// `Var` → `%name`. Integer constants print as the stored **unsigned** decimal.
/// Float constants print as their raw IEEE-754 bits in lower-case zero-padded
/// `0x`-hex (8 digits for f32, 16 for f64) — losslessly preserving NaN payloads
/// and `-0.0` (D5).
fn print_value(v: Value) -> String {
  case v {
    Var(name) -> "%" <> name
    ConstI32(bits) -> "i32.const " <> int.to_string(bits)
    ConstI64(bits) -> "i64.const " <> int.to_string(bits)
    ConstF32(bits) -> "f32.const 0x" <> hex_pad(bits, 8)
    ConstF64(bits) -> "f64.const 0x" <> hex_pad(bits, 16)
  }
}

/// Lower-case hex of `n`, left-zero-padded to at least `width` digits.
fn hex_pad(n: Int, width: Int) -> String {
  string.pad_start(string.lowercase(int.to_base16(n)), width, "0")
}

/// Comma-separated parenthesised list of values: `(%a, i32.const 1)` / `()`.
fn value_list(vs: List(Value)) -> String {
  "(" <> string.join(list.map(vs, print_value), ", ") <> ")"
}

/// Comma-separated parenthesised list of value types: `(i32, i64)` / `()`.
fn valtype_list(ts: List(ValType)) -> String {
  "(" <> string.join(list.map(ts, print_valtype), ", ") <> ")"
}

// ───────────────────────────── expressions ─────────────────────────────

/// `n` spaces of indentation.
fn spaces(n: Int) -> String {
  string.repeat(" ", n)
}

/// Prints an expression as a *statement*: indented to `indent`, then the expression.
fn stmt(indent: Int, e: Expr) -> String {
  spaces(indent) <> print_expr(indent, e)
}

/// Renders an expression. By convention the FIRST line carries NO leading indent
/// (the caller positions it — e.g. after `let (...) = `), while every continuation
/// line is absolutely indented relative to `indent`. The sequencing forms (`Let`,
/// `Charge`) place their continuation body on the next line at the same `indent`;
/// the structured-control forms (`Block`/`Loop`/`If`/`Switch`) indent their bodies
/// by one further level (`indent + 2`).
fn print_expr(indent: Int, e: Expr) -> String {
  case e {
    Values(vs) -> "values " <> value_list(vs)
    Num(op, args) -> "num " <> numop_to_string(op) <> " " <> value_list(args)
    Convert(op, arg) ->
      "convert " <> convop_to_string(op) <> " " <> print_value(arg)
    TermOp(op, args) ->
      "term " <> termop_to_string(op) <> " " <> value_list(args)
    MemLoad(op, addr, offset) ->
      "mem.load "
      <> print_memaccess(op)
      <> " "
      <> print_value(addr)
      <> " offset="
      <> int.to_string(offset)
    MemStore(op, addr, value, offset) ->
      "mem.store "
      <> print_memaccess(op)
      <> " "
      <> print_value(addr)
      <> " "
      <> print_value(value)
      <> " offset="
      <> int.to_string(offset)
    GlobalGet(name) -> "global.get @" <> name
    GlobalSet(name, value) ->
      "global.set @" <> name <> " " <> print_value(value)
    CallDirect(fn_name, args) -> "call @" <> fn_name <> " " <> value_list(args)
    CallIndirect(table, index, ty, args) ->
      "call_indirect @"
      <> table
      <> " ["
      <> print_value(index)
      <> "] : "
      <> print_functype(ty)
      <> " "
      <> value_list(args)
    CallHost(capability, name, args) ->
      "call_host \""
      <> escape(capability)
      <> "\" \""
      <> escape(name)
      <> "\" "
      <> value_list(args)
    Let(names, rhs, body) ->
      "let ("
      <> string.join(list.map(names, fn(n) { "%" <> n }), ", ")
      <> ") = "
      <> print_expr(indent, rhs)
      <> "\n"
      <> stmt(indent, body)
    Block(label, result, body) ->
      "block $"
      <> label
      <> " : "
      <> valtype_list(result)
      <> " {\n"
      <> stmt(indent + 2, body)
      <> "\n"
      <> spaces(indent)
      <> "}"
    Loop(label, params, result, body) ->
      "loop $"
      <> label
      <> " ("
      <> string.join(list.map(params, print_loopparam), ", ")
      <> ") : "
      <> valtype_list(result)
      <> " {\n"
      <> stmt(indent + 2, body)
      <> "\n"
      <> spaces(indent)
      <> "}"
    If(cond, result, then_branch, else_branch) ->
      "if "
      <> print_value(cond)
      <> " : "
      <> valtype_list(result)
      <> " {\n"
      <> stmt(indent + 2, then_branch)
      <> "\n"
      <> spaces(indent)
      <> "} else {\n"
      <> stmt(indent + 2, else_branch)
      <> "\n"
      <> spaces(indent)
      <> "}"
    Switch(selector, result, arms, default) ->
      "switch "
      <> print_value(selector)
      <> " : "
      <> valtype_list(result)
      <> " {\n"
      <> string.concat(list.map(arms, fn(a) { print_arm(indent, a) }))
      <> spaces(indent + 2)
      <> "default {\n"
      <> stmt(indent + 4, default)
      <> "\n"
      <> spaces(indent + 2)
      <> "}\n"
      <> spaces(indent)
      <> "}"
    Break(label, values) -> "break $" <> label <> " " <> value_list(values)
    Continue(label, values) ->
      "continue $" <> label <> " " <> value_list(values)
    Return(values) -> "return " <> value_list(values)
    Trap(reason) -> "trap " <> trapreason_to_string(reason)
    Charge(cost, body) ->
      "charge " <> int.to_string(cost) <> "\n" <> stmt(indent, body)
  }
}

/// Renders one `switch` arm at `indent + 2`, body at `indent + 4`.
fn print_arm(indent: Int, arm: SwitchArm) -> String {
  let SwitchArm(match, body) = arm
  spaces(indent + 2)
  <> "case "
  <> int.to_string(match)
  <> " {\n"
  <> stmt(indent + 4, body)
  <> "\n"
  <> spaces(indent + 2)
  <> "}\n"
}

/// Renders one loop iteration variable: `%name:ty = <init-value>`.
fn print_loopparam(p: LoopParam) -> String {
  let LoopParam(name, ty, init) = p
  "%" <> name <> ":" <> print_valtype(ty) <> " = " <> print_value(init)
}

/// Renders a memory-access descriptor: `<bytes>` optionally followed by ` signed`.
fn print_memaccess(m: MemAccess) -> String {
  let MemAccess(bytes, signed) = m
  case signed {
    True -> int.to_string(bytes) <> " signed"
    False -> int.to_string(bytes)
  }
}

// ───────────────────────────── op spelling tables ─────────────────────────────
// These are the single source of truth for the textual spellings; the parser's
// `string_to_*` mirror them. The full-surface round-trip test proves they agree.

/// Renders the 32/64 integer width suffix (`32`/`64`).
fn iwidth_str(w: IntWidth) -> String {
  case w {
    W32 -> "32"
    W64 -> "64"
  }
}

/// Renders the 32/64 float width suffix (`32`/`64`).
fn fwidth_str(w: FloatWidth) -> String {
  case w {
    FW32 -> "32"
    FW64 -> "64"
  }
}

/// Renders an integer width as a value-type token (`i32`/`i64`) for conv-op spellings.
fn iwidth_ty(w: IntWidth) -> String {
  case w {
    W32 -> "i32"
    W64 -> "i64"
  }
}

/// Renders a float width as a value-type token (`f32`/`f64`) for conv-op spellings.
fn fwidth_ty(w: FloatWidth) -> String {
  case w {
    FW32 -> "f32"
    FW64 -> "f64"
  }
}

/// Renders a neutral, width-tagged numeric op (D6): `i.<mnemonic>.<width>` for
/// integer ops, `f.<mnemonic>.<width>` for float ops (e.g. `i.add.32`, `f.div.64`).
fn numop_to_string(op: NumOp) -> String {
  case op {
    IAdd(w) -> "i.add." <> iwidth_str(w)
    ISub(w) -> "i.sub." <> iwidth_str(w)
    IMul(w) -> "i.mul." <> iwidth_str(w)
    IDivS(w) -> "i.div_s." <> iwidth_str(w)
    IDivU(w) -> "i.div_u." <> iwidth_str(w)
    IRemS(w) -> "i.rem_s." <> iwidth_str(w)
    IRemU(w) -> "i.rem_u." <> iwidth_str(w)
    IAnd(w) -> "i.and." <> iwidth_str(w)
    IOr(w) -> "i.or." <> iwidth_str(w)
    IXor(w) -> "i.xor." <> iwidth_str(w)
    IShl(w) -> "i.shl." <> iwidth_str(w)
    IShrS(w) -> "i.shr_s." <> iwidth_str(w)
    IShrU(w) -> "i.shr_u." <> iwidth_str(w)
    IRotl(w) -> "i.rotl." <> iwidth_str(w)
    IRotr(w) -> "i.rotr." <> iwidth_str(w)
    IClz(w) -> "i.clz." <> iwidth_str(w)
    ICtz(w) -> "i.ctz." <> iwidth_str(w)
    IPopcnt(w) -> "i.popcnt." <> iwidth_str(w)
    IEqz(w) -> "i.eqz." <> iwidth_str(w)
    IEq(w) -> "i.eq." <> iwidth_str(w)
    INe(w) -> "i.ne." <> iwidth_str(w)
    ILtS(w) -> "i.lt_s." <> iwidth_str(w)
    ILtU(w) -> "i.lt_u." <> iwidth_str(w)
    IGtS(w) -> "i.gt_s." <> iwidth_str(w)
    IGtU(w) -> "i.gt_u." <> iwidth_str(w)
    ILeS(w) -> "i.le_s." <> iwidth_str(w)
    ILeU(w) -> "i.le_u." <> iwidth_str(w)
    IGeS(w) -> "i.ge_s." <> iwidth_str(w)
    IGeU(w) -> "i.ge_u." <> iwidth_str(w)
    FAdd(w) -> "f.add." <> fwidth_str(w)
    FSub(w) -> "f.sub." <> fwidth_str(w)
    FMul(w) -> "f.mul." <> fwidth_str(w)
    FDiv(w) -> "f.div." <> fwidth_str(w)
    FMin(w) -> "f.min." <> fwidth_str(w)
    FMax(w) -> "f.max." <> fwidth_str(w)
  }
}

/// Renders a conversion op. Fixed spellings for the width/sign changes
/// (`i32.wrap_i64`, `i64.extend_i32_s`, `i32.extend8_s`, …) and parametric
/// spellings for the rest: `trunc_sat_s.<from>.<to>` (e.g. `trunc_sat_s.f64.i32`),
/// `reinterpret_f2i.<fw>` / `reinterpret_i2f.<iw>`, and `box.<ty>` / `unbox.<ty>`
/// for the explicit term↔numeric boxing bridge (`box.i32`, `unbox.f64`).
fn convop_to_string(op: ConvOp) -> String {
  case op {
    I32WrapI64 -> "i32.wrap_i64"
    I64ExtendI32S -> "i64.extend_i32_s"
    I64ExtendI32U -> "i64.extend_i32_u"
    I32Extend8S -> "i32.extend8_s"
    I32Extend16S -> "i32.extend16_s"
    I64Extend8S -> "i64.extend8_s"
    I64Extend16S -> "i64.extend16_s"
    I64Extend32S -> "i64.extend32_s"
    TruncSatS(from, to) ->
      "trunc_sat_s." <> fwidth_ty(from) <> "." <> iwidth_ty(to)
    TruncSatU(from, to) ->
      "trunc_sat_u." <> fwidth_ty(from) <> "." <> iwidth_ty(to)
    ReinterpretFToI(w) -> "reinterpret_f2i." <> fwidth_ty(w)
    ReinterpretIToF(w) -> "reinterpret_i2f." <> iwidth_ty(w)
    BoxInt(w) -> "box." <> iwidth_ty(w)
    UnboxInt(w) -> "unbox." <> iwidth_ty(w)
    BoxFloat(w) -> "box." <> fwidth_ty(w)
    UnboxFloat(w) -> "unbox." <> fwidth_ty(w)
  }
}

/// Renders a term-layer op (Phase-2 lock-now): `make_tuple`, `make_cons`, or
/// `tuple_get.<index>` (the index encoded in the spelling).
fn termop_to_string(op: TermOp) -> String {
  case op {
    MakeTuple -> "make_tuple"
    MakeCons -> "make_cons"
    TupleGet(index) -> "tuple_get." <> int.to_string(index)
  }
}

/// Renders a trap reason as the snake_case of its constructor (a clean 1:1
/// rendering): `int_div_by_zero`, `int_overflow`, `unreachable`,
/// `indirect_call_type_mismatch`, `memory_out_of_bounds`.
fn trapreason_to_string(r: TrapReason) -> String {
  case r {
    IntDivByZero -> "int_div_by_zero"
    IntOverflow -> "int_overflow"
    Unreachable -> "unreachable"
    IndirectCallTypeMismatch -> "indirect_call_type_mismatch"
    MemoryOutOfBounds -> "memory_out_of_bounds"
  }
}

// ───────────────────────────── string & bytes helpers ─────────────────────────────

/// Escapes a string for the `"…"` form: backslash, double-quote, and the common
/// control chars get a backslash escape; all other characters pass through.
fn escape(s: String) -> String {
  string.to_graphemes(s)
  |> list.map(escape_char)
  |> string.concat
}

/// Escapes a single grapheme for a quoted string literal.
fn escape_char(c: String) -> String {
  case c {
    "\\" -> "\\\\"
    "\"" -> "\\\""
    "\n" -> "\\n"
    "\t" -> "\\t"
    "\r" -> "\\r"
    _ -> c
  }
}

/// Renders a `BitArray` of bytes as `0x` followed by two lower-case hex digits per
/// byte (empty array → `0x`). Leading zero bytes are preserved (significant).
fn print_hexbytes(b: BitArray) -> String {
  "0x" <> hex_of_bytes(b, "")
}

/// Accumulates the lower-case hex-pair rendering of each byte of `b`.
fn hex_of_bytes(b: BitArray, acc: String) -> String {
  case b {
    <<byte:8, rest:bytes>> ->
      hex_of_bytes(
        rest,
        acc <> string.pad_start(string.lowercase(int.to_base16(byte)), 2, "0"),
      )
    _ -> acc
  }
}

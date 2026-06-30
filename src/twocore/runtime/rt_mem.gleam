//// `rt_mem` — linear memory: the `paged` implementation + the flat-binary `rebuild`
//// oracle (owner: unit 04). SIGNATURES frozen by unit 01; BODIES implemented by unit 04.
////
//// **State location.** `load`/`store`/`size`/`grow`/`init_data` operate on the `mem` field
//// of THIS process's cell — read via `rt_state.mem_get`, write the new memory value back
//// via `rt_state.mem_put`. The memory value is OPAQUE to `rt_state` (held as `Dynamic`);
//// `rt_mem` owns its shape and coerces. The handle never leaves the cell.
////
//// **No-wrap effective address (E3).** `ea = addr (unsigned i32) + offset (static u32)` is
//// computed as a BIGNUM and never reduced mod 2³²; an access traps iff
//// `ea + access_bytes > current_byte_len`. A multi-byte store traps BEFORE writing any
//// byte (all-or-nothing — zero corruption). Little-endian byte order.
////
//// **`grow` resource cap (E3).** A finite Safe max-pages cap is baked into the memory by
//// `fresh` (single-sourced) so `grow` enforces it without threading a profile through
//// generated code; `grow` returns `-1` past the cap/declared max and never allocates, and
//// charges fuel proportional to the bytes allocated.
////
//// **`rebuild` oracle (E4).** A flat-binary reference implementation is held to explicit
//// spec-corner tests and differentially tested against `paged`. Memory is a BEAM immutable
//// binary, so a bounds bug's worst case is a wrong/missing trap or a node-safe crash —
//// never a host out-of-bounds read. Tier P/O, never NIF.
////
//// NB (freeze): the public signatures below are frozen by name/arity/types. Their `todo`
//// bodies leave every parameter unused, so each is written `_name` (the Gleam idiom for an
//// unimplemented stub); unit 04 drops the underscore when it implements the body.

import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option}
import twocore/ir.{type TrapReason}

/// Build a FRESH opaque memory of `min_pages` zero-filled 64 KiB pages.
///
/// - `min_pages`: the initial page count (the module's declared memory minimum).
/// - `max_pages`: the module's declared maximum in pages, or `None` for "unbounded"
///   (still subject to `safe_cap`).
/// - `safe_cap`: the finite Safe max-pages cap (single-sourced; see E3), baked into the
///   returned value so `grow` enforces it without a profile parameter.
/// - Returns the fresh memory value as `Dynamic` (opaque, ready to hand to
///   `rt_state.seed`). Total — never fails.
pub fn fresh(
  _min_pages: Int,
  _max_pages: Option(Int),
  _safe_cap: Int,
) -> Dynamic {
  todo
}

/// Load `bytes` bytes (little-endian) from `addr + offset` in this process's memory,
/// producing a `result_width`-bit value.
///
/// - `bytes`: the access width in bytes (1/2/4/8).
/// - `signed`: whether a sub-word load is sign-extended to `result_width` (else zero-
///   extended). Irrelevant when `bytes * 8 == result_width`.
/// - `result_width`: the result's width in bits (32 or 64) — disambiguates e.g.
///   `i32.load8_s` from `i64.load8_s`.
/// - `addr`: the unsigned i32 base address.
/// - `offset`: the static unsigned offset (added as a bignum — no wrap).
/// - Returns `Ok(bits)` (the loaded value as a raw bit pattern), or
///   `Error(MemoryOutOfBounds)` if `ea + bytes > byte_len`.
pub fn load(
  _bytes: Int,
  _signed: Bool,
  _result_width: Int,
  _addr: Int,
  _offset: Int,
) -> Result(Int, TrapReason) {
  todo
}

/// Store the low `bytes` bytes (little-endian) of `value` to `addr + offset` in this
/// process's memory. All-or-nothing: traps BEFORE writing any byte if out of bounds.
///
/// - `bytes`: the store width in bytes (1/2/4/8). The value's sign is irrelevant.
/// - `addr`: the unsigned i32 base address.
/// - `value`: the value whose low `bytes` bytes are written (raw bit pattern).
/// - `offset`: the static unsigned offset (added as a bignum — no wrap).
/// - Returns `Ok(Nil)` on success, or `Error(MemoryOutOfBounds)` (with zero mutation).
pub fn store(
  _bytes: Int,
  _addr: Int,
  _value: Int,
  _offset: Int,
) -> Result(Nil, TrapReason) {
  todo
}

/// The current size of this process's memory, in 64 KiB pages (`memory.size`).
///
/// - Returns the page count. Total.
pub fn size() -> Int {
  todo
}

/// Grow this process's memory by `delta` pages (`memory.grow`).
///
/// - `delta`: the number of pages to add (≥ 0).
/// - Returns the PREVIOUS size in pages on success, or `-1` if the growth would exceed the
///   declared max or the Safe cap (in which case nothing is allocated). Newly-added pages
///   are zero-filled.
pub fn grow(_delta: Int) -> Int {
  todo
}

/// Write an active DATA segment's `bytes` into this process's memory at `offset`, at
/// instantiation. Bounds-checked (no-wrap).
///
/// - `offset`: the destination byte offset.
/// - `bytes`: the raw bytes to write.
/// - Returns `Ok(Nil)`, or `Error(MemoryOutOfBounds)` if the segment does not fit (an
///   instantiation-time trap).
pub fn init_data(_offset: Int, _bytes: BitArray) -> Result(Nil, TrapReason) {
  todo
}

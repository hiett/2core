//// Spec-grounded tests for `rt_mem` (unit 04) — the `paged` linear memory + the flat-binary
//// `rebuild` oracle.
////
//// These assert WebAssembly linear-memory SEMANTICS (not whatever the impl emits), citing
//// the spec, and hold BOTH the paged impl and the oracle to the same corner cases (a shared
//// bug must not hide — E4). The op set mirrors the official `memory_trap`/`address`/
//// `endianness`/`float_memory`/`memory_size`/`memory_redundancy` `.wast`; those are wired
//// END-TO-END at the capstone (unit 11), once decode/lower/emit reach memory ops — here we
//// call rt_mem's API directly (there is no pipeline path to memory yet).
////
//// Spec refs:
//// - exec/instructions (load/store, memory.size/grow):
////   <https://webassembly.github.io/spec/core/exec/instructions.html>
//// - exec/modules (active data init): <https://webassembly.github.io/spec/core/exec/modules.html>
//// - syntax/values (little-endian, two's complement, IEEE bits):
////   <https://webassembly.github.io/spec/core/syntax/values.html>
////
//// Structure: (1) spec-corner tests, each run on BOTH impls; (2) a randomized DIFFERENTIAL
//// suite (paged ≡ oracle) across several chunk sizes; (3) cell-backed wrapper tests
//// (seed → op → observe persistence + grow fuel); (4) a constant-space store-loop smoke.

import gleam/dynamic
import gleam/option.{None, Some}
import gleeunit/should
import twocore/ir.{MemoryOutOfBounds}
import twocore/runtime/rt_mem
import twocore/runtime/rt_meter
import twocore/runtime/rt_state.{StateDecl}

// Page byte length; one fresh page = 65536 bytes.
const page: Int = 65_536

/// A generous Safe cap so the spec-corner tests are governed by the declared max / hard cap,
/// not by `safe_cap` (which unit 11 owns). `100_000 > 65_536`, so it never binds below the
/// 65536-page hard cap.
const big_cap: Int = 100_000

// ───────────────────────────── 1. Little-endian multi-byte layout (endianness.wast) ─────────────────────────────

// Per the spec all loads/stores are little-endian: storing `0x04030201` as an i32 lays bytes
// `01 02 03 04` at +0..+3, and an i32 load reads them back as `0x04030201`.

pub fn le_layout_paged_test() {
  let m = rt_mem.fresh_mem(1, Some(1), big_cap, rt_mem.default_chunk_bytes)
  let assert Ok(m) = rt_mem.mem_store(m, 4, 0, 0x04030201, 0)
  // Each byte, low-to-high.
  rt_mem.mem_load(m, 1, False, 32, 0, 0) |> should.equal(Ok(0x01))
  rt_mem.mem_load(m, 1, False, 32, 1, 0) |> should.equal(Ok(0x02))
  rt_mem.mem_load(m, 1, False, 32, 2, 0) |> should.equal(Ok(0x03))
  rt_mem.mem_load(m, 1, False, 32, 3, 0) |> should.equal(Ok(0x04))
  // The whole i32 reads back identically (redundant load after store — memory_redundancy).
  rt_mem.mem_load(m, 4, False, 32, 0, 0) |> should.equal(Ok(0x04030201))
}

pub fn le_layout_oracle_test() {
  let o = rt_mem.o_fresh(1, Some(1), big_cap)
  let assert Ok(o) = rt_mem.o_store(o, 4, 0, 0x04030201, 0)
  rt_mem.o_load(o, 1, False, 32, 0, 0) |> should.equal(Ok(0x01))
  rt_mem.o_load(o, 1, False, 32, 1, 0) |> should.equal(Ok(0x02))
  rt_mem.o_load(o, 1, False, 32, 2, 0) |> should.equal(Ok(0x03))
  rt_mem.o_load(o, 1, False, 32, 3, 0) |> should.equal(Ok(0x04))
  rt_mem.o_load(o, 4, False, 32, 0, 0) |> should.equal(Ok(0x04030201))
}

// ───────────────────────────── 2. Sign vs zero extend × result width ─────────────────────────────

// `loadN_s` sign-extends to the operand width; `loadN_u` zero-extends. `result_width`
// disambiguates `i32.load8_s` (→ 0xFFFFFF80) from `i64.load8_s` (→ 0xFF..FF80) for byte 0x80,
// and the all-ones byte 0xFF.

pub fn sign_zero_extend_paged_test() {
  let m = rt_mem.fresh_mem(1, Some(1), big_cap, rt_mem.default_chunk_bytes)
  let assert Ok(m) = rt_mem.mem_store(m, 1, 0, 0x80, 0)
  let assert Ok(m) = rt_mem.mem_store(m, 1, 1, 0xFF, 0)
  // 0x80: i32.load8_s, i64.load8_s, load8_u.
  rt_mem.mem_load(m, 1, True, 32, 0, 0) |> should.equal(Ok(0xFFFFFF80))
  rt_mem.mem_load(m, 1, True, 64, 0, 0) |> should.equal(Ok(0xFFFFFFFFFFFFFF80))
  rt_mem.mem_load(m, 1, False, 32, 0, 0) |> should.equal(Ok(0x80))
  // 0xFF.
  rt_mem.mem_load(m, 1, True, 32, 1, 0) |> should.equal(Ok(0xFFFFFFFF))
  rt_mem.mem_load(m, 1, True, 64, 1, 0)
  |> should.equal(Ok(0xFFFFFFFFFFFFFFFF))
  rt_mem.mem_load(m, 1, False, 32, 1, 0) |> should.equal(Ok(0xFF))
}

pub fn sign_zero_extend_oracle_test() {
  let o = rt_mem.o_fresh(1, Some(1), big_cap)
  let assert Ok(o) = rt_mem.o_store(o, 1, 0, 0x80, 0)
  let assert Ok(o) = rt_mem.o_store(o, 1, 1, 0xFF, 0)
  rt_mem.o_load(o, 1, True, 32, 0, 0) |> should.equal(Ok(0xFFFFFF80))
  rt_mem.o_load(o, 1, True, 64, 0, 0) |> should.equal(Ok(0xFFFFFFFFFFFFFF80))
  rt_mem.o_load(o, 1, False, 32, 0, 0) |> should.equal(Ok(0x80))
  rt_mem.o_load(o, 1, True, 32, 1, 0) |> should.equal(Ok(0xFFFFFFFF))
  rt_mem.o_load(o, 1, True, 64, 1, 0) |> should.equal(Ok(0xFFFFFFFFFFFFFFFF))
  rt_mem.o_load(o, 1, False, 32, 1, 0) |> should.equal(Ok(0xFF))
}

// `i64.load16_s` of 0x8000 → 0xFFFFFFFFFFFF8000; `i64.load32_s` of 0x80000000 → high bits set.
pub fn wide_sign_extend_paged_test() {
  let m = rt_mem.fresh_mem(1, Some(1), big_cap, rt_mem.default_chunk_bytes)
  let assert Ok(m) = rt_mem.mem_store(m, 2, 0, 0x8000, 0)
  let assert Ok(m) = rt_mem.mem_store(m, 4, 8, 0x80000000, 0)
  rt_mem.mem_load(m, 2, True, 64, 0, 0)
  |> should.equal(Ok(0xFFFFFFFFFFFF8000))
  rt_mem.mem_load(m, 2, True, 32, 0, 0) |> should.equal(Ok(0xFFFF8000))
  rt_mem.mem_load(m, 4, True, 64, 8, 0)
  |> should.equal(Ok(0xFFFFFFFF80000000))
  rt_mem.mem_load(m, 4, False, 64, 8, 0) |> should.equal(Ok(0x80000000))
}

// ───────────────────────────── 3. Zero-fill (never-written + freshly grown) ─────────────────────────────

// A never-written in-bounds byte reads 0; every byte of a freshly grown page reads 0 (the
// sparse default-zero map gives this for free). (memory.wast)

pub fn zero_fill_paged_test() {
  let m = rt_mem.fresh_mem(1, Some(3), big_cap, rt_mem.default_chunk_bytes)
  // Never-written bytes at assorted in-bounds offsets read 0.
  rt_mem.mem_load(m, 1, False, 32, 0, 0) |> should.equal(Ok(0))
  rt_mem.mem_load(m, 4, False, 32, 12_345, 0) |> should.equal(Ok(0))
  rt_mem.mem_load(m, 8, False, 64, page - 8, 0) |> should.equal(Ok(0))
  // Grow one page; every byte of the new page reads 0.
  let #(old, m) = rt_mem.mem_grow(m, 1)
  old |> should.equal(1)
  rt_mem.mem_load(m, 1, False, 32, page, 0) |> should.equal(Ok(0))
  rt_mem.mem_load(m, 8, False, 64, 2 * page - 8, 0) |> should.equal(Ok(0))
}

pub fn zero_fill_oracle_test() {
  let o = rt_mem.o_fresh(1, Some(3), big_cap)
  rt_mem.o_load(o, 1, False, 32, 0, 0) |> should.equal(Ok(0))
  rt_mem.o_load(o, 4, False, 32, 12_345, 0) |> should.equal(Ok(0))
  let #(old, o) = rt_mem.o_grow(o, 1)
  old |> should.equal(1)
  rt_mem.o_load(o, 1, False, 32, page, 0) |> should.equal(Ok(0))
}

// ───────────────────────────── 4. No-wrap effective address (memory_trap / address.wast) ─────────────────────────────

// ea = addr + offset is a bignum; it is NEVER reduced mod 2^32. addr = 0xFFFFFFFF with a
// large static offset must TRAP, not wrap to a small in-bounds ea.

pub fn no_wrap_ea_paged_test() {
  let m = rt_mem.fresh_mem(1, Some(2), big_cap, rt_mem.default_chunk_bytes)
  // 0xFFFFFFFF + 100 = 0x10000_0063, far past byte_len = 65536. Must trap (no wrap to 99).
  rt_mem.mem_load(m, 4, False, 32, 0xFFFFFFFF, 100)
  |> should.equal(Error(MemoryOutOfBounds))
  rt_mem.mem_store(m, 4, 0xFFFFFFFF, 0xDEADBEEF, 100)
  |> should.equal(Error(MemoryOutOfBounds))
  // A wrap-bug would have computed ea = 99 (in bounds). Prove byte 99 is untouched (still 0).
  rt_mem.mem_load(m, 4, False, 32, 99, 0) |> should.equal(Ok(0))
}

pub fn no_wrap_ea_oracle_test() {
  let o = rt_mem.o_fresh(1, Some(2), big_cap)
  rt_mem.o_load(o, 4, False, 32, 0xFFFFFFFF, 100)
  |> should.equal(Error(MemoryOutOfBounds))
  rt_mem.o_store(o, 4, 0xFFFFFFFF, 0xDEADBEEF, 100)
  |> should.equal(Error(MemoryOutOfBounds))
}

// ───────────────────────────── 5. Exact-length off-by-one (address.wast) ─────────────────────────────

// An access ending EXACTLY at byte_len is in bounds; one byte past traps.

pub fn off_by_one_paged_test() {
  let m = rt_mem.fresh_mem(1, Some(1), big_cap, rt_mem.default_chunk_bytes)
  // Last in-bounds i32: ea = 65532, ea+4 = 65536 == byte_len → OK.
  rt_mem.mem_load(m, 4, False, 32, page - 4, 0) |> should.equal(Ok(0))
  // One byte further: ea = 65533, ea+4 = 65537 > 65536 → trap.
  rt_mem.mem_load(m, 4, False, 32, page - 3, 0)
  |> should.equal(Error(MemoryOutOfBounds))
  // Last single byte in bounds; first byte past traps.
  rt_mem.mem_load(m, 1, False, 32, page - 1, 0) |> should.equal(Ok(0))
  rt_mem.mem_load(m, 1, False, 32, page, 0)
  |> should.equal(Error(MemoryOutOfBounds))
}

pub fn off_by_one_oracle_test() {
  let o = rt_mem.o_fresh(1, Some(1), big_cap)
  rt_mem.o_load(o, 4, False, 32, page - 4, 0) |> should.equal(Ok(0))
  rt_mem.o_load(o, 4, False, 32, page - 3, 0)
  |> should.equal(Error(MemoryOutOfBounds))
  rt_mem.o_load(o, 1, False, 32, page - 1, 0) |> should.equal(Ok(0))
  rt_mem.o_load(o, 1, False, 32, page, 0)
  |> should.equal(Error(MemoryOutOfBounds))
}

// ───────────────────────────── 6. Partial multi-byte store traps with ZERO mutation (E3) ─────────────────────────────

// A multi-byte store straddling byte_len traps BEFORE any byte is written — including the
// in-bounds prefix. We seed a known i32, attempt a straddling store, and prove every byte is
// unchanged.

pub fn partial_store_zero_mutation_paged_test() {
  let m = rt_mem.fresh_mem(1, Some(1), big_cap, rt_mem.default_chunk_bytes)
  // Seed bytes at 65532..65535 = DD CC BB AA (i32 0xAABBCCDD, little-endian).
  let assert Ok(m) = rt_mem.mem_store(m, 4, page - 4, 0xAABBCCDD, 0)
  // Straddling store: ea = 65534, ea+4 = 65538 > 65536 → trap.
  rt_mem.mem_store(m, 4, page - 2, 0x11223344, 0)
  |> should.equal(Error(MemoryOutOfBounds))
  // mem_store returns the input Mem untouched on error; the original `m` is unchanged.
  rt_mem.mem_load(m, 4, False, 32, page - 4, 0)
  |> should.equal(Ok(0xAABBCCDD))
  rt_mem.mem_load(m, 1, False, 32, page - 2, 0) |> should.equal(Ok(0xBB))
  rt_mem.mem_load(m, 1, False, 32, page - 1, 0) |> should.equal(Ok(0xAA))
}

pub fn partial_store_zero_mutation_oracle_test() {
  let o = rt_mem.o_fresh(1, Some(1), big_cap)
  let assert Ok(o) = rt_mem.o_store(o, 4, page - 4, 0xAABBCCDD, 0)
  rt_mem.o_store(o, 4, page - 2, 0x11223344, 0)
  |> should.equal(Error(MemoryOutOfBounds))
  rt_mem.o_load(o, 4, False, 32, page - 4, 0)
  |> should.equal(Ok(0xAABBCCDD))
}

// ───────────────────────────── 7. memory.grow: OLD size, then -1 past max / cap (memory_size.wast) ─────────────────────────────

// grow returns the OLD size on success and -1 past the declared max / Safe cap / hard cap,
// allocating nothing; size reflects only successful grows.

pub fn grow_declared_max_paged_test() {
  let m = rt_mem.fresh_mem(1, Some(3), big_cap, rt_mem.default_chunk_bytes)
  rt_mem.mem_size(m) |> should.equal(1)
  let #(r1, m) = rt_mem.mem_grow(m, 1)
  r1 |> should.equal(1)
  rt_mem.mem_size(m) |> should.equal(2)
  let #(r2, m) = rt_mem.mem_grow(m, 1)
  r2 |> should.equal(2)
  rt_mem.mem_size(m) |> should.equal(3)
  // Past the declared max (3): -1, allocate nothing, size unchanged.
  let #(r3, m) = rt_mem.mem_grow(m, 1)
  r3 |> should.equal(-1)
  rt_mem.mem_size(m) |> should.equal(3)
  // delta 0 is a successful no-op returning the current size.
  let #(r4, _m) = rt_mem.mem_grow(m, 0)
  r4 |> should.equal(3)
}

pub fn grow_declared_max_oracle_test() {
  let o = rt_mem.o_fresh(1, Some(3), big_cap)
  let #(r1, o) = rt_mem.o_grow(o, 1)
  r1 |> should.equal(1)
  let #(r2, o) = rt_mem.o_grow(o, 1)
  r2 |> should.equal(2)
  let #(r3, o) = rt_mem.o_grow(o, 1)
  r3 |> should.equal(-1)
  rt_mem.o_size(o) |> should.equal(3)
}

// The Safe `safe_cap` binds when no max is declared (max_pages = None). Paged grow allocates
// nothing for unwritten pages, so we can probe the cap cheaply.
pub fn grow_safe_cap_paged_test() {
  // max = None, safe_cap = 5 → effective max 5.
  let m = rt_mem.fresh_mem(2, None, 5, rt_mem.default_chunk_bytes)
  let #(r1, m) = rt_mem.mem_grow(m, 3)
  r1 |> should.equal(2)
  rt_mem.mem_size(m) |> should.equal(5)
  let #(r2, m) = rt_mem.mem_grow(m, 1)
  r2 |> should.equal(-1)
  rt_mem.mem_size(m) |> should.equal(5)
}

// The 65536-page hard cap binds even when safe_cap/declared-max are larger. Paged pages cost
// nothing until written, so start near the cap and probe it without allocating gigabytes.
pub fn grow_hard_cap_paged_test() {
  // safe_cap huge, max None → effective max = min(200000, 65536) = 65536.
  let m = rt_mem.fresh_mem(65_535, None, 200_000, rt_mem.default_chunk_bytes)
  let #(r1, m) = rt_mem.mem_grow(m, 1)
  r1 |> should.equal(65_535)
  rt_mem.mem_size(m) |> should.equal(65_536)
  // One more page would be 65537 > 65536 → -1.
  let #(r2, _m) = rt_mem.mem_grow(m, 1)
  r2 |> should.equal(-1)
}

// A negative delta never grows (defensive; WASM delta is u32 so this is unreachable upstream).
pub fn grow_negative_delta_paged_test() {
  let m = rt_mem.fresh_mem(2, Some(4), big_cap, rt_mem.default_chunk_bytes)
  let #(r, m) = rt_mem.mem_grow(m, -1)
  r |> should.equal(-1)
  rt_mem.mem_size(m) |> should.equal(2)
}

// ───────────────────────────── 8. f32/f64 round-trip preserves raw bits incl. NaN (float_memory.wast) ─────────────────────────────

// f32/f64 store/load are raw-byte moves over the IEEE bit pattern — never a BEAM-double
// round-trip (which would mangle NaN payloads / signalling bits). Store a NaN-payload pattern
// and read the identical bits back.

pub fn float_nan_roundtrip_paged_test() {
  let m = rt_mem.fresh_mem(1, Some(1), big_cap, rt_mem.default_chunk_bytes)
  // f64 signalling-NaN-ish payload, and -0.0.
  let f64_nan = 0x7FF8000000000001
  let f64_neg_zero = 0x8000000000000000
  // f32 quiet NaN with payload, and +Inf.
  let f32_nan = 0x7FC00001
  let f32_pos_inf = 0x7F800000
  let assert Ok(m) = rt_mem.mem_store(m, 8, 0, f64_nan, 0)
  let assert Ok(m) = rt_mem.mem_store(m, 8, 8, f64_neg_zero, 0)
  let assert Ok(m) = rt_mem.mem_store(m, 4, 16, f32_nan, 0)
  let assert Ok(m) = rt_mem.mem_store(m, 4, 20, f32_pos_inf, 0)
  rt_mem.mem_load(m, 8, False, 64, 0, 0) |> should.equal(Ok(f64_nan))
  rt_mem.mem_load(m, 8, False, 64, 8, 0) |> should.equal(Ok(f64_neg_zero))
  rt_mem.mem_load(m, 4, False, 32, 16, 0) |> should.equal(Ok(f32_nan))
  rt_mem.mem_load(m, 4, False, 32, 20, 0) |> should.equal(Ok(f32_pos_inf))
}

pub fn float_nan_roundtrip_oracle_test() {
  let o = rt_mem.o_fresh(1, Some(1), big_cap)
  let f64_nan = 0x7FF8000000000001
  let f32_nan = 0x7FC00001
  let assert Ok(o) = rt_mem.o_store(o, 8, 0, f64_nan, 0)
  let assert Ok(o) = rt_mem.o_store(o, 4, 8, f32_nan, 0)
  rt_mem.o_load(o, 8, False, 64, 0, 0) |> should.equal(Ok(f64_nan))
  rt_mem.o_load(o, 4, False, 32, 8, 0) |> should.equal(Ok(f32_nan))
}

// ───────────────────────────── 9. init_data: in-bounds writes exact bytes; OOB traps (instantiation abort) ─────────────────────────────

pub fn init_data_paged_test() {
  let m = rt_mem.fresh_mem(1, Some(1), big_cap, rt_mem.default_chunk_bytes)
  let assert Ok(m) = rt_mem.mem_init_data(m, 10, <<0xDE, 0xAD, 0xBE, 0xEF>>)
  rt_mem.mem_load(m, 1, False, 32, 10, 0) |> should.equal(Ok(0xDE))
  rt_mem.mem_load(m, 1, False, 32, 13, 0) |> should.equal(Ok(0xEF))
  // i32.load reads them little-endian: bytes DE AD BE EF → 0xEFBEADDE.
  rt_mem.mem_load(m, 4, False, 32, 10, 0) |> should.equal(Ok(0xEFBEADDE))
  // A segment that overruns byte_len traps (whole-range check, no partial write).
  rt_mem.mem_init_data(m, page - 2, <<1, 2, 3, 4>>)
  |> should.equal(Error(MemoryOutOfBounds))
  // The straddling segment wrote nothing: the last in-bounds byte is still 0.
  rt_mem.mem_load(m, 1, False, 32, page - 2, 0) |> should.equal(Ok(0))
}

pub fn init_data_oracle_test() {
  let o = rt_mem.o_fresh(1, Some(1), big_cap)
  let assert Ok(o) = rt_mem.o_init_data(o, 10, <<0xDE, 0xAD, 0xBE, 0xEF>>)
  rt_mem.o_load(o, 4, False, 32, 10, 0) |> should.equal(Ok(0xEFBEADDE))
  rt_mem.o_init_data(o, page - 2, <<1, 2, 3, 4>>)
  |> should.equal(Error(MemoryOutOfBounds))
}

// An empty active segment is always in bounds (even at byte_len), and is a no-op.
pub fn init_data_empty_segment_paged_test() {
  let m = rt_mem.fresh_mem(1, Some(1), big_cap, rt_mem.default_chunk_bytes)
  rt_mem.mem_init_data(m, page, <<>>) |> should.be_ok
}

// ───────────────────────────── 10. Chunk-boundary-crossing access (alignment is non-semantic) ─────────────────────────────

// An unaligned access that crosses a physical chunk boundary must read/write correctly —
// alignment is only a hint. With chunk = 65, an i32 at addr 63 spans chunk 0 and chunk 1.
pub fn chunk_boundary_crossing_test() {
  let m = rt_mem.fresh_mem(1, Some(1), big_cap, 65)
  let assert Ok(m) = rt_mem.mem_store(m, 4, 63, 0x04030201, 0)
  // Whole i32 reads back across the boundary.
  rt_mem.mem_load(m, 4, False, 32, 63, 0) |> should.equal(Ok(0x04030201))
  // Each byte sits where expected: 63,64 in chunk 0; 65,66 in chunk 1.
  rt_mem.mem_load(m, 1, False, 32, 63, 0) |> should.equal(Ok(0x01))
  rt_mem.mem_load(m, 1, False, 32, 64, 0) |> should.equal(Ok(0x02))
  rt_mem.mem_load(m, 1, False, 32, 65, 0) |> should.equal(Ok(0x03))
  rt_mem.mem_load(m, 1, False, 32, 66, 0) |> should.equal(Ok(0x04))
  // A neighbouring byte is untouched.
  rt_mem.mem_load(m, 1, False, 32, 62, 0) |> should.equal(Ok(0))
  rt_mem.mem_load(m, 1, False, 32, 67, 0) |> should.equal(Ok(0))
}

// ───────────────────────────── 11. DIFFERENTIAL: paged ≡ oracle over randomized streams (E4) ─────────────────────────────

// One observable result of an op (loaded value/trap, store ok/trap, grow result, init
// ok/trap) — compared between paged and oracle in lockstep.
type OpResult {
  RLoad(Result(Int, ir.TrapReason))
  RStore(Result(Nil, ir.TrapReason))
  RGrow(Int)
  RInit(Result(Nil, ir.TrapReason))
}

type Op {
  OpLoad(bytes: Int, signed: Bool, width: Int, addr: Int, offset: Int)
  OpStore(bytes: Int, addr: Int, value: Int, offset: Int)
  OpGrow(delta: Int)
  OpInit(offset: Int, bytes: BitArray)
}

/// A 31-bit linear-congruential PRNG (deterministic so a failure reproduces). Returns the
/// next state in `[0, 2^31)`.
fn lcg(state: Int) -> Int {
  let next = state * 1_103_515_245 + 12_345
  bitand(next, 0x7FFFFFFF)
}

@external(erlang, "erlang", "band")
fn bitand(a: Int, b: Int) -> Int

@external(erlang, "erlang", "bor")
fn bitor(a: Int, b: Int) -> Int

@external(erlang, "erlang", "bsl")
fn bsl(a: Int, b: Int) -> Int

/// Drive paged and oracle through the same `count` random ops at physical chunk size `chunk`;
/// assert identical results+traps at every step and an identical final flat byte image.
fn run_differential(chunk: Int, count: Int, seed: Int) -> Nil {
  let m = rt_mem.fresh_mem(1, Some(4), big_cap, chunk)
  let o = rt_mem.o_fresh(1, Some(4), big_cap)
  let #(m, o) = diff_loop(m, o, seed, count)
  // Final byte image must be identical (catches any silent LE/sparse-zero/boundary drift).
  rt_mem.to_flat(m) |> should.equal(rt_mem.o_flat(o))
}

fn diff_loop(
  m: rt_mem.Mem,
  o: rt_mem.OMem,
  seed: Int,
  remaining: Int,
) -> #(rt_mem.Mem, rt_mem.OMem) {
  case remaining <= 0 {
    True -> #(m, o)
    False -> {
      let #(op, seed) = gen_op(rt_mem.mem_size(m) * page, seed)
      let #(m, rp) = apply_paged(m, op)
      let #(o, ro) = apply_oracle(o, op)
      // The security boundary: paged and oracle must agree on value AND trap, every step.
      rp |> should.equal(ro)
      diff_loop(m, o, seed, remaining - 1)
    }
  }
}

fn apply_paged(m: rt_mem.Mem, op: Op) -> #(rt_mem.Mem, OpResult) {
  case op {
    OpLoad(b, s, w, a, off) -> #(m, RLoad(rt_mem.mem_load(m, b, s, w, a, off)))
    OpStore(b, a, v, off) ->
      case rt_mem.mem_store(m, b, a, v, off) {
        Ok(m2) -> #(m2, RStore(Ok(Nil)))
        Error(e) -> #(m, RStore(Error(e)))
      }
    OpGrow(d) -> {
      let #(r, m2) = rt_mem.mem_grow(m, d)
      #(m2, RGrow(r))
    }
    OpInit(off, bytes) ->
      case rt_mem.mem_init_data(m, off, bytes) {
        Ok(m2) -> #(m2, RInit(Ok(Nil)))
        Error(e) -> #(m, RInit(Error(e)))
      }
  }
}

fn apply_oracle(o: rt_mem.OMem, op: Op) -> #(rt_mem.OMem, OpResult) {
  case op {
    OpLoad(b, s, w, a, off) -> #(o, RLoad(rt_mem.o_load(o, b, s, w, a, off)))
    OpStore(b, a, v, off) ->
      case rt_mem.o_store(o, b, a, v, off) {
        Ok(o2) -> #(o2, RStore(Ok(Nil)))
        Error(e) -> #(o, RStore(Error(e)))
      }
    OpGrow(d) -> {
      let #(r, o2) = rt_mem.o_grow(o, d)
      #(o2, RGrow(r))
    }
    OpInit(off, bytes) ->
      case rt_mem.o_init_data(o, off, bytes) {
        Ok(o2) -> #(o2, RInit(Ok(Nil)))
        Error(e) -> #(o, RInit(Error(e)))
      }
  }
}

/// Generate a random op given the current `byte_len`. Addresses span in-bounds, a few bytes
/// past the end, and occasionally `0xFFFFFFFF` (the no-wrap probe); widths/signs/values are
/// random; grows stay within the 4-page max.
fn gen_op(byte_len: Int, seed: Int) -> #(Op, Int) {
  let s = lcg(seed)
  case s % 10 {
    k if k < 5 -> {
      let s2 = lcg(s)
      let bytes = pick_bytes(s2 % 4)
      let #(addr, s3) = pick_addr(s2, byte_len)
      let s4 = lcg(s3)
      let s5 = lcg(s4)
      #(OpStore(bytes, addr, pick_value(s5), s4 % 8), s5)
    }
    k if k < 8 -> {
      let s2 = lcg(s)
      let bytes = pick_bytes(s2 % 4)
      let #(width, s3) = pick_width(bytes, s2)
      let s4 = lcg(s3)
      let #(addr, s5) = pick_addr(s4, byte_len)
      let signed = s4 % 2 == 0
      #(OpLoad(bytes, signed, width, addr, s5 % 8), s5)
    }
    8 -> {
      let s2 = lcg(s)
      #(OpGrow(s2 % 3), s2)
    }
    _ -> {
      let s2 = lcg(s)
      let len = s2 % 6
      let #(addr, s3) = pick_addr(s2, byte_len)
      let #(bytes, s4) = rand_bytes(len, s3)
      #(OpInit(addr, bytes), s4)
    }
  }
}

fn pick_bytes(i: Int) -> Int {
  case i {
    0 -> 1
    1 -> 2
    2 -> 4
    _ -> 8
  }
}

fn pick_width(bytes: Int, seed: Int) -> #(Int, Int) {
  case bytes {
    8 -> #(64, seed)
    _ -> {
      let s = lcg(seed)
      case s % 2 {
        0 -> #(32, s)
        _ -> #(64, s)
      }
    }
  }
}

/// Mostly in-bounds (a touch past byte_len so OOB is exercised), occasionally `0xFFFFFFFF`
/// (the no-wrap probe — must trap, never wrap).
fn pick_addr(seed: Int, byte_len: Int) -> #(Int, Int) {
  let s = lcg(seed)
  case s % 17 == 0 {
    True -> #(0xFFFFFFFF, s)
    False -> #(s % { byte_len + 16 }, s)
  }
}

/// A pseudo-random ~64-bit value (high byte reachable so 8-byte stores vary fully).
fn pick_value(seed: Int) -> Int {
  let a = lcg(seed)
  let b = lcg(a)
  bitor(bsl(a, 33), b)
}

/// A deterministic `n`-byte BitArray for init segments.
fn rand_bytes(n: Int, seed: Int) -> #(BitArray, Int) {
  case n <= 0 {
    True -> #(<<>>, seed)
    False -> {
      let s = lcg(seed)
      let #(rest, s2) = rand_bytes(n - 1, s)
      #(<<{ s % 256 }, rest:bits>>, s2)
    }
  }
}

// Several chunk sizes — including the 64-byte REFC edge + 1, an odd size, and the default —
// so the differential proves correctness is chunk-size-independent.
pub fn differential_chunk_65_test() {
  run_differential(65, 250, 0x1234)
}

pub fn differential_chunk_100_test() {
  run_differential(100, 250, 0xBEEF)
}

pub fn differential_chunk_default_test() {
  run_differential(rt_mem.default_chunk_bytes, 250, 0xC0FFEE)
}

pub fn differential_chunk_4096_alt_seed_test() {
  run_differential(4096, 300, 0x5EED)
}

// ───────────────────────────── 12. Cell-backed wrappers (seed → op → observe persistence) ─────────────────────────────

// The public load/store/size/grow read+write the `mem` slot of THIS process's cell. We seed a
// fresh memory via rt_state, exercise the wrappers, and observe persistence + isolation.

pub fn cell_store_load_roundtrip_test() {
  rt_state.seed(StateDecl(
    mem: rt_mem.fresh(1, Some(2), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  rt_mem.store(4, 0, 0x04030201, 0) |> should.equal(Ok(Nil))
  // The store persisted in the cell across the separate load call.
  rt_mem.load(4, False, 32, 0, 0) |> should.equal(Ok(0x04030201))
  rt_mem.load(1, False, 32, 0, 0) |> should.equal(Ok(0x01))
  rt_mem.load(1, True, 32, 3, 0) |> should.equal(Ok(0x04))
  // An out-of-bounds load through the cell traps.
  rt_mem.load(4, False, 32, page, 0)
  |> should.equal(Error(MemoryOutOfBounds))
}

pub fn cell_size_and_grow_test() {
  rt_state.seed(StateDecl(
    mem: rt_mem.fresh(1, Some(3), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  rt_mem.size() |> should.equal(1)
  rt_mem.grow(1) |> should.equal(1)
  rt_mem.size() |> should.equal(2)
  // Past the declared max: -1, no allocation, size unchanged.
  rt_mem.grow(5) |> should.equal(-1)
  rt_mem.size() |> should.equal(2)
  // The grown page is zero and writable.
  rt_mem.load(4, False, 32, page, 0) |> should.equal(Ok(0))
  rt_mem.store(4, page, 0xCAFEBABE, 0) |> should.equal(Ok(Nil))
  rt_mem.load(4, False, 32, page, 0) |> should.equal(Ok(0xCAFEBABE))
}

pub fn cell_grow_charges_fuel_proportional_test() {
  rt_meter.reset_fuel()
  rt_state.seed(StateDecl(
    mem: rt_mem.fresh(1, Some(4), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  // A successful grow of 2 pages charges 2 * 65536 bytes of fuel (proportional to allocation).
  rt_mem.grow(2) |> should.equal(1)
  rt_meter.fuel_consumed() |> should.equal(2 * page)
  // A FAILED grow (past max) allocates nothing and charges nothing.
  rt_mem.grow(100) |> should.equal(-1)
  rt_meter.fuel_consumed() |> should.equal(2 * page)
}

pub fn cell_isolation_between_seeds_test() {
  // Seed A, write a byte.
  rt_state.seed(StateDecl(
    mem: rt_mem.fresh(1, Some(1), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  rt_mem.store(1, 42, 0xAB, 0) |> should.equal(Ok(Nil))
  rt_mem.load(1, False, 32, 42, 0) |> should.equal(Ok(0xAB))
  // Re-seed: fresh memory. A's write must NOT bleed through.
  rt_state.seed(StateDecl(
    mem: rt_mem.fresh(1, Some(1), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  rt_mem.load(1, False, 32, 42, 0) |> should.equal(Ok(0))
}

pub fn cell_partial_store_trap_no_mutation_test() {
  rt_state.seed(StateDecl(
    mem: rt_mem.fresh(1, Some(1), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  let assert Ok(Nil) = rt_mem.store(4, page - 4, 0xAABBCCDD, 0)
  // A straddling store traps and (since the cell is not written on the error path) leaves the
  // prior bytes intact.
  rt_mem.store(4, page - 2, 0x11223344, 0)
  |> should.equal(Error(MemoryOutOfBounds))
  rt_mem.load(4, False, 32, page - 4, 0) |> should.equal(Ok(0xAABBCCDD))
}

pub fn cell_init_data_test() {
  rt_state.seed(StateDecl(
    mem: rt_mem.fresh(1, Some(1), big_cap),
    globals: [],
    table: dynamic.nil(),
  ))
  rt_mem.init_data(8, <<0xDE, 0xAD, 0xBE, 0xEF>>) |> should.equal(Ok(Nil))
  rt_mem.load(4, False, 32, 8, 0) |> should.equal(Ok(0xEFBEADDE))
  rt_mem.init_data(page - 2, <<1, 2, 3, 4>>)
  |> should.equal(Error(MemoryOutOfBounds))
}

// ───────────────────────────── 13. Constant-space store loop (E1, D8 #4) ─────────────────────────────

// ~100k stores threaded through the pure paged core: each store supersedes the prior Mem
// (only the latest is live; superseded versions are garbage and touched chunks are shared).
// We assert the loop completes and the final read is correct — exercising the
// supersede-and-share path the constant-space property rests on. (The precise allocation-
// profile measurement is the capstone, unit 11.)
pub fn constant_space_store_loop_test() {
  let m = rt_mem.fresh_mem(1, Some(1), big_cap, rt_mem.default_chunk_bytes)
  let m = store_loop(m, 0, 100_000)
  // After 100k superseding stores, the paged structure is still sound: a fresh store/load
  // round-trips, proving the supersede-and-share path held up across the whole loop.
  let assert Ok(m) = rt_mem.mem_store(m, 4, 128, 0x0BADF00D, 0)
  rt_mem.mem_load(m, 4, False, 32, 128, 0) |> should.equal(Ok(0x0BADF00D))
}

fn store_loop(m: rt_mem.Mem, i: Int, n: Int) -> rt_mem.Mem {
  case i >= n {
    True -> m
    False -> {
      // Vary the address across the page so many chunks are touched (and shared).
      let addr = i * 4 % { page - 4 }
      let assert Ok(m) = rt_mem.mem_store(m, 4, addr, i, 0)
      store_loop(m, i + 1, n)
    }
  }
}

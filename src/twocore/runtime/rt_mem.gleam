//// `rt_mem` — linear memory: the `paged` implementation + the flat-binary `rebuild`
//// oracle (owner: unit 04). SIGNATURES frozen by unit 01; BODIES implemented by unit 04.
////
//// **State location.** `load`/`store`/`size`/`grow`/`init_data` operate on the `mem` field
//// of THIS process's cell — read via `rt_state.mem_get`, write the new memory value back
//// via `rt_state.mem_put`. The memory value is OPAQUE to `rt_state` (held as `Dynamic`);
//// `rt_mem` owns its shape and coerces (via `gleam_stdlib:identity/1`, a tier-O no-op — the
//// cell is the sole producer/consumer of this term, so the coercion is sound). The handle
//// never leaves the cell.
////
//// **Representation (the immutable, sparse, paged `Mem`).** Memory is a record
//// `{pages, max, chunk, data}` where `data` is a SPARSE `Dict(chunk_idx -> chunk-binary)`.
//// `byte_len = pages * 65536`. The WASM **page** (65536 B) is the grow/size unit; the
//// physical **chunk** (`chunk` bytes, default 4096, kept `> 64` so chunks are off-heap REFC
//// binaries shared by reference across `Mem` versions) is the binary-granularity knob,
//// DECOUPLED from the page. An ABSENT chunk reads as all-zero and costs nothing, so a
//// freshly-grown / never-written in-bounds region reads as `0` with no allocation and `grow`
//// is O(1) in allocation. A store copies only the affected chunk(s); untouched chunks stay
//// structurally shared, and the superseded `Mem` is garbage.
////
//// **No-wrap effective address (E3).** `ea = addr (unsigned i32) + offset (static u32)` is
//// computed as a BIGNUM and never reduced mod 2³²; an access traps iff
//// `ea + access_bytes > current_byte_len`. A multi-byte store traps BEFORE writing any
//// byte (all-or-nothing — zero corruption). Little-endian byte order. f32/f64 loads/stores
//// are raw-byte moves over the IEEE bit pattern — never a BEAM-double round-trip.
////
//// **`grow` resource cap (E3).** A finite Safe max-pages cap is baked into the memory by
//// `fresh` (single-sourced) so `grow` enforces it without threading a profile through
//// generated code; `grow` returns `-1` past the cap/declared max and never allocates, and
//// charges fuel proportional to the bytes allocated (`rt_meter.charge(delta * 65536)`).
////
//// **`rebuild` oracle (E4).** A flat-binary reference implementation (`OMem`) is held to
//// explicit spec-corner tests and differentially tested against `paged`. Memory is a BEAM
//// immutable binary, so a bounds bug's worst case is a wrong/missing trap or a node-safe
//// crash — never a host out-of-bounds read. Tier P/O, never NIF.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/option.{type Option, None, Some}
import twocore/ir.{type TrapReason, MemoryOutOfBounds}
import twocore/runtime/rt_meter
import twocore/runtime/rt_state

// ───────────────────────────── constants ─────────────────────────────

/// The fixed WASM page size in bytes (`64 KiB`). `memory.size`/`memory.grow` count pages;
/// `byte_len = pages * page_bytes`.
pub const page_bytes: Int = 65_536

/// The absolute i32-memory address cap: a 32-bit-indexed memory cannot exceed `2^16` pages
/// (`4 GiB`). `grow` enforces this regardless of the declared/Safe max.
pub const hard_max_pages: Int = 65_536

/// The default physical chunk size in bytes used by the cell-backed `fresh`. Chosen `> 64`
/// so chunks are off-heap REFC binaries (structurally shared across `Mem` versions); `4096`
/// is the 4–8 KiB sweet spot. Correctness is chunk-size-independent (the oracle proves it),
/// so this is a pure tuning knob.
pub const default_chunk_bytes: Int = 4096

// ───────────────────────────── the immutable paged Mem ─────────────────────────────

/// Immutable, sparse, paged linear memory. Mutation builds a NEW `Mem`; the per-instance
/// cell holds the latest. Opaque: callers go through the pure core / cell-backed API.
///
/// - `pages`: current size in 64 KiB WASM pages (the `memory.size` source).
/// - `max`: the EFFECTIVE max in pages baked at `fresh` time, `min(declared_max, safe_cap,
///   65536)` — `grow` never exceeds it.
/// - `chunk`: physical chunk size in bytes (`> 64`); decoupled from the 64 KiB page.
/// - `data`: SPARSE map `chunk_idx -> chunk-sized binary`; an ABSENT chunk is all-zero.
pub opaque type Mem {
  Mem(pages: Int, max: Int, chunk: Int, data: Dict(Int, BitArray))
}

/// Coerce a `Mem` into the opaque `Dynamic` the cell stores. Identity at run time
/// (`gleam_stdlib:identity/1`); tier-O, cannot fail.
@external(erlang, "gleam_stdlib", "identity")
fn mem_to_dynamic(mem: Mem) -> Dynamic

/// Coerce the cell's opaque `Dynamic` back into a `Mem`. Identity at run time; sound because
/// `rt_mem` is the sole producer of the term `rt_state` holds in the `mem` slot.
@external(erlang, "gleam_stdlib", "identity")
fn dynamic_to_mem(value: Dynamic) -> Mem

// ───────────────────────────── public cell-backed API (frozen heads) ─────────────────────────────

/// Build a FRESH opaque memory of `min_pages` zero-filled 64 KiB pages.
///
/// - `min_pages`: the initial page count (the module's declared memory minimum).
/// - `max_pages`: the module's declared maximum in pages, or `None` for "unbounded"
///   (still subject to `safe_cap`).
/// - `safe_cap`: the finite Safe max-pages cap (single-sourced; see E3), baked into the
///   returned value so `grow` enforces it without a profile parameter.
/// - Returns the fresh memory value as `Dynamic` (opaque, ready to hand to
///   `rt_state.seed`). Total — never fails. The baked effective max is
///   `min(min_pages-declared-or-safe_cap, safe_cap, 65536)`.
pub fn fresh(min_pages: Int, max_pages: Option(Int), safe_cap: Int) -> Dynamic {
  mem_to_dynamic(fresh_mem(min_pages, max_pages, safe_cap, default_chunk_bytes))
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
///   `Error(MemoryOutOfBounds)` if `ea + bytes > byte_len`. Reads the `Mem` from the cell.
pub fn load(
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Result(Int, TrapReason) {
  mem_load(current_mem(), bytes, signed, result_width, addr, offset)
}

/// Store the low `bytes` bytes (little-endian) of `value` to `addr + offset` in this
/// process's memory. All-or-nothing: traps BEFORE writing any byte if out of bounds.
///
/// - `bytes`: the store width in bytes (1/2/4/8). The value's sign is irrelevant.
/// - `addr`: the unsigned i32 base address.
/// - `value`: the value whose low `bytes` bytes are written (raw bit pattern).
/// - `offset`: the static unsigned offset (added as a bignum — no wrap).
/// - Returns `Ok(Nil)` on success (and writes the new `Mem` back to the cell), or
///   `Error(MemoryOutOfBounds)` with ZERO mutation.
pub fn store(
  bytes: Int,
  addr: Int,
  value: Int,
  offset: Int,
) -> Result(Nil, TrapReason) {
  case mem_store(current_mem(), bytes, addr, value, offset) {
    Ok(updated) -> {
      rt_state.mem_put(mem_to_dynamic(updated))
      Ok(Nil)
    }
    Error(reason) -> Error(reason)
  }
}

/// The current size of this process's memory, in 64 KiB pages (`memory.size`).
///
/// - Returns the page count. Total. Reads the `Mem` from the cell.
pub fn size() -> Int {
  mem_size(current_mem())
}

/// Grow this process's memory by `delta` pages (`memory.grow`).
///
/// - `delta`: the number of pages to add (≥ 0).
/// - Returns the PREVIOUS size in pages on success, or `-1` if the growth would exceed the
///   declared max, the Safe cap, OR the 65536-page hard cap (in which case NOTHING is
///   allocated, the memory is unchanged, and no fuel is charged). Newly-added pages are
///   zero-filled. On success it charges `delta * page_bytes` fuel (proportional to the bytes
///   allocated — a big grow is not O(1)-cheap, E3) and writes the new `Mem` back.
pub fn grow(delta: Int) -> Int {
  let #(result, updated) = mem_grow(current_mem(), delta)
  case result {
    -1 -> -1
    old -> {
      rt_meter.charge(delta * page_bytes)
      rt_state.mem_put(mem_to_dynamic(updated))
      old
    }
  }
}

/// Write an active DATA segment's `bytes` into this process's memory at `offset`, at
/// instantiation. Bounds-checked (no-wrap), whole range up front.
///
/// - `offset`: the destination byte offset.
/// - `bytes`: the raw bytes to write.
/// - Returns `Ok(Nil)` (writing the new `Mem` back), or `Error(MemoryOutOfBounds)` if the
///   segment does not fit (an instantiation-time trap; nothing is written).
pub fn init_data(offset: Int, bytes: BitArray) -> Result(Nil, TrapReason) {
  case mem_init_data(current_mem(), offset, bytes) {
    Ok(updated) -> {
      rt_state.mem_put(mem_to_dynamic(updated))
      Ok(Nil)
    }
    Error(reason) -> Error(reason)
  }
}

/// Read THIS process's current `Mem` out of the cell. Fail-closed: `rt_state.mem_get`
/// `panic`s on an un-seeded cell (it never returns garbage), which `rt_mem` propagates.
fn current_mem() -> Mem {
  dynamic_to_mem(rt_state.mem_get())
}

// ───────────────────────────── the pure paged core (the testable algebra) ─────────────────────────────

/// Build a fresh `Mem` of `min_pages` zero pages with a caller-chosen physical `chunk` size.
/// This is the pure constructor the cell-backed `fresh` wraps (with `default_chunk_bytes`)
/// and the differential suite drives across several chunk sizes.
///
/// - `min_pages`: initial pages (zero-filled — the sparse map starts empty, so no allocation).
/// - `max_pages`/`safe_cap`: see `fresh`; the baked `max` is `min(declared_or_safe_cap,
///   safe_cap, 65536)`.
/// - `chunk`: physical chunk size in bytes; keep `> 64` for off-heap REFC chunks.
/// - Returns the fresh `Mem`. Total.
pub fn fresh_mem(
  min_pages: Int,
  max_pages: Option(Int),
  safe_cap: Int,
  chunk: Int,
) -> Mem {
  Mem(
    pages: min_pages,
    max: effective_max(max_pages, safe_cap),
    chunk: chunk,
    data: dict.new(),
  )
}

/// Pure load against an explicit `Mem`. Same contract as `load` but threads `m` instead of
/// reading the cell. Returns `Ok(bits)` or `Error(MemoryOutOfBounds)`.
pub fn mem_load(
  m: Mem,
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Result(Int, TrapReason) {
  let ea = addr + offset
  case in_bounds(m, ea, bytes) {
    False -> Error(MemoryOutOfBounds)
    True -> {
      let raw = read_bytes(m, ea, bytes)
      case signed {
        True -> Ok(decode_signed(raw, bytes, result_width))
        False -> Ok(decode_unsigned(raw, bytes))
      }
    }
  }
}

/// Pure store against an explicit `Mem`. Bounds-checks FIRST (trap-before-write, all-or-
/// nothing), then rebuilds only the affected chunk(s). Returns `Ok(new_mem)` or
/// `Error(MemoryOutOfBounds)` (the input `Mem` is returned untouched in the error path).
pub fn mem_store(
  m: Mem,
  bytes: Int,
  addr: Int,
  value: Int,
  offset: Int,
) -> Result(Mem, TrapReason) {
  let ea = addr + offset
  case in_bounds(m, ea, bytes) {
    False -> Error(MemoryOutOfBounds)
    True -> Ok(write_bytes(m, ea, encode_le(value, bytes)))
  }
}

/// Pure `memory.size`: the current page count of `m`.
pub fn mem_size(m: Mem) -> Int {
  m.pages
}

/// Pure `memory.grow`. NO fuel charge (the cell-backed `grow` adds it). Returns
/// `#(old_pages, new_mem)` on success (pages += delta; new pages read as zero for free via
/// the sparse map), or `#(-1, m)` if `delta < 0`, or `pages + delta` would exceed the baked
/// `max` or the 65536-page hard cap — allocating nothing.
pub fn mem_grow(m: Mem, delta: Int) -> #(Int, Mem) {
  let old = m.pages
  let new = old + delta
  case delta >= 0 && new <= m.max && new <= hard_max_pages {
    True -> #(old, Mem(..m, pages: new))
    False -> #(-1, m)
  }
}

/// Pure active-data-segment write at instantiation. Bounds-checks the WHOLE range up front
/// (`offset + len <= byte_len`); on overflow returns `Error(MemoryOutOfBounds)` with no
/// write (aborts instantiation). Otherwise returns `Ok(new_mem)`.
pub fn mem_init_data(
  m: Mem,
  offset: Int,
  bytes: BitArray,
) -> Result(Mem, TrapReason) {
  let len = bit_array.byte_size(bytes)
  case offset >= 0 && offset + len <= byte_len(m) {
    False -> Error(MemoryOutOfBounds)
    True -> Ok(write_bytes(m, offset, bytes))
  }
}

/// Canonicalise a paged `Mem` to one flat `byte_len`-length binary (every in-bounds byte,
/// absent chunks rendered as zero). Used by the differential test to compare the paged byte
/// image against the oracle's. O(byte_len); for tests only.
pub fn to_flat(m: Mem) -> BitArray {
  read_bytes(m, 0, byte_len(m))
}

// ───────────────────────────── the flat-binary rebuild oracle (E4) ─────────────────────────────

/// The trivially-correct flat-binary reference memory used ONLY in tests. `data` is one
/// contiguous binary of length `pages * page_bytes`; a store rebuilds the whole binary
/// (copy-on-write) — slow but unmistakable.
pub opaque type OMem {
  OMem(pages: Int, max: Int, data: BitArray)
}

/// Fresh oracle of `min_pages` zero pages, baking the same effective `max` as `fresh_mem`.
pub fn o_fresh(min_pages: Int, max_pages: Option(Int), safe_cap: Int) -> OMem {
  OMem(pages: min_pages, max: effective_max(max_pages, safe_cap), data: <<
    0:size({ min_pages * page_bytes * 8 }),
  >>)
}

/// Oracle load (same contract as `mem_load`) — `binary` slice + the shared LE codec.
pub fn o_load(
  o: OMem,
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Result(Int, TrapReason) {
  let ea = addr + offset
  let limit = o.pages * page_bytes
  case ea >= 0 && ea + bytes <= limit {
    False -> Error(MemoryOutOfBounds)
    True -> {
      let raw = take(o.data, ea, bytes)
      case signed {
        True -> Ok(decode_signed(raw, bytes, result_width))
        False -> Ok(decode_unsigned(raw, bytes))
      }
    }
  }
}

/// Oracle store (same contract as `mem_store`): bounds-check, then rebuild the whole binary.
pub fn o_store(
  o: OMem,
  bytes: Int,
  addr: Int,
  value: Int,
  offset: Int,
) -> Result(OMem, TrapReason) {
  let ea = addr + offset
  let limit = o.pages * page_bytes
  case ea >= 0 && ea + bytes <= limit {
    False -> Error(MemoryOutOfBounds)
    True -> {
      let new_bytes = encode_le(value, bytes)
      let pre = take(o.data, 0, ea)
      let post = take(o.data, ea + bytes, limit - ea - bytes)
      Ok(OMem(..o, data: <<pre:bits, new_bytes:bits, post:bits>>))
    }
  }
}

/// Oracle `memory.grow`: append `delta * page_bytes` zero bytes, same caps as `mem_grow`.
pub fn o_grow(o: OMem, delta: Int) -> #(Int, OMem) {
  let old = o.pages
  let new = old + delta
  case delta >= 0 && new <= o.max && new <= hard_max_pages {
    True -> #(
      old,
      OMem(..o, pages: new, data: <<
        o.data:bits,
        0:size({ delta * page_bytes * 8 }),
      >>),
    )
    False -> #(-1, o)
  }
}

/// Oracle active-data-segment write (same contract as `mem_init_data`).
pub fn o_init_data(
  o: OMem,
  offset: Int,
  bytes: BitArray,
) -> Result(OMem, TrapReason) {
  let len = bit_array.byte_size(bytes)
  let limit = o.pages * page_bytes
  case offset >= 0 && offset + len <= limit {
    False -> Error(MemoryOutOfBounds)
    True -> {
      let pre = take(o.data, 0, offset)
      let post = take(o.data, offset + len, limit - offset - len)
      Ok(OMem(..o, data: <<pre:bits, bytes:bits, post:bits>>))
    }
  }
}

/// Oracle `memory.size`.
pub fn o_size(o: OMem) -> Int {
  o.pages
}

/// The oracle's flat byte image (its whole `data` binary) — the differential reference for
/// `to_flat(paged)`.
pub fn o_flat(o: OMem) -> BitArray {
  o.data
}

// ───────────────────────────── shared helpers ─────────────────────────────

/// `2^n` as a BEAM bignum (used for sign-extension widths beyond 62 bits).
fn pow2(n: Int) -> Int {
  int.bitwise_shift_left(1, n)
}

/// The effective max in pages baked at `fresh` time: the smallest of the declared max (when
/// present), the Safe `safe_cap`, and the 65536-page hard cap. Dropping the declared max when
/// `None` gives `min(safe_cap, 65536)`. This NEVER lets untrusted code allocate past
/// `safe_cap` (E3), and reduces to the spec's `min(declared_max, 65536)` whenever
/// `safe_cap >= 65536`.
fn effective_max(max_pages: Option(Int), safe_cap: Int) -> Int {
  let cap = int.min(safe_cap, hard_max_pages)
  case max_pages {
    Some(declared) -> int.min(declared, cap)
    None -> cap
  }
}

/// `byte_len = pages * 65536`, the current (possibly-grown) length the bounds-check uses.
fn byte_len(m: Mem) -> Int {
  m.pages * page_bytes
}

/// The no-wrap bounds predicate: an access of `n` bytes at effective address `ea` is in
/// bounds iff `ea >= 0` and `ea + n <= byte_len`. `ea` is a bignum and is NEVER masked to
/// 32 bits, so `addr = 0xFFFFFFFF` + a large offset correctly fails here (it does not wrap).
fn in_bounds(m: Mem, ea: Int, n: Int) -> Bool {
  ea >= 0 && ea + n <= byte_len(m)
}

/// Encode `value`'s low `bytes` bytes little-endian. The `/little` integer segment wraps
/// `value` to `bytes * 8` bits automatically, which is exactly the `store8/16/32` low-bits
/// semantics. f32/f64 stores reuse this (the value is already the raw IEEE bit pattern).
fn encode_le(value: Int, bytes: Int) -> BitArray {
  let bits = bytes * 8
  <<value:size(bits)-little>>
}

/// Decode `bytes` little-endian bytes as an UNSIGNED integer — the loaded bit pattern for
/// `loadN_u` / plain / `f32.load` / `f64.load` (zero-extension is identity on the bit pattern).
fn decode_unsigned(raw: BitArray, bytes: Int) -> Int {
  let bits = bytes * 8
  let assert <<u:size(bits)-little-unsigned>> = raw
  u
}

/// Decode `bytes` little-endian bytes as a SIGNED integer then sign-extend to
/// `result_width` bits, returning the UNSIGNED two's-complement bit pattern in
/// `[0, 2^result_width)` — for `loadN_s`. (A raw negative `Int` must never escape into the
/// value layer.) E.g. byte `0x80`: `i32.load8_s` → `0xFFFFFF80`; `i64.load8_s` →
/// `0xFFFFFFFFFFFFFF80`. `result_width` is what disambiguates the two.
fn decode_signed(raw: BitArray, bytes: Int, result_width: Int) -> Int {
  let bits = bytes * 8
  let assert <<s:size(bits)-little-signed>> = raw
  case s >= 0 {
    True -> s
    False -> s + pow2(result_width)
  }
}

/// Slice `len` bytes from `bin` at byte offset `at` (zero-copy sub-binary). Short-circuits
/// `len <= 0` to the empty binary (so end-of-binary zero-length slices never fail).
fn take(bin: BitArray, at: Int, len: Int) -> BitArray {
  case len <= 0 {
    True -> <<>>
    False -> {
      let assert Ok(slice) = bit_array.slice(bin, at, len)
      slice
    }
  }
}

/// Read `n` bytes starting at absolute byte address `ea` from the paged `Mem`, handling a
/// chunk-boundary span. Absent chunks contribute zero bytes WITHOUT being materialised.
fn read_bytes(m: Mem, ea: Int, n: Int) -> BitArray {
  case n <= 0 {
    True -> <<>>
    False -> {
      let cs = m.chunk
      let first = ea / cs
      let end_byte = ea + n - 1
      let last = end_byte / cs
      case first == last {
        True -> read_in_chunk(m, first, ea % cs, n)
        False -> read_span(m, ea, n, <<>>)
      }
    }
  }
}

/// Read `n` bytes wholly inside chunk `idx` at intra-chunk offset `off`. An ABSENT chunk is
/// all-zero, so it short-circuits to `n` zero bytes (never materialising the full chunk).
fn read_in_chunk(m: Mem, idx: Int, off: Int, n: Int) -> BitArray {
  case dict.get(m.data, idx) {
    Ok(chunk) -> take(chunk, off, n)
    Error(Nil) -> <<0:size({ n * 8 })>>
  }
}

/// Read a byte run that spans ≥ 2 chunks: take the in-chunk prefix, then recurse on the
/// remainder at the next chunk boundary, concatenating little-endian-order byte runs.
fn read_span(m: Mem, ea: Int, remaining: Int, acc: BitArray) -> BitArray {
  case remaining <= 0 {
    True -> acc
    False -> {
      let cs = m.chunk
      let idx = ea / cs
      let off = ea % cs
      let avail = cs - off
      let n = int.min(remaining, avail)
      let part = read_in_chunk(m, idx, off, n)
      read_span(m, ea + n, remaining - n, <<acc:bits, part:bits>>)
    }
  }
}

/// Write `bytes` starting at absolute byte address `ea`, rebuilding only the touched
/// chunk(s) and leaving the rest structurally shared. Callers MUST have bounds-checked first.
fn write_bytes(m: Mem, ea: Int, bytes: BitArray) -> Mem {
  write_loop(m, ea, bytes, bit_array.byte_size(bytes))
}

/// Per-chunk write loop: splice the in-chunk run into chunk `idx` (materialising a zero chunk
/// if absent), `dict.insert` the rebuilt chunk, and recurse for the remaining bytes.
fn write_loop(m: Mem, ea: Int, bytes: BitArray, remaining: Int) -> Mem {
  case remaining <= 0 {
    True -> m
    False -> {
      let cs = m.chunk
      let idx = ea / cs
      let off = ea % cs
      let avail = cs - off
      let n = int.min(remaining, avail)
      let part = take(bytes, 0, n)
      let rest = take(bytes, n, remaining - n)
      let chunk = chunk_for_store(m, idx, cs)
      let rebuilt = splice_chunk(chunk, off, part, cs)
      let m2 = Mem(..m, data: dict.insert(m.data, idx, rebuilt))
      write_loop(m2, ea + n, rest, remaining - n)
    }
  }
}

/// The chunk to write into: the stored chunk, or a freshly-materialised all-zero chunk when
/// absent (materialisation happens ONLY on a store, never a load).
fn chunk_for_store(m: Mem, idx: Int, cs: Int) -> BitArray {
  case dict.get(m.data, idx) {
    Ok(chunk) -> chunk
    Error(Nil) -> <<0:size({ cs * 8 })>>
  }
}

/// Replace `part`'s bytes at intra-chunk offset `off` inside the `cs`-byte chunk `c`,
/// returning the rebuilt chunk (one `cs`-byte allocation; `pre`/`post` are zero-copy
/// sub-binaries).
fn splice_chunk(c: BitArray, off: Int, part: BitArray, cs: Int) -> BitArray {
  let n = bit_array.byte_size(part)
  let pre = take(c, 0, off)
  let post = take(c, off + n, cs - off - n)
  <<pre:bits, part:bits, post:bits>>
}

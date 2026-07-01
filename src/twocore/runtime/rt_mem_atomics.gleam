//// `rt_mem_atomics` — the tier-O `atomics` linear-memory backend (owner: unit P4-04). The
//// **O(1) performance lever** (G2): `load`/`store`/`grow` in constant time over a FIXED array
//// of Erlang `atomics` 64-bit words, backing a byte-addressable little-endian linear memory.
////
//// **Trust tier (G6).** `atomics` is ERTS-native — no custom C, no NIF — so it is memory-safe
//// by construction and CANNOT crash the node; Safe permits it (tier P or O, never N). A bounds
//// bug's worst case is a wrong/missing trap or a node-safe process crash, NEVER a host
//// out-of-bounds read (the §11 security invariant). The array is PROCESS-LOCAL and never shared
//// (G8, the threads/shared-memory hard non-goal).
////
//// **Correctness is identical to `paged`, byte-for-byte (E4).** Little-endian throughout;
//// no-wrap effective address → trap on every access (E3); all-or-nothing multi-byte stores
//// (trap-before-write); the Safe max-pages cap. Held byte-for-byte to the flat-binary `rebuild`
//// oracle (`rt_mem`'s `o_*`), so the atomics tier is byte-identical to paged and to the spec.
//// f32/f64 store/load are raw-byte moves over the IEEE bit pattern — never a BEAM-double
//// round-trip, so NaN payloads / signalling bits survive (D5).
////
//// **`grow` is the sharp edge (§C).** `atomics` arrays are FIXED SIZE at creation, so `fresh`
//// pre-allocates to the effective max (`reserve` words) and `grow` is a pure watermark move
//// within `[0, max]` (the words already exist → O(1), `-1` past the cap, never a re-allocation).
//// On an UNCAPPED module (effective max = the 65536-page / 4 GiB hard ceiling), the eager
//// reservation would exceed the node-safe `atomics_reserve_cap_pages` ceiling, so the build is
//// FAIL-CLOSED REJECTED at link time (unit 07's `validate_binding`) — NEVER a silent 4 GiB
//// pre-allocation and NEVER a silent `paged` degrade. `a_fresh` is a defensive backstop that
//// `panic`s node-safe if ever reached with an over-cap reservation (unreachable post-validation).
////
//// **Byte↔word addressing (LE, exact).** Byte address `a` → word `w = a / 8`, `atomics` index
//// `ix = w + 1` (1-indexed), byte position `p = a mod 8` where `p = 0` is the least-significant
//// byte. A word's value is `Σ_{k=0..7} byte[8w+k]·256^k`. A multi-byte access of `n <= 8` bytes
//// spans word `w` and, iff `p + n > 8`, word `w+1` — at most two words. Alignment is a hint;
//// unaligned and word-boundary-crossing accesses are fully supported.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/option.{type Option, None, Some}
import twocore/ir.{type TrapReason, MemoryOutOfBounds}
import twocore/runtime/rt_mem
import twocore/runtime/rt_meter
import twocore/runtime/rt_state.{type InstanceState}

// ───────────────────────────── constants ─────────────────────────────

/// Words per 64 KiB page: `rt_mem.page_bytes / 8 = 8192`. The physical backing of `n` pages is
/// `n * words_per_page` unsigned 64-bit `atomics` words. (The frozen page size `page_bytes` and
/// hard cap `hard_max_pages` are single-sourced from `rt_mem`.)
pub const words_per_page: Int = 8192

/// The tier-O node-safety ceiling: the MOST pages `fresh` will eagerly reserve as `atomics`
/// words. A module whose effective max exceeds this is FAIL-CLOSED REJECTED at link time (§C) —
/// `atomics` requires a bounded max/cap `=<` the reserve cap; it never silently degrades to
/// `paged` and never pre-allocates past this ceiling. Eager reservation of `p` pages costs
/// `p * 64 KiB` of `atomics` backing, so an UNBOUNDED reserve is a node-OOM (node-crash) vector —
/// forbidden for a tier that "cannot crash the node" (G6). FINITE and well below the 65536-page
/// (4 GiB) i32 ceiling; a tuning knob unit 07/10 may adjust. Default: a conservative 4096 pages
/// (256 MiB of eager reservation at the ceiling).
pub const atomics_reserve_cap_pages: Int = 4096

// ───────────────────────────── the opaque atomics handle ─────────────────────────────

/// Tier-O linear memory backed by a fixed array of Erlang `atomics` 64-bit words (the O(1)
/// mutable store). Opaque: callers go through the pure `a_*` core / the cell + threaded
/// wrappers. The `atomics` `ref` is PROCESS-LOCAL and never shared (G8). There is NO paged
/// fallback variant: when the effective max exceeds the node-safe reserve cap (§C), the build is
/// FAIL-CLOSED REJECTED at link time — never silently pre-allocated at 4 GiB and never silently
/// degraded to `paged`. So `a_fresh` only ever constructs `AtomicsBacked`.
///
/// - `ref`: the opaque `atomics` array handle (from `atomics:new/2`, `{signed, false}` →
///   unsigned 64-bit words). MUTABLE, shared by reference; a store mutates it IN PLACE.
/// - `pages`: the current logical size in 64 KiB pages — the `memory.size` source and the
///   bounds-check length (`byte_len = pages * page_bytes`). A watermark, NOT the physical size.
/// - `max`: the effective max in pages (`min(declared_max ?? safe_cap, safe_cap, 65536)`);
///   `grow` never exceeds it.
/// - `reserve`: the physical reservation in pages (`max(min_pages, max)`); `ref` holds
///   `reserve * words_per_page` zero-initialised words. `grow` is a pure watermark move within
///   `[0, max]` — the words already exist.
pub opaque type Atomics {
  AtomicsBacked(ref: Dynamic, pages: Int, max: Int, reserve: Int)
}

// ───────────────────────────── the `atomics` FFI (twocore_-namespaced shim) ─────────────────────────────

/// Allocate a fresh zero-initialised `atomics` array of `arity` unsigned 64-bit words. `arity`
/// must be `>= 1`. Tier-O, cannot crash the node. See `twocore_rt_mem_atomics_ffi`.
@external(erlang, "twocore_rt_mem_atomics_ffi", "new")
fn atomics_new(arity: Int) -> Dynamic

/// Read the 1-indexed word `ix` (a `0..2^64-1` integer) from `ref`. No copy.
@external(erlang, "twocore_rt_mem_atomics_ffi", "get")
fn atomics_get(ref: Dynamic, ix: Int) -> Int

/// Write `val` (a `0..2^64-1` integer) into the 1-indexed word `ix`, mutating `ref` IN PLACE.
@external(erlang, "twocore_rt_mem_atomics_ffi", "put")
fn atomics_put(ref: Dynamic, ix: Int, val: Int) -> Nil

// ───────────────────────────── the opaque `Dynamic` coercions ─────────────────────────────

/// Coerce an `Atomics` handle into the opaque `Dynamic` the cell / threaded record stores.
/// Identity at run time (`gleam_stdlib:identity/1`); tier-O, cannot fail.
@external(erlang, "gleam_stdlib", "identity")
fn atomics_to_dynamic(a: Atomics) -> Dynamic

/// Coerce the cell / record's opaque `Dynamic` back into an `Atomics`. Identity at run time;
/// sound because `rt_mem_atomics` is the sole producer of the term held in the `mem` slot.
@external(erlang, "gleam_stdlib", "identity")
fn dynamic_to_atomics(value: Dynamic) -> Atomics

// ───────────────────────────── the pure `a_*` core (value-threaded, effectful) ─────────────────────────────

/// Whether a tier-O `atomics` binding of `(min_pages, max_pages, safe_cap)` can be node-safely
/// reserved: the physical reservation `reserve = max(min_pages, effective_max)` pages must be
/// `=<` `reserve_cap`. This is the SINGLE source unit 07's `validate_binding` calls to
/// FAIL-CLOSED REJECT an over-cap / uncapped `atomics` binding at LINK time ("atomics requires a
/// bounded max/cap `=<` the reserve cap") — never a silent `paged` degrade or a 4 GiB
/// pre-allocation (§C).
///
/// - `min_pages`: the module's declared memory minimum in pages.
/// - `max_pages`: the module's declared maximum in pages, or `None` for "unbounded".
/// - `safe_cap`: the finite Safe max-pages cap (`binding.safe_max_pages`).
/// - `reserve_cap`: the node-safe reservation ceiling (normally `atomics_reserve_cap_pages`).
/// - Returns `Ok(reserve_pages)` when the binding is admissible (`atomics` engages O(1)), or
///   `Error(Nil)` when `reserve > reserve_cap` (the caller MUST reject, never degrade).
pub fn reservation(
  min_pages: Int,
  max_pages: Option(Int),
  safe_cap: Int,
  reserve_cap: Int,
) -> Result(Int, Nil) {
  let reserve = int.max(min_pages, effective_max(max_pages, safe_cap))
  case reserve <= reserve_cap {
    True -> Ok(reserve)
    False -> Error(Nil)
  }
}

/// Build a fresh tier-O memory of `min_pages` zero pages, pre-reserving `reserve =
/// max(min_pages, eff)` pages of `atomics` words up front.
///
/// - `min_pages`: initial pages (zero-filled — `atomics:new` zeroes the words).
/// - `max_pages`/`safe_cap`: the declared max / Safe cap; the baked effective max is
///   `eff = min(declared_max ?? cap, cap)` with `cap = min(safe_cap, hard_max_pages)` — the same
///   `effective_max` `rt_mem`'s paged core bakes (the differential proves they agree).
/// - `reserve_cap`: the node-safe reservation ceiling (`atomics_reserve_cap_pages`).
/// - Returns the fresh `AtomicsBacked`. REQUIRES `reserve =< reserve_cap`: unit 07's
///   `validate_binding` rejects an over-cap / uncapped binding at LINK time, so this is only
///   ever reached with an admissible reservation. Reached with an OVER-CAP `reserve` (unreachable
///   post-validation) it FAILS CLOSED — a node-safe `panic` ("atomics requires a bounded max/cap
///   <= the reserve cap") — never silently pre-allocating 4 GiB and never degrading to `paged`
///   (§C, keystone §B.2). At least one word is always reserved (a 0-page memory still needs a
///   valid `atomics` array; the extra word is never in bounds).
pub fn a_fresh(
  min_pages: Int,
  max_pages: Option(Int),
  safe_cap: Int,
  reserve_cap: Int,
) -> Atomics {
  let eff = effective_max(max_pages, safe_cap)
  let reserve = int.max(min_pages, eff)
  case reserve <= reserve_cap {
    False ->
      panic as "rt_mem_atomics.a_fresh: atomics requires a bounded max/cap <= the reserve cap (over-cap reservation, unreachable post-validation)"
    True -> {
      let arity = int.max(1, reserve * words_per_page)
      AtomicsBacked(
        ref: atomics_new(arity),
        pages: min_pages,
        max: eff,
        reserve: reserve,
      )
    }
  }
}

/// Pure load (same contract as `rt_mem.mem_load`): assemble the raw `n`-byte little-endian value
/// from the `<= 2` touched words and decode with the frozen LE codec.
///
/// - `bytes`: the access width (1/2/4/8).
/// - `signed`: whether a sub-word load is sign-extended to `result_width` (else zero-extended).
/// - `result_width`: the result's width in bits (32/64) — disambiguates `i32.load8_s` from
///   `i64.load8_s`.
/// - `addr`/`offset`: the unsigned i32 base and static offset. `ea = addr + offset` is a BIGNUM,
///   NEVER masked (§D no-wrap).
/// - Returns `Ok(bits)` (the loaded value as a raw bit pattern), or `Error(MemoryOutOfBounds)`
///   iff `ea < 0` or `ea + bytes > byte_len`. Read-only.
pub fn a_load(
  a: Atomics,
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Result(Int, TrapReason) {
  let ea = addr + offset
  case in_bounds(a, ea, bytes) {
    False -> Error(MemoryOutOfBounds)
    True -> {
      let raw = gather(a, ea, bytes)
      case signed {
        True -> Ok(decode_signed(raw, bytes, result_width))
        False -> Ok(raw)
      }
    }
  }
}

/// Pure store. Bounds-checks the WHOLE `[ea, ea+bytes)` range FIRST (trap-before-write,
/// all-or-nothing — ZERO mutation on trap), then scatters `value`'s low `bytes` bytes into the
/// `<= 2` touched words by read-modify-write.
///
/// - `bytes`: the store width (1/2/4/8). The low `bytes` bytes are written (wraps `store8/16/32`
///   for free); f32/f64 reuse this over the raw IEEE bits.
/// - `addr`/`value`/`offset`: the base address, raw bit pattern, and static offset.
/// - Returns `Ok(a')` where `a'` is the SAME `AtomicsBacked` handle (mutated in place — the `ref`
///   is shared by reference), or `Error(MemoryOutOfBounds)` with zero mutation.
pub fn a_store(
  a: Atomics,
  bytes: Int,
  addr: Int,
  value: Int,
  offset: Int,
) -> Result(Atomics, TrapReason) {
  let ea = addr + offset
  case in_bounds(a, ea, bytes) {
    False -> Error(MemoryOutOfBounds)
    True -> {
      scatter(a, ea, value, bytes)
      Ok(a)
    }
  }
}

/// Pure `memory.size`: the current page-count watermark of `a`.
pub fn a_size(a: Atomics) -> Int {
  a.pages
}

/// Pure `memory.grow`. NO fuel charge (the cell/threaded wrappers add it). A pure watermark move
/// within the pre-reserved words: returns `#(old_pages, a')` on success (`pages += delta`; the
/// grown pages read as zero — their words were reserved and never written), or `#(-1, a)` if
/// `delta < 0`, or `pages + delta` would exceed the baked `max` or the 65536-page hard cap —
/// allocating NOTHING. O(1): no re-allocation, no copy.
pub fn a_grow(a: Atomics, delta: Int) -> #(Int, Atomics) {
  let old = a.pages
  let new = old + delta
  case delta >= 0 && new <= a.max && new <= rt_mem.hard_max_pages {
    True -> #(old, AtomicsBacked(..a, pages: new))
    False -> #(-1, a)
  }
}

/// Pure active-data-segment write at instantiation. Bounds-checks the WHOLE range up front
/// (`offset >= 0 && offset + len <= byte_len`); on overflow returns `Error(MemoryOutOfBounds)`
/// with no write (aborts instantiation). Otherwise scatters the bytes and returns `Ok(a')` (the
/// SAME handle — mutated in place).
pub fn a_init_data(
  a: Atomics,
  offset: Int,
  bytes: BitArray,
) -> Result(Atomics, TrapReason) {
  let len = bit_array.byte_size(bytes)
  case offset >= 0 && offset + len <= byte_len(a) {
    False -> Error(MemoryOutOfBounds)
    True -> {
      write_data_loop(a, offset, bytes)
      Ok(a)
    }
  }
}

/// The whole in-bounds byte image (`pages * page_bytes` bytes, little-endian) — the differential
/// reference mirrored on `rt_mem.to_flat`/`o_flat` for the oracle to compare byte-for-byte.
/// Gathers the `AtomicsBacked` words word-by-word. O(byte_len); tests only.
pub fn a_flat(a: Atomics) -> BitArray {
  flat_loop(a, 0, a.pages * words_per_page, <<>>)
}

// ───────────────────────────── cell-backed wrappers (state_strategy: Cell) ─────────────────────────────

/// Build a FRESH tier-O memory (the frozen `fresh` head), returning it as the opaque `Dynamic`
/// the cell stores. Uses the default `atomics_reserve_cap_pages`; an over-cap / uncapped binding
/// is rejected at link time (§C) so this only ever builds `AtomicsBacked`.
///
/// - `min_pages`/`max_pages`/`safe_cap`: see `a_fresh`.
/// - Returns the fresh memory value as `Dynamic` (ready to hand to `rt_state.seed`).
pub fn fresh(min_pages: Int, max_pages: Option(Int), safe_cap: Int) -> Dynamic {
  atomics_to_dynamic(a_fresh(
    min_pages,
    max_pages,
    safe_cap,
    atomics_reserve_cap_pages,
  ))
}

/// Load from THIS process's cell memory (read-only; no write-back). See `a_load`.
pub fn load(
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Result(Int, TrapReason) {
  a_load(current_atomics(), bytes, signed, result_width, addr, offset)
}

/// Store into THIS process's cell memory. The O(1) win over paged: an `AtomicsBacked` store
/// mutates the shared `ref` IN PLACE, so the handle value is UNCHANGED and NO `rt_state.mem_put`
/// is emitted (the pdict write-back paged pays on every store is elided). Returns `Ok(Nil)` or
/// `Error(MemoryOutOfBounds)` (zero mutation). See `a_store`.
pub fn store(
  bytes: Int,
  addr: Int,
  value: Int,
  offset: Int,
) -> Result(Nil, TrapReason) {
  case a_store(current_atomics(), bytes, addr, value, offset) {
    Ok(_a) -> Ok(Nil)
    Error(reason) -> Error(reason)
  }
}

/// The current size of THIS process's cell memory, in 64 KiB pages (`memory.size`).
pub fn size() -> Int {
  a_size(current_atomics())
}

/// Grow THIS process's cell memory by `delta` pages (`memory.grow`). Returns the PREVIOUS size on
/// success, or `-1` past the max / hard cap (allocating nothing, no fuel charged). On success it
/// charges `delta * page_bytes` fuel (proportional to the pages made addressable — a big grow is
/// not O(1)-cheap for the scheduler, E3) and writes the new watermark record back to the cell
/// (`grow` moves the `pages` field, so the handle value CHANGES — unlike `store`).
pub fn grow(delta: Int) -> Int {
  let #(result, updated) = a_grow(current_atomics(), delta)
  case result {
    -1 -> -1
    old -> {
      rt_meter.charge(delta * rt_mem.page_bytes)
      rt_state.mem_put(atomics_to_dynamic(updated))
      old
    }
  }
}

/// Write an active DATA segment into THIS process's cell memory at `offset`, at instantiation.
/// Bounds-checked (no-wrap), whole range up front. The `ref` is mutated in place, so — like
/// `store` — NO `mem_put`. Returns `Ok(Nil)` or `Error(MemoryOutOfBounds)` (nothing written).
pub fn init_data(offset: Int, bytes: BitArray) -> Result(Nil, TrapReason) {
  case a_init_data(current_atomics(), offset, bytes) {
    Ok(_a) -> Ok(Nil)
    Error(reason) -> Error(reason)
  }
}

/// Read THIS process's current `Atomics` out of the cell. Fail-closed: `rt_state.mem_get`
/// `panic`s on an un-seeded cell (it never returns garbage), which propagates here.
fn current_atomics() -> Atomics {
  dynamic_to_atomics(rt_state.mem_get())
}

// ───────────────────────────── threaded wrappers (state_strategy: Threaded) ─────────────────────────────

/// Threaded load (read-only): projects `st.mem`, drives `a_load`, leaves `st` UNCHANGED.
pub fn t_load(
  st: InstanceState,
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Result(Int, TrapReason) {
  a_load(project(st), bytes, signed, result_width, addr, offset)
}

/// Threaded store. Per §A.2/§10 the mutable backend returns the SAME `st`: the `ref` is mutated
/// in place, so the `mem` `Dynamic` is unchanged (nothing to re-inject). Returns `Ok(st)` or
/// `Error(MemoryOutOfBounds)` (zero mutation).
pub fn t_store(
  st: InstanceState,
  bytes: Int,
  addr: Int,
  value: Int,
  offset: Int,
) -> Result(InstanceState, TrapReason) {
  case a_store(project(st), bytes, addr, value, offset) {
    Ok(_a) -> Ok(st)
    Error(reason) -> Error(reason)
  }
}

/// Threaded `memory.size` (read-only): `st` unchanged.
pub fn t_size(st: InstanceState) -> Int {
  a_size(project(st))
}

/// Threaded `memory.grow`. Returns `#(prev_pages, st')` where `st'` rebinds `st.mem` to the new
/// watermark record, or `#(-1, st)` past the cap (unchanged). Charges `delta * page_bytes` grow
/// fuel on the SUCCESS path (P2 — parity with the cell `grow`, so metered+threaded is
/// byte-identical to metered+cell, and an untrusted portable module cannot allocate to the page
/// cap with zero CPU accounting).
pub fn t_grow(st: InstanceState, delta: Int) -> #(Int, InstanceState) {
  let #(result, updated) = a_grow(project(st), delta)
  case result {
    -1 -> #(-1, st)
    old -> {
      rt_meter.charge(delta * rt_mem.page_bytes)
      #(old, rt_state.with_mem(st, atomics_to_dynamic(updated)))
    }
  }
}

/// Threaded active-data-segment write at instantiation. The `ref` is mutated in place → returns
/// the SAME `st`, or `Error(MemoryOutOfBounds)` (nothing written). See `a_init_data`.
pub fn t_init_data(
  st: InstanceState,
  offset: Int,
  bytes: BitArray,
) -> Result(InstanceState, TrapReason) {
  case a_init_data(project(st), offset, bytes) {
    Ok(_a) -> Ok(st)
    Error(reason) -> Error(reason)
  }
}

/// The differential hook (§B.2): the tier's whole in-bounds byte image, for the oracle to compare
/// byte-for-byte. Coerces the opaque `mem` `Dynamic` to `Atomics`, then `a_flat`.
pub fn to_flat(mem: Dynamic) -> BitArray {
  a_flat(dynamic_to_atomics(mem))
}

/// Project the opaque memory value out of the threaded record and coerce it to `Atomics` (the
/// field seam is unit 03's `rt_state.mem`). Read-only.
fn project(st: InstanceState) -> Atomics {
  dynamic_to_atomics(rt_state.mem(st))
}

// ───────────────────────────── shared helpers ─────────────────────────────

/// `2^n` as a BEAM bignum (for masks/widths up to 64 bits and sign-extension folds).
fn pow2(n: Int) -> Int {
  int.bitwise_shift_left(1, n)
}

/// The low-`b`-bits mask `(1 << b) - 1` (e.g. `mask(8) = 0xFF`, `mask(64) = 2^64-1`).
fn mask(b: Int) -> Int {
  pow2(b) - 1
}

/// The effective max in pages baked at `fresh` time: the smallest of the declared max (when
/// present), the Safe `safe_cap`, and the 65536-page hard cap. `None` drops the declared max,
/// giving `min(safe_cap, 65536)`. Re-derived here from `rt_mem`'s frozen formula; the differential
/// proves it agrees with `rt_mem`'s baked `max`. NEVER lets untrusted code allocate past
/// `safe_cap` (E3).
fn effective_max(max_pages: Option(Int), safe_cap: Int) -> Int {
  let cap = int.min(safe_cap, rt_mem.hard_max_pages)
  case max_pages {
    Some(declared) -> int.min(declared, cap)
    None -> cap
  }
}

/// `byte_len = pages * page_bytes`, the current (possibly-grown) length the bounds-check uses.
fn byte_len(a: Atomics) -> Int {
  a.pages * rt_mem.page_bytes
}

/// The no-wrap bounds predicate: an access of `n` bytes at effective address `ea` is in bounds
/// iff `ea >= 0` and `ea + n <= byte_len`. `ea` is a bignum and is NEVER masked to 32 bits, so
/// `addr = 0xFFFFFFFF` + a large offset correctly fails here (it does not wrap).
fn in_bounds(a: Atomics, ea: Int, n: Int) -> Bool {
  ea >= 0 && ea + n <= byte_len(a)
}

/// Decode the raw `bytes`-byte little-endian value `raw` (unsigned, in `[0, 2^{8·bytes})`) as a
/// SIGNED integer sign-extended to `result_width` bits, returning the UNSIGNED two's-complement
/// bit pattern in `[0, 2^result_width)` — for `loadN_s`. Transcribes `rt_mem`'s frozen
/// `decode_signed` (a negative fold `s + 2^result_width`) directly in integer arithmetic: iff the
/// top bit of the `bytes`-byte value is set, `raw` denotes the negative `raw - 2^{8·bytes}`, so the
/// bit pattern is `raw - 2^{8·bytes} + 2^result_width`. E.g. byte `0x80`: `i32.load8_s` →
/// `0xFFFFFF80`, `i64.load8_s` → `0xFF…FF80`.
fn decode_signed(raw: Int, bytes: Int, result_width: Int) -> Int {
  let b = bytes * 8
  case raw >= pow2(b - 1) {
    True -> raw - pow2(b) + pow2(result_width)
    False -> raw
  }
}

/// Assemble the raw `n`-byte (`n <= 8`) little-endian value at effective address `ea` from the
/// `<= 2` touched words (§A.2). `raw = Σ byte[ea+k]·256^k`, an unsigned integer in
/// `[0, 2^{8·n})`. Read-only; callers MUST have bounds-checked `ea`.
fn gather(a: Atomics, ea: Int, n: Int) -> Int {
  let w = ea / 8
  let p = ea % 8
  let ix = w + 1
  case p + n <= 8 {
    True ->
      // Single word: bytes [p, p+n) of word `w`. Shift the byte at `p` down to bit 0, keep `8n`.
      int.bitwise_and(
        int.bitwise_shift_right(atomics_get(a.ref, ix), 8 * p),
        mask(8 * n),
      )
    False -> {
      // Two words: low `(8-p)` bytes from word `w` (its top bytes), high `n-(8-p)` bytes from
      // word `w+1` (its low bytes).
      let lo_bytes = 8 - p
      let lo = int.bitwise_shift_right(atomics_get(a.ref, ix), 8 * p)
      let hi =
        int.bitwise_and(atomics_get(a.ref, ix + 1), mask(8 * { n - lo_bytes }))
      int.bitwise_or(lo, int.bitwise_shift_left(hi, 8 * lo_bytes))
    }
  }
}

/// Scatter `value`'s low `n` bytes (`n <= 8`) little-endian into the `<= 2` touched words at
/// effective address `ea` by read-modify-write (`new = (old & ~field) | (bytes << pos)`), then
/// `put` (§A.2). Process-local, so a plain `get`+`put` (no `compare_exchange`) — the array is
/// never contended. Callers MUST have bounds-checked `ea` (all-or-nothing). Mutates `ref` IN
/// PLACE; returns `Nil`.
fn scatter(a: Atomics, ea: Int, value: Int, n: Int) -> Nil {
  let w = ea / 8
  let p = ea % 8
  let ix = w + 1
  let v = int.bitwise_and(value, mask(8 * n))
  case p + n <= 8 {
    True -> {
      write_field(a, ix, p, n, v)
      Nil
    }
    False -> {
      let lo_bytes = 8 - p
      let lo_part = int.bitwise_and(v, mask(8 * lo_bytes))
      let hi_part = int.bitwise_shift_right(v, 8 * lo_bytes)
      // Word `w`: overwrite its top `lo_bytes` bytes (positions [p, 8)).
      write_field(a, ix, p, lo_bytes, lo_part)
      // Word `w+1`: overwrite its low `n-lo_bytes` bytes (positions [0, n-lo_bytes)).
      write_field(a, ix + 1, 0, n - lo_bytes, hi_part)
      Nil
    }
  }
}

/// Read-modify-write `len` bytes (`bits = len`) into word `ix` at byte position `pos`: clear the
/// field `[8·pos, 8·pos + 8·len)`, then OR in `bits` (already `<= 8·len` bits wide, positioned at
/// `pos`). `int.bitwise_not(field_mask)` is negative (infinite sign extension), but `band` with
/// the unsigned `old` (`< 2^64`) yields an unsigned result, so the stored word stays in
/// `[0, 2^64)`. Mutates `ref` IN PLACE.
fn write_field(a: Atomics, ix: Int, pos: Int, len: Int, bits: Int) -> Nil {
  let field_mask = int.bitwise_shift_left(mask(8 * len), 8 * pos)
  let old = atomics_get(a.ref, ix)
  let cleared = int.bitwise_and(old, int.bitwise_not(field_mask))
  let new = int.bitwise_or(cleared, int.bitwise_shift_left(bits, 8 * pos))
  atomics_put(a.ref, ix, new)
}

/// Write an arbitrary-length `bytes` BitArray into memory starting at `ea`, one byte per
/// single-byte `scatter`. Callers MUST have bounds-checked the whole range (`a_init_data`).
/// Instantiation-time only; O(len). Empty `bytes` is a no-op.
fn write_data_loop(a: Atomics, ea: Int, bytes: BitArray) -> Nil {
  case bytes {
    <<b:size(8), rest:bits>> -> {
      scatter(a, ea, b, 1)
      write_data_loop(a, ea + 1, rest)
    }
    _ -> Nil
  }
}

/// Gather words `[i, total)` into a growing little-endian byte accumulator (`acc`). Each word is
/// emitted as 8 little-endian bytes, so the byte at address `8w+k` is bits `[8k, 8k+8)` of word
/// `w` — the exact LE layout. Tail-recursive so the BEAM binary-append optimisation keeps it
/// O(total).
fn flat_loop(a: Atomics, i: Int, total: Int, acc: BitArray) -> BitArray {
  case i >= total {
    True -> acc
    False ->
      flat_loop(a, i + 1, total, <<
        acc:bits,
        { atomics_get(a.ref, i + 1) }:size(64)-little,
      >>)
  }
}

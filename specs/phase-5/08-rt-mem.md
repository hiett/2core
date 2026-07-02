# Unit P5-08 — `rt_mem` extension: bulk memory + multi-memory + memory64

> **One owner · Wave A · the memory-runtime surface-completion unit.** Freeze deps:
> `«RT3-SIG-FROZEN»` (keystone P5-01 doc-freezes the extended `rt_mem`/`rt_mem_atomics`/
> `rt_mem_nif` public heads + the `rt_state` memories-vector and passive-data seam),
> `«IR3-FROZEN»` (the `IdxType`/segment/`TrapReason` shapes I consume). Read
> [`00-overview.md`](00-overview.md) (H1–H8) first, then the two templates this doc mirrors:
> [`../phase-2/04-rt-mem.md`](../phase-2/04-rt-mem.md) (the paged core + `rebuild` oracle) and
> [`../phase-4/04-rt-mem-atomics.md`](../phase-4/04-rt-mem-atomics.md) (the tier-O `atomics`
> backend). Phase-1 D1–D10 / Phase-2 E1–E8 / Phase-3 F1–F8 / Phase-4 G1–G8 all still hold.

---

## Context

Phase 2 built `rt_mem` — an immutable, sparse, paged linear memory held byte-for-byte to a
flat-binary `rebuild` oracle (E4). Phase 3/4 added the tier-O `atomics` backend (the O(1) lever)
and the tier-N `nif` skeleton, all behind one uniform backend interface reached through the
`state_strategy` (`cell` / `threaded`) and `mem_tier` (`paged` / `atomics` / `nif`) seams. Every
tier is spec-correct **by construction** because it is held byte-for-byte to the same oracle.

What the engine still cannot do is the rest of standardized linear memory: the **bulk-memory**
operations (`memory.fill` / `memory.copy` / `memory.init` + `data.drop` and passive/droppable data
segments — the finalized bulk-memory proposal, WASM 2.0 §exec/instructions), **multiple memories**
(every memory instruction carries a memory index; the module holds a *vector* of memories rather
than a single one — the multi-memory proposal, now living-standard), and **64-bit memories**
(`i64`-indexed addressing where `byte_len` may exceed 2³² and bounds arithmetic is 64-bit — the
memory64 proposal). This unit grows the memory runtime to that complete surface while staying
**conformance-neutral by default** (H7): a module with one 32-bit memory, active-only data, and no
bulk ops must compile to **byte-identical** `.core` and run byte-identically on every
`(state_strategy × mem_tier)` — the existing public heads (`load/5`, `store/4`, `size/0`, `grow/1`,
`init_data/2`, `fresh/3`, and their `t_*` twins) are **untouched in body and signature**; all new
capability is **additive**.

The load-bearing correctness properties carry over unchanged and are the security boundary (H6):
**little-endian**, **no-wrap effective address → trap** (`ea` is a BEAM bignum, never masked),
**eager bounds → trap before any write** (all-or-nothing), and **f32/f64 as raw-byte moves** (D5).
The new ops extend exactly these invariants: every bulk op checks its **whole** range up front and
mutates **zero** bytes on a trap; `memory.copy` is **overlap-correct (memmove)**; and memory64
requires **no change to the byte machinery** — the existing bignum `ea`/`byte_len` already address
past 2³² — only the page cap and the `fresh` seed learn the index width. A bounds bug's worst case
stays a wrong/missing trap or a node-safe process crash, **never a host escape** (tier P/O; the
tier-N native impl remains deferred behind the byte-identical skeleton, §E).

## Goal

Implement, against the spec and held to the `rebuild` oracle, every bulk-memory primitive with
**spec-exact** semantics — `memory.fill` (eager bounds, low-byte fill), `memory.copy` (memmove,
overlap-correct in either direction, cross-memory-capable, eager bounds on *both* ranges),
`memory.init` (from a passive/active data segment's *current* bytes, eager bounds on both the
segment and the memory), and the byte-level behavior of `data.drop` (init from a dropped/empty
segment traps for `n > 0`, is a no-op for `n = 0`). Route every memory op through a **memory index**
(defaulting to 0, so the single-memory path is byte-identical) over a `rt_state` **memories
vector**. Make memory64 work by baking the **index-width-appropriate page cap** into the `fresh`
seed and `grow` — and mark every memory64-specific deliverable **cleanly cuttable** per H8. Do it
across **paged** (`rt_mem`), **atomics** (`rt_mem_atomics`), and the **nif** skeleton
(`rt_mem_nif`), under **both** state strategies, and **prove** it by extending the flat-binary
oracle (`o_fill`/`o_copy`/`o_init`) and the differential (`paged ≡ atomics ≡ oracle`) to the new
ops, plus spec-corner tests transcribed from the bulk/multi-memory/memory64 `.wast` files.

## Files owned (single-owner · additive per D1)

- `src/twocore/runtime/rt_mem.gleam` — **EXTEND (additive).** The paged bulk pure core
  (`mem_fill`/`mem_copy`/`mem_init`), the oracle extension (`o_fill`/`o_copy`/`o_init`), the
  memory-index-routed cell/threaded wrappers (`fill`/`copy`/`init` + the `_at` load/store/size/
  grow/init_data variants), and the memory64-aware `fresh64` / cap plumbing. The Phase-2/4 frozen
  heads and pure `mem_*`/`o_*` core stay **byte-identical**.
- `src/twocore/runtime/rt_mem_atomics.gleam` — **EXTEND (additive).** The tier-O bulk pure core
  (`a_fill`/`a_copy`/`a_init`), the matching cell/threaded/`_at` wrappers, and the memory64 gate
  (an `i64` memory's cap almost always exceeds `atomics_reserve_cap_pages` → fail-closed rejected).
- `src/twocore/runtime/rt_mem_nif.gleam` — **EXTEND (additive).** The delegating skeleton wrappers
  for every new head (each re-exports the `rt_mem` body — spec-correct by construction, not the
  native ceiling; the deferred C NIF drops in behind the identical heads).
- `test/twocore/runtime/rt_mem_test.gleam`, `test/twocore/runtime/rt_mem_atomics_test.gleam` —
  **EXTEND.** The differential + spec-corner suites for the new ops.

## Deliverables & freeze milestones

Under `«RT3-SIG-FROZEN»` the keystone (P5-01) publishes these public heads as `todo`-free
doc-frozen signatures; this unit fills the bodies. The frozen additive surface (final names pinned
by P5-01 — I scope against these):

```gleam
// ── paged (rt_mem) — additive to the Phase-2/4 frozen heads ──
// Pure bulk core (value-threaded, the testable algebra):
pub fn mem_fill(m: Mem, dest: Int, value: Int, count: Int) -> Result(Mem, TrapReason)
pub fn mem_copy(dst_m: Mem, src_m: Mem, dst: Int, src: Int, count: Int) -> Result(Mem, TrapReason)
pub fn mem_init(m: Mem, seg: BitArray, dst: Int, src: Int, count: Int) -> Result(Mem, TrapReason)
// memory64: an index-width-aware fresh + a per-memory hard cap baked into `Mem`.
pub fn fresh64(min_pages: Int, max_pages: Option(Int), safe_cap: Int) -> Dynamic       // i64 memory (deferrable)
pub fn fresh_mem_idx(min_pages, max_pages, safe_cap, chunk, idx: IdxType) -> Mem        // pure ctor
// Multi-memory cell wrappers (memidx-routed; new, so no byte-identity constraint):
pub fn fill(mem_idx: Int, dest: Int, value: Int, count: Int) -> Result(Nil, TrapReason)
pub fn copy(dst_mem: Int, src_mem: Int, dst: Int, src: Int, count: Int) -> Result(Nil, TrapReason)
pub fn init(mem_idx: Int, seg: BitArray, dst: Int, src: Int, count: Int) -> Result(Nil, TrapReason)
pub fn load_at(mem_idx, bytes, signed, result_width, addr, offset) -> Result(Int, TrapReason)
pub fn store_at(mem_idx, bytes, addr, value, offset) -> Result(Nil, TrapReason)
pub fn size_at(mem_idx: Int) -> Int
pub fn grow_at(mem_idx: Int, delta: Int) -> Int
pub fn init_data_at(mem_idx: Int, offset: Int, bytes: BitArray) -> Result(Nil, TrapReason)
// Threaded twins (thread InstanceState): t_fill / t_copy / t_init / t_load_at / … (same shapes,
//   leading `st`, returning the rebound record; §A.3).
// Oracle extension (tests only):
pub fn o_fill(o: OMem, dest, value, count) -> Result(OMem, TrapReason)
pub fn o_copy(dst_o: OMem, src_o: OMem, dst, src, count) -> Result(OMem, TrapReason)
pub fn o_init(o: OMem, seg: BitArray, dst, src, count) -> Result(OMem, TrapReason)
```

The `atomics` and `nif` modules expose the **same** cell/threaded/`_at`/bulk heads (backend swap,
G5); `rt_mem_atomics` adds the pure `a_fill`/`a_copy`/`a_init` core.

**This unit is done** when the differential (`paged ≡ atomics ≡ oracle`) is green over randomized
sequences that include bulk ops, overlapping copies, cross-memory copies, and dropped-segment
inits; every spec-corner below passes on all impls; conformance `fail == 0` under every shipped
`(state_strategy × mem_tier)`; `gleam format --check` is clean and `gleam build` has **zero
warnings**; and every public fn/type carries a `///` contract doc. "Done" = *the suite passes*, not
"it compiles".

## Depends on (freeze milestones)

- **`«RT3-SIG-FROZEN»`** (P5-01) — the additive heads above, doc-frozen. Stub against them until
  the keystone lands green.
- **`«IR3-FROZEN»`** (P5-01) — `IdxType { Idx32 Idx64 }`, the `DataSegment`/`DataMode` shape
  (`DataActive(mem, offset)` / `DataPassive`), and any bulk `TrapReason`. I consume, do not own,
  these. Per the provisional surface bulk ops reuse the existing `MemoryOutOfBounds`; **no new
  `TrapReason` is expected** (§A.2 open question).
- **Unit 09 (imports + `rt_state`)** — the **memories vector** and the **passive-data drop state**
  are `rt_state` fields (09/keystone own `rt_state.gleam`, not this unit — the reconcile seam noted
  in overview §4). I define the required `rt_state` contract (§A.1/§A.4); 09 implements it. Until
  09 publishes it, develop the **pure cores** (`mem_*`/`a_*`/`o_*`), which thread explicit handles
  and touch no state — the wrappers are a thin shell added last.
- **Unit 06 (`emit_core`)** and **unit 05 (lower)** consume my heads (they emit the bulk/`_at`
  calls and project passive-data bytes); I hand them the seam in §A. **Unit 07 (`rt_table`)** is
  the exact structural parallel for passive *element* segments + multiple tables — coordinate the
  drop-state shape so data and element segments are symmetric.

---

## A. Multi-memory — the memories vector & index routing (the seam)

### A.1 The `rt_state` memories vector (unit 09's field; my required contract)

Today `rt_state.InstanceState` holds a single opaque `mem: Dynamic`. Multi-memory makes the module
carry a **vector** of memories; every memory op names an index. Per H3 the index is a **static
immediate** resolved at emit time — no runtime memory *handle* ever flows through the IR (the
tier-agnostic rule from Phase-4 G5 holds). The **required `rt_state` surface** (owned by 09):

```gleam
// cell strategy (index-routed; the memory value stays OPAQUE to rt_state, coerced by rt_mem):
pub fn mem_get_at(idx: Int) -> Dynamic            // memory `idx` of this process's cell
pub fn mem_put_at(idx: Int, mem: Dynamic) -> Nil  // write memory `idx` back
// threaded strategy:
pub fn mem_at(st: InstanceState, idx: Int) -> Dynamic
pub fn with_mem_at(st: InstanceState, idx: Int, mem: Dynamic) -> InstanceState
```

**Byte-identity discipline (H7).** `rt_state` keeps the existing `mem_get/0`, `mem_put/1`,
`mem(st)`, `with_mem(st,_)` as **exact index-0 aliases** (`mem_get() == mem_get_at(0)`). The
Phase-2/4 `rt_mem.load/5`/`store/4`/… bodies are **not touched**: they still call `rt_state.mem_get`
/ `mem_put`, which now read/write slot 0 of the vector. Generated `.core` for a single-memory
module is therefore **byte-identical** — the vector change is invisible to the compiled module (it
lives entirely inside the fixed runtime library). Recommended physical shape: a `Dict(Int, Dynamic)`
keyed by memory index (O(1) routing, sparse), seeded from `StateDecl.mems` in index order (imported
memories occupy the low indices, then module-defined memories — 09's instantiation concern).

### A.2 The bulk & indexed pure ops carry the index only at the wrapper

The pure paged core (`mem_fill`/`mem_copy`/`mem_init`) threads **explicit `Mem` values** — no index,
no state. Index routing lives **only** in the cell/threaded wrappers, which project the right
handle(s) from the vector, drive the pure core, and persist. This keeps the algebra tier- and
index-agnostic and lets the differential drive `mem_*`/`a_*`/`o_*` in lockstep without any state.

`memory.copy` is the one op that touches **two** indices (`dst_mem`, `src_mem`). The pure
`mem_copy(dst_m, src_m, …)` takes two handles; the wrapper projects both. When `dst_mem == src_mem`
the wrapper passes the **same** handle twice — overlap is handled by snapshotting the source region
first (§B.2), so same-index and cross-index copy share one code path.

**No new `TrapReason`** (provisional surface, confirmed): every bulk trap is
`MemoryOutOfBounds` (spec message *"out of bounds memory access"*). *Open question for P5-01:* if
init-from-a-dropped-segment ever needs a distinct message it would be one new reason with a
`spec_trap_message` — but the spec uses the same out-of-bounds message, so I recommend reuse.

### A.3 Cell vs threaded wrappers (backend-uniform, §D of the phase-4 template)

Each new op has a **cell** form (reads/writes the pdict cell via `mem_get_at`/`mem_put_at`) and a
**threaded** form (`t_*`, threading `InstanceState` via `mem_at`/`with_mem_at`). Reads leave state
untouched; mutators persist. For **paged** the memory is immutable, so a mutator rebinds slot
`mem_idx` to a **new** `Mem`. For **atomics** the `ref` mutates in place, so a mutator returns the
**same** handle and — like the Phase-4 `store` — writes back only when the record value changed
(`grow` moves the watermark; `fill`/`copy`/`init` do not). This is exactly the Phase-4 wrapper
posture, generalized to an index. Worked sketch (paged cell `fill`):

```gleam
/// `memory.fill` on memory `mem_idx`: fill `count` bytes at `dest` with the low byte of `value`.
/// Eager bounds (trap-before-write, all-or-nothing). O(count); charges count-proportional fuel on
/// success (§F). Returns Ok(Nil) or Error(MemoryOutOfBounds) with ZERO mutation.
pub fn fill(mem_idx: Int, dest: Int, value: Int, count: Int) -> Result(Nil, TrapReason) {
  case mem_fill(from_dynamic(rt_state.mem_get_at(mem_idx)), dest, value, count) {
    Ok(updated) -> {
      rt_meter.charge(count)                 // §F resource bound
      rt_state.mem_put_at(mem_idx, mem_to_dynamic(updated))
      Ok(Nil)
    }
    Error(reason) -> Error(reason)
  }
}
```

### A.4 Passive-data drop state — the seam (unit 09 owns the field; I own the byte semantics)

Passive data segments are droppable: `data.drop x` marks segment `x` empty; a later
`memory.init x` sees a **zero-length** segment. This drop state is **instance state** and threads
through the existing state seam (H2 — "no new seam"): `rt_state` (unit 09) holds the passive data
segments' **current bytes**, seeded at instantiate from the module's passive `DataSegment`s.

**Recommended division (least coupling, parallels the frozen `init_data(bytes: BitArray)`):**
`rt_mem` stays a pure byte-mover — `mem_init`/`init` take the segment's **current bytes** as a
`BitArray` parameter; `emit_core` (06) **projects** those bytes from `rt_state` at the call site and
`data.drop` is a pure `rt_state` op. Required `rt_state` surface (09):

```gleam
pub fn data_seg(idx: Int) -> BitArray             // current bytes of passive data segment `idx` (ε if dropped)
pub fn data_drop(idx: Int) -> Nil                 // set segment `idx` to ε (cell)
pub fn t_data_seg(st, idx) -> BitArray
pub fn t_data_drop(st, idx) -> InstanceState      // threaded
```

`emit_core` lowers `MemInit(mem, seg, dst, src, count)` →
`rt_mem:init(Mem, rt_state:data_seg(Seg), Dst, Src, Count)` and `DataDrop(seg)` →
`rt_state:data_drop(Seg)`. This unit **owns the byte semantics** (init-from-dropped traps/no-ops,
proven at the `rt_mem` level via `mem_init(m, <<>>, …)`) and the tests; unit 09 owns the drop
**storage**. Coordinate the shape with unit 07 (passive *element* segments) so data and element
drop state are symmetric.

*Open question:* an alternative is for `rt_mem` to own an opaque `Datas` value (like it owns `Mem`)
that `rt_state` holds as `Dynamic` and `data_drop` mutates — parallel to the mem/table opacity
pattern. I recommend the projection design above (smaller `rt_state`, `rt_mem` stays a byte-mover),
but flag the choice for the reconcile pass since 07/09 must agree.

---

## B. Bulk memory ops — spec-exact semantics

> Spec anchors — transcribe these exactly, do not re-derive:
> execution: <https://webassembly.github.io/spec/core/exec/instructions.html#memory-instructions>,
> validation: <https://webassembly.github.io/spec/core/valid/instructions.html#memory-instructions>,
> binary: <https://webassembly.github.io/spec/core/binary/instructions.html>.
> Binary opcodes (decode is unit 03's — cited for grounding): `memory.init` = `0xFC 0x08 <dataidx>
> <memidx>`; `data.drop` = `0xFC 0x09 <dataidx>`; `memory.copy` = `0xFC 0x0A <dstmemidx> <srcmemidx>`;
> `memory.fill` = `0xFC 0x0B <memidx>`. Pre-multi-memory the memidx immediates were a reserved `0x00`.

### B.1 The semantics table (operands popped top-first; bounds are EAGER, checked before any write)

| op | operands (pop order) | immediates | trap condition (before any write) | effect on success |
|---|---|---|---|---|
| `memory.fill` | `n` (count), `val`, `d` (dest) | `memidx` | `d + n > len(mem)` | `mem[d .. d+n) := (val & 0xFF)` |
| `memory.copy` | `n`, `s` (src), `d` (dst) | `dstmemidx`, `srcmemidx` | `s + n > len(src)` **or** `d + n > len(dst)` | `dst[d .. d+n) := src[s .. s+n)` (memmove) |
| `memory.init` | `n`, `s`, `d` | `dataidx`, `memidx` | `s + n > len(data)` **or** `d + n > len(mem)` | `mem[d .. d+n) := data[s .. s+n)` |
| `data.drop` | — | `dataidx` | (never traps) | `data[dataidx] := ε` |

**Bounds are strict `>`.** An op whose range ends *exactly* at `len` is in bounds. A **zero-length**
op is in bounds iff its start index is `≤ len` (`d + 0 = d`, trap iff `d > len`) — so `fill(len, _,
0)` succeeds but `fill(len+1, _, 0)` traps, and `copy`/`init` likewise trap on a zero-length op
whose src or dst start is past the respective length. Transcribe the exact boundary assertions from
`memory_fill.wast`/`memory_copy.wast`/`memory_init.wast` — the `.wast` is the authority for the
precise offsets. (Spec pseudocode: check `d + n > len` → trap; then `if n = 0 return`; then write
one byte and recurse — the up-front check is what makes it eager and all-or-nothing.)

**`memory.fill` writes the LOW BYTE only.** `val` is an i32; only `val & 0xFF` is written. E.g.
`fill(d, 0x12345678, 4)` writes `78 78 78 78`.

**`memory.copy` is memmove.** Overlapping ranges copy correctly in either direction. The spec
defines it by direction (`if d ≤ s` copy forward else backward); the equivalent, simpler, and
tier-uniform realization is **snapshot the source region first, then write** (§B.2) — the result is
*as if* the source were copied to a temporary buffer and then to the destination, which is the
definition of memmove.

**`memory.init` from a dropped/empty segment.** `data.drop` sets the segment to `ε` (length 0). A
subsequent `init` with `n > 0` traps (`s + n > 0`); with `n = 0` (and `s = 0`) it is a no-op
(`0 > 0` is false). This is the exact spec behavior and is testable at the `rt_mem` level as
`mem_init(m, <<>>, 0, 0, n)`.

### B.2 The paged pure core (immutable → memmove-correct for free)

Because `Mem` is immutable, the source region is snapshotted (a zero-copy sub-binary read from the
*old* `Mem`) **before** any chunk of the destination is rebuilt — so overlap is automatically
correct and same-vs-cross-memory copy share one path. All three reuse the frozen `read_bytes`/
`write_bytes`/`byte_len` helpers and the frozen no-wrap `in_bounds` discipline (bignum `ea`, never
masked).

```gleam
/// `memory.fill`: bounds-check `[dest, dest+count)` up front, then write `count` copies of
/// `value & 0xFF`. Ok(new_mem) or Error(MemoryOutOfBounds) (input Mem returned untouched).
pub fn mem_fill(m: Mem, dest: Int, value: Int, count: Int) -> Result(Mem, TrapReason) {
  case dest >= 0 && count >= 0 && dest + count <= byte_len(m) {
    False -> Error(MemoryOutOfBounds)
    True  -> Ok(write_bytes(m, dest, repeat_byte(int.bitwise_and(value, 0xFF), count)))
  }
}

/// `memory.copy` (memmove): eager bounds on BOTH ranges, then snapshot the source region from the
/// immutable `src_m` and splice it into `dst_m`. `dst_m`/`src_m` are the same value for a
/// same-index copy; distinct for a cross-memory copy. Returns the new `dst_m`.
pub fn mem_copy(dst_m: Mem, src_m: Mem, dst: Int, src: Int, count: Int) -> Result(Mem, TrapReason) {
  case src >= 0 && dst >= 0 && count >= 0
    && src + count <= byte_len(src_m) && dst + count <= byte_len(dst_m) {
    False -> Error(MemoryOutOfBounds)
    True  -> Ok(write_bytes(dst_m, dst, read_bytes(src_m, src, count)))   // snapshot-then-write
  }
}

/// `memory.init` from a data segment's CURRENT bytes `seg` (ε if dropped): eager bounds on the
/// segment (`src+count <= len(seg)`) AND the memory (`dst+count <= byte_len`), then splice.
pub fn mem_init(m: Mem, seg: BitArray, dst: Int, src: Int, count: Int) -> Result(Mem, TrapReason) {
  case src >= 0 && dst >= 0 && count >= 0
    && src + count <= bit_array.byte_size(seg) && dst + count <= byte_len(m) {
    False -> Error(MemoryOutOfBounds)
    True  -> Ok(write_bytes(m, dst, take(seg, src, count)))
  }
}
```

`repeat_byte(byte, count)` builds a `count`-byte constant `BitArray` — a doubling builder
(O(log count) concatenations of off-heap REFC binaries) so a large fill does not do O(count)
allocations; no new FFI required. `count = 0` yields `<<>>` → `write_bytes` is a no-op → `Ok(m)`
(matches the spec `n = 0` return). `take`/`read_bytes`/`write_bytes` already short-circuit
zero-length ranges (Phase-2 helpers). **Overlap worked example** (`memory_copy.wast`): memory
`[0,1,2,3,4,5,6,7]`; `copy(dst=1, src=0, count=3)` → snapshot `src = <<0,1,2>>` → write at 1 →
`[0,0,1,2,4,5,6,7]`. `copy(dst=0, src=1, count=3)` → snapshot `<<1,2,3>>` → `[1,2,3,3,4,5,6,7]`.
Both are memmove-correct because the source is materialized first.

### B.3 Fail-closed all-or-nothing

Every bulk op computes its bounds as **bignum** sums (`dest + count`, `src + count`, `dst + count`)
and traps `MemoryOutOfBounds` **before** constructing any bytes — so a trapping op mutates zero
bytes, including any in-bounds prefix (the security property, §"Effect"). This is identical to the
frozen multi-byte-store invariant, extended to a whole range.

---

## C. memory64 — the deferrable half (index width, caps)

> Spec anchor: the memory64 proposal (living-standard §types/limits + §exec). Marked **cuttable**
> per H8 — every deliverable in this section is bracketed so it can be removed without touching the
> bulk/multi-memory work. Do **not** claim memory64 unless `memory64.wast`/`address64.wast` run.

The key insight — and why memory64 is cheap and cleanly cuttable — is that the **byte machinery is
already 64-bit-correct**. The frozen `ea = addr + offset` is a BEAM bignum and is **never masked**;
`byte_len = pages * page_bytes` is a bignum; the LE codec, `in_bounds`, `read_bytes`/`write_bytes`,
and every §B bulk op operate on bignums. So an `i64` address `> 2³²`, an offset `> 2³²`, and a
`byte_len > 2³²` already flow through the existing code **unchanged**. memory64 needs only:

1. **An index-width-appropriate page cap.** The frozen `hard_max_pages = 65_536` is the **i32** cap
   (2¹⁶ pages = 4 GiB). A 64-bit memory has a much larger cap, so it must be baked per memory:
   ```gleam
   /// The hard page cap for `idx`: `65_536` (2^16, i32 = 4 GiB) for Idx32, or the i64 memory cap
   /// for Idx64. VERIFY the exact Idx64 value against the finalized memory64/3.0 limits rules
   /// (candidate: 2^48 pages = 2^64 bytes) before shipping — flagged in Open questions.
   pub const hard_max_pages_i64: Int = 0x1_0000_0000_0000    // 2^48 pages — CONFIRM
   fn hard_cap(idx: IdxType) -> Int { case idx { Idx32 -> hard_max_pages  Idx64 -> hard_max_pages_i64 } }
   ```
2. **A width-aware `fresh` that bakes the cap into `max`.** The `Mem`/`OMem`/`Atomics` records gain
   an `idx: IdxType` (or an already-folded `hard`) field; `fresh64/3` (i64) and the existing
   `fresh/3` (i32) both fold `effective_max = min(declared ?? safe_cap, safe_cap, hard_cap(idx))`.
   Adding a field to the opaque `Mem` does **not** change generated `.core` (`Mem` is opaque, built
   by `fresh`); the i32 path is byte-identical (same cap, same result).
3. **`grow` capped at the memory's own hard cap.** `mem_grow` currently checks
   `new <= m.max && new <= hard_max_pages`. Since `m.max` already folds the correct per-width cap
   (step 2), the redundant global `hard_max_pages` check is dropped in favor of `new <= m.max`
   (identical for i32 where `m.max ≤ 65_536`; correct for i64 where `m.max` may exceed 65_536).

Nothing else changes. A 32-bit memory is byte-identical to Phase-4; a 64-bit memory addresses,
loads, stores, fills, copies, inits, and grows with `i64`/bignum arithmetic through the same code.
Validation (unit 04) enforces that a memory's address operand type matches its `idx_type` and that
`memory.copy`/`init` operand widths agree with the memories involved — the runtime is agnostic
(operands arrive as resolved bignums).

**Cut plan (if H8 defers memory64 to Phase 6):** drop `fresh64`, the `idx`/`hard` field, and the
`hard_max_pages_i64` constant; keep `hard_max_pages = 65_536` inline in `mem_grow`. The
bulk/multi-memory deliverables are entirely independent and stay.

---

## D. The oracle & differential extension (E4 — the proof)

The flat-binary `rebuild` oracle (`OMem`, one contiguous binary; store rebuilds the whole thing) is
the trivially-correct reference. Extend it with the three bulk ops — each is a slice + splice on the
flat binary, so it is memmove-correct and eager-bounds-correct **by construction**:

```gleam
pub fn o_fill(o: OMem, dest, value, count) -> Result(OMem, TrapReason)   // splice `count` copies of (value & 0xFF)
pub fn o_copy(dst_o: OMem, src_o: OMem, dst, src, count) -> Result(OMem, TrapReason)  // slice src region, splice into dst
pub fn o_init(o: OMem, seg: BitArray, dst, src, count) -> Result(OMem, TrapReason)    // slice seg, splice
```

Each bounds-checks with the same strict-`>` predicate, then `<<pre:bits, new:bits, post:bits>>`
rebuild — O(byte_len) per op, slow but unmistakable. `o_copy` slices the source region from the
*old* `src_o` binary before splicing → memmove-correct (same as paged). The **differential**
(extended in `rt_mem_test.gleam`) drives one shared op trace — a randomized sequence of `load` /
`store` / `grow` / `init_data` **plus** `fill` / `copy` / `init` (random widths, addresses spanning
in/out-of-bounds, **overlapping copies in both directions**, cross-memory copies, and inits from
both full and **dropped (ε)** segments) — through the pure paged core, the oracle, and (in
`rt_mem_atomics_test.gleam`) the `a_*` core in lockstep, asserting after each op: **identical return
value, identical trap (`Ok`/`Error(reason)`), and identical flat byte image** (`to_flat(paged) ==
o_flat(oracle) == a_flat(atomics)`). Run across several chunk sizes (chunk-independence is itself an
assertion) and across bounded memories that engage `AtomicsBacked`. A shared bug cannot hide because
the oracle itself is held to the §"Verification" spec-corner tests.

---

## E. `atomics` and `nif` tiers — bulk + multi-mem + mem64

### E.1 `atomics` (tier-O, `rt_mem_atomics`)

The `atomics` backend mutates a fixed array of 64-bit words **in place**, so the bulk ops must
respect direction on overlap. The uniform, correct realization mirrors §B.2: **gather the source
region into an immutable `BitArray` snapshot first, then scatter** — overlap-correct regardless of
direction, and cross-memory-correct (a distinct `ref`). Pure core (value-threaded, effectful — the
`ref` mutates in place and the same handle is returned):

```gleam
/// `memory.fill`: eager bounds, then scatter `value & 0xFF` across `[dest, dest+count)`. Byte-by-
/// byte `scatter` is correct; a word-aligned fast path (write whole words of the repeated byte) is
/// an optional perf nicety. Returns Ok(a) (same handle) or Error(MemoryOutOfBounds) (zero mutation).
pub fn a_fill(a: Atomics, dest: Int, value: Int, count: Int) -> Result(Atomics, TrapReason)
/// `memory.copy` (memmove): eager bounds on BOTH ranges, GATHER the whole `src` region from
/// `src_a` into a BitArray, then SCATTER into `dst_a` (snapshot-first → overlap-correct even when
/// `dst_a` and `src_a` are the same handle). Returns Ok(dst_a).
pub fn a_copy(dst_a: Atomics, src_a: Atomics, dst: Int, src: Int, count: Int) -> Result(Atomics, TrapReason)
/// `memory.init` from `seg`'s current bytes: eager bounds on seg AND memory, then scatter.
pub fn a_init(a: Atomics, seg: BitArray, dst: Int, src: Int, count: Int) -> Result(Atomics, TrapReason)
```

The cell/threaded wrappers route by index (§A.3) and — because the `ref` mutates in place —
`fill`/`copy`/`init` write back **no** `mem_put` (the handle value is unchanged), the same O(1)
constant-factor win the Phase-4 `store` earns. **Multi-memory** = multiple `AtomicsBacked` handles
in the vector; `a_copy` across indices reads one `ref`, writes another. **memory64 + atomics**: a
64-bit memory's effective max almost always exceeds `atomics_reserve_cap_pages` (a few thousand
pages), so `reservation`/`a_fresh` **fail-closed reject** it at link time (§C of the Phase-4
template) — memory64 realistically runs on `paged` (and the `nif` skeleton = paged). This is
correct and honest: no silent 4 GiB pre-alloc, no silent degrade. Only a memory64 module with a
tiny bounded max engages `atomics`.

### E.2 `nif` (tier-N skeleton, `rt_mem_nif`)

`rt_mem_nif` delegates every head to `rt_mem` (the node-safe skeleton — spec-correct by
construction, not the native ceiling). Add trivial delegating wrappers for the new heads:

```gleam
pub fn fill(mem_idx, dest, value, count)  { rt_mem.fill(mem_idx, dest, value, count) }
pub fn copy(dst_mem, src_mem, dst, src, count) { rt_mem.copy(dst_mem, src_mem, dst, src, count) }
pub fn init(mem_idx, seg, dst, src, count) { rt_mem.init(mem_idx, seg, dst, src, count) }
pub fn fresh64(min_pages, max_pages, safe_cap) { rt_mem.fresh64(min_pages, max_pages, safe_cap) }
// … load_at / store_at / size_at / grow_at / init_data_at + the t_* twins, each re-exporting rt_mem.
```

Coercion soundness holds unchanged: under `mem_tier == Nif` the `mem` slot is produced solely by
`rt_mem_nif.fresh`/`fresh64` (which call `rt_mem`), so delegating to `rt_mem`'s coercing entry
points is sound. The deferred C NIF drops in behind these byte-identical heads with zero call-site
change.

---

## F. Fuel / resource bound for O(count) ops

`memory.fill`/`copy`/`init` are **O(count)** in work (and, for a large `fill`/`copy` snapshot, in
memory) — an untrusted portable module could otherwise do unbounded CPU/allocation in a single op,
a resource-exhaustion escape (E3/F5). Following the Phase-4 `grow` precedent (the runtime-side
dynamic fuel charge — `count` is a *runtime* value, so it cannot be a static IR `Charge` node), each
bulk-op **wrapper** charges `rt_meter.charge(count)` on the **success** path (after the bounds check
passes), on **both** the cell and threaded strategies **identically**, so metered+threaded stays
byte-identical to metered+cell (the G7 trap-parity bar). The pure `mem_*`/`a_*`/`o_*` cores stay
**charge-free** (testable). A trapping op charges nothing (it did no work).

*Open question (pin with the planner):* Phase 4 called `grow` "the ONE runtime-side dynamic fuel
charge." Adding bulk-op charges introduces three more. I **recommend** charging `count` bytes
(consistent with `grow`'s `delta * page_bytes` bytes-touched accounting) because the Safe CPU/memory
bound demands it; confirm the exact unit and whether `copy` charges `count` once or `2 * count`
(read + write). Whatever is chosen, it must be identical across strategies and tiers.

---

## Effect / soundness / security note

- **Fail-closed bounds — the security property (H6).** Every bulk op checks its **whole** range as
  **bignum** sums (never masked mod 2³²/2⁶⁴) and traps `MemoryOutOfBounds` **before** any byte is
  written → **zero mutation on trap**, including any in-bounds prefix. The worst case of a bounds
  bug is a wrong/missing trap or a node-safe process crash — **never a host out-of-bounds read**
  (tier P/O: a BEAM binary / `atomics` array is memory-safe by construction; the tier-N native impl
  stays deferred behind the skeleton). This is the §11 security invariant, extended to whole ranges.
- **memmove correctness.** `memory.copy` snapshots the source before writing (paged: an immutable
  sub-binary; atomics: a gathered `BitArray`), so overlapping and cross-memory copies are correct in
  either direction — no partial-overwrite corruption.
- **Effectful barriers (H2).** All bulk ops are effectful; `ir/effect.gleam` (unit 01) classifies
  them as barriers — never CSE'd, reordered, or eliminated. `rt_mem` never calls `rt_trap`;
  `emit_core` does the `{ok,_}`/`{error,R}` case + raise (the seam). `data.drop` and the passive-data
  bytes are instance state (unit 09), reached only through the state seam — no ambient authority
  (D3a).
- **Conformance-neutral by default (H7).** A single 32-bit memory, active-only data, no bulk ops →
  the frozen `load/5`/`store/4`/`size/0`/`grow/1`/`init_data/2`/`fresh/3` heads and their `t_*`
  twins are byte-identical in body and signature; the memories vector and `idx` field live inside
  the fixed runtime library, invisible to the compiled module's `.core`. Floats-as-bits (D5) and the
  no-wrap `ea` are untouched.
- **Resource bound (E3/F5).** O(count) bulk ops charge count-proportional fuel on success (§F), so
  an untrusted module cannot do unbounded work in one op; `grow` past the (per-width) cap still
  returns −1.

---

## Verification — Definition of Done (D8)

Tests assert **WebAssembly semantics** (and the oracle), never "whatever the impl emits" — no
change-detectors. Spec-cited.

1. **Differential `paged ≡ atomics ≡ oracle`** over randomized op streams that include `fill` /
   `copy` (overlapping both directions + cross-memory) / `init` (full **and** dropped/ε segments)
   interleaved with `load` / `store` / `grow` / `init_data`, across several chunk sizes and on
   bounded memories that engage `AtomicsBacked`. Assert identical value, trap, and flat byte image
   after every op. (E4; the primary proof.)
2. **Spec-corner tests on the pure cores (`mem_*`, `a_*`, and the oracle `o_*`):**
   - **`fill` low-byte + count:** `fill(d, 0x12345678, 4)` writes `78 78 78 78`; `fill(d, v, 0)` is
     a no-op. (`memory_fill.wast`)
   - **`fill` eager bounds / zero mutation:** `dest + count == byte_len` succeeds; `+1` traps and
     re-reading the in-bounds prefix shows it **unchanged**; `fill(byte_len, v, 0)` succeeds,
     `fill(byte_len+1, v, 0)` traps. (`memory_fill.wast`)
   - **`copy` memmove overlap:** the §B.2 worked examples (`copy(1,0,3)` and `copy(0,1,3)` on
     `[0..7]`) match the memmove result in both directions; eager bounds on **both** src and dst;
     a trapping copy leaves the dst prefix unchanged. (`memory_copy.wast`)
   - **cross-memory `copy`:** `copy(dst_mem=0, src_mem=1, …)` reads memory 1 and writes memory 0;
     bounds use each memory's own length. (multi-memory suite)
   - **`init` from segment + dropped:** writes `seg[src..src+count)` at `dst`; eager bounds on
     `seg` **and** memory; `init` from a dropped (ε) segment with `n > 0` **traps** and with `n = 0`
     is a **no-op**; `src + count > len(seg)` traps. (`memory_init.wast`, `bulk.wast`)
   - **no-wrap `ea`** carries to bulk ops: a `dest`/`src`/`dst` near 2³² with a large count does not
     wrap to in-bounds. (`memory_copy.wast`/`address.wast`)
3. **Spec anchor `.wast`, reserved here.** Transcribe the assertions of `bulk.wast`,
   `memory_fill.wast`, `memory_copy.wast`, `memory_init.wast` as `rt_mem`-level tests **now** (their
   semantics *are* this unit's contract); reserve those filenames in the allowlist so unit 11 flips
   them to end-to-end pass across `paged`/`atomics` and both state strategies. The multi-memory
   proposal's `.wast` (multiple `(memory)` decls; memidx immediates on load/store/fill/copy/init)
   are reserved for the multi-memory path.
4. **memory64 (cuttable — only if shipped):** a 64-bit memory with `byte_len > 2³²` loads/stores/
   fills/copies/inits at addresses `> 2³²`; `grow` uses the i64 cap and a 32-bit memory is
   byte-identical; `memory64.wast`/`address64.wast` reserved. If H8 defers memory64, this item and
   all §C code are cut cleanly (bulk/multi-memory unaffected).
5. **Constant-space + resource bound.** A ~100k-iteration store/fill loop over the cell/threaded API
   holds bounded process memory (superseded `Mem` is garbage / `atomics` mutates in place); a large
   `fill`/`copy` charges count-proportional fuel on success and nothing on a trap (§F), identically
   across strategies (the metered-parity bar).
6. `gleam format --check src test` clean; `gleam build` with **zero warnings** (every public fn
   total — no `todo`/`panic`/`let assert` on untrusted paths; coercions sole-producer-sound);
   `gleam test` green (≥ current count); conformance `fail == 0` under every shipped
   `(state_strategy × mem_tier)`; every public fn/type carries a `///` contract doc (what /
   params+ranges / `Result` semantics / failure modes).

**Done = the extended `rt_mem`/`rt_mem_atomics` suites pass** (the differential over bulk ops + every
spec-corner on all impls + the multi-memory routing + the resource-bound/constant-space tests), not
"it compiles."

## What this unit leaves

- **Unit 09 (`rt_state` + imports)** implements the **memories vector** (`mem_get_at`/`mem_put_at`/
  `mem_at`/`with_mem_at`, keeping `mem_get/0` etc. as index-0 aliases) and the **passive-data drop
  state** (`data_seg`/`data_drop` + `t_*`), and seeds `StateDecl.mems` (imported memories at the low
  indices) — the seam pinned in §A. Imported memories are provided state wired here.
- **Unit 06 (`emit_core`)** emits the bulk/`_at` calls, projects passive-data bytes from `rt_state`
  into `rt_mem:init`, wires `DataDrop → rt_state:data_drop`, and routes memory ops by index (emitting
  the frozen `load/5` form for a single-memory-index-0 module so `.core` stays byte-identical).
- **Unit 05 (lower)** lowers `MemFill`/`MemCopy`/`MemInit`/`DataDrop` and the memidx/idx-width; **04
  (validate)** types the operands against each memory's `idx_type` and enforces cross-memory copy
  operand widths; **03 (decode)** owns the `0xFC 8/9/10/11` opcodes + memidx/dataidx immediates.
- **Unit 07 (`rt_table`)** is the structural parallel for passive **element** segments +
  `table.init`/`copy`/`elem.drop` + multiple tables — coordinate the drop-state shape so data and
  element segments are symmetric.

## Open questions (for the planner / cross-unit sync)

1. **Passive-data drop-state ownership (§A.4).** I recommend `emit_core` projecting `rt_state.
   data_seg(idx)` into `rt_mem:init` (rt_mem stays a byte-mover; `data.drop` is a pure `rt_state`
   op), parallel to the frozen `init_data(bytes: BitArray)`. The alternative — `rt_mem` owning an
   opaque `Datas` value held by `rt_state` as `Dynamic` — mirrors the mem/table opacity pattern.
   07/09 must agree; pick one in reconcile.
2. **memory64 i64 page cap (§C).** The exact `hard_max_pages_i64` must be sourced from the finalized
   memory64/3.0 limits rules (candidate 2⁴⁸ pages = 2⁶⁴ bytes — **verify**, do not ship a guessed
   constant). If unverifiable at build time, defer memory64 per H8 rather than bake a wrong cap.
3. **Bulk-op fuel charge (§F).** Confirm bulk ops charge count-proportional fuel (I recommend yes —
   the Safe resource bound requires it) and the exact amount (`count` vs `2*count` for `copy`). It
   must be identical across strategies/tiers to preserve metered parity. This changes Phase 4's "one
   dynamic fuel charge" framing.
4. **No new `TrapReason` (§A.2).** Bulk ops reuse `MemoryOutOfBounds` (same spec message). Confirm
   P5-01 adds none for the memory path.
5. **`_at` vs always-indexed emit.** I keep the frozen non-indexed heads for the memory-0 path (for
   byte-identity) and add `_at` variants. Confirm `emit_core` (06) emits the non-indexed form for
   single-memory modules and the `_at` form only for multi-memory modules — otherwise the corpus is
   not byte-identical.

# Phase 2 — Overview & Shared Contracts

> **Read this first, then [`specs/phase-1/00-overview.md`](../phase-1/00-overview.md).**
> Phase-1's decisions **D1–D10 still hold** (one owner per file, runtime layers as Gleam
> modules called through the binding chokepoint with no ambient authority, per-stage error
> types, floats-as-bit-patterns, named-label IR, spec-first tests, the strict Definition of
> Done). This page adds the Phase-2 decisions **E1–E8** and the work breakdown. Phase 1 is
> complete and green (313 tests, 0 warnings, conformance 1740/1359/0).

---

## 1. The Phase-2 goal

> **Complete WebAssembly 1.0 (the MVP).** A real `.wasm` module that *uses* **linear
> memory** (load/store the full width matrix, `memory.size`/`memory.grow`,
> bounds-checked → trap), **tables + `call_indirect`** (runtime type-check → trap),
> **globals**, the **full float + integer conversion** surface, and **active
> data/element/start instantiation**, compiles and runs **spec-correctly on the BEAM in
> Safe mode**. The conformance suite jumps as the memory / table / global / float / trapping-
> conversion assertions move skip → pass.

The genuinely new, load-bearing thing Phase 2 introduces is **mutable instance state**
(memory grows and is written, globals mutate, tables are populated) — Phase 1 had **none**
(its generated code is pure). How that state is represented and reached is Phase 2's
keystone decision (**E1**), exactly as the IR + runtime ABI were Phase 1's.

### Acceptance (owned by the capstone, unit 11)

The Phase-2 corpus runs end-to-end through `load → instantiate → invoke` and matches the
spec suite; plus the new fail-closed / isolation properties:

| Area | Must demonstrate |
|---|---|
| memory | `i32.store` then `i32.load` round-trips; `load8_s`/`load16_u`/… widths; little-endian; an out-of-bounds load **and** an out-of-bounds (partial, multi-byte) store **trap** with zero corruption; `memory.grow` grows + returns old size, returns `-1` past the cap |
| tables | `call_indirect` to the right type runs; wrong type / out-of-bounds index / null slot each **trap** (the three distinct reasons) — and never via a data-driven `apply` |
| globals | mutable global round-trips through `global.set`/`global.get`; an immutable global rejects `global.set` at validation |
| floats | `sqrt`/`ceil`/`floor`/`nearest`/`abs`/`neg`/`copysign`, the 6 comparisons, **trapping** `trunc_f*_s/u` (trap on NaN/Inf/out-of-range), `convert_i*`, `demote`/`promote` — spec-bit-exact |
| instantiation | active data/element segments initialize memory/table; an out-of-bounds active segment **traps at instantiation**; a trapping `start` fails instantiation; two instances never observe each other's state |
| isolation | mutable state is per-instance and reset on (re)instantiation (one-instance-one-process) |

### Honest scope (E8 — do not overstate)

- **Tier-O, not tier-P.** Phase 2 ships the **`cell`** (process-dictionary) state strategy
  (tier-O, in-bounds for Safe). The tier-P **`threaded`** "zero-OTP, runs-anywhere" build —
  the high-level pitch's headline — is **Phase 3**. Say so; don't claim the runs-anywhere
  property yet.
- **Deferred to Phase 3 (state it, don't drop it silently):** non-function **imports**
  (imported memory/table/global + the spec `spectest` module → several `.wast` stay
  skipped); **reference types** (externref/funcref values, `table.get/set/copy/fill`,
  typed `select_t`, `elem.wast`); **bulk memory** (`memory.fill/copy/init`, `data.drop`);
  **multi-memory** (`memory.wast`, `table.wast`, `memory_grow.wast` are un-convertible /
  multi-memory at the pin — see unit 11); **SIMD**, **memory64**, **GC**, the **WAT text
  parser**, and the **optimizer** / **Unsafe profile**.
- **CPU metering stays observe-only** (a known Phase-1 gap). But **memory resource
  exhaustion IS fixed** in Phase 2 (E3): the Safe profile imposes a hard max-pages cap and
  charges `memory.grow` proportionally, so untrusted code cannot allocate unboundedly.

---

## 2. The Phase-2 decisions (E1–E8)

### E1 — Mutable instance state = the **`cell`** strategy (the keystone)

Instance state — the paged memory page-map, the mutable globals, and the table — lives in
the **process dictionary** of the instance's process (one-instance-one-process), under a
**single fixed namespaced key** holding an opaque record `{mem, globals, table}` (never
under program-chosen names). It is **tier-O** (process-local, memory-safe, cannot crash the
node), in-bounds for Safe (P or O, never N), and follows the precedent `rt_meter` already
set. The runtime layers read/write that cell; **generated function arities are unchanged**.

Why cell (verified by the critique): it **preserves the constant-space tail-loop and
preemption** properties Phase 1 proved — the state handle never becomes a loop-carried
value, the tail-`apply` back-edge is byte-for-byte unchanged, pdict `get` is **by-reference
(no copy)**, and pdict get/put are ordinary reduction-consuming ops (scheduler still
preempts). The threaded tier-P alternative would add a loop-carried handle param and a fresh
page-map version per store — correctly deferred.

**Two precise corrections to keep (do not overstate):**
- It is **arity/ABI-compatible**, **not "pure"**: every generated function that touches
  memory/globals/tables now **reads+writes the cell → it is effectful**. Phase-1 (no-memory)
  modules stay genuinely pure. **E6** records the optimizer consequence.
- The binding chokepoint does **not** isolate cell↔threaded — that is a codegen-**shape**
  change (`state_strategy` sub-axis), a real future emit_core retrofit, **not** a module
  swap. **Mitigation:** all stateful-op lowering routes through **one emit_core
  state-access seam** (realized by cell as pdict get/put), so the Phase-3 threaded build is a
  *seam expansion*, not a scattered rewrite. The IR carries **no handle operand** (its
  memory/global nodes are tier-agnostic), so the retrofit is provably confined to emit_core +
  the runtime.

The frozen state ABI is named **`«CELL-STATE-ABI-FROZEN»`** — explicitly the tier-O cell
convention only (mutating ops return the WASM result / `ok`; the handle stays hidden in the
cell). The threaded tier-P ABI is a **separate, later** freeze, not inherited. (The §10
"one signature serves both" rule applies to the rt_mem *backend* axis — `rebuild`/`paged`/
`atomics` — **not** to the cell↔threaded *state* tier.)

### E2 — IR2 extension (most of the surface was already lock-now; close the gaps)

The IR already models `Module.memory`/`globals`/`data_segments`, `MemLoad`/`MemStore`,
`GlobalGet`/`GlobalSet`, `CallIndirect`, `MemoryDecl`/`GlobalDecl`/`DataSegment`,
`MemAccess`, and `TrapReason{MemoryOutOfBounds, IndirectCallTypeMismatch}`. Unit 01 freezes
the **gaps** the critique found (these MUST all land in `«IR2-FROZEN»` or a late discovery
re-breaks every exhaustive match):

- **`MemSize` / `MemGrow` Expr nodes** — entirely missing today, yet "memory grows" is the
  headline. `mem_size() -> i32 pages`; `mem_grow(delta) -> i32 prev-size or -1`.
- **A result width/sign on the load path** — `MemAccess(bytes, signed)` **cannot**
  disambiguate `i32.load8_s` vs `i64.load8_s` (same bytes+sign, different result bit
  pattern). Add a result `ValType` (or `IntWidth`) to the load. Stores need only byte width
  (sign is irrelevant — document it). (Raw-bits float rep means a load needs only width+sign,
  not a float-vs-int tag: `f32.load` == `i32.load` at the byte level.)
- **`tables: List(TableDecl)`** on `Module` + **element segments** — `CallIndirect`
  references a table that has no declaration today.
- **The remaining float ops as `NumOp`/`ConvOp` variants:** `FAbs/FNeg/FCeil/FFloor/
  FTrunc/FNearest/FSqrt/FCopysign` and `FEq/FNe/FLt/FGt/FLe/FGe` (per width); `ConvOp`
  trapping `TruncS/U` (f→i, ×8), `ConvertS/U` (i→f, ×8), `F32DemoteF64`/`F64PromoteF32`.
- **New `TrapReason` variants** + their `rt_trap.spec_trap_message` substrings:
  `InvalidConversionToInteger` ("invalid conversion to integer", for NaN/Inf trapping
  trunc — distinct from `IntOverflow` for out-of-range), `UndefinedElement`
  ("undefined element", table index OOB), `UninitializedElement` ("uninitialized element",
  null slot).
- **The trapping-`Convert` ABI:** trapping float→int converts return `Result(Int,
  TrapReason)`; emit_core must learn which `ConvOp`s trap and wire `{ok,_}/{error,_}` +
  `case` + `rt_trap:raise` (like `idiv_s`). Non-trapping converts stay total.

`«RTNUM2-SIG-FROZEN»`: unit 01 also publishes the new `rt_num` float/convert function
**signatures** as `todo`-stubs (mirroring Phase-1's `«RTNUM-SIG-FROZEN»`) so unit 06 (bodies)
and unit 10 (emit mapping) don't race on names.

### E3 — Security & resource bounds for the new authority (fail-closed, *tested*)

- **No-wrap effective address.** `ea = addr (unsigned i32) + offset (static u32)` computed
  as a **bignum** (never reduced mod 2³²); trap iff `ea + access_bytes > current_byte_len`.
  Multi-byte stores trap **before any byte is written** (all-or-nothing). Test the wrap
  boundary (`addr = 0xFFFFFFFF` + large offset), the exact-length off-by-one, and a partial
  store (must trap with zero mutation). This is the classic OOB-corruption escape.
- **`memory.grow` resource cap (sandbox-escape fix).** The Safe profile imposes a **hard
  max-pages cap** (a finite default even when the module declares `max_pages: None`);
  `memory.grow` returns `-1` (the WASM-native failure) past the cap and never allocates;
  `grow` charges fuel **proportional to allocated bytes** (a big grow cannot be O(1)-cheap).
- **`call_indirect` no ambient authority.** Dispatch via **build-controlled** closures / a
  fixed funcidx→local dispatcher populated at instantiation from element segments — **never**
  `apply(Module, Fun, Args)` with `Module`/`Fun` drawn from table/runtime data. Three guards,
  each fail-closed and in order: index-in-bounds (else `UndefinedElement`), slot-non-null
  (else `UninitializedElement`), then **exact structural `FuncType` match** (else
  `IndirectCallTypeMismatch`). The structural codegen-security test (unit 10) is extended to
  assert this.
- **Per-instance isolation.** State is keyed per-instance and **reset on every
  (re)instantiation** (one-instance-one-process; fresh/zeroed memory+table). Runtime layers
  **fail-closed (trap) on an un-seeded cell** — never read garbage. Tested: two instantiations
  never observe each other's state.
- Memory is a BEAM **immutable binary** → it **cannot** be coerced into an out-of-bounds
  *host* read; a bounds-check bug's worst case is a wrong/missing trap or a node-safe process
  crash, never a host escape. rt_mem/rt_table/rt_state are tier P/O, never NIF.

### E4 — Differential `rebuild` oracle, held to the spec (not just consistency)

rt_mem ships a flat-binary **`rebuild` oracle** as the reference the **`paged`** impl is
differentially tested against. But a shared bug (wrong endianness, wrapped address, missing
zero-fill) makes "paged ≡ oracle" pass while both are wrong — so the **oracle itself** is
held to explicit spec-corner tests (LE multi-byte layout, zero-fill of grown/never-written
bytes, no-wrap address, trap-before-write, grow `-1`), **and** the official `memory_trap`/
`address`/`endianness` `.wast` are enabled at the rt_mem unit, not only the capstone.

### E5 — Instantiation is a first-class contract (frozen in unit 01)

Phase 1's run-ABI is `load → apply` (no init step). Phase 2 needs `load → **instantiate** →
invoke`. Unit 01 freezes the contract; units 10 (emit the entry) and 11 (the run-ABI + harness)
implement it:

- The backend emits a generated **`instantiate/N` entry** that, in WASM spec order, (1) seeds a
  **fresh** per-instance cell (fresh `mem`/`table` built by `rt_mem:fresh`/`rt_table:new` and
  handed to `rt_state:seed`; globals from their constant inits), (2) writes active **element**
  segments into the table, (3) writes active **data** segments into memory, (4) runs the
  **start** function — bounds-checking each active segment, **trapping at instantiation** on
  OOB (`TableOutOfBounds` / `MemoryOutOfBounds`), and propagating a trapping `start`. (Phase-2 const-init exprs are **constant literals**
  — `t.const`; imported-global init exprs are deferred with imports.)
- `pipeline.gleam`'s run-ABI **and** the conformance `Driver` both change to
  `load → instantiate → invoke`; the `Instance` carries the per-instance id / process context;
  the runner models instantiation-time traps and cross-invoke state persistence.

### E6 — Stateful ops are effects (optimizer barrier)

`MemLoad`/`MemStore`/`MemGrow`/`GlobalGet`/`GlobalSet`/`CallIndirect` are **side-effecting,
non-reorderable, non-CSE-able**. The future optimizer (Phase 3) must treat them as memory
barriers (no CSE of a load across a store; no reorder across a grow; no dead-store elimination
without an aliasing proof). Cheap to state now, expensive to retrofit after an optimizer ships.

### E7 — WASM 1.0 completeness gaps Phase-1 silently dropped (fold into decode/lower)

- The **integer/bit conversions** `i32.wrap_i64` (0xA7), `i64.extend_i32_s/u` (0xAC/0xAD),
  and the **4 reinterprets** (0xBC–0xBF) are **not decoded today** (the IR ConvOps + rt_num
  bodies exist, but the AST/decoder lack them). The 0xA7–0xBF block interleaves int+float —
  unit 07 scopes the **full block**, not "float opcodes."
- **`select`** (0x1B) is decoded+validated but `lower.gleam` returns `Unsupported` — lower it
  (to `If`). `select_t` (0x1C, typed) is **deferred** with reference types (skip those asserts).
- **memarg alignment validation:** decode both `align` + `offset`; validate `2^align ≤
  access-byte-width` (`align.wast` `assert_invalid`); discard `align` after (non-semantic).
- **`start` section** (id 8) + the **active data/element** sections (ids 9/11) + the **table**
  (id 4) / **global** (id 6) sections decode and drive instantiation (E5).
- **Non-function imports** (memory/table/global) and the spec `spectest` module: **deferred to
  Phase 3** — the runner skips the dependent assertions with a logged reason (honest-skip).

### E8 — Honest scope

See §1. Tier-O cell (not tier-P); non-function imports / reftypes / bulk-memory / multi-memory
/ SIMD / WAT-parser / optimizer / Unsafe deferred; CPU fuel still observe-only but **memory
exhaustion fixed**.

---

## 3. Dependency DAG — freeze milestones

```
WAVE 0   01 KEYSTONE (one owner): «IR2-FROZEN» (types+grammar+trap reasons) ·
            «CELL-STATE-ABI-FROZEN» (cell convention + state-access seam + instantiation
            contract + Binding fields + safe profile lands green) · «RTNUM2-SIG-FROZEN»
                 │                    │                    │
   ┌─────────────┼────────────────────┼─────────────┬──────┴────────┐
   ▼ (fast-follow)                     ▼ cell-iface  ▼ rtnum2-sig     ▼ «IR2»+ABI freezes
 ┌──────────┐  ┌───────────┐  ┌───────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐
 │02 .ir    │  │03 rt_state│  │04 rt_mem  │  │05 rt_tab+ │  │06 rt_num │  │10 emit + │
 │printer/  │  │ +globals  │  │ paged +   │  │ call_ind. │  │ floats   │  │instantiate│
 │parser ext│  │ +lifecycle│  │ oracle    │  │ dispatch  │  │ bodies   │  │ entry    │
 └──────────┘  └───────────┘  └───────────┘  └──────────┘  └──────────┘  └──────────┘
   WAVE A         WAVE A         WAVE A         WAVE A        WAVE A        WAVE B (∥ A!)
                                                                                │
 ┌──────────┐  publishes «WASM-AST2» (day 1)         ┌──────────┐  ┌──────────┐
 │07 decode │──────────────────────────────────────▶│08 validate│  │09 lower  │
 │ ext      │  (AST types) ───────────────┬─────────▶│ ext (AST  │  │ ext (AST │
 └──────────┘                             │          │ only)     │  │ +IR2)    │
   WAVE A                                  └─────────▶└──────────┘  └──────────┘
                                                        WAVE B         WAVE B
        ┌────────────────────────────────────────────────────────────────┐
WAVE C  │ 11 CAPSTONE: load→instantiate→invoke run-ABI + harness upgrade + │
        │  Safe profile (mem/table/state + max-pages cap) + Phase-2 .wast  │
        │  allowlist + acceptance corpus + refresh the conformance image   │
        └────────────────────────────────────────────────────────────────┘
```

- **emit_core (10) runs in parallel with the runtime units (03–06)** — it needs only the
  *frozen signatures* (`«IR2-FROZEN»` + `«CELL-STATE-ABI-FROZEN»` + `«RTNUM2-SIG-FROZEN»`),
  not their implementations. Do not serialize it behind them.
- **validate (08) is AST-only** (the security boundary) — it gates on `«WASM-AST2»` (07's
  type stub, published day 1), not on completed decoding, and parallels the IR work.
- The printer/parser impl (02) is a **fast-follow off the freeze critical path** (the *types*
  + grammar unblock everyone; the round-trip test gates nothing downstream).

---

## 4. File-ownership map (D1)

> Single owner per file. Several units **extend** Phase-1 files (single-owner, additive). The
> keystone makes deliberate, documented cross-file reaches (it must, to land green).

| File | Owner | Notes |
|---|---|---|
| `src/twocore/ir.gleam` | **01** | Extend: tables/elem, MemSize/MemGrow, load result-width, float NumOp/ConvOp, TrapReasons. `«IR2-FROZEN»`. |
| `src/twocore/runtime/instance.gleam` | **01** | Extend `Binding` (mem/table/state modules) + `safe_default`. |
| `src/twocore/runtime/rt_trap.gleam` | **01** *(reach)* | Add the 3 new `spec_trap_message` mappings (exhaustive match). |
| `src/twocore/runtime/profiles.gleam` | **01** *(reach)* + **11** | 01 updates `profiles.safe` so the Binding extension compiles green; 11 owns the Safe-profile wiring + max-pages cap. |
| `src/twocore/runtime/rt_num.gleam` | **01 → 06** | 01 freezes the new float/convert signatures (`todo`); 06 fills bodies. |
| `specs/phase-2/ir2-grammar-delta.md` | **01** | The `.ir` grammar additions (frozen with the types). |
| `src/twocore/ir/printer.gleam`, `ir/parser.gleam` | **02** | Extend for the new variants; keep round-trip green. |
| `src/twocore/runtime/rt_state.gleam` | **03** | The per-instance pdict cell holder (opaque `{mem,globals,table}`), fresh/reset, fail-closed, + mutable global cells; the instance-lifecycle helpers. |
| `src/twocore/runtime/rt_mem.gleam` | **04** | `paged` + `rebuild` oracle; no-wrap bounds-check; load/store/size/grow; data-write; the differential suite. |
| `src/twocore/runtime/rt_table.gleam` | **05** | Table value + the 3-fault fail-closed `call_indirect` dispatch (build-controlled); element-write. |
| `src/twocore/frontend/wasm/ast.gleam`, `wasm/decode.gleam` | **07** | Decode the table/memory/global/element/data/start sections + the full opcode set (load/store matrix, size/grow, 0xA7–0xBF conversions, floats, select, global/table ops). `«WASM-AST2»` day 1. |
| `src/twocore/frontend/wasm/validate.gleam` | **08** | Typing for all new ops; memarg alignment; const-expr validation. AST-only. |
| `src/twocore/frontend/wasm/lower.gleam` | **09** | Lower the new ops to IR2 (named labels); lower active data/element/global-init + `select`; the (constant-literal) const-expr lowering. |
| `src/twocore/backend/emit_core.gleam` | **10** | Lower mem/global/table/size/grow/call_indirect + the new float NumOp/ConvOp via the state-access seam; trapping-convert case/raise; zero-result ordered effects; emit the `instantiate/N` entry; extend the security-invariant test. |
| `src/twocore.gleam`, `src/twocore/pipeline.gleam` | **11** | Run-ABI → `load→instantiate→invoke`; CLI. |
| `test/twocore/conformance/**`, `vendor/ALLOWLIST`, `vendor.sh` | **11** | Per-file flag column; the Phase-2 allowlist + within-file skip lists; acceptance corpus; refresh `docs/wasm-conformance.svg`. |

> **rt_state vs globals:** globals **are** instance state → handled by `rt_state` (no separate
> `rt_global` module, no extra Binding field). `GlobalGet/Set` call the state module.
> `rt_state` is an **opaque** per-instance cell holder; `rt_mem` owns the page-map value shape,
> `rt_table` owns the table value shape — all opaque to `rt_state`, so 03/04/05 stay parallel.

---

## 5. How to claim & complete (same as Phase 1)

Read this page → your unit doc → [`specs/state.md`](../state.md). Set status `in-progress`;
confirm your freeze milestones; build to the Definition of Done (D8: spec-cited tests, doc
comments, `gleam format` clean, **zero warnings**, the unit's conformance/interface suite);
update `state.md` with what you leave. When in doubt about a foundational decision, **ask the
planner** rather than guessing. The manager QA-gates (`format`/`build`/`test`) and commits each
unit.

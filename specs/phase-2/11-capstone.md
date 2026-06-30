# Unit 11 — Capstone: run-ABI, linker/Safe profile & conformance

> **1–3 owners · Wave C (last) · depends on the freezes of ALL of 01–10.** Read
> [`00-overview.md`](00-overview.md) (E1–E8), [`01-interface-freeze.md`](01-interface-freeze.md)
> (the cell ABI + instantiation contract), and Phase-1 [`07`](../phase-1/07-conformance-harness.md)
> (the harness you extend) first. Phase 1 is complete and green: **313 tests, 0 warnings,
> conformance 1740 / 1359 / 0**.

---

## Context

Phase 1's run-ABI is `load → apply` because Phase-1 generated code is **pure** — no memory,
no globals, no tables, no init step. Phase 2 introduces the first **mutable instance state**
(E1, the `cell` strategy: the page-map / globals / table live in **the instance process's
process dictionary** under one fixed key) and therefore a real **instantiation** step. The
generated `instantiate/0` (emitted by unit 10) seeds a fresh cell, evaluates global inits,
writes active data/element segments, and runs `start` — and any of those can **trap at
instantiation**. State is **process-local**, so an instance's `instantiate` and every one of
its invokes **must run in one owned process** (one-instance-one-process), or an export reads
the caller's empty pdict and silently returns garbage.

This unit is the capstone: it turns the run-ABI into `load → instantiate → invoke` with
per-instance isolation, wires the Safe profile's new runtime layers + the hard max-pages cap,
and **proves** Phase-2 with an expanded conformance allowlist and a real memory/table/global/
float acceptance corpus running on the BEAM.

## Goal

`load → instantiate → invoke` with one-instance-one-process isolation; the Safe profile wired
to `rt_mem`/`rt_table`/`rt_state` with a finite **hard max-pages cap**; the Phase-2 spec-suite
allowlist (memory, call_indirect, globals, full floats) and acceptance corpus **green, fail=0**,
with documented honest skips; the conformance image refreshed and the new numbers reported.

## Files owned

- `src/twocore.gleam` — the CLI `run` subcommand (load → instantiate → invoke).
- `src/twocore/pipeline.gleam` — the run-ABI: `instantiate` + `invoke` in the owning process.
- `src/twocore/runtime/profiles.gleam` — Safe-profile wiring + the **max-pages cap** policy.
- `test/twocore/conformance/**` — the runner (`runner.gleam`), the real `driver.gleam`,
  `fixture.gleam` (new instantiation-trap command), `conformance_test.gleam`, `corpus_test.gleam`,
  the within-file skip predicate, and `corpus/*` (the new acceptance programs).
- `test/twocore/conformance/vendor/ALLOWLIST` — the Phase-2 allowlist + a per-file flag column.
- `test/twocore/conformance/vendor/vendor.sh` — pass the per-file flag to `wast2json`.
- `docs/wasm-conformance.svg` — regenerated; its generator `scripts/gen-conformance-svg.sh`
  footnote text updated to Phase-2 scope (co-located refresh, additive only).
- A test/CLI FFI seam for one-instance-one-process (extend `test/twocore_conformance_ffi.erl`
  and `src/twocore_cli_ffi.erl` — both `twocore_`-prefixed, single-owned by this unit).

> No publish-day-1 stub here — this is the terminal unit. It consumes every freeze; it
> produces nothing downstream depends on.

## Depends on

- `«CELL-STATE-ABI-FROZEN»` (01) — the instantiation contract, the cell convention, and the
  `Binding` fields `mem_module`/`table_module`/`state_module` (01 already populates them in
  `safe_default`/`profiles.safe` to compile green; you finalize the wiring + cap).
- Unit 10 — the generated **`instantiate/0`** entry and the stateful-op codegen.
- Units 03/04/05/06 — `rt_state` (cell + lifecycle), `rt_mem` (paged + cap), `rt_table`
  (3-fault dispatch), `rt_num` (float bodies).
- Units 07/08/09 — decode/validate/lower of the memory/table/global/float surface.
- **Stub against meanwhile:** the harness plumbing (allowlist, `vendor.sh` flag column,
  fixture parsing, the within-file skip predicate, the one-instance-one-process FFI, the
  acceptance `.wat`/`.expected` files) is **pure plumbing** — build it against the existing
  `driver.stub()` and re-point at `driver.pipeline()` when 03–10 land. The run-ABI shape can
  be coded against the frozen `instantiate/0` contract before unit 10 finishes.

## Scope — in / out for Phase 2

**In:** the `load → instantiate → invoke` run-ABI; one-instance-one-process isolation +
reset-on-(re)instantiation; Safe profile wiring + the finite max-pages cap (E3, fail-closed);
the Tier-A allowlist + Tier-B `align --enable-memory64`; the within-file structural skip lists;
the acceptance corpus; the refreshed image.

**Out (E8 deferrals — record, do not add):** the tier-P `threaded` build; non-function
**imports** + the `spectest` module (so `linking`/`imports`/global-import `.wast` stay skipped);
**reference types** (`elem.wast`, `table_get/set/copy/fill.wast`, `table_init.wast`); **bulk
memory** (`memory_fill/copy/init.wast`); **multi-memory** (`memory.wast`, `table.wast`,
`memory_grow.wast` — un-convertible / multi-memory at the pin); SIMD/memory64/GC; the WAT
parser; the optimizer; the Unsafe profile; CPU-fuel enforcement (still observe-only).

## Deliverables

### A. Run-ABI — `load → instantiate → invoke`, one-instance-one-process

The cell is process-local, so an instance owns a process; `instantiate/0` and every invoke run
**inside it**. Add a `twocore_`-prefixed Erlang FFI seam (in the conformance + CLI shims):

```erlang
start_instance(Module) -> {ok, Pid} | {error, Reason}   %% spawn; run Module:instantiate() IN
%%   the spawned process (seeds ITS pdict cell); on a trap reply {error, RenderedReason};
%%   on success enter the receive loop holding the cell for the instance's lifetime.
call_instance(Pid, Fun, Args) -> {ok, V} | {error, Reason}  %% message round-trip: the instance
%%   process runs apply(Module, Fun, Args) in ITS OWN process (reads ITS cell), replies.
stop_instance(Pid) -> nil.                               %% kill the process → cell auto-GC'd.
```

The instance-process loop, schematically:

```erlang
spawn(fun() ->
  case (try {ok, Module:instantiate()} catch _:R -> {error, render(R)} end) of
    {error, Why} -> Parent ! {started, {error, Why}};       %% instantiation-time trap
    {ok, _}      -> Parent ! {started, {ok, self()}}, loop(Module)
  end end).
loop(M) -> receive {invoke,F,A,From} ->
             From ! {result, (try {ok, apply(M,F,A)} catch _:R -> {error, render(R)} end)},
             loop(M);
           stop -> ok end.
```

- **`pipeline.gleam`:** change the run-ABI to `load → instantiate → invoke`. Add
  `instantiate(beam, mod) -> Result(InstanceProc, String)` (loads the module **once**
  globally via `build_beam.load_module`, then `start_instance` — `Error(reason)` surfaces an
  instantiation-time trap). `invoke(proc, export, args) -> RunResult` routes through
  `call_instance`. `run_source` composes `source_to_ir → ir_to_core → core_to_beam →
  instantiate → invoke`. Keep the raw-bit-pattern argument/result ABI unchanged (D5).
- **`twocore.gleam`:** `run` reports an instantiation trap as `trap: <reason>` (exit non-zero),
  identical surfacing to a runtime trap.
- **The conformance `Driver` / `Instance`:** `runner.Instance` carries the **`InstanceProc`**
  (the owning pid) instead of a bare module atom. `driver.instantiate` compiles+loads, then
  `start_instance` — returning `Error(reason)` on an instantiation trap (no longer always
  `Ok`). `driver.invoke` runs the export via `call_instance` in the owner process. **(Re)defining
  a module spawns a fresh process → a fresh zeroed cell** (isolation + reset are automatic).
  Cross-invoke state **persists** because successive invokes hit the same process's pdict.
- **Honest instantiation-trap modeling:** add a `fixture.AssertUninstantiable(line, filename,
  text)` command (the spec's `assert_uninstantiable`; the OOB-active-segment case the modern
  spec frames as a runtime trap at instantiation / the legacy `assert_unlinkable`). Its runner
  arm loads + `start_instance`s the module and asserts it **fails to instantiate** with a trap
  whose spec phrase contains `text` (via `runner.trap_matches`). A success = a fail; the
  existing `Unhandled → skip` path no longer silently drops these.

### B. Profiles — Safe wiring + the hard max-pages cap (E3, fail-closed)

`profiles.safe()` returns the `Binding` with `mem_module="twocore@runtime@rt_mem"`,
`table_module="twocore@runtime@rt_table"`, `state_module="twocore@runtime@rt_state"` (01
populated these; confirm they are live and used by `driver.pipeline()` — switch the driver
from a bare `safe_default()` to `profiles.safe()` so the Phase-2 layers are wired). Add the
**hard max-pages cap** as the single source of Safe policy:

```gleam
/// The Safe-profile hard cap on linear-memory pages: a FINITE default that applies even
/// when the module declares `max_pages: None`. Untrusted code cannot allocate unboundedly
/// (E3). `memory.grow` past it returns -1 and allocates nothing; `grow` charges fuel
/// proportional to allocated bytes. Must be ≤ 65536 (the 2^16-page / 4 GiB address cap).
pub fn safe_max_pages() -> Int { ... }   // a finite default, e.g. a few hundred pages
```

The effective memory max at seed time is `min(declared_max ?? safe_max_pages(),
safe_max_pages(), 65536)`. The **mechanism** (grow returns `-1` past the effective max, never
allocates) lives in `rt_mem`/`rt_state` seeding (P2-04). **Fail-closed:** there is no
constructor in `profiles.gleam` that yields an unsafe posture; add a test asserting the Safe
cap is finite and that `profiles` exposes no way to lift it. (Coordinate with P2-04 so the cap
value is single-sourced — see the planner note in this unit's closing.)

### C. Conformance — the Phase-2 allowlist, the flag column, the within-file skips

- **`vendor/ALLOWLIST`** gains an optional **trailing flag column** (whitespace-separated):
  `align<TAB>--enable-memory64`. Tier-A entries stay flagless.
- **`vendor.sh`** today runs `wast2json "$src" -o "$out"` with no flags; parse the flag column
  and pass it through (`wast2json $flags "$src" -o "$out"`). Leave the un-convertible/multi-mem
  files **out of the allowlist** (they auto-skip-or-aren't-listed; honest file-level gap).
- **Within-file skips** live in the runner as a `should_skip(file, command) -> Option(reason)`
  predicate **keyed to STRUCTURAL PATTERNS, never line numbers** (the pin auto-updates monthly;
  line numbers are fragile). A skipped assertion is **counted as skip with a reason — never
  silently passed**. Most fall out of existing fail-closed paths (a reftype/multi-table/extended-
  const module fails decode/validate → its dependent asserts skip; `assert_exhaustion` →
  `Unhandled` skip; text `module_type` → the existing `TextModule` skip). The **one** that needs
  an explicit predicate is `align`'s 2 memory64 `assert_invalid`: enabling `--enable-memory64`
  flips them from invalid → **valid**, so our MVP-strict decoder rejecting them is a *false pass*
  — skip any `assert_invalid` whose module our decoder rejects with the **64-bit-memarg-offset**
  decode error (structural, pin-robust).
- **`conversions.wast`** is **already allowlisted** — do **not** re-add it. The Phase-2 work is
  to **stop skipping** its 67 trapping float→int asserts and its convert/promote/demote/
  non-saturating-trunc returns, which now pass because unit 06 lands the float bodies.
- `conformance_test.gleam` already globs every `*.json` in `fixtures/` and gates `fail==0 &&
  pass>0`; the new files flow in automatically once vendored. Update its skip-reason histogram
  framing (and the SVG footnote) from "Phase-1 slice" to the Phase-2 remaining-skip set.

### D. Acceptance corpus — real programs on the BEAM through `load → instantiate → invoke`

Authored `corpus/<name>.wat` (built with `wat2wasm`) + `<name>.expected` (values sourced from
the spec `.wast` / wasmtime, cited in `#` comments). Phase-2's decoder decodes these as real
`.wat` (no hand-built IR needed, unlike Phase-1's float/host cases). Extend `corpus.gleam` with
an **`InstantiateTraps(text)`** expectation (`instantiate => trap <text>`), distinct from the
existing compile-time `Rejects`. Programs:

| # | Program | Proves |
|---|---|---|
| 1 | memory round-trip + OOB | `i32.store` then `i32.load` round-trips; an OOB load **and** a partial multi-byte store **trap** ("out of bounds memory access"), store with zero mutation |
| 2 | `call_indirect` 3 faults | right type runs; wrong type → "indirect call type mismatch"; OOB index → "undefined element"; null slot → "uninitialized element" |
| 3 | mutable global | `global.set` then `global.get` round-trips a mutable global (immutable `global.set` already rejected at validation by unit 08) |
| 4 | growable / cap | `memory.grow(1)` returns old size; `memory.size` reflects it; a grow past `safe_max_pages()` returns `-1` and does not allocate |
| 5 | trapping trunc | `i32.trunc_f32_s(NaN/Inf)` → "invalid conversion to integer"; out-of-range → "integer overflow"; in-range truncates |
| 6 | cross-instance isolation | a dedicated `corpus_test` fn instantiates the **same** module **twice** (two processes); writes/global-sets in one are invisible to the other |
| 7 | trapping-start | a module whose `start` traps (or an OOB active data segment) **fails to instantiate** (`instantiate => trap …`) |

Add a **store-in-a-loop constant-space** test (a `memory.store` every iteration for ~100k
iterations) asserting constant process memory — proving the cell preserves the Phase-1
tail-loop / preemption property for the *actual* memory path (not inferred from `rt_meter`).

## Grounded facts you MUST honor (verified at the pin — transcribe faithfully)

Pin: `WebAssembly/testsuite @ 193e551ff22663995b1ac95dc62344133669e14b` ("Auto-update for
2026-06-17"), wabt **1.0.41**, wasmtime 46.0.1 — a **WASM-3.0-era** testsuite. **"Root file
name == MVP" is FALSE here.** All counts below were measured by running `wast2json` at the pin.

**Tier A — ADD, plain `wast2json` (no flags), pure-MVP or MVP-with-named-skips:**

```
memory_trap        # 180: 170 assert_trap OOB load/store — the bounds-check workhorse
address            # 256: 206 ret + 49 trap — i32/i64/f32/f64 load/store w/ static offset
endianness         # 68:  little-endian load/store of every width
float_memory       # 84:  f32/f64 load/store incl NaN-bit preservation (D5)
memory_size        # 38:  memory.size + MVP memory.grow growth semantics
memory_redundancy  # 7:   load/store aliasing / no-spurious-reorder
call_indirect      # 169: SKIP 2 assert_exhaustion + the reftype multi-table module
global             # 114: SKIP ~6 externref/funcref asserts + 2 extended-const inits ($z3,$z5)
f32 f64 f32_cmp f64_cmp f32_bitwise f64_bitwise float_misc float_exprs   # full scalar floats
float_literals     # 99 ret in scope; SKIP its 78 assert_malformed (module_type=text, not binary)
# conversions is ALREADY allowlisted — do NOT re-add; STOP SKIPPING its 67 traps
#   (35 "integer overflow" + 32 "invalid conversion to integer") + convert/promote/demote/trunc
```

**Tier B — ADD with a per-file feature flag (needs the ALLOWLIST/`vendor.sh` flag column):**

```
align  --enable-memory64   # 140 total; run 47 ret + 1 trap + ~42 invalid + 48 malformed;
#   SKIP the 2 memory64 assert_invalid (64-bit offset 0xFFFF_FFFF_FFFF_FFFF) — enabling the
#   flag makes them VALID, so running them is a false failure.
```

**Tier C — DEFER (record as honest gaps, do NOT add):** `memory.wast` / `table.wast` —
**un-convertible** even with `--enable-all` (the script-level `(module definition …)` construct
+ `0x1_0000_0000` page literals / typed-ref `(ref null func)`); `memory_grow.wast` — **100%
multi-memory** at the pin (3 modules, explicit `$mem` index on all 47 asserts) → **MVP grow
coverage comes from `memory_size.wast`**, not here; `elem.wast` (function-references);
`memory_fill/copy/init.wast` (bulk-memory); `table_get/set/copy/fill.wast` (reftype runtime);
`table_init.wast` (un-convertible, GC `array`/`arrayref`).

**Within-file skip lists (key to structure, never line numbers — pin-fragile):**
`call_indirect` {2 `assert_exhaustion`; the 3 explicit-table-index `call_indirect` + their
multi-table module}; `global` {externref/funcref get asserts; `$z3`/`$z5` extended-const-init
modules}; `align` {2 memory64 `assert_invalid`}; `float_literals` {78 text-format
`assert_malformed`}. These map to features the IR/decoder/validator **deliberately lack**.

**Pitfalls (every one bit someone at the pin):**

- `wabt 1.0.41` enables **reference-types + bulk-memory by default**, so `table_*`/`memory_fill`/
  `memory_copy`/`memory_init` **convert plain yet are out of scope** — gate DEFER on whether the
  IR supports the ops, **not** on whether `wast2json` succeeds. "Converts plain" ≠ "is MVP".
- Enabling a flag to make a file **parse** can invalidate that file's baked-in `assert_invalid`
  (align's 2 memory64 cases) — **skip**, don't run.
- `~12,800` new runnable assertions, but **~93 % are scalar floats**. The architecturally-hard,
  genuinely-new runtime work is only **~860** (memory ~630 + `call_indirect` ~129 + global ~59):
  memory_trap 180 + address 255 + endianness 68 + float_memory 84 + memory_size 36 +
  memory_redundancy 7. Don't let the float count make the memory/table/global runtime look done.
- **Honest-skip, never silent-pass.** A skip is "assertion not run + counted as skip with a
  reason"; never count it as a pass.

**Spec trap phrases (already mapped by `rt_trap.spec_trap_message`, units 01/09):**
`MemoryOutOfBounds → "out of bounds memory access"`, `IndirectCallTypeMismatch → "indirect call
type mismatch"`, `UndefinedElement → "undefined element"`, `UninitializedElement →
"uninitialized element"`, `InvalidConversionToInteger → "invalid conversion to integer"`,
`IntOverflow → "integer overflow"`. Instantiation order (exec/modules.html): globals → active
elements → active data → `start`; an active segment whose `[offset, offset+n)` exceeds the
table/memory bound **aborts instantiation** (no partial write).

## Verification — Definition of Done (D8)

- **Acceptance corpus green** through `load → instantiate → invoke`: all 7 programs + the
  cross-instance-isolation test + the store-in-loop constant-space test pass on the BEAM. Tests
  assert **spec behavior**, citing the spec — memory bounds-check trap & instantiation order
  (<https://webassembly.github.io/spec/core/exec/instructions.html>,
  <https://webassembly.github.io/spec/core/exec/modules.html>); `call_indirect`'s 3 ordered
  traps (exec/instructions.html); trapping trunc (exec/numerics.html); global immutability
  (valid/instructions.html). **No change-detector tests** — values come from the `.wast`/wasmtime,
  not from whatever the code emits.
- **Expanded conformance runs `fail=0`** with the documented honest skips, and the new files
  produce real passes (the Tier-A memory/call_indirect/global/float files move skip → pass).
  Run `vendor.sh` (it must report the new files OK + the deferred set skipped) then the
  `conformance_test` gate (`fail==0 && pass>0`).
- **Safe cap proven fail-closed:** the growable program hits the cap (`grow` returns `-1`, no
  allocation); a test asserts `safe_max_pages()` is finite and `profiles` exposes no unsafe
  posture.
- **`gleam format --check src test` clean; `gleam build` ZERO warnings; `gleam test` stays
  green (≥313, now higher).** CI already runs `vendor.sh` + the full conformance — keep it green.
- **Refresh the image:** `RUN_VENDOR=1 scripts/gen-conformance-svg.sh`, commit
  `docs/wasm-conformance.svg`, and **report the new pass/skip/fail numbers** (the headline jumps
  as ~12.8k float + ~860 runtime assertions move skip → pass).

## Concurrency

Three near-independent sub-tasks, all buildable against `driver.stub()` before 03–10 land:

1. **Run-ABI + one-instance-one-process** (`pipeline.gleam`, `twocore.gleam`, `profiles.gleam`,
   the FFI shims, the fixture instantiation-trap command + runner arm). Needs the frozen
   `instantiate/0` contract (01/10).
2. **Conformance plumbing** (`ALLOWLIST` flag column, `vendor.sh`, the within-file structural
   skip predicate, `conformance_test` framing). Pure plumbing — no compiler dependency.
3. **Acceptance corpus** (`corpus/*.wat`/`.expected`, `corpus.gleam` `InstantiateTraps`,
   `corpus_test`). Needs 03–10 to actually run, but the `.wat`/`.expected` can be authored early.

**Must be frozen first:** the generated `instantiate/0` (10), the cell ABI + instantiation
contract + `Binding` fields (01), and the `rt_mem` cap mechanism (04). Re-point the stub driver
at `driver.pipeline()` once they are green.

## What this leaves for others

Phase 3: the tier-P `threaded` state build; non-function **imports** + the `spectest` module
(unblocks `linking`/`imports`/global-import `.wast`); **reference types** (`elem.wast`,
`table_get/set/copy/fill.wast`, `table_init.wast`, typed `select_t`); **bulk memory**
(`memory_fill/copy/init.wast`, `data.drop`); **multi-memory** (`memory.wast`, `table.wast`,
`memory_grow.wast`); SIMD / memory64 / GC; the WAT text parser; the optimizer (the E6 effect
barriers are already recorded); the Unsafe profile; CPU-fuel **enforcement** (still observe-only).
A future deliberate **pin bump** to a wabt release that parses `(module definition …)` could
recover the un-convertible `memory.wast`/`table.wast` — a reviewed change, not a default.

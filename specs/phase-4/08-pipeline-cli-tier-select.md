# Unit 08 — pipeline binding-threading + CLI tier/strategy selection (decision #5)

> **One owner. Wave B. The pipeline/CLI application seam for the two Phase-4 axes.** Depends on
> **FREEZES ONLY** — `«STATE-STRATEGY-FROZEN»` (`Binding.state_strategy` + `StateStrategy`) and
> `«MEM-TIER-FROZEN»` (`Binding.mem_tier`/`table_tier` + the tier→module map + the
> Safe-forbids-nif `validate_binding` shape), both from unit 01. It needs those *signatures* +
> unit 07's *profile constructors*, not the threaded codegen (02), the tier bodies (04/05/06),
> nor the differential (09) — so it does **not** serialize behind them. Read
> [`00-overview.md`](00-overview.md) (G1–G8), [`01-interface-freeze.md`](01-interface-freeze.md)
> (the frozen surface), then the Phase-1/2/3 overviews (D1–D10, E1–E8, F1–F8) and the analog
> [`../phase-3/09-emit-pipeline-opt.md`](../phase-3/09-emit-pipeline-opt.md).

---

## Context

Phase 4 adds **no new pipeline stage** and **no new IR node** (G7). The two new axes —
`state_strategy` (§A, G1) and `mem_tier`/`table_tier` (§B, G2) — are **build-time fields on the
one `Binding`** that already threads through every stage. So this unit is pure *plumbing*: three
jobs, none of which touches the middle of the pipeline.

1. **The pipeline threads the chosen `Binding` unchanged.** `source_to_ir → lower_ir →
   optimize_ir → ir_to_core (emit_core) → core_to_beam` already carries `binding` end-to-end
   (`pipeline.gleam`). The tier is consumed **only** at `emit_core` (which reads the
   `binding.*_module` name the linker resolved for the chosen tier — G5, tier-agnostic codegen)
   and by the **linked runtime module** at run time. There is **no new stage and no new
   `PipelineError` variant** — the Phase-4 fields ride the existing seam, exactly as the Phase-3
   policy fields did (unit 09). This unit *documents and locks* that the threading is unchanged.

2. **The CLI selects a profile / strategy / tier.** New flags on the compile verbs pick a
   composed deployment profile (`--portable`, `--ceiling`) or apply the two axes orthogonally
   (`--threaded` for `state_strategy`, `--tier paged|atomics|nif` for `mem_tier`, `--table-tier
   paged|ets|atomics` for `table_tier`), on top of the existing `--unsafe` policy flag. The
   default is the fail-closed **Safe / `Cell` / `Paged`** posture (D4) — every non-default
   posture must be **named**. `--tier nif` without an Unsafe base is **rejected at the CLI**
   fail-closed (G6, `validate_binding`).

3. **The run-ABI works under `Threaded` + `atomics`.** Under `state_strategy: Threaded` the
   instance state travels as a **value** (`rt_state.InstanceState`), not in the pdict cell (G1) —
   the generated `instantiate/0` *returns* the record and each invoke threads it (keystone §A.3).
   The owned-process run-ABI (`pipeline.gleam` + `twocore_cli_ffi.erl`) must carry the record
   through `load → instantiate → invoke` so a `Threaded`/`atomics` build runs **byte-identically**
   to `Cell`/`paged` end-to-end.

The load-bearing correctness claim (proven corpus-wide by capstone 11, G7): **every shipped
`(state_strategy × mem_tier × table_tier × policy)` combination is runnable end-to-end from the
CLI, byte-identically.** This unit builds the surface; the differential is unit 09's.

---

## Deliverables & freeze milestones

**Consumes:** `«STATE-STRATEGY-FROZEN»` (`Binding.state_strategy`, `StateStrategy = Cell |
Threaded`) and `«MEM-TIER-FROZEN»` (`Binding.mem_tier`/`table_tier`, `MemTier = Paged | Atomics |
Nif`, `TableTier = TablePaged | TableEts | TableAtomics`, the tier→module map §B.1, the
`validate_binding` shape §B.4) — all from unit 01, all landed green with `safe_default() =
Cell/Paged/TablePaged`. From unit 07 (parallel Wave B): the composed profiles `profiles.portable()`
/ `profiles.ceiling()`, the single coherent tier→module coupler `profiles.resolve_tiers` (P5, §A.2 —
makes `mem_module`/`table_module` follow the declared tiers), the fail-closed `validate_binding`,
and `link/1` — the **sole** `Binding → Instance` seam (§B.2/§C — their *shapes* are keystone-frozen;
unit 08 stubs against them until 07 lands, exactly as unit-09 stubbed against `profiles.unsafe()`).

**Produces (no downstream freeze — application/wiring, not a contract):** the pipeline
**binding-threading lock** (`pipeline.gleam` doc + a no-new-stage test); the **strategy-aware
run-ABI** (`instantiate`/`invoke_instance` carry the `InstanceState` record under `Threaded`; the
extended `twocore_cli_ffi.erl` threaded loop); the **CLI axis surface** (`--portable`/`--ceiling`/
`--threaded`/`--tier`/`--table-tier` + `resolve_binding` + the fail-closed Safe-forbids-nif CLI
rejection + refreshed `usage()`); the three wiring tests.

---

## Files owned (single-owner-additive)

- `src/twocore/pipeline.gleam` — **EXTEND.** Make the run-ABI (`instantiate`/`invoke_instance`/
  `run_source`) strategy-aware (§C); add the binding-threading lock doc. (This unit's owner in
  Phase 4; the additive growth of the Phase-1/3 file.)
- `src/twocore.gleam` — **EXTEND.** Add the `--portable`/`--ceiling`/`--threaded`/`--tier`/
  `--table-tier` flags, the `resolve_binding` composer, and the refreshed `usage()`.
- `src/twocore_cli_ffi.erl` — **EXTEND.** Add the `Threaded` process loop (thread the returned
  `InstanceState` record across invokes). This is the run-ABI shim owned by the pipeline+CLI unit
  (created by Phase-1 unit 11c; a hand-written support shim, not a unit-owned Gleam source file).
- `test/twocore/cli_test.gleam`, `test/twocore/pipeline_opt_test.gleam` (or a new
  `test/twocore/pipeline_tier_test.gleam`) — the new wiring tests.

**Not owned (consumed):** `runtime/instance.gleam` (keystone — read the axis fields, never edit),
`runtime/profiles.gleam` (unit 07 — call `portable`/`ceiling`/`resolve_tiers`/`validate_binding`/
`link`), `backend/emit_core.gleam` (unit 02 — the threaded codegen), the tier runtime
modules (04/05/06).

---

## Depends on (freeze milestones)

| Freeze | From | What you take | Stub against meanwhile |
|---|---|---|---|
| `«STATE-STRATEGY-FROZEN»` | 01 | `Binding.state_strategy`, `StateStrategy`. | `Cell` is the landed default; a `Threaded` binding is constructible immediately (`Binding(..profiles.safe(), state_strategy: Threaded)`), so the CLI selector + run-ABI signatures are testable before the threaded codegen (02) lands. |
| `«MEM-TIER-FROZEN»` | 01 | `Binding.mem_tier`/`table_tier`, `MemTier`/`TableTier`, the tier→module map (§B.1), `validate_binding` shape (§B.4). | `Paged`/`TablePaged` are the landed defaults; the `Atomics`/`Nif` bindings typecheck at the freeze, so `resolve_binding`'s composition + the Safe-forbids-nif rejection are testable before the tier bodies (04/05) land. |
| `profiles.portable()`/`ceiling()`/`resolve_tiers`/`validate_binding`/`link` | 07 | the composed profiles + the single coherent tier→module coupler (`resolve_tiers`, P5) + the fail-closed gate + the sole `Binding → Instance` seam (`link/1`). | Until 07 lands, `resolve_binding` sets the axis fields by record-spread then applies the keystone-frozen `resolve_tiers` (tier→module map) + `validate_binding` freeze body; `link` stubs as `validate_binding ∘ resolve_tiers ∘ instantiate`. |

**Not blocked on:** 02 (threaded codegen), 04/05/06 (tier bodies), 09 (differential). The run-ABI
threading (§C) needs only the frozen `Threaded` return contract (keystone §A.3), not the emitted
bodies; a `Cell`/`paged` build exercises the *unchanged* path today, and a `Threaded`/`atomics`
build runs end-to-end the moment 02/04 land — with **no** further pipeline or CLI change.

---

## Scope — in / out

**In:** the strategy-aware run-ABI (§C) + the binding-threading lock (§A); the CLI axis flags +
`resolve_binding` + the fail-closed default + the Safe-forbids-nif CLI rejection (§B); the
`twocore_cli_ffi.erl` threaded loop; the wiring tests. **Every existing stage stays independently
invokable** (decision #5).

**Out (do not build here):** the threaded `emit_core` seam / uniform export ABI (02); the tier
runtime bodies (04/05/06); the `portable`/`ceiling` constructors + `resolve_tiers`/
`validate_binding`/`link` **bodies** + tier→module ownership (07 — this unit *calls*
them); the corpus differential + constant-space-under-threaded proof (09); the benchmark (10).
**No new pipeline stage, no new `PipelineError` variant, no new IR node** (G7).

---

## A. The pipeline threads the chosen `Binding` unchanged (no new stage)

### A.1 The tier/strategy is a build-time choice consumed at `emit_core` + the linked runtime

The whole point of the keystone's G5 (tier-agnostic IR, tier = module swap) and G1 (strategy =
codegen-shape switch in `emit_core`) is that **the pipeline itself does not grow**. `binding`
already flows through `source_to_ir → lower_ir → optimize_ir → ir_to_core → core_to_beam`
(`pipeline.gleam`), and the two Phase-4 axes are consumed at exactly two points, both downstream
of the pipeline's stage graph:

- **codegen (unit 02):** `emit_core.emit_module(m, binding)` reads `binding.state_strategy` to pick
  the seam's function family (`store` vs `t_store`, §A.3 keystone) and `binding.mem_module`/
  `table_module`/`state_module` — the *module names the linker already resolved for the chosen
  tier* (G5). It never reads `mem_tier`/`table_tier` directly; the tier is invisible to codegen.
- **run time (units 03/04/05/06):** the linked `twocore@runtime@rt_mem*`/`rt_table*` module
  implements the chosen tier behind the uniform interface (keystone §B.2).

> **Invariant (locked by this unit).** For any IR module `m` and any `binding`, the pipeline runs
> the **same five stages in the same order** regardless of `state_strategy`/`mem_tier`/
> `table_tier`. No stage branches on a Phase-4 axis; only `emit_core` (the one codegen seam) and
> the linked runtime module do. There is **no `optimize`-like new stage** for tiers, and no new
> `PipelineError` — a tier/strategy mismatch is a *linker* rejection (`validate_binding`, §B.3),
> surfaced before the pipeline runs, not a pipeline-stage error.

The deliverable is a `pipeline.gleam` module-doc paragraph stating this (mirroring unit 09's
posture-agnostic lock), so a future agent knows the Phase-4 axes are pure `Binding` data that ride
the existing seam — and that adding a tier is a runtime-module + `Binding`-field job, never a
pipeline edit.

> **Sole-seam lock (P5).** Wherever the pipeline/CLI turns a `Binding` into a `profiles.Instance`
> (the build-time instance handle the run-ABI links against), it routes through **`profiles.link/1`
> exclusively** — `validate_binding ∘ resolve_tiers ∘ instantiate` (unit 07 §D.3) — **never**
> `profiles.instantiate/1` directly. This is what keeps the fail-closed gate and the coherent
> tier→module coupling un-bypassable: the ungated `instantiate/1` is the path of least resistance
> (= fail-open) if a caller reaches it, so `link/1` is the *only* sanctioned `Binding → Instance`
> call site in `pipeline.gleam`/`twocore.gleam`, and this unit proves it (§Verification 1).

### A.2 Every stage stays independently invokable (decision #5)

The Phase-1/3 decomposition is preserved verbatim: `source_to_ir`, `lower_ir`, `optimize_ir`,
`ir_to_core`, `core_to_beam`, `parse_ir`, `instantiate`, `invoke_instance`, `stop_instance`,
`exec_beam` each stay callable in isolation. Selecting a tier/strategy changes only *which
`Binding`* a caller threads — never the stage set. A caller can (e.g.) `to-core --portable
foo.ir` to inspect the `Threaded`/`paged` `.core` without running it, or `emit --tier atomics
foo.ir` to see the `atomics`-linked codegen, exactly as `emit --unsafe` inspects the Unsafe
codegen today.

---

## B. CLI axis selection (profile / strategy / tier flags)

### B.1 The flag surface

The compile verbs (`run`, `to-core`, `emit`, `to-beam-wasm`) gain three orthogonal axis flags on
top of the existing `--unsafe` policy flag. `opt` keeps only `--unsafe` (it drives the optimizer,
which reads no tier). The flags compose a `Binding` in two layers — a **base profile** then
**orthogonal overrides**:

| Flag | Axis | Effect |
|---|---|---|
| `--portable` | composed profile | base = `profiles.portable()` (G3 runs-anywhere: `Threaded`+`Paged`+`bif`+Safe). |
| `--ceiling` | composed profile | base = `profiles.ceiling()` (G3 perf build: Unsafe+`Atomics`+`Cell`+aggressive). |
| `--unsafe` | policy (Phase 3) | base = `profiles.unsafe()` (unchanged). |
| *(none)* | policy default | base = `profiles.safe()` — **fail-closed** (D4): Safe/`Cell`/`Paged`. |
| `--threaded` | `state_strategy` | override base → `Binding(..base, state_strategy: Threaded)`. |
| `--tier paged\|atomics\|nif` | `mem_tier` | set `mem_tier: t`; `resolve_binding` then runs `profiles.resolve_tiers` so `mem_module` follows coherently — `--tier atomics` links `rt_mem_atomics`, not the base's stale `paged` module (§B.2, P5). |
| `--table-tier paged\|ets\|atomics` | `table_tier` | set `table_tier: t`; `resolve_tiers` couples `table_module` (§B.2). |

The base profiles are **mutually exclusive** (at most one of `--portable`/`--ceiling`/`--unsafe`);
the axis overrides are **orthogonal** and may be combined with any base (subject to §B.3's
fail-closed check). This lets the CLI express the whole `state_strategy × mem_tier × table_tier ×
policy` space the capstone must prove: e.g. `--threaded --tier atomics` (tier-P state over tier-O
memory), or `--ceiling` alone (the packaged perf build).

### B.2 `resolve_binding` — compose base + orthogonal overrides + fail-closed validate

A single pure resolver in `twocore.gleam` turns the parsed flags into a coherent, validated
`Binding`. It is the CLI's **one** binding-construction site, so the fail-closed rule (§B.3) is
enforced in exactly one place:

```gleam
/// Compose the CLI's requested `Binding` from a base profile + the orthogonal axis overrides,
/// couple the declared tiers to their modules, then validate it fail-closed (G6/P5). Each axis is
/// a plain field set by record-spread (`--threaded` → `state_strategy`, `--tier`/`--table-tier` →
/// `mem_tier`/`table_tier`); `profiles.resolve_tiers` (unit 07, §A.2) is then the **single source**
/// that makes `mem_module`/`table_module` follow the declared tiers — so a `--tier atomics` build
/// actually links `rt_mem_atomics`, never the base's stale `paged` module (P5 — `mem_tier` is not
/// advisory). The `twocore@runtime@*` names live in `profiles`/`instance`, never re-spelled in the
/// CLI (D1).
///
/// - `base`: the profile chosen by `--portable`/`--ceiling`/`--unsafe`/(default `safe()`).
/// - `threaded`: `True` iff `--threaded` was given → `state_strategy: Threaded`.
/// - `mem`/`table`: the parsed `--tier`/`--table-tier` selections (`None` = keep the base's).
/// - Returns `Ok(binding)` — a coherent, `resolve_tiers`-coupled `Binding` — for any coherent
///   composition, or `Error(msg)` fail-closed when the result is policy-incoherent (Safe + `Nif`,
///   G6) — surfaced as a CLI error (exit non-zero), NEVER silently downgraded. Total.
fn resolve_binding(
  base: Binding,
  threaded: Bool,
  mem: Option(MemTier),
  table: Option(TableTier),
) -> Result(Binding, String) {
  let b0 = case threaded {
    True -> Binding(..base, state_strategy: Threaded)
    False -> base
  }
  let b1 = case mem { Some(t) -> Binding(..b0, mem_tier: t) None -> b0 }
  let b2 = case table { Some(t) -> Binding(..b1, table_tier: t) None -> b1 }
  // Single coherent coupling (P5): make `mem_module`/`table_module` follow the declared tiers
  // before validating, so `--tier atomics` links `rt_mem_atomics`, not `base`'s stale module.
  case profiles.validate_binding(profiles.resolve_tiers(b2)) {
    Ok(binding) -> Ok(binding)
    Error(e) -> Error("incoherent profile: " <> profiles.describe_link_error(e))
  }
}
```

After the record-spread sets `mem_tier: Atomics`, `resolve_tiers` sets `mem_module:
"twocore@runtime@rt_mem_atomics"` (the keystone §B.1 map, unit 07 §A.2) — so `emit_core` (which
reads only `mem_module`, G5) transparently links the tier-O backend, never the base's stale `paged`
module (P5 — `mem_tier` is never advisory). `validate_binding` is the fail-closed gate (§B.4):
`Error(SafeForbidsNif)` iff `mode == Safe && mem_tier == Nif`, plus `Error(TierModuleMismatch)` if a
`mem_module` ever disagreed with its tier (it cannot here — `resolve_tiers` ran first); every other
composition is admitted. The validated `Binding` is later turned into an `Instance` **only** through
`profiles.link/1` (the sole seam, §C.3), never `profiles.instantiate/1` directly.

### B.3 Fail-closed default; Safe-forbids-nif rejected at the CLI

The default profile stays `profiles.safe()` (D4/F4) — Safe / `Cell` / `Paged` / `TablePaged` — and
**no flag combination yields a non-default posture by omission**. Because Gleam has no default
field values, every axis override is an explicit token; leaving Safe/`Cell`/`Paged` requires
naming `--unsafe`/`--ceiling`, `--threaded`, or `--tier`/`--table-tier`.

The **Safe-forbids-nif** rule (G6) is enforced at the CLI through `resolve_binding`'s
`validate_binding` call: `run --tier nif foo.wasm f` (a Safe base + `Nif` memory) returns
`Error("incoherent profile: Safe forbids the nif memory tier …")` and the process exits non-zero
— it is **never** silently downgraded to `paged` and never runs. `nif` memory is reachable only
by *also* naming an Unsafe base: `run --unsafe --tier nif …` or `run --ceiling …`. This is the CLI
face of the keystone's two-layer fail-closed guarantee: the profile API is unconstructible into
Safe+Nif, and the linker gate rejects a hand-built one.

Dispatch (Gleam matches top-to-bottom; the axis flags are parsed before the positional operands):

```gleam
// e.g. the `emit` verb — the other compile verbs follow the same shape:
["emit", ..rest] -> {
  let #(flags, positionals) = split_axis_flags(rest)   // → base + threaded + mem + table
  case positionals {
    [path] ->
      case resolve_binding(base_of(flags), flags.threaded, flags.mem, flags.table) {
        Error(msg) -> Error(msg)                        // fail-closed (Safe+Nif) → exit non-zero
        Ok(binding) -> cmd_emit(path, binding)
      }
    _ -> Error(usage())
  }
}
```

`split_axis_flags` is a small total flag parser (order-independent among the axis flags; unknown
tokens → `usage()`). The existing `--unsafe` on `run`/`to-core`/`emit`/`opt` is subsumed as one of
the base selectors. `to-beam`/`build` still take **no** profile (they compile already-emitted
`.core`, which has no `Binding`) — documented in `usage()`.

---

## C. The threaded run-ABI (state travels as a value)

### C.1 `Cell` path unchanged; `Threaded` path threads the record

Under `state_strategy: Cell` (the default) the run-ABI is **byte-identical to today**: the owned
process runs `instantiate/0` (which seeds the pdict cell and returns `'ok'`), then each
`invoke_instance` applies `Fun(Args)` in that process (`twocore_cli_ffi.erl`,
`start_instance`/`instance_loop`). The `Cell` path must not change by one atom (G7).

Under `state_strategy: Threaded` the instance's memory/table/globals travel as an
`rt_state.InstanceState` **value**, not in the pdict (G1). The keystone §A.3 fixes the contract:
the generated `instantiate/0` **returns the record** (via `fresh`, threaded through element →
data → start), and each invoke passes it as the **leading argument**, receiving `{ResultPackage,
St'}` back and threading `St'` to the next call. So the owned process must **hold the record as a
loop variable** across invokes:

- `instantiate`: run `Module:instantiate()`; under `Threaded` it returns the record `St0` (which
  the process stores) instead of `'ok'`.
- `invoke_instance(proc, export, args)`: under `Threaded`, apply `Module:export(St, Args…)`,
  destructure `{Result, St'}`, store `St'`, and return `Result` (unpacked to the value list per
  the Phase-1 `function_return` shape). Under `Cell`, apply `Module:export(Args…)` unchanged.

Crucially, **one instance is still one process** even under `Threaded`: the per-instance
`seed_fuel`/`seed_policy` seeds (F5/F4) remain **pdict**-seeded in that process (metering/host are
orthogonal to state threading, keystone §A.3), so the owned process is still required — only the
*instance state* moves from the pdict cell to a loop variable.

### C.2 The strategy-aware mechanism (self-detecting FFI; uniform threaded export ABI)

The run-ABI stays **signature-stable** — `pipeline.instantiate(beam, mod)` /
`invoke_instance(proc, export, args)` do not gain a `Binding` parameter (the mandate's "threads
the chosen Binding unchanged"). The process discriminates strategy from `instantiate/0`'s **return
value**, which is unambiguous by the keystone's shapes:

- `Cell`'s `instantiate/0` returns the atom `'ok'` → the existing `instance_loop` (apply
  `Fun(Args)`).
- `Threaded`'s `instantiate/0` returns the record, which Gleam compiles to the tagged tuple
  `{instance_state, Mem, Globals, Table}` → a new `threaded_loop(St)` carrying `St`.

`start_instance` matches on the return: `ok -> instance_loop(Module)` vs `{instance_state,_,_,_} =
St -> threaded_loop(Module, St)`. `threaded_loop` applies `Module:Fun([St | Args]) -> {R, St2}`,
extracts `R`, and recurses with `St2`; `bench_instance` likewise threads across its N calls. This
keeps `pipeline.gleam`'s run-ABI unchanged and confines the strategy branch to the shim.

> **Cross-unit contract (flag to unit 02 / the keystone).** For `threaded_loop` to be uniform,
> **every exported function under `Threaded` must present the uniform ABI `export(St, Args…) ->
> {ResultPackage, St'}`** — including a *pure* export (its export wrapper threads `St` through
> unchanged: `{R, St}`). Keystone §A.3's uniform-threading rule threads `St` through
> *state-reaching* functions; the run-ABI additionally needs the **export boundary** to be
> uniformly threaded so the driver need not know per-export which functions touch state. Unit 02
> owns emitting that export wrapper; this unit **requires** it and asserts it (§Verification 2).
> (If unit 02 instead keeps pure exports un-threaded, the run-ABI must consult per-export arity —
> a strictly worse design; raised as an open question.)

### C.3 `run_source` under `Threaded` + `atomics`

`run_source(wasm, binding, export, args)` is unchanged in shape: `source_to_ir → ir_to_core
(binding) → core_to_beam → instantiate → invoke_instance → stop_instance`. Because the run-ABI
self-detects strategy (§C.2) and `emit_core` links the tier via `mem_module` (§A.1), a
`Threaded`/`atomics` binding runs the *same* driver code as `Cell`/`paged`; the difference is
entirely inside the loaded `.beam` (threaded calling convention) and the linked runtime
(`rt_mem_atomics`). The DoD (§Verification 3) is that `run add.wasm add 2 3` and
`sum_to.wasm sum_to 100` return the **same** results under `--threaded --tier atomics` as under
the default — byte-identical, the G7 bar.

---

## Effect / soundness / security note

- **Fail-closed default survives both new axes (D4/G6).** Every compile verb defaults to
  `profiles.safe()` = Safe/`Cell`/`Paged`; a non-default posture is an explicit named token, and
  `resolve_binding`'s single `validate_binding` call rejects Safe+Nif at the CLI (exit non-zero).
  No flag path yields a `nif` memory under Safe, nor any non-default posture by omission — the CLI
  face of the keystone's unconstructible-Safe+Nif property.
- **No ambient authority (D3a) is unaffected.** This unit adds no codegen; `emit_core` still emits
  fixed `twocore@runtime@*` atoms (the tier is a build-controlled `mem_module` swap; the strategy a
  codegen-shape switch), and the threaded run-ABI passes only the build-produced `InstanceState`
  record + integer args — no program-data module/atom reaches a call target.
- **Threads / shared memory stay a hard non-goal (§12).** The `Threaded` record is threaded through
  **one** owned process's call chain (a loop variable), never shared; `atomics`/`ets` tiers are
  process-local. One-instance-one-process holds — the record never escapes its process.
- **Floats-as-bits (D5) unchanged; conformance-neutral (G7).** Args/results stay raw unsigned
  bit-pattern integers; the threaded record carries raw-bit globals + raw-byte memory. No IR node,
  no `TrapReason`, no grammar, no new stage — the default Cell/paged path is byte-identical, and
  every other combination is required to be too (unit 09).

---

## Verification — Definition of Done (D8)

Tests assert **spec/decision behavior** (the CLI selects each posture; the run-ABI is
byte-identical across postures), not whatever the code emits. "Done" = the suite below passes.

1. **The CLI selects each combination (decision #5, fail-closed) and routes through `link/1`
   alone.** Assert `resolve_binding` yields `state_strategy: Threaded` under `--threaded`;
   `mem_tier: Atomics` + `mem_module: "twocore@runtime@rt_mem_atomics"` under `--tier atomics` (the
   `resolve_tiers` coupling actually ran — the module follows the declared tier, not the base's
   stale `paged`, P5); `profiles.portable()`/`ceiling()` under `--portable`/`--ceiling`; and the
   fail-closed **Safe/`Cell`/`Paged`** default with no flag. Assert **`run --tier nif …` (Safe
   base) is rejected** (non-`Ok`, message names the incoherence, G6) while `run --ceiling …` /
   `run --unsafe --tier nif …` are **accepted**. Assert the CLI's only `Binding → Instance` path is
   `profiles.link/1` — `resolve_binding` produces the validated `Binding` and `link/1` is the sole
   call site that turns it into an `Instance` (no direct `profiles.instantiate/1` in
   `pipeline.gleam`/`twocore.gleam`), so the gate cannot be bypassed (P5, §A sole-seam lock). Basis:
   G3/G6, D4.
2. **The run-ABI works under `Threaded` + `atomics` (G7).** Compile+invoke `add.wasm`/`sum_to.wasm`
   through `pipeline.run_source(_, binding, …)` for `binding ∈ {safe(); +state_strategy: Threaded;
   +resolve_tiers(mem_tier: Atomics); +both}` and assert **identical** spec-correct results (`add(2,3)==5`,
   `sum_to(100)==5050`) across all four — the G7 byte-identical bar. Back it with a run-ABI unit
   test that the threaded loop threads `St'` (a two-invoke sequence on a stateful module observes
   persisted state) and that a *pure* export under a `Threaded` build returns the right value (the
   §C.2 uniform-export-ABI cross-check on unit 02). *Green once 02 + 04 land; until then the
   `Cell`/`paged` arms pass and the `Threaded`/`atomics` arms are `skip`-annotated against the
   frozen contract, never asserted false.*
3. **Every stage stays independently invokable (decision #5).** `emit --tier atomics foo.ir`,
   `to-core --portable foo.ir`, and `opt --unsafe foo.ir` each succeed and print the stage's output
   for the selected posture (no stage folded away); `to-beam foo.core` still takes no profile.
   Assert the pipeline runs the **same five stages** regardless of axis (the §A.1 lock) — e.g.
   `to-core --portable` and `to-core` differ only in the emitted `.core`, not in which stages ran.
4. **No regression.** `gleam format --check src test` clean; `gleam build` **zero warnings**;
   `gleam test` stays green (**674, conformance 15747/411/0 under both profiles**). The existing
   `cli_test`/`pipeline_opt_test`/`acceptance_test` are untouched-and-green (the default posture is
   byte-identical). Every new public/private function carries a doc comment stating its contract
   (D8), and `usage()` documents every new flag + the fail-closed default + the Safe-forbids-nif
   rule.

**Proof of goal:** tests 1–3 are the unit's proof — the CLI can *name* every deployment posture,
the fail-closed default and Safe-forbids-nif rejection hold at the command line, the run-ABI
carries state as a value under `Threaded`, and every combination runs end-to-end byte-identically;
the corpus-wide differential over all of them is capstone/unit-09's DoD, run *through* the surface
this unit assembles.

---

## Open questions (for the planner / cross-unit sync)

- **Does unit 02 emit a uniform threaded export ABI (`export(St,Args)->{R,St'}` for *every*
  export, pure ones included)?** The run-ABI's self-detecting `threaded_loop` (§C.2) needs it. The
  clean answer is yes (a thin export wrapper threading `St`); the fallback (per-export arity
  consultation in the run-ABI) is strictly worse. **Flag to the keystone/unit 02.**
- **Tier→module coupling API — resolved (P5).** The single coherent coupler is
  `profiles.resolve_tiers` (unit 07 §A.2), not per-axis `with_mem_tier`/`with_table_tier` helpers:
  `resolve_binding` sets the tier fields by record-spread then calls `resolve_tiers` once, keeping
  the `twocore@runtime@*` names single-sourced in `profiles`/`instance` (D1). `resolve_binding` is
  the CLI's one binding site, so this coupling lives in exactly one place. **Synced with unit 07.**

---

## What this unit leaves

- **Unit 02:** once the threaded seam + uniform threaded export ABI land, a `--threaded` build runs
  end-to-end through the run-ABI this unit made strategy-aware — no further pipeline/CLI change;
  test 2's `Threaded` arms flip from `skip` to asserted.
- **Unit 04/05/06:** once a tier backend links (via `resolve_tiers`'s coherent `mem_module`/
  `table_module` coupling), `--tier atomics`/`--table-tier ets`/… runs end-to-end through the
  **unchanged** pipeline; the tier is invisible to every stage but `emit_core`.
- **Unit 07:** `resolve_binding` is the sole consumer of `portable`/`ceiling`/`resolve_tiers`/
  `validate_binding`, and `link/1` is the sole `Binding → Instance` seam it routes through; the CLI
  hardens the Safe-forbids-nif gate into a user-facing fail-closed rejection.
- **Unit 09 / 10:** the corpus-wide `(strategy × tier)` byte-identity differential and the honest
  re-measurement run *through* the CLI/run-ABI this unit assembled;
  `--portable`/`--ceiling`/`--threaded`/`--tier` are their posture-selection handles.

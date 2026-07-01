# Unit 10 — The Linker: `profiles.unsafe()` + Safe/Unsafe Coexistence (B3)

> **One owner (`profiles.gleam`, extend). Wave «UNSAFE».** Read [`00-overview.md`](00-overview.md)
> (F1–F8) first, then the keystone [`01-interface-freeze.md`](01-interface-freeze.md)
> (`«UNSAFE-PROFILE-FROZEN»`) — this unit **binds to** its frozen `Binding` policy fields,
> the five policy enums, and the bare `profiles.unsafe()` constructor it landed green. Phase-1's
> D1–D10 and Phase-2's E1–E8 still hold. This unit turns the keystone's green stub into the
> **first-class Unsafe profile**, wires the linker so a **Safe instance and an Unsafe instance of
> the same module coexist on one node with no leakage** (F4, high-level §10/§13 "the instance is
> the unit of policy"), and specifies the **B3 monomorphized build** as the Unsafe perf path.

This is a **linker/profile** unit, not a middle-end or runtime one. It owns **only
`profiles.gleam` + its tests**; `instance.gleam` (the `Binding`/`Instance` types, the five policy
enums) is **keystone(01)-owned** and this unit merely imports it (per the ownership decision). It
owns no optimizer pass, no `charge` body, no host impl — those are units 03–09. It **assembles**
the vetted pieces into a
named posture and **proves the coexistence property** the whole phase claims. Everything it needs
from the runtime (`rt_meter` enforce, passthrough stdlib, open BIF/host) and the middle-/back-end
(Unsafe `ir_lower`, the `ir_opt` driver) is delivered by 05–09; this unit is the seam that names
them together and demonstrates the two modes are real and isolated.

---

## Deliverables & freeze milestones

**Consumes (frozen upstream):**
- `«UNSAFE-PROFILE-FROZEN»` (unit 01): `instance.Binding` with the five policy fields
  (`opt_level`, `meter`, `bif_gate`, `stdlib`, `host_policy`); the five enums
  (`MeterMode`/`BifGate`/`StdlibMode`/`HostPolicy` in `instance.gleam`, `OptLevel` in `ir_opt`);
  `instance.safe_default()` in the fail-closed Safe posture; and the bare, green
  `profiles.unsafe()` constructor + its explicit-opt-in test.
- The end-to-end Unsafe build path: `ir_lower` mode-application (unit 08), `emit_core` + the
  `ir_opt` driver + the CLI `opt` verb (unit 09), enforcing `rt_meter` (05), `passthrough`
  stdlib + `open` BIF (06), `rt_host` `whitelist`/`open` (07).
- The Phase-2 run-ABI: `pipeline.instantiate/2` (spawns an instance's **owned process** and runs
  its generated `instantiate/0`), `invoke_instance`, `stop_instance` — one-instance-one-process
  isolation (E1/E5), owned by unit 09's `pipeline.gleam`.

**Produces (this unit):**
- `profiles.unsafe()` as a **fully-documented first-class profile** alongside `safe()` /
  `safe_capped()`, with the exact aggressive posture asserted field-by-field against F4.
- `profiles.unsafe_instance()` — the one-call Unsafe linker path, mirroring `safe_instance()`.
- `profiles.safe_metered(budget: Int)` — a Safe profile with a **lowered per-instance fuel
  budget**, mirroring `safe_capped(max_pages)`: `Binding(..safe(), fuel_budget: budget)`. Threads
  the `Binding.fuel_budget: Int` value channel (keystone 01) that `instantiate/0` bakes into
  `seed_fuel` (unit 09 §A.4) — exactly one channel for the CPU bound.
- The **coexistence model (B3 builds + per-instance seeded policy)**: the `Instance(binding)`
  record + the linker realize *instance-as-unit-of-policy* on top of the Phase-2 per-process
  cell — a Safe and an Unsafe instance of one module (two distinct-atom `.beam` builds sharing
  the identical `rt_*` runtime) run concurrently with correct, isolated results and no capability
  leakage. `is_safe(inst)` distinguishes them.
- A written **B3 monomorphization** spec (the Unsafe perf path) — how the build-time binding
  already yields a per-profile specialized `.beam`, and why that is the zero-overhead Unsafe
  artifact (F5). Specified, not newly implemented (B2's link-time binding *is* B3 per profile).
- Tests: the aggressive-posture assertion, the coexistence + isolation proof, `is_safe`
  distinction, and the fail-closed enumeration (no accidental Unsafe by omission).

**Freeze:** this unit produces no new milestone; it consumes `«UNSAFE-PROFILE-FROZEN»` and is a
prerequisite (with 08/09) for the capstone's (unit 11) Safe-vs-Unsafe differential.

---

## A. `profiles.unsafe()` — the fully-wired Unsafe binding (F4)

`profiles.gleam` today ships exactly one posture family: `safe()` (= `instance.safe_default()`)
and `safe_capped(max_pages)` (the same posture with a **lowered** page cap). The keystone reached
in and added a bare `unsafe()`; this unit is the **owner** that finalizes its contract and its
tests. Per the D1 rule that governs this file since Phase 1, `profiles.gleam` **imports**
`instance.gleam` and never re-spells the vetted `twocore@runtime@rt_*` module strings — `unsafe()`
is a **record spread over `safe_default()`** that overrides only the policy fields.

```gleam
import twocore/middle/ir_opt.{Aggressive}
import twocore/runtime/instance.{
  type Binding, Binding, BifOpen, HostOpen, MeterOff, StdlibPassthrough, Unsafe,
  safe_default,
}

/// The named **Unsafe** profile (F4) — the platform's second named mode. It is the aggressive
/// posture in one value: the aggressive optimizer, no CPU metering, the open BIF gate,
/// passthrough stdlib, and the open host — while keeping the **identical**
/// `twocore@runtime@rt_*` runtime module names as `safe()` (the runtime *code* is shared; the
/// two profiles are distinct B3 builds and the instance is the unit of policy).
///
/// Fail-closed (D4/D9): this is the **only** constructor in `profiles` that yields
/// `mode: Unsafe`. There is no path to an Unsafe posture by omission — `safe()`,
/// `safe_capped(_)`, `safe_default()`, and `safe_instance()` are all fully Safe. Unsafe is an
/// explicit, tested opt-in, exactly as `safe_capped` can only *lower* the page cap. Total.
pub fn unsafe() -> Binding {
  Binding(
    ..safe_default(),
    mode: Unsafe,
    opt_level: Aggressive,       // baseline + Unsafe-only passes (F1/F4)
    meter: MeterOff,             // ir_lower inserts NO Charge nodes → zero overhead (F5)
    bif_gate: BifOpen,           // admits the resolver's build-controlled targets (F6, not arbitrary BIFs) — never ambient (D3a)
    stdlib: StdlibPassthrough,   // in-rt_stdlib shim (same stdlib_module atom); ≡ own observably (F6)
    host_policy: HostOpen,       // all host imports permitted (still no data-driven apply, D3a)
  )
}
```

**The posture, field by field (asserted against F4, not against the constructor):**

| Field | `safe()` (fail-closed) | `unsafe()` (aggressive) | Realized by (unit) |
|---|---|---|---|
| `mode` | `Safe` | `Unsafe` | `is_safe`/`mode` (this unit) |
| `opt_level` | `Baseline` | `Aggressive` | `ir_opt` driver (09) |
| `meter` | `MeterFuel` | `MeterOff` | `ir_lower` Charge insertion (08) + `rt_meter` (05) |
| `bif_gate` | `BifAllowlist` | `BifOpen` | `ir_lower` gate (08) / `rt_bif` (06) |
| `stdlib` | `StdlibOwn` | `StdlibPassthrough` | `ir_lower` resolve (08) / `rt_stdlib` (06) |
| `host_policy` | `HostDenyAll` | `HostOpen` | `rt_host` (07) |
| `safe_max_pages` | `65536` | `65536` (inherited) | `rt_mem:fresh` (Phase 2) |
| `fuel_budget` | `rt_meter.default_fuel_budget` | inherited (no budget under `MeterOff`) | `instantiate/0` bakes `seed_fuel` (09) |
| `*_module` names | `twocore@runtime@rt_*` | **identical** | `emit_core` chokepoint (D3b) |

**The i32 hard cap is not a sandbox lever, and Unsafe keeps it.** `unsafe()` spreads
`safe_default()`, so it inherits `safe_max_pages: 65536` — the i32 4 GiB address-space bound
(2¹⁶ pages), which is a **WASM invariant** (spec §2.5.4 *Limits*, §4.2.8 *Memory Instances*), not
a Safe policy. Unsafe *permits* trust tiers O/N (F4/F8) and drops the sandbox's *lowering* lever
(there is deliberately no `unsafe_capped`), but it does not lift the address-space ceiling —
`memory.grow` past 2¹⁶ pages still returns `-1`. Say so; do not imply Unsafe grants unbounded
memory (it does not — that is the Phase-4 `rt_mem` `nif` tier, deferred).

### `safe_metered(budget)` — the Safe fuel-budget channel

`Binding` carries `fuel_budget: Int` (keystone 01); `safe_default()` sets it to
`rt_meter.default_fuel_budget` and `unsafe()` inherits it (harmless — `MeterOff` seeds no
budget). Mirroring `safe_capped(max_pages)` for CPU, this unit adds the Safe constructor that
**lowers** the per-instance budget:

```gleam
import twocore/runtime/rt_meter

/// A Safe profile with a lowered per-instance CPU-fuel budget (F5) — the CPU analogue of
/// `safe_capped(max_pages)`. `instantiate/0` bakes `seed_fuel(binding.fuel_budget)` (unit 09
/// §A.4), so a smaller `budget` traps a runaway loop sooner with `FuelExhausted`. Stays fully
/// Safe (`mode: Safe`, all five Safe policy fields); only the budget is lowered. Total.
pub fn safe_metered(budget: Int) -> Binding {
  Binding(..safe(), fuel_budget: budget)
}
```

There is deliberately no `unsafe_metered`: `MeterOff` has no budget to lower (§C). The single
fuel-budget channel is `Binding.fuel_budget` — `emit_core` bakes it and nothing else (unit 09
§A.4; unit 05 §D's "emit_core bakes the default directly" fallback is deleted — exactly one
channel).

---

## B. The instance is the unit of policy — coexistence via B3 builds + seeded policy (F4)

> High-level §13: *the instance is the unit of security policy.* This is the claim unit 10
> proves: a **Safe** instance and an **Unsafe** instance of the *same module* alive on **one
> node**, concurrently, with correct results and **no state or capability leakage** between them.

### B.1 The realization, given the current thin `Instance` and the Phase-2 cell

The linker record is deliberately thin — it carries only the binding:

```gleam
/// A runnable instance assembled by the linker (`rt_instance`, high-level §13). It carries the
/// build-time `Binding` — the resolved runtime posture — and is the **unit of policy**: two
/// instances of one module may hold *different* bindings (one Safe, one Unsafe) and neither can
/// observe or widen the other's state or capabilities (§B.2).
pub type Instance {
  Instance(binding: Binding)
}
```

Three existing facts combine to make coexistence sound **without any new mechanism**:

1. **Policy is an attribute of the instance, not the node.** `Instance` carries its `Binding`;
   `mode(inst)` / `is_safe(inst)` read `inst.binding.mode`. A caller holding two instances
   distinguishes their postures purely through the record — never by inspecting shared globals.

2. **State isolation is already per-process (E1).** Phase 2's `«CELL-STATE-ABI-FROZEN»` puts an
   instance's mutable state (linear memory, mutable globals, table) **and** its fuel counter in
   *that instance's own process dictionary*, under one fixed namespaced key. Unit 09's
   `pipeline.instantiate/2` runs `instantiate/0` and every `invoke_instance` inside one **owned
   process** per instance. Two instances are two processes with **disjoint** pdicts, so mutating
   the Safe instance's memory or a global is invisible to the Unsafe instance and vice versa — an
   OS-level property, not a convention the linker must enforce.

3. **Shared runtime code is stateless across instances.** Because `unsafe()` keeps the **identical**
   `twocore@runtime@rt_*` module names as `safe()`, both instances call the *same loaded runtime
   modules* — but every one of those modules (`rt_mem`/`rt_table`/`rt_state`/`rt_meter`) operates
   only on **the current process's cell** (spec §4.2 *Runtime Structure*: the store is per-instance).
   Sharing the runtime *code* therefore shares no *data*. This is exactly why the **instance**, not
   the compiled module, is the unit of policy.

### B.2 No capability leakage under the open Unsafe posture (D3a)

The Unsafe instance's `HostOpen` / `BifOpen` posture does **not** widen the Safe instance's
`HostDenyAll` / `BifAllowlist`, but the two levers isolate by **different** mechanisms:

- **Host policy is per-instance seeded run-time state.** `instantiate/0` seeds
  `rt_host.seed_policy(binding.host_policy)` into the instance's **own process dictionary** (unit
  09 §A.4 / unit 07); every `call_host` reads `current_policy()` from *that* process's cell. The
  Safe instance's process holds `host_deny_all`, the Unsafe instance's holds `host_open`, and an
  unseeded process defaults **deny-all** (fail-closed) — so the postures are isolated by the same
  process boundary that isolates memory, never by a node-global authority table. It is **not** a
  build-baked constant read from the code; it is seeded per instance and read per host call.
- **The BIF gate is build-time (B3).** `bif_gate` is applied by `ir_lower` at build (unit 08):
  the Unsafe build's generated code simply lacks the allowlist rejections the Safe build has —
  two distinct-atom `.beam`s, so there is no shared mutable capability set for the Unsafe build to
  relax; the Safe `.beam` still routes host imports through `rt_host` and still fails closed.
- Even `open`, generated code never performs a data-driven `apply(Mod, F, Args)` with `Mod` from
  program data (D3a/F6): `open` widens the *build-controlled* reachable handler set, it introduces
  **no ambient authority** and reaches into no other instance's process.

So coexistence needs no firewall between the instances: the process boundary isolates state **and
the seeded host policy**, the per-profile build isolates the build-time gate, and D3a guarantees
neither "open" lever is a shared global.

### B.3 What "same module" means, honestly

The two instances run the **same source module** compiled under two profiles. Because several of
the Safe/Unsafe differences are **build-time** (aggressive vs baseline optimizer; `Charge`
present vs *absent* per F5; own vs passthrough stdlib resolution), the two instances execute
**different `.beam` artifacts** — the emitted `.core` for a metered Safe function differs from the
Unsafe one by *exactly* the charge instrumentation (F5's differential). That per-profile
specialization is **B3** (§C), and it is fine: coexistence requires the two postures be *alive on
one node without leakage*, which §B.1 guarantees — it does **not** require both postures to run
off one shared `.beam`. The clean `Instance`/`Binding` abstraction (*the instance is the unit of
policy*) is the API *over* the two monomorphized builds; a true single-`.beam`, runtime-selected
posture (the deferred "B1" swap) is Phase-4+ (§C).

**One practical linker requirement (module-name distinctness).** Two `.beam`s cannot load on one
node under the same module atom. The generated module atom is `ir.Module.name` (a plain build-time
field), so the linker gives the two builds **distinct output names** (e.g. the Unsafe build's IR
module renamed with a `_unsafe` suffix before `emit_core`). No new API is required — setting the
field suffices — but this unit documents it as the load-time precondition for coexistence and adds
a tiny helper if the capstone wants one seam:

```gleam
/// Derive a distinct output module name for a coexisting build of the same source (§B.3), so a
/// Safe and an Unsafe `.beam` of one module load together on one node without an atom clash.
/// Lives in `profiles.gleam` (unit-10-owned); `instance.gleam` is keystone-owned and untouched.
/// Pure string derivation; introduces no policy. Total.
pub fn coexist_name(base: String, mode: instance.Mode) -> String
```

---

## C. B3 — the monomorphized build is the Unsafe perf path (specify, don't re-implement)

**B3 = whole-program monomorphization per profile.** Crucially, Phase-1's **B2 link-time-fixed
binding already delivers it**: the `Binding` is a *build-time input* to `ir_lower`/`ir_opt`/
`emit_core` (D3b), so handing the pipeline `profiles.unsafe()` yields a `.beam` **specialized for
Unsafe** — aggressive-optimized, with **no `Charge` calls at all** (not no-ops: absent, F5),
passthrough-stdlib-resolved, open-BIF-resolved. There is nothing new to build here: the linker's
job is to **select the profile** and route it through the existing driver (unit 09's
`optimize(module, binding.opt_level)` call site + `ir_lower`'s `binding.meter`/`bif_gate`/`stdlib`
switches). The Unsafe artifact is the zero-overhead one **by construction**, which is the whole
point of putting policy on the `Binding` (F7 single-source-of-truth) rather than dispatching it at
run time.

**Why B3 (not a true runtime-dispatch "B1") is the Phase-3 perf path.** The shipped design
already seeds **per-instance runtime state** — the fuel budget (`seed_fuel`) and the host policy
(`seed_policy`) — into each instance's process cell (unit 09 §A.4); a host call reading its seeded
policy is fine because host calls are capability-boundary crossings, not the hot path. The part
that is deferred is a genuine single-`.beam` that keeps `Charge` sites in the code and branches on
a per-instance `meter` flag **on every function/loop** — that **re-introduces the hot-path
overhead F5 exists to eliminate** (a metered branch on the back-edge is not zero-overhead). So
Phase 3 bakes metering **in/out at build** (B3): the Unsafe build has no `Charge` sites at all,
the Safe build meters unconditionally, and neither branches a hot path on a per-instance meter
flag. The two specialized builds are each instantiated as an isolated instance and presented
through one `Instance`/`Binding` type. The runtime-dispatch "B1" (one `.beam` whose hot path
branches on a per-instance `meter` flag) is a **documented Phase-4+ option**, valuable only where
binary size beats hot-path cost — *specified here, not implemented* (F8: state it, don't drop it).

The linker adds the Unsafe one-call path, mirroring the Safe one:

```gleam
/// Convenience: the runnable Unsafe instance — `instantiate(unsafe())`. The one-call path a
/// caller uses to link the Unsafe profile, mirroring `safe_instance()`. Being the sole Unsafe
/// convenience, it keeps the fail-closed guarantee legible: an author must *name* `unsafe`/
/// `unsafe_instance` to leave Safe. Total.
pub fn unsafe_instance() -> Instance {
  instantiate(unsafe())
}
```

`instantiate/1`, `mode/1`, and `is_safe/1` are **unchanged** — they already read the binding, so
they carry the Unsafe posture through with no edit (`is_safe(unsafe_instance()) == False`).

---

## Effect / soundness / security note

- **Fail-closed default survives the second mode (D4/D9).** The default profile is Safe; every
  `safe*` constructor and `safe_default()` yield `mode: Safe` with the full fail-closed posture
  (`Baseline`/`MeterFuel`/`BifAllowlist`/`StdlibOwn`/`HostDenyAll`). `unsafe()` /
  `unsafe_instance()` are the **only** Unsafe paths, both explicit and both tested (§Verification).
  There is no partial/defaulted way to acquire an Unsafe field — Gleam has no default field values,
  so an Unsafe posture requires *naming* the constructor. Unsafe by omission is impossible.
- **No ambient authority under `open` (D3a).** `BifOpen`/`HostOpen`/`StdlibPassthrough` widen a
  *build-controlled* allow-set; none introduces a data-driven `apply(Mod,F,Args)` with `Mod` from
  program data, and none reaches across the process boundary into another instance's cell
  (§B.2). The linker only *names* these postures; units 06–08 preserve D3a and unit 09 extends the
  structural security test for `open`.
- **Unsafe does not license incorrect results (F2/F8).** WASM has no C-style UB — every
  ill-defined operation traps (spec §4.4). The Unsafe posture changes *policy* (metering off,
  gates open, aggressive opt), never *WASM semantics*: the coexistence proof (§Verification)
  asserts the Unsafe instance returns **byte-identical** results and **identical traps** to the
  Safe instance over the corpus, by bit pattern (D5/D7).
- **`FuelExhausted` is Safe-only, by construction.** With `meter: MeterOff`, the Unsafe build has
  no `Charge` sites and no `seed_fuel`, so `FuelExhausted` (F5) is *unreachable* in an Unsafe
  instance — a runaway loop in Unsafe runs to native completion (or is preempted by the BEAM
  scheduler), while the *same* loop in a Safe instance traps at the seeded fuel bound. The two
  behaviors coexist because the budget lives in each instance's own process cell.

---

## Verification (Definition of Done)

Spec-cited, behavior-asserting tests (no change-detectors, D8). "Done" = **the suite passes**, not
"it compiles". Owned test file: `test/twocore/runtime/profiles_test.gleam` (extends the keystone's
seed) plus a coexistence file (e.g. `test/twocore/runtime/linker_coexist_test.gleam`).

1. **`unsafe()` has the exact aggressive posture (F4).** Assert *field by field* against F4 (the
   spec, not the constructor body): `unsafe().mode == Unsafe`, `opt_level == Aggressive`,
   `meter == MeterOff`, `bif_gate == BifOpen`, `stdlib == StdlibPassthrough`,
   `host_policy == HostOpen`, and that the `*_module` names, `safe_max_pages`, and `fuel_budget`
   are **identical to `safe()`** (the runtime code is shared and `fuel_budget` is inherited but
   unused under `MeterOff`; only the posture differs — the instance is the unit of policy).
2. **Fail-closed enumeration (D4/D9).** Assert `safe()`, `safe_capped(n)` (any `n`),
   `safe_metered(n)` (any `n`), `safe_default()`, and `safe_instance().binding` are **all** the
   full Safe posture (`mode: Safe` + all five Safe policy fields — `safe_metered` lowers only
   `fuel_budget`, never a posture field), and that `unsafe()` / `unsafe_instance().binding` are
   the **only** values with `mode: Unsafe`. No accidental Unsafe by omission.
3. **`is_safe` distinguishes at the instance level (§B).** `is_safe(safe_instance()) == True`;
   `is_safe(unsafe_instance()) == False`; `mode(unsafe_instance()) == Unsafe`.
4. **Coexistence + isolation — a Safe and an Unsafe instance of one module, concurrently (F4).**
   Compile one source module twice (via the unit-09 pipeline) — under `profiles.safe()` and under
   `profiles.unsafe()`, with distinct output module names (§B.3) — load **both** on the node, and
   `pipeline.instantiate/2` each into its **own owned process**. Then, concurrently:
   - assert both return **byte-identical, spec-correct** results for the same export/args (F2 —
     Unsafe never changes an observable answer; compare by bit pattern, D5/D7);
   - for a **stateful** module (memory/global), mutate the Safe instance's state, then read the
     Unsafe instance's — assert it is **unchanged** (disjoint per-process cells, E1), and vice
     versa; neither instance observes the other's store (spec §4.2 per-instance store);
   - assert `is_safe` of the two live instances still distinguishes them.
   This is the concrete "instance = unit of policy" proof (high-level §13); it depends on 08/09
   being green (the Unsafe build path) and reuses the Phase-2 harness unchanged.
5. **Doc comments on every public function** (contract: intent / params & ranges / return &
   `Result`/`Option` semantics / failure & panic modes), `////` module doc updated to name the
   second profile. `gleam format --check src test` clean; `gleam build` **zero warnings**;
   `gleam test` green with the full suite (the coexistence proof included).

---

## What this unit leaves

- **Unit 11 (capstone)** runs the full Safe-vs-Unsafe **differential** over the whole acceptance +
  spec corpus (this unit proves coexistence + isolation on representative modules; the capstone
  proves *identical results/traps everywhere*), the optimizer-soundness differential, the
  real-metering trap proof, and the honest benchmark — reusing `profiles.unsafe()` /
  `unsafe_instance()` and the coexistence harness this unit ships.
- **Phase 4** may add a true runtime-dispatch **B1** (one `.beam`, per-instance posture read from
  the cell) where binary size beats hot-path cost — specified in §C, deferred here; and the
  Unsafe-permitted **tier-N `rt_mem`** ceiling (F8), which this unit deliberately does *not* grant
  (Unsafe keeps the i32 hard cap). Both are stated, not dropped.

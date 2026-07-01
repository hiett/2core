# Unit 06 — passthrough stdlib (`rt_stdlib`) + open BIF gate (`rt_bif`)

> **One owner; two files, extended single-owner-additively.** Read
> [`00-overview.md`](00-overview.md) (F4/F6/F7), then the keystone
> [`01-interface-freeze.md`](01-interface-freeze.md) (the `StdlibMode`/`BifGate` enums,
> `binding.stdlib`/`binding.bif_gate`, and the Unsafe posture this unit binds to). This unit
> makes **two of the Unsafe speed levers real** (F6): `rt_stdlib` learns to *route* a shared
> stdlib call to a faster **trusted** BEAM path — realized as a thin shim inside `rt_stdlib`, so
> the emitted module stays `stdlib_module` — instead of the vetted own body, and `rt_bif` learns
> to run its build-time allowlist gate **open** — widening the admitted set to the targets the
> build-time resolver constructs (the passthrough/own surface only), never arbitrary BIFs —
> reachable **only** under Unsafe. Both are proven **observably identical to Safe**
> where they apply, and both keep D3a intact: *open widens a build-controlled allow-set; it
> never introduces a data-driven `apply(Mod, Fun, Args)` with `Mod` from program data.*

---

## Deliverables & freeze milestones

**Consumes (frozen by unit 01, `«UNSAFE-PROFILE-FROZEN»`):**

- `instance.StdlibMode = StdlibOwn | StdlibPassthrough` and `instance.BifGate =
  BifAllowlist | BifOpen`, and the `Binding` policy fields `stdlib: StdlibMode` /
  `bif_gate: BifGate`.
- `profiles.safe()` posture (`StdlibOwn` / `BifAllowlist`) and `profiles.unsafe()` posture
  (`StdlibPassthrough` / `BifOpen`) — the structural guarantee that the open/passthrough
  postures are reachable **only** through the explicit, tested `unsafe()` opt-in (F4/D4/D9).
- The existing frozen runtime surface this unit extends: `rt_stdlib.gcd/2`, and
  `rt_bif.{BifTarget, BifError, allowlist, check, is_allowed}` (Phase-1 unit 09).

**Produces (owned by this unit):**

1. `rt_stdlib` build-time **routing**: `shared_surface/0`, `passthrough_route/2`,
   `resolve/4` — the single source of truth for *which BEAM target a shared stdlib call
   resolves to* under each `StdlibMode`. Consumed by `ir_lower` (unit 08); never called by
   generated code.
2. `rt_bif` **gated** check: `check_gated/2` — the allowlist gate parameterised by `BifGate`
   (`BifAllowlist` = the untouched fail-closed `check/1`; `BifOpen` = a no-op admit of any
   build-fixed target). Consumed by `ir_lower` (unit 08).
3. The **`passthrough ≡ own` differential** (§D) and the **open-gate** suite (§C.3): the
   proof that passthrough changes no observable answer on the shared surface, that open
   admits a previously-rejected but build-fixed target, and that Safe still rejects it.

**Freeze note:** this unit adds no types to the `Binding` and no IR nodes (F7). It adds
*additive* public functions to two runtime files. It does **not** edit `ir_lower` — unit 08
owns the wiring (reads `binding.stdlib`/`binding.bif_gate`, calls `resolve/4` and
`check_gated/2`). This unit ships the functions and their tests; unit 08 threads them.

---

## Context — where these two levers sit

Under Safe (Phase 1/2), a `CallHost(stdlib_capability, name, args)` is resolved *inside*
`ir_lower` against a one-entry surface (`gcd`), its concrete `module:fn/arity` target is
gated through `rt_bif.check/1` (fail-closed allowlist), and `emit_core` emits a direct
`call 'twocore@runtime@rt_stdlib':'gcd'(A, B)`. Two policy knobs turn this into the Unsafe
fast path (F6):

- **`StdlibPassthrough`** changes the *resolution target*: where a shared function has a
  faster, trusted, semantically-identical BEAM equivalent, resolve to *that* instead of the
  own body. (The vetted own body stays the reference the passthrough is proven against.)
- **`BifOpen`** changes the *gate verdict*: a build-fixed target outside the small Safe
  allowlist is admitted rather than rejected. Passthrough targets are exactly such
  targets — which is *why* passthrough needs open, and why both are bundled in `unsafe()`.

Neither knob is reachable under Safe: `profiles.safe()` pins `StdlibOwn` + `BifAllowlist`
(unit 01, tested as the fail-closed default). This unit only has to make the two Unsafe
verdicts *real and provably faithful*.

---

## A. Profile → own vs passthrough (`binding.stdlib`, `StdlibMode`)

The **profile is the single source of truth** (F7): `binding.stdlib` selects the resolution
strategy, exactly as `binding.mode` selects the pipeline branch today. `ir_lower` (unit 08)
reads it and calls the resolver this unit owns — it never re-decides own-vs-passthrough
itself, so the routing table has one home.

```gleam
//// additions to src/twocore/runtime/rt_stdlib.gleam — BUILD-TIME stdlib routing (F6).
//// These functions are consulted by `ir_lower` (unit 08) at COMPILE time to choose a call
//// target; they are NOT called by generated code (the runtime bodies below — `gcd` — are).
//// Acyclic: `rt_stdlib → rt_bif → instance → ir_opt → ir` (nothing on that chain imports
//// `rt_stdlib`).
import gleam/option.{type Option, None, Some}
import twocore/runtime/instance.{type StdlibMode, StdlibOwn, StdlibPassthrough}
import twocore/runtime/rt_bif.{type BifTarget, BifTarget}

/// The shared stdlib **surface**: the `#(ir_name, own_fn, arity)` triples a frontend may
/// reach via `CallHost(stdlib_capability, ir_name, args)`. This is the single source of
/// truth for the surface (unit 08 adopts it, retiring `ir_lower`'s local `own_stdlib_surface`
/// so the two cannot drift). Phase-3 surface: exactly `#("gcd", "gcd", 2)` — F7 adds no new
/// frontend surface, so passthrough must stay conformance-neutral over exactly this set.
pub fn shared_surface() -> List(#(String, String, Int))

/// The passthrough route for shared-stdlib `name`/`arity`, or `None` to keep it IN-HOUSE.
/// A registered route always names a thin shim INSIDE `rt_stdlib` (module = `stdlib_module`, a
/// `twocore@runtime@rt_*` module in the D3a `runtime_modules` set) whose body calls the faster
/// BIF — NEVER a bare `erlang`/OTP module — so the emitted call's module atom is invariant
/// across profiles (§B.2, D3a). A route is registered ONLY when the wrapped BIF is, provably,
/// ALL of:
///   (a) FASTER than the own body on the hot path;
///   (b) TRUSTED — a vetted OTP function that is node-safe (cannot crash the node, no
///       partial/`badarg` reachable on the call's domain);
///   (c) OBSERVABLY IDENTICAL to the own body across the WHOLE input domain incl. every
///       spec/edge case (the §D differential is the admission gate).
/// If any of (a)/(b)/(c) fails, the function is KEPT IN-HOUSE (`None`).
///
/// Phase-3 registry: `gcd` has no BEAM equivalent that satisfies (a)+(b)+(c) — OTP ships no
/// `gcd` BIF, and `gcd`'s sign/zero conventions plus its constant-space tail recursion are
/// load-bearing — so it is kept in-house and `passthrough_route("gcd", 2) == None`. The
/// registry is the seam future routes are added to, each admitted only by passing §D.
pub fn passthrough_route(name: String, arity: Int) -> Option(BifTarget)

/// Resolve a shared-stdlib call to its concrete build-fixed BEAM `BifTarget` under `mode`.
///
/// - `StdlibOwn`         → the own target `own_module:<own_fn>/arity` (Safe; unchanged path).
/// - `StdlibPassthrough` → `passthrough_route(name, arity)` if registered — a shim in the SAME
///   `own_module`, so only the target *function* differs and the emitted module atom is
///   unchanged — else the own target (the in-house fallback — passthrough NEVER silently drops
///   a function).
///
/// - `own_module`: the own-impl module name, read from `binding.stdlib_module` (never
///   hard-coded, so `resolve` and the `rt_bif` allowlist agree by construction).
/// - Return: `Ok(target)` with a BUILD-FIXED triple (D3a — module/fn/arity are compiler
///   data, never program input), or `Error(Nil)` iff `name`/`arity` is not on
///   `shared_surface()` (an unknown stdlib fn — `ir_lower` maps this to `UnknownStdlibFn`).
/// Total — never panics.
pub fn resolve(
  name: String,
  arity: Int,
  mode: StdlibMode,
  own_module: String,
) -> Result(BifTarget, Nil)
```

**Why the resolver lives in `rt_stdlib`, not `ir_lower`.** The set of shared functions, their
own targets, and their passthrough routes are one coupled fact; splitting them across files
is how drift bugs are born (Phase-1 already needed a `resolved_stdlib_targets` cross-check to
stop exactly that). Centralising them here means unit 08's wiring is a two-line call
(`resolve` + `check_gated`) and the anti-drift cross-check (§C.3) compares one table against
one allowlist.

---

## B. `rt_stdlib` passthrough — the routing table and the honest surface

### B.1 The per-function routing decision (the whole design)

Passthrough is a **per-function** decision, not a global switch: each shared function is
either **routed** (to a BEAM stdlib/BIF target) or **kept in-house** (own body). The decision
is the (a)+(b)+(c) test in `passthrough_route`'s contract. This is the faithful reading of
F6's *"route each shared stdlib function to the BEAM stdlib/BIF where it is faster AND
trusted, keeping a few functions in-house"* — the "few in-house" are the functions that fail
the test.

**Applied to the Phase-3 surface (`{gcd}`): `gcd` is kept in-house.** Honestly:

- **(a) faster?** Marginal at best — Euclid over BEAM bignums is already native `rem`/`abs`
  primitives with a tail loop; there is no coarser BIF to win on.
- **(b) trusted?** OTP ships no `gcd` BIF to route to.
- **(c) identical?** `gcd`'s conventions (`gcd(n, 0) = |n|`, `gcd(0, 0) = 0`, negatives folded
  to magnitude — see `rt_stdlib.gcd`'s doc) are precise and its tail recursion is
  constant-space; any substitute would have to reproduce all of that.

So `passthrough_route("gcd", 2) == None`, and under `StdlibPassthrough` `gcd` resolves back
to `rt_stdlib:gcd/2` — the **in-house fallback**. Consequence, and this is a *feature*:
**passthrough is observably identical to own on the current surface by construction**, which
is exactly the conformance-neutrality F7 requires (both profiles produce identical results).
The §D differential asserts this rather than assuming it, and — critically — it is the gate
every *future* route must clear, so the mechanism is what makes the speed lever safe to grow,
not the size of today's registry.

> **Honest scope (matches the phase's ethos, §00 F8).** Phase 3 ships **zero active passthrough
> routes**: the one-function shared surface (`gcd`) has no qualifying BEAM equivalent, so the
> registry is empty and `gcd` stays in-house under **both** profiles. What this unit ships is the
> *mechanism* (routing table + resolver + admission differential) fully working and proven —
> together with the §D.3 **non-vacuity self-test** that proves the differential can actually fail
> on a deliberately-wrong route. The `passthrough ≡ own` differential therefore proves the
> MECHANISM and its non-vacuity self-test, **not** a live route. As the shared stdlib grows
> (later phases / new frontends), each candidate route is registered here and admitted only by
> passing §D. Do not overstate today's registry; do prove the machinery.

### B.2 Passthrough shims — always inside `rt_stdlib` (the emit target is invariant)

Every passthrough route is realized as a thin, tier-vetted **shim** added to `rt_stdlib` (a new
public function whose body calls the faster native BIF), and `passthrough_route` names *that
shim's* target — so its module is **invariably `stdlib_module`** (a `twocore@runtime@rt_*`
module in the D3a `runtime_modules` set). There is **no** direct route to a bare `erlang`/OTP
module: `passthrough_route` never returns a `BifTarget` naming a module outside the own runtime,
so `emit_core` always emits `call '<stdlib_module>':'<fn>'(…)` and the emitted **module atom is
byte-identical under both profiles** — only the in-module *implementation* differs (own Euclid
body vs the passthrough shim that calls the BIF). This keeps the D3a `runtime_modules`
structural guard (unit 09, not weakened) and the §D differential **permanent**, not contingent
on today's registry. Any shim added here obeys the same tier discipline as `gcd`: total,
node-safe, doc-commented with its contract and failure modes (Phase-1 §5 totality rule). No shim
is added for the Phase-3 surface (gcd is in-house), so none ships now; the shape is specified so
a future route is single-owner-additive on this file.

---

## C. `rt_bif` — the open gate

### C.1 The gated check (`check_gated/2`)

The Safe allowlist (`check/1`, `allowlist/0`, `is_allowed/1`) is **untouched** — Phase-1 unit
09's fail-closed gate stays byte-for-byte as-is. This unit adds one function that *wraps* it
with the `BifGate` posture:

```gleam
//// additions to src/twocore/runtime/rt_bif.gleam — the build-time gate, now POSTURE-aware
//// (F6). Still build-time only, still not runtime-linked, still not in the `Binding`.
//// Acyclic: `rt_bif → instance → ir_opt → ir`.
import twocore/runtime/instance.{type BifGate, BifAllowlist, BifOpen}

/// Gate a build-fixed `target` under the `gate` posture chosen by the profile
/// (`binding.bif_gate`, F6/F7). This is the ONE place the allowlist can be relaxed.
///
/// - `BifAllowlist` (Safe): fail-closed — **exactly `check(target)`**. A non-allowlisted
///   target (including a known module/fn with the wrong arity) is rejected
///   `Error(NotAllowlisted(target))`. Nothing about the Safe gate changes.
/// - `BifOpen` (Unsafe): the allowlist gate is a **no-op admit** — any BUILD-FIXED `target`
///   is permitted, `Ok(Nil)`. This is NOT "arbitrary BIF access": it widens the
///   *build-controlled* allow-set from the small vetted list to exactly the targets the
///   compiler's build-time resolver constructs (the passthrough/own surface only), never
///   arbitrary BIFs — node-safety rests on per-route human vetting, not on the gate. It does
///   NOT — and cannot — introduce ambient authority: `target` is a `BifTarget` value the
///   resolver built from a fixed module/fn/arity, never a module atom read from program data,
///   and admitting it emits a STATIC `call '<mod>':'<fn>'(...)`, not an `apply/3` of runtime
///   data (D3a; §Effect note).
/// Total — never panics.
pub fn check_gated(target: BifTarget, gate: BifGate) -> Result(Nil, BifError) {
  case gate {
    BifAllowlist -> check(target)
    BifOpen -> Ok(Nil)
  }
}
```

### C.2 `BifOpen` is reachable only under Unsafe (structural)

`BifGate` is set by the profile: `profiles.safe()`/`safe_capped()` fix `BifAllowlist`;
`profiles.unsafe()` is the sole constructor that yields `BifOpen` (unit 01, tested as an
explicit opt-in). There is **no way** to call `check_gated(_, BifOpen)` from a Safe build —
`ir_lower` passes `binding.bif_gate`, and a Safe binding's field is `BifAllowlist`. So the
open verdict is a property of the *linked profile*, not a flag a program can flip. This is the
same fail-closed-by-construction shape Phase-1 relied on (there was simply no `open` variant
to reach); Phase-3 adds the variant but keeps the only door to it behind the tested
`unsafe()` opt-in (F4/D4/D9).

### C.3 Open-gate & anti-drift tests (this unit owns them)

Spec-behaviour assertions (D8), in `test/twocore/runtime/rt_bif_test.gleam` (extended):

- **Safe still rejects.** For a build-fixed target NOT on `allowlist()` (representative:
  `BifTarget("erlang", "abs", 1)`), `check_gated(t, BifAllowlist) == Error(NotAllowlisted(t))`
  **and** `== check(t)` (the Safe gate is literally unchanged).
- **Open admits a previously-rejected but build-fixed call.** For that same `t`,
  `check_gated(t, BifOpen) == Ok(Nil)` — the target Safe just rejected is admitted under open.
- **Open does not corrupt the allowlisted case.** For an allowlisted target
  (`BifTarget("twocore@runtime@rt_stdlib", "gcd", 2)`), both postures return `Ok(Nil)`.
- **Reachability is profile-bound.** `profiles.safe().bif_gate == BifAllowlist` and
  `profiles.unsafe().bif_gate == BifOpen` — open cannot be reached from a Safe profile.
- **Anti-drift (owned jointly with unit 08's cross-check).** For every entry of
  `shared_surface()`, `resolve(name, arity, StdlibOwn, mod)` is on `allowlist()` (the own path
  is always Safe-gateable), and every `passthrough_route` target is a well-formed
  `BifTarget` — so a mis-registered route is caught here, not at runtime.

---

## D. The `passthrough ≡ own` differential (F6/F2)

**"Observably identical" is the deliverable, and it is proven differentially** (F6 restates F2
for this unit): for every shared function, resolving under `StdlibOwn` and under
`StdlibPassthrough` must yield **the same observable answer on the same input**, over the
whole domain the function's spec/definition ranges across, *including every edge case*.

### D.1 Equality is by bit pattern (D5/D7)

Results are compared **by bit pattern** (D5 floats-as-bits, D7): a float passthrough must
reproduce NaN payloads, `-0.0`, and rounding *exactly*, and an integer passthrough must
reproduce wrap/sign exactly. "Close enough" is a fail. For a function whose spec is a WASM
numeric operation, the input battery must include the WASM spec's numeric edge cases
(WebAssembly spec §4.3 *Numerics* — NaN propagation, signed zero, overflow/trap boundaries);
for a function whose spec is a host/math operation, the battery comes from that function's
definition. This unit's shared surface is `gcd`, whose spec is the **mathematical** gcd (not
the implementation): the battery asserts the definition, per Phase-1 §DoD "spec, not code."

### D.2 The harness (parameterised over the surface)

```
for each #(ir_name, own_fn, arity) in shared_surface():
    own_t = resolve(ir_name, arity, StdlibOwn,         module)   // Ok(_)
    pt_t  = resolve(ir_name, arity, StdlibPassthrough, module)   // Ok(_)
    for each input in spec_battery(ir_name):
        assert invoke(own_t, input) ==bits== invoke(pt_t, input)
```

- `invoke` calls the resolved **build-fixed** target. In a *test* harness a build-fixed
  `apply(Mod, Fun, Args)` is legitimate — `Mod`/`Fun` are compile-time constants from the
  routing table, not program data — so this does not violate D3a (which constrains *generated
  code*, not the compiler's own test tooling). Reuse the Phase-1 catching-apply FFI shim
  (`twocore_..._ffi.erl`) so a passthrough that *raises* on some input is caught and surfaces
  as a diff, not a crashed runner.
- `spec_battery("gcd")`: from the mathematical definition — `gcd(12,18)=6`, `gcd(18,12)=6`,
  `gcd(0,5)=5`, `gcd(5,0)=5`, `gcd(0,0)=0`, `gcd(17,5)=1`, negatives (`gcd(-12,18)=6`,
  `gcd(12,-18)=6`, `gcd(-12,-18)=6`), and large bignums (crossing the 60-bit small-int
  boundary, so a native-int passthrough that silently truncated would diverge). For `gcd` the
  two resolved targets are the same in-house `rt_stdlib:gcd/2`, so the assertion holds by
  construction — and it is exactly the regression guard that fires the day a route is
  mis-registered for `gcd`.

### D.3 Non-vacuity — prove the harness proves something

A differential that can only pass is worthless. This unit ships a **machinery self-test**: a
test-local registry that deliberately routes `gcd` to a WRONG target (e.g. an `erlang`
subtraction/`-` or an off-by-convention variant), run through the *same* harness, and asserts
the differential **FAILS** on at least one battery input. This proves the harness detects a
real mismatch — so its green run over the real registry is meaningful. (The self-test uses a
build-fixed wrong target too; it never apply's program data.)

---

## Effect / soundness / security note

- **D3a survives open — the load-bearing invariant.** `BifOpen` widens *which build-fixed
  targets are admitted*; it changes **nothing** about *how targets are constructed or called*.
  Every `BifTarget` `check_gated` ever sees was built by the compiler's resolver from a fixed
  `#(module, function, arity)`; open just stops rejecting the ones outside the small Safe list.
  The code `emit_core` emits for an admitted target is still a **static**
  `call '<module>':'<fn>'(Args…)` — there is no `apply(Mod, F, Args)` anywhere with `Mod`
  derived from program/attacker input. "Open" is *not* "arbitrary dynamic dispatch"; it is "a
  bigger, still-build-controlled, allow-set." Unit 09 extends the structural codegen
  security-invariant test to assert this holds for an Unsafe/`BifOpen` build (no data-driven
  `apply`).
- **Passthrough adds no authority.** `StdlibPassthrough` only changes a *resolution target*
  among build-fixed BEAM functions; it grants no capability and reads no program data. A
  routed target must be **trusted and node-safe** (test (b)) — a passthrough is never a route
  to something that can crash the node or escape the sandbox's *value* semantics. (Passthrough
  is an Unsafe *speed* posture, not a *trust-tier* change — the tier ladder is Phase 4, §00.)
- **Fail-closed default (D4/D9).** Safe = `StdlibOwn` + `BifAllowlist`, unchanged and untested
  paths untouched. Open/passthrough are reachable only via the explicit `unsafe()` opt-in.
  There is no posture reachable by omission that relaxes the gate.
- **Unsafe is not incorrect (F8).** Passthrough may only route to a target proven identical on
  the whole domain (§D). It may not "assume no bad input and skip a trap" — WASM has no UB, so
  a passthrough that changed a trap into a wrong value would fail the differential and is
  inadmissible.

---

## Verification (Definition of Done)

Done = **the suites below pass**, not "it compiles" (D8).

- **`passthrough ≡ own` differential (§D)** green over `shared_surface()`, compared by bit
  pattern (D5/D7), with the spec-derived `gcd` battery incl. all edge cases — and the
  **non-vacuity self-test** (§D.3) proving the harness fails on a deliberately-wrong route.
- **Open-gate suite (§C.3)** green: Safe rejects a build-fixed non-allowlisted target
  (`check_gated(t, BifAllowlist) == check(t) == Error(NotAllowlisted(t))`); open admits that
  same target (`check_gated(t, BifOpen) == Ok(Nil)`); allowlisted targets pass under both;
  and `BifOpen` is reachable only from `profiles.unsafe()`.
- **Anti-drift** green: every `shared_surface()` own target is on `allowlist()`; every
  registered `passthrough_route` is a well-formed `BifTarget`.
- **`resolve/4` behaviour** green: `StdlibOwn` → own target for every entry;
  `StdlibPassthrough` → the registered route or the own fallback (never a dropped function);
  `Error(Nil)` for an off-surface name.
- **Doc comments** on every new public function — contract, params (units/ranges), return
  (`Ok`/`Error`/`Some`/`None` semantics), failure/divergence modes (CLAUDE.md §2 / D8).
- **`gleam format --check src test` clean; `gleam build` zero warnings; `gleam test` green
  before and after** (the full suite stays 509+, conformance 1740/1359/0 — this unit is
  conformance-neutral, F7). New functions are total; no `todo`, no `let assert` on runtime
  values.

---

## What this unit leaves

- **Unit 08 (`ir_lower`)** wires the two levers: reads `binding.stdlib`, calls
  `rt_stdlib.resolve(name, arity, binding.stdlib, binding.stdlib_module)` to pick the target,
  and gates it through `rt_bif.check_gated(target, binding.bif_gate)` — retiring `ir_lower`'s
  local `own_stdlib_surface`/`resolve_stdlib_fn` in favour of `rt_stdlib.shared_surface`/
  `resolve` (single source of truth). Under Safe nothing changes (StdlibOwn + BifAllowlist =
  today's behaviour); under Unsafe the passthrough target (if any) is chosen and BifOpen
  admits it.
- **Unit 09 (`emit_core` + security test)** extends the structural codegen security-invariant
  test to an Unsafe/`BifOpen` build: assert the emitted `.core` still contains no data-driven
  `apply(Mod, F, Args)` (D3a holds under open).
- **Unit 11 (capstone)** runs the Safe-vs-Unsafe whole-corpus differential; because
  passthrough is conformance-neutral on the current surface and open only *widens* an
  allow-set the compiler already only fills with build-fixed targets, the Unsafe corpus result
  must be byte-identical to Safe — this unit's §D differential is the per-function lemma that
  makes that whole-corpus claim credible.
- **Future phases** grow `shared_surface()`/`passthrough_route`; each new route is admitted
  only by passing this unit's §D differential — the mechanism, not the size of today's
  registry, is the durable deliverable.
</content>
</invoke>

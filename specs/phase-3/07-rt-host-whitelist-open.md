# Unit 07 — `rt_host` whitelist / open (F4)

> **One owner: `src/twocore/runtime/rt_host.gleam` (single-owner-additive) + its test.**
> Read [`00-overview.md`](00-overview.md) (F1–F8) and the keystone
> [`01-interface-freeze.md`](01-interface-freeze.md) (§B — `«UNSAFE-PROFILE-FROZEN»`) first,
> then [`phase-1/00-overview.md`](../phase-1/00-overview.md) (D3a/D4/D9) and
> [`phase-2/00-overview.md`](../phase-2/00-overview.md) (E1 one-instance-one-process). Phase 1
> shipped **only** the deny-all host boundary (unit 09). This unit makes the other two
> `HostPolicy` postures real — **whitelist** (an explicit build-controlled allow-set of
> `#(capability, name)` pairs) and **open** (Unsafe passthrough) — **without** widening the
> module's authority: dispatch stays inside the *one* build-controlled `rt_host` module and
> never becomes a data-driven `apply/3` (D3a). Deny-all remains the fail-closed **default**.

Host imports are the capability boundary of the sandbox (high-level §6/§13). Phase 3's Unsafe
profile (F4) bundles `host_policy: HostOpen`; a Safe profile may run `HostDenyAll` **or**
`HostWhitelist(allow)`; it may **never** be `HostOpen`. This unit is pure runtime work — it
implements the three dispatch behaviours behind the frozen `call_host/3` ABI, adds the
per-instance policy seam, and preserves every fail-closed property the Phase-1 boundary proved.

---

## Deliverables & freeze milestones

**Consumes** `«UNSAFE-PROFILE-FROZEN»` (keystone §B), already frozen and green:

- `instance.HostPolicy = HostDenyAll | HostWhitelist(allow: List(#(String, String))) | HostOpen`.
- `Binding.host_policy: HostPolicy`; `safe_default().host_policy == HostDenyAll`;
  `profiles.unsafe().host_policy == HostOpen` (the sole `Unsafe` opt-in, D4/D9).

**Produces** (all inside `rt_host.gleam`, single-owner-additive — no new freeze milestone; unit
07 is a leaf under `«UNSAFE-PROFILE-FROZEN»`):

1. The **build-fixed handler registry** `resolve_handler/2` — the `#(capability, name) → vetted
   handler` mapping, fixed in this module's source (no ambient authority).
2. The **per-instance policy seam** `seed_policy/1` + `current_policy/0` — a process-local
   posture, seeded at instantiation, defaulting to `HostDenyAll` when unseeded (fail-closed).
3. The **policy-gated dispatch** — `call_host/3` refined to honour deny-all / whitelist / open,
   keeping the Phase-1 deny term `{capability_denied, Cap, Name}` byte-identical.

**Coordinates** the `seed_policy/1` signature with unit **09** (`emit_core` synthesizes
`instantiate/0` and seeds the policy there, exactly as it seeds fuel via `rt_meter.seed_fuel/1`)
and the `HostWhitelist` Safe-profile constructor with unit **10** (the linker). **Out of
scope:** the emit-side seed call (09 — `ir_lower`/08 cannot emit `instantiate`), a
`safe_whitelist(..)` profile constructor (10), and any new host *functions* — the
broad host environment (`spectest`, the Porffor host shim) is Phase 5/6, not this unit (F8).

---

## A. Starting point — the Phase-1 deny-all boundary (what exists)

`rt_host.gleam` today is exactly the deny-all dispatcher (unit 09): one public function that
**unconditionally** raises the catchable error-class reason `{capability_denied, Cap, Name}`:

```gleam
pub fn call_host(capability: String, name: String, _args: List(x)) -> a {
  erlang_error(#(CapabilityDenied, capability, name))   // never returns
}
```

The calling convention (`instance.gleam`) has generated code emit
`call 'twocore@runtime@rt_host':'call_host'(Cap, Name, [Args…])` for a genuine host import; a
resolved `own`-stdlib call (`("std","gcd")`) is rewritten by `ir_lower` into a **direct**
`rt_stdlib` call and never reaches here (D3a — the stdlib path is separate). Unit 07 keeps that
split and keeps deny-all's exact behaviour as the **unseeded default**, so all 509 existing tests
stay green. The three additive pieces (B/C/D) turn the always-raise into a **policy-gated**
dispatch.

---

## B. The build-fixed handler registry — no ambient authority (D3a)

The `#(capability, name) → handler` mapping is **fixed in this module's source**, exactly as
`rt_bif.allowlist/0` is a fixed list and `rt_table` dispatches through build-controlled closures
(never `apply(Module, Fun, Args)` on data-derived names — [`rt_table.gleam`](../../src/twocore/runtime/rt_table.gleam)
"No ambient authority"). A host value is a raw bit pattern (D5 — i32/i64/f32/f64 all `Int`), so a
handler has the same `List(Int) -> List(Int)` shape `call_indirect` uses.

```gleam
/// A vetted host handler: raw WASM argument bit patterns (D5) → result bit patterns.
/// Every handler is TOTAL and node-safe (tier-P/O, never a node-crashing partial) — a host
/// handler that could crash the node is a sandbox hole. Its FuncType-correctness is the
/// embedder's contract; `rt_host` invokes it structurally by argument list.
pub type HostHandler =
  fn(List(Int)) -> List(Int)

/// Resolve the BUILD-FIXED vetted handler for a host `#(capability, name)`, if 2core provides
/// one. This mapping is a literal `case` in THIS module — it is NEVER constructed from program
/// or runtime data (D3a): the only inputs are the static capability/name strings, and the
/// result is a closure written here at build time, invoked directly (`handler(args)`), never
/// `apply(Mod, Fun, Args)` with a data-derived `Mod`/`Fun`.
///
/// Returns `Ok(handler)` for a vetted pair, `Error(Nil)` when 2core implements no such host
/// function. `Error(Nil)` is FAIL-CLOSED for BOTH whitelist and open (§D): an unimplemented
/// import is denied, never assumed callable.
fn resolve_handler(capability: String, name: String) -> Result(HostHandler, Nil) {
  case capability, name {
    // The Phase-3 host environment is deliberately minimal (F7 adds no host surface). This
    // single representative handler is deterministic + side-effect-free (tier-P), so it neither
    // perturbs the F2 optimizer differential nor introduces non-determinism, and it exercises
    // the admit path end-to-end. The broad environment (spectest, the Porffor host shim) plugs
    // into this same registry in Phase 5/6 — one new arm each, no dispatch change (F8).
    "env", "identity" -> Ok(fn(args) { args })
    _, _ -> Error(Nil)
  }
}
```

> **Spec anchor.** A WebAssembly module's host imports are resolved at **instantiation** against
> external values the embedder supplies (WebAssembly spec §4.5.4 *Instantiation* / §2.5.11
> *Imports*); an unprovided import is a link error. `resolve_handler` is 2core's fixed set of
> *provided* host functions; a `#(cap,name)` with no handler is the "not provided" case. Host
> function invocation itself (§4.4.7 *Function Calls*, host-function case; §7 *Embedding*) may
> return results, trap, or diverge — so denying a call by diverging with an error is spec-sound.

---

## C. The per-instance policy seam — fail-closed by default (D4)

The instance is the unit of policy (F4). Each instance runs in its **own** process (E1,
one-instance-one-process), so its host posture lives in that process's dictionary — exactly where
Phase-2 put the state cell and unit 05 puts the fuel budget (`rt_meter.seed_fuel/1`). This keeps
`host_module` a **single** build-controlled module for every profile: the policy selects
*behaviour*, not the module.

```gleam
import gleam/dynamic.{type Dynamic}
import twocore/runtime/instance.{
  type HostPolicy, HostDenyAll, HostOpen, HostWhitelist,
}

/// `erlang:put/2` / `erlang:get/1` — process-local dictionary (tier-O, node-safe), the same
/// mechanism `rt_meter`'s fuel counter and `rt_state`'s cell use. Process-local ⇒ two instances
/// on one node meter and gate INDEPENDENTLY (F4 coexistence).
@external(erlang, "erlang", "put")
fn erlang_put(key: k, value: v) -> Dynamic

@external(erlang, "erlang", "get")
fn erlang_get(key: k) -> Dynamic

/// Identity coercion of the stored `Dynamic` back to `HostPolicy`. Sound because `rt_host` is
/// the SOLE producer of the term under this key (the `rt_table` cell-coercion precedent). Only
/// reached for a seeded value; the unseeded `undefined` atom is guarded FIRST (see below).
@external(erlang, "gleam_stdlib", "identity")
fn coerce_policy(raw: Dynamic) -> HostPolicy

/// The pdict key. A 0-field constructor ⇒ the unique, namespace-hygienic atom
/// `twocore_rt_host_policy`, so it cannot clash with another library's pdict keys.
type HostKey {
  TwocoreRtHostPolicy
}

/// Seed THIS instance's host policy (F4). Called once by `emit_core`'s synthesized
/// `instantiate/0` (unit 09 — the sole seed emitter) inside the instance's OWNED process,
/// alongside `rt_meter.seed_fuel` and the state cell — so the posture is isolated per instance
/// and GC'd with the process.
///
/// - `policy`: the build-controlled `binding.host_policy` (`HostDenyAll` for Safe,
///   `HostWhitelist(allow)` for Safe-whitelist, `HostOpen` for Unsafe). The value is baked as a
///   Core Erlang literal at emit time from the `Binding` — it is NEVER derived from program data.
/// - Returns `Nil`. Total; process-local; cannot crash the node.
pub fn seed_policy(policy: HostPolicy) -> Nil {
  let _ = erlang_put(TwocoreRtHostPolicy, policy)
  Nil
}

/// The host policy in effect for the CURRENT process.
///
/// - Returns the seeded `HostPolicy`, or **`HostDenyAll` when no policy was seeded** — the
///   FAIL-CLOSED default (D4). `erlang:get/1` yields the atom `undefined` for an absent key;
///   `current_policy` treats that as deny, so Phase-1/2 code (which never seeds) still denies
///   every host call and the 509 existing tests are unchanged. Total; exposed for tests.
pub fn current_policy() -> HostPolicy {
  let raw = erlang_get(TwocoreRtHostPolicy)
  case is_unseeded(raw) {
    True -> HostDenyAll
    False -> coerce_policy(raw)
  }
}
```

`is_unseeded(raw)` is `True` iff `raw` is the Erlang atom `undefined` (what `erlang:get/1`
returns for a never-set key), decoded via `gleam/dynamic`. **This guard is load-bearing** — it,
not `coerce_policy`, is what makes "no seed ⇒ deny" a hard property, so it gets its own test
(§Verification). (Note `HostDenyAll`/`HostOpen` compile to the atoms `host_deny_all`/`host_open`
and `HostWhitelist(_)` to `{host_whitelist, Allow}` — all distinct from `undefined`, so the guard
is unambiguous.)

---

## D. The policy-gated dispatch — deny / whitelist / open

`call_host/3` keeps its **frozen name + arity** (the ABI generated code emits) and its **exact
deny term**; only its type is refined so a dispatched call can *return* a result. Since deny-all
never returns and no Phase-1/2/3 corpus program consumes a host result yet, the refinement is
behaviour-preserving for every existing path.

```gleam
import gleam/list

/// `erlang:error/1` — raises a catchable error-class exception; never returns.
@external(erlang, "erlang", "error")
fn erlang_error(reason: a) -> b

/// The deny-all rejection tag → the atom `capability_denied` (unchanged from Phase 1).
type Tag {
  CapabilityDenied
}

/// Dispatch a host import under THIS instance's policy (F4). ABI: arity 3, name `call_host`,
/// emitted verbatim by `emit_core` — UNCHANGED, so no generated code changes.
///
/// - `capability` / `name`: the import's `#(capability, name)` identity (echoed on denial).
/// - `args`: the call's raw WASM argument bit patterns (D5).
/// - Return: the handler's result bit patterns on a permitted, implemented call; otherwise it
///   **diverges** by raising the catchable `{capability_denied, Capability, Name}` (error class,
///   the same channel traps ride — unit 11's runner catches it as a `Trapped` denial).
///
/// Policy semantics (fail-closed conjunction — permitted AND implemented):
/// - `HostDenyAll` — **every** call denied (no `#(cap,name)`, argument, or handler makes it
///   return). Deny-all denies even a call for which `resolve_handler` HAS a handler.
/// - `HostWhitelist(allow)` — dispatched iff `#(cap,name) ∈ allow` AND a handler exists; every
///   other pair (unlisted, or listed-but-unimplemented) is denied.
/// - `HostOpen` — dispatched iff a handler exists; a `#(cap,name)` with no build-fixed handler
///   is STILL denied (even open cannot invoke a non-existent handler — no ambient authority).
pub fn call_host(
  capability: String,
  name: String,
  args: List(Int),
) -> List(Int) {
  case current_policy() {
    HostDenyAll -> deny(capability, name)
    HostWhitelist(allow) ->
      case list.contains(allow, #(capability, name)) {
        True -> dispatch(capability, name, args)
        False -> deny(capability, name)
      }
    HostOpen -> dispatch(capability, name, args)
  }
}

/// Resolve the build-fixed handler and invoke it DIRECTLY (`handler(args)` — a closure
/// application, never `apply/3` on data-derived names, D3a). No build-fixed handler ⇒ deny
/// (fail-closed for both whitelist and open).
fn dispatch(capability: String, name: String, args: List(Int)) -> List(Int) {
  case resolve_handler(capability, name) {
    Ok(handler) -> handler(args)
    Error(Nil) -> deny(capability, name)
  }
}

/// Raise the Phase-1 deny term (byte-identical): error-class `{capability_denied, Cap, Name}`.
fn deny(capability: String, name: String) -> List(Int) {
  erlang_error(#(CapabilityDenied, capability, name))
}
```

**Why `host_module` stays one build-controlled module.** All three postures dispatch through the
single `rt_host` module named by `binding.host_module` (`"twocore@runtime@rt_host"` for Safe
*and* Unsafe — `profiles.unsafe()` keeps the identical `*_module` names, keystone §B.4). The
policy is per-instance state, not a module swap; the reachable code is always this module's
build-fixed `case`. "Open" widens *which build-fixed handlers are reachable*, it introduces **no**
new authority: the reachable set is bounded by `resolve_handler`, and the whitelist allow-set is
build-controlled `Binding` data baked at emit time — never a module/atom from program input (D3a).

**Wiring the seed (units 09/10).** `emit_core` (unit 09) synthesizes `instantiate/0` and is the
**sole** emitter of per-instance seeds: it emits one `call
'twocore@runtime@rt_host':'seed_policy'(P)` there, where `P` is `binding.host_policy` baked as a
Core Erlang literal — emitted under **both** profiles (`ir_lower`/08 never emits `instantiate`).
Safe seeds `host_deny_all` (or a whitelist); Unsafe seeds `host_open`. Every *non-*`instantiate`
function body is posture-agnostic, so the **hot** host-call sites are byte-identical across
profiles; only `instantiate/0` differs, and only by its one-time seed literal. A Safe
**whitelist** profile (`mode: Safe`, `host_policy: HostWhitelist(allow)`) is a valid fail-closed
posture; its constructor is unit 10's to expose (this unit makes it *work* and *tested* via
`seed_policy`).

**Host is fail-closed by omission; fuel must be armed.** Note the asymmetry with metering: an
unseeded host posture defaults to `HostDenyAll` — deny is the safe omission, so a build that
forgets to seed still denies. A fuel budget has no safe omission — an unseeded metered build
would run unbounded — so `instantiate/0` **always** actively arms it
(`seed_fuel(binding.fuel_budget)` under `MeterFuel`, per units 05/09). The host channel is the
model both seams follow: the seed is the source of truth, and the *only* posture reachable by
omission is the fail-closed one.

---

## Effect / soundness / security note

- **No ambient authority survives open (D3a).** The dispatched target is always a closure written
  in this module and selected by a literal `case`; `rt_host` never builds a module/function atom
  from `capability`/`name`/`args` and never calls `erlang:apply/3` on data-derived names. Open
  widens the *build-controlled* reachable set; it adds none. Unit 09 extends the structural
  codegen security-invariant test to cover the `open` posture (no data-driven `apply`).
- **Fail-closed everywhere (D4/D9).** The unseeded default is deny; deny-all denies unconditionally
  (even a handler-backed pair); whitelist denies the complement of `allow` **and** any
  listed-but-unimplemented pair; open denies any handler-less pair. There is no `#(cap,name)`,
  argument, seeded value, or handler that turns `HostDenyAll` into a return. `HostOpen` is
  reachable **only** through `profiles.unsafe()` (keystone §B.4) — an explicit, tested opt-in,
  never a Safe posture, never a default.
- **Host calls stay effectful (F3/E6).** `CallHost` is an effect barrier regardless of policy; the
  optimizer never elides, reorders, CSEs, or duplicates a host call (baseline touches only pure
  subtrees; aggressive relaxes only *named*, corpus-neutral barriers, and host calls are not
  among them). Changing the host *dispatch* changes no effect classification.
- **Tier-O, node-safe.** The pdict policy read is tier-O (Safe permits P or O, never N); every
  handler is total (a partial handler that could crash the node is a sandbox hole — the type
  documents the totality obligation). The deny term rides the same catchable error-class channel
  as `rt_trap` (`{wasm_trap, Kind}` ↔ `{capability_denied, Cap, Name}`), so the run-ABI surfaces a
  denial as an ordinary `Trapped` with no new plumbing.
- **Coexistence (F4).** Safe and Unsafe are distinct **builds** of the same source module (B3
  monomorphization — different OUTPUT modules that nonetheless share this one
  `twocore@runtime@rt_host` runtime module). Because the posture is process-local per-instance
  state, a Safe (deny) instance and an Unsafe (open) instance run on one node with **no** policy
  leakage — each process reads only its own seed. Unit 10/11 prove the end-to-end coexistence.

---

## Verification (Definition of Done)

Tests assert **security / spec behaviour**, never "whatever the code emits" (D8). The five
Phase-1 deny-all tests stay green (update only the one `["payload"]` `List(String)` argument in
`denies_arbitrary_capability_test` to numeric — the refined `List(Int)` arg type; deny ignores
args, so the asserted denial is unchanged). Denials are caught via the existing
`twocore_rt_test_ffi` `host_denial/1` helper.

- **Default is deny-all (fail-closed).** In a process that has **not** called `seed_policy`,
  `current_policy() == HostDenyAll` and `call_host(cap, name, _)` denies for a spread of pairs —
  including `#("env","identity")`, which HAS a handler. Proves "no seed ⇒ deny" (the `is_unseeded`
  guard), the property that keeps Phase-1/2 unchanged (§4.5.4 — an unprovided import is not
  callable).
- **Deny-all denies everything.** `seed_policy(HostDenyAll)`; the same spread all deny, including
  the handler-backed `#("env","identity")`. Deny-all is unconditional — no argument or handler
  makes it return.
- **Whitelist admits exactly the listed pairs.** `seed_policy(HostWhitelist([#("env","identity")]))`;
  `call_host("env","identity",[7,8]) == [7,8]` (dispatched to the vetted handler); **every**
  other pair denies — an unlisted handler-backed pair (if any is added later), an unlisted
  handler-less pair (`#("fs","open")`), and the empty pair `#("","")`. Assert admission of the
  listed set AND denial of its complement (the mandate's "admits exactly the listed, denies the
  rest").
- **Whitelisted-but-unimplemented denies.** `seed_policy(HostWhitelist([#("fs","open")]))` (a pair
  with no handler); `call_host("fs","open",_)` denies. Proves the fail-closed conjunction
  (permitted AND implemented), not just membership.
- **Open dispatches, but only to real handlers.** `seed_policy(HostOpen)`;
  `call_host("env","identity",[42]) == [42]`; a handler-less pair `call_host("no","handler",_)`
  **denies** — even open cannot invoke a non-existent handler (D3a; §4.5.4 unprovided import).
- **Isolation (per-instance policy).** Seeding a policy in one process does not change
  `current_policy()` in a freshly-spawned process (it reads `HostDenyAll`) — the pdict is
  process-local, the basis of F4 coexistence. (Full Safe+Unsafe coexistence e2e is unit 11.)
- **No ambient authority (structural).** By construction/review: `dispatch` invokes a build-fixed
  closure, never `apply/3` on `capability`/`name`. Unit 09 extends the emit-side security-invariant
  test to the `open` posture.
- **Gate.** `gleam format --check src test` clean; `gleam build` **zero warnings** (no `todo`,
  underscore unused params); **every public function doc-commented** with contract + divergence
  modes (D8); `gleam test` green before and after (509 → 509 + the new rt_host cases). **Done = the
  rt_host suite (deny/whitelist/open + default + isolation) passes**, not "it compiles."

---

## What this unit leaves

- **Unit 09 (`emit_core`)** — synthesizes `instantiate/0` (the sole emitter of per-instance
  seeds) and binds `rt_host.seed_policy/1` there: the seed carries `binding.host_policy` as a Core
  Erlang literal (alongside `rt_meter.seed_fuel`), and the `open`-posture structural security test
  (no data-driven `apply`) extends the Phase-2 codegen invariant test. `ir_lower`/08 does the
  IR-side lowering that feeds emit but never emits `instantiate` (keystone §C.2, corrected).
- **Unit 10 (linker / profiles)** — may expose a Safe **whitelist** profile (`mode: Safe`,
  `host_policy: HostWhitelist(allow)`); `rt_host` already makes it fail-closed-correct. Assembles
  `profiles.unsafe()` (open) coexistence.
- **Unit 11 (capstone)** — proves a Safe (deny) and an Unsafe (open) instance of the same module
  coexist on one node with no policy leakage, through the run-ABI.
- **Phase 5/6** — the real host environment: `spectest`'s functions (Phase 5, with non-function
  imports) and the Porffor host shim (Phase 6) each add one `resolve_handler` arm — no dispatch,
  seam, or policy change (F8).

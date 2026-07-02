# 2core

> ⚠️ **Experimental.** This is a research project, not a production tool. The WebAssembly
> frontend and the whole compiler platform behind it — the shared optimizer, both security
> modes, and the trust-tier runtime ladder — now work end-to-end. But it's early: several
> post-MVP WASM proposals and all the non-WASM frontends aren't built yet, and it isn't
> tuned for production. Check [`specs/state.md`](specs/state.md) for exactly what is and
> isn't done.

**2core is an experiment in compiling code to run fast and _preemptively_ on the BEAM.**

It's a **multi-frontend compiler platform**, written in [Gleam](https://gleam.run), that
lowers several source languages into **one shared, language-neutral intermediate
representation (IR)** and emits **Core Erlang** — so the output runs as ordinary,
fairly-scheduled BEAM code — **compiled rather than interpreted**. The bet is that compiling *to Erlang* — rather than
shipping a long-running interpreter — is what preserves BEAM preemption (even a tight loop
yields fairly and can't monopolise a scheduler) while getting close to native speed.

WebAssembly is the **first** frontend, because so much already compiles *to* WASM —
which transitively brings Rust and (via [Porffor](https://github.com/CanadaHonk/porffor),
a JS→WASM compiler) JavaScript along. A goal that follows directly from the WASM frontend
is **JavaScript on the BEAM via Porffor** — *any Porffor application runs via 2core on the
BEAM* — and a Gleam/Erlang frontend is planned to follow. The intent is for all of
them to share one IR, one optimizer, one backend, one standard library, and one security
model.

## Status — what works today

**Phases 1–4 are complete.** A real `.wasm` binary compiles all the way to a loaded,
running `.beam` module through a fully modular `decode → validate → lower → IR → optimize →
Core Erlang → .beam → instantiate → run` pipeline — and it now runs under **two coexisting
security modes** (sandboxed **Safe** and aggressive **Unsafe**) across a **trust-tier
runtime ladder** (from a pure "runs-anywhere" build to O(1) native-ish memory). The whole
project builds with **zero warnings** and **906 passing tests**.

```sh
$ gleam run -- run add.wasm add 2 3             # decode → validate → lower → IR → optimize → Core Erlang → .beam → run
5
$ gleam run -- run fib.wasm fib 10
55
$ gleam run -- run add.wasm add 2 3 --portable  # the tier-P "runs-anywhere" build (no OTP-native state, no NIF)
5
$ gleam run -- run add.wasm add 2 3 --unsafe    # the aggressive-optimizer "Unsafe" profile
5
$ gleam run -- ir add.wasm                       # dump the shared IR in its textual form
module @twocore@wasm@add { … }
```

Every stage is independently invokable (`decode`, `validate`, `lower`, `ir`, `ir-lower`,
`opt`, `emit`, `to-core`, `build`, `run`). What's proven end-to-end:

- **the WASM 1.0 MVP** — integer + control flow (`block`/`loop`/`if`, `br`/`br_table`,
  `call`), **linear memory** (the full load/store matrix, `memory.size`/`grow`,
  bounds-checked → trap), **tables + `call_indirect`** (runtime type-check → trap),
  **globals**, the **full float + conversion** surface, and active data/element/start
  **instantiation**;
- **spec-faithful numerics** *through codegen* — two's-complement wrap, signed/unsigned
  `div`/`rem` + trapping conversions, IEEE floats (round-to-nearest-ties-to-even, canonical
  NaN, the `INT_MIN / -1` / divide-by-zero / out-of-bounds / type-mismatch **traps**);
- **constant-space, preemptible loops** — `sum_to(100000)` runs as a tail-recursive BEAM
  loop without stack growth (even with metering, memory writes, or the threaded state
  record in the loop);
- **a shared IR optimizer** — a *baseline* (trust-neutral) pass set and an *aggressive*
  (Unsafe-only) pass set, proven to change **no** observable result: `OptNone ≡ Baseline ≡
  Aggressive`, byte-identical across the whole corpus;
- **two coexisting security modes** — **Safe** (vetted in-house stdlib, a tiny BEAM-function
  allowlist, deny-all host, **enforcing** CPU-fuel metering that traps a runaway loop, no
  node-crashing native code) and **Unsafe** (aggressive optimizer, passthrough stdlib, open
  BIFs, no metering); the *same source* compiles to both, and they run isolated on one node;
- **a trust-tier runtime ladder** — a tier-P **`threaded`** "runs-anywhere" build (a
  purely-functional instance-state record threaded through the generated code — no process
  dictionary, no OTP-native state, no NIF, provably can't crash the node), a tier-O
  **`atomics`** O(1) memory backend, and a tier-N **`nif`** ceiling (interface + node-safe
  skeleton; the production C impl is deferred). Every combination produces byte-identical
  results;
- **the sandbox seams** — the `call_host` capability boundary (fail-closed), bounds-checked
  memory with a **grow resource cap**, `call_indirect` with no ambient authority, and
  Safe-mode's **fail-closed** rejection of node-crashing (tier-N) backends; mutable state is
  per-instance (one-instance-one-process) and reset on instantiation.

What's deliberately **not** here yet (Phase 5+): reference types, bulk memory, multi-memory,
SIMD, memory64, non-function imports, the WAT text parser; a production C NIF for the tier-N
ceiling; and the JS/Rust/Gleam frontends. The full roadmap and per-component status live in
[`specs/state.md`](specs/state.md).

## How it works

- **One shared IR, many frontends.** Every source language lowers into a single,
  **language-neutral** IR (deliberately *not* WASM-shaped) with a canonical textual form
  (`.ir`). Behind it sit one optimizer, one backend, and one runtime — so adding a
  language is "write a frontend," not "rebuild the stack."
- **Structured control → tail-recursive loops.** `block`/`loop`/`if`/`switch` lower to a
  `letrec` of tail-recursive functions; proper BEAM tail calls make loops constant-space
  and preemptible.
- **A dual value model.** A BEAM-native **term** model (for dynamic/term languages) *and*
  an opt-in **fixed-width numeric + linear-memory** model (for WASM/Rust), with explicit
  conversions between them — so term languages don't pay for linear memory, and low-level
  languages keep exact WASM semantics.
- **Safe / Unsafe modes.** Two global modes that coexist on one node: **Safe** sandboxes
  untrusted code (vetted in-house stdlib, a tiny allowlist of BEAM functions, deny-all host
  access, enforcing CPU-fuel metering, no node-crashing native code); **Unsafe** emits the
  fastest code (aggressive optimizer, passthrough stdlib, open BIFs, no metering). Same
  source, two builds, isolated per instance.
- **A trust-tier runtime ladder.** Orthogonal to Safe/Unsafe: the mutable-state layers
  (memory, tables, instance state) have interchangeable backends spanning **P** (pure — no
  OTP-native state, no NIF, runs anywhere, can't crash the node) → **O** (OTP-native, O(1),
  memory-safe) → **N** (native NIF, the ceiling, can crash the node). Safe permits P or O,
  never N; the tier is a build-time choice, so identical source yields different `.beam`s
  with byte-identical behaviour.
- **Everything modular.** Each stage and runtime layer is a narrow, independently-callable
  interface with interchangeable implementations — the design treats that modularity as
  *both* the security model and the replaceability model.
- **Built in Gleam; output is pure Core Erlang.** The compiler runs at build time on the
  BEAM; whether any native code runs underneath is a per-deployment choice.

## An honest note on speed

The pitch is *preemptive and close-to-native*; the measured reality (see the [Phase-4
benchmark](docs/phase-4-benchmark.md)) is more nuanced, and we'd rather be honest about it.
Compiling to Erlang buys preemption for free, and the "runs-anywhere" threaded build carries
essentially **no** overhead over the tier-O default. On raw throughput, the tier-O `atomics`
memory backend is a measured **~2.3–2.9×** faster than the pure `paged` one — but 2core is
**not yet** faster than hand-written Erlang on a memory-heavy kernel (CRC-32 is ~32× slower,
down from ~76×). The remaining gap is BEAM bignum numerics and the per-operation runtime
seam call; the biggest lever left — a native-code (tier-N) numerics/memory backend — is
deliberately deferred. In short: correct, sandboxed, preemptive, and runs-anywhere today;
faster-than-hand-written-Erlang is future work, and honestly measured, not asserted.

## Frontend roadmap

1. **WASM** — *implemented.* Also the path to **Rust → BEAM** (via Rust→WASM).
2. **JavaScript via [Porffor](https://github.com/CanadaHonk/porffor)** — *a goal:* a JS→WASM
   AOT compiler feeding the WASM frontend, so **any Porffor application runs via 2core on the
   BEAM**. Now that 2core covers the WASM 2.0 surface (minus SIMD), the WASM Porffor emits is
   already largely runnable; the work remaining to reach the goal is a **Porffor-ABI host
   shim** (an `rt_host` supplying Porffor's runtime intrinsics, since Porffor uses its own ABI
   rather than WASI) — not yet built or tested.
3. **Erlang / Gleam frontend** — write Gleam, deploy to the platform, and (via Safe mode)
   be provably unable to take over the VM.

## WebAssembly conformance

The WASM frontend is differential-tested against the official
[WebAssembly spec test suite](https://github.com/WebAssembly/testsuite) (pinned), run
through the real compile-and-execute pipeline. Of the assertions we attempt, **100% pass
and 0 fail** (15,747 passing), and in-scope coverage of the MVP suite is **~97%**; the
remaining "out of scope" share is spec coverage for post-MVP proposals the platform doesn't
target yet (reference types, bulk/multi-memory, SIMD). Because the optimizer, both security
modes, and every trust-tier are proven behaviour-preserving, that green holds **identically**
under the Safe *and* Unsafe profiles and across every shipped `(state × memory-tier)`
combination.

<p align="center">
  <img src="docs/wasm-conformance.svg" width="640"
       alt="WebAssembly spec-suite conformance: 15,747 passing, 411 out of scope, 0 failing">
</p>

> Regenerate with `scripts/gen-conformance-svg.sh` (run `RUN_VENDOR=1 …` to fetch the full
> pinned fixture set first). The image reflects the full allowlist; a fresh checkout ships
> only a small committed fixture subset, so `gleam test` runs green without re-vendoring.

## Development

Requires the standard Gleam toolchain — **Gleam 1.17+**, Erlang/OTP 29. For the full
conformance run you also need **wabt** (`wat2wasm`/`wast2json`/`spectest-interp`).

```sh
gleam test                          # run all tests (unit + the committed conformance subset)
gleam format --check src test       # CI requires this
gleam run -- run mod.wasm fn a b            # compile a .wasm and invoke an export on the BEAM
gleam run -- run mod.wasm fn a b --unsafe   # …under the aggressive Unsafe profile
gleam run -- run mod.wasm fn a b --portable # …under the tier-P runs-anywhere build
gleam run -- ir mod.wasm                    # dump the shared IR (.ir text)

# Full WASM spec-suite conformance (clones the pinned testsuite, needs wabt + network):
bash test/twocore/conformance/vendor/vendor.sh && gleam test
```

See [`CLAUDE.md`](CLAUDE.md) for contributor conventions (definition of done, testing
against the spec, commit rules).

## Specification

- [`specs/00-high-level.md`](specs/00-high-level.md) — the canonical architecture spec
  (the IR, the layer map, the security model).
- [`specs/state.md`](specs/state.md) — the live status ledger: every component, what's
  done, and what each leaves for the next.
- Per-phase work breakdowns (one unit per file), each with an `00-overview.md`:
  [`phase-1/`](specs/phase-1/) (WASM MVP foundations), [`phase-2/`](specs/phase-2/) (full
  WASM 1.0), [`phase-3/`](specs/phase-3/) (the optimizer + Unsafe mode + real metering),
  [`phase-4/`](specs/phase-4/) (the trust-tier ladder + the runs-anywhere build).

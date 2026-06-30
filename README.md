# 2core

> ⚠️ **Experimental — pre-implementation.** Nothing described here is built yet. This repository is an experiment that is *going to try* to do what's laid out below. Treat everything as **intent and direction**, not as working features or claims about what exists today.

**2core is an experiment in compiling code to run fast and _preemptively_ on the BEAM.**

The goal it's reaching for: a **multi-frontend compiler platform**, written in [Gleam](https://gleam.run), that lowers several source languages into **one shared, language-neutral intermediate representation (IR)** and emits **Core Erlang** from it — so the output runs as ordinary, fairly-scheduled BEAM code. Loosely: the way Arc runs JavaScript on the BEAM today, but **compiled rather than interpreted**.

None of this works yet. The sections below describe the plan, not the present.

## The goal

The project wants to find out whether you can take code written for *other* runtimes — starting with WebAssembly — and **compile** it down to Core Erlang so it runs natively on the BEAM: fast, and **preemptively scheduled** like any other BEAM process (so even a tight loop yields fairly and can't monopolise a scheduler). The bet is that compiling to Erlang — rather than shipping a long-running interpreter — is what preserves that preemption while getting close to native speed.

WebAssembly is the entry point because so much already compiles *to* WASM. If the WASM frontend works, then Rust (via Rust→WASM) and JavaScript (via a JS→WASM compiler) come along transitively — and beyond that, the plan is to add native frontends for JavaScript and Gleam/Erlang. The intent is for all of them to share one IR, one optimizer, one backend, one standard library, and one security model.

## How it's going to try to get there

Key ideas the design is betting on — all still to be built:

- **One shared IR, many frontends.** Every source language is meant to lower into a single, **language-neutral** IR (deliberately *not* WASM-shaped). Behind that IR sits one optimizer, one backend, and one runtime — so adding a language is "write a frontend," not "rebuild the stack."
- **WASM first.** The WebAssembly frontend is the first thing to build. It aims to transitively unlock **Rust → Erlang** (via Rust→WASM) and **JS → Erlang** (via a JS→WASM compiler) without writing those frontends by hand.
- **Compile to Core Erlang; run on the BEAM.** The backend intends to emit Core Erlang, then hand it to the standard Erlang compiler to produce a loadable `.beam` module — so generated code is ordinary BEAM code, **preemptively scheduled** for free.
- **Structured control flow → tail-recursive loops.** WASM (and JS/Gleam) control flow is *already* structured, so the plan is to lower `block`/`loop`/`if`/`switch` into a `letrec` of tail-recursive functions. Proper BEAM tail calls should make loops constant-space and preemptible.
- **A dual value model.** A BEAM-native **term** model (for dynamic/term languages like JS and Gleam) *and* an opt-in **fixed-width numeric + linear-memory** model (for WASM and Rust), with explicit conversions between them — so term languages don't pay for linear memory, and low-level languages keep exact WASM semantics.
- **Safe / Unsafe modes.** Two planned global modes: **Unsafe** (emit the fastest possible near-native code, full BEAM access) and **Safe** (sandbox untrusted code — an in-house vetted standard library, a tiny allowlist of BEAM functions, deny-all host access, no node-crashing native code, and metering on). The intent is for Safe and Unsafe instances to coexist on one node.
- **Everything modular.** Each stage and runtime layer is meant to be a narrow, independently-callable interface with many interchangeable implementations. The design treats that modularity as *both* the security model and the replaceability model.
- **Built in Gleam; output is pure Core Erlang.** The compiler itself is written in Gleam (build-time, on the BEAM); whether any native code runs underneath is a per-deployment choice, never a global assumption.

## Planned frontend roadmap

In intended order — none implemented yet:

1. **WASM** *(first)* — the initial frontend; also brings **Rust → Erlang** along via Rust→WASM.
2. **JavaScript via [Porffor](https://github.com/CanadaHonk/porffor)** *(bridge)* — a JS→WASM AOT compiler feeding the WASM frontend, as an early proof-of-concept. Bounded by Porffor's experimental JS coverage, and explored as a benchmark rather than a complete JS solution.
3. **Arc as a native JavaScript frontend** *(later)* — emitting the IR directly (using the term value model instead of boxing JS through linear memory), rather than going through the WASM bridge.
4. **Erlang / Gleam frontend** *(later)* — write Gleam, deploy to the platform, and (via Safe mode) be provably unable to take over the VM.

## Status

Pre-implementation. The repository currently holds the architecture specification and a hello-world Gleam scaffold — `gleam run` just prints a placeholder. There is no compiler here yet.

## Specification

The full, canonical architecture spec lives in [`specs/00-high-level.md`](specs/00-high-level.md). It is the source of truth for everything above and goes much deeper into the IR, the layer map, the security model, and the work breakdown.

## Development

```sh
gleam run   # run the (placeholder) entry point
gleam test  # run the tests
gleam format # format the code (CI requires this)
```

See [`CLAUDE.md`](CLAUDE.md) for contributor conventions (definition of done, testing against the spec, and commit rules).

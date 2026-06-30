# Specification: A Multi-Frontend Compiler Platform Targeting the BEAM

**Status:** Canonical architecture specification (pre-implementation). Supersedes all prior WASM→Core Erlang scope/addendum/modular documents — they are folded in here and re-scoped. WASM is now the *first frontend* of a larger compiler platform, not the whole system.
**Audience:** A downstream planning agent and the agent swarm that implements it.

**The shape of the thing.** A compiler that lowers multiple source languages into **one shared, language-neutral IR (ours)**, and emits **Core Erlang** from that IR so the result runs **fast and preemptively on the BEAM** — the way Arc runs JS today, but compiled rather than interpreted. WASM is the first frontend (and transitively gives Rust→Erlang and, via Porffor, JS→Erlang); Arc (JS) and Erlang/Gleam follow as additional frontends. All frontends share one IR, one optimizer, one backend, one standard library, and one security model.

**Three governing constraints (unchanged):**
1. **Built in Gleam** (build-time, on the BEAM).
2. **Generated code is pure Core Erlang.** Native code underneath is a per-deployment, per-layer choice (§10), never a global property.
3. **Every component is modular** — each stage and layer is a narrow, independently-invokable interface with many interchangeable implementations. This is the security model *and* the replaceability model (§13).

**Faithfulness beats raw speed; breadth and parallelism beat minimal effort** (implemented by a large agent swarm).

---

## 1. The platform vision (what's now vs. later)

```
   FRONTENDS (per-language → IR)         SHARED MIDDLE-END            BACKEND          RUNTIME
 ┌───────────────────────────┐
 │ WASM   (now)              │─┐      ┌──────────────────┐     ┌──────────────┐   ┌──────────────┐
 │ Rust   (via WASM, now-ish)│ ├────▶ │   SHARED IR      │────▶│ IR → Core    │──▶│ shared rt +  │
 │ JS via Porffor (this wk)  │ │      │  + optimizer     │     │ Erlang AST → │   │ optional     │
 │ JS/Arc (later, native FE) │ │      │  + stdlib/cap    │     │ .core → BEAM │   │ linear-mem   │
 │ Erlang/Gleam (later)      │─┘      │    lowering      │     └──────────────┘   │ subsystem    │
 └───────────────────────────┘        └──────────────────┘                       └──────────────┘
         each stage is a public, independently-callable interface; the IR has a textual form
```

- **Now:** the WASM frontend, the shared IR, the IR→Core-Erlang backend, the Safe/Unsafe security modes, and stdlib scaffolding. Rust→Erlang falls out for free (Rust→WASM→IR→Erlang) — not native-Rust speed, but real.
- **This week (bridge):** JS via **Porffor** (JS→WASM AOT) feeding the WASM frontend → "JS on the BEAM, fast." A proof-of-concept, bounded by Porffor's maturity (§8.2).
- **Later:** **Arc as a native JS frontend** (it stops being an interpreter and emits the IR directly — better than the Porffor bridge because it uses the term value model and the shared stdlib instead of boxing JS through linear memory); an **Erlang/Gleam frontend** (write Gleam, deploy to the platform, provably unable to take over the VM via Safe mode).

The decisions in §2 are what must be made **now** — even though most frontends are later — so the platform doesn't have to be rebuilt to accept them.

---

## 2. Decisions to lock now (the load-bearing ones)

These keep the IR frontend-agnostic and every stage independently targetable. Get them right up front; they are expensive to retrofit.

1. **The IR is language-neutral and the stable public target** — *not* WASM-shaped. No WASM-isms (linear memory, stack typing, fixed-width-only numerics) baked into the IR core. WASM is one frontend that lowers *into* the IR.
2. **Linear memory is an optional IR feature**, declared per module — so term-based frontends (JS, Gleam) don't pay for it and don't link the memory runtime.
3. **IR control flow is structured** (block/loop/if/switch/break/continue/return; no arbitrary `goto`). Every frontend either is already structured (WASM, JS, Gleam) or relooper-izes before the IR. This keeps the backend (one uniform `letrec`+tail-call lowering) simple.
4. **Dual value model:** a high-level **term model** (BEAM-native values — the default, used by JS/Gleam/Erlang) and an opt-in **fixed-width numeric + linear-memory model** (used by WASM/Rust), with explicit conversion ops between them. Don't force JS objects through linear memory, nor WASM bytes through Erlang terms.
5. **Every stage boundary is a public, independently-invokable API, and the IR has a canonical, serializable textual form** (`.ir`). Any part of the chain can be driven, dumped, and tested in isolation — this is the explicit requirement that each link be callable independently.
6. **`call_host` is the single capability boundary.** Stdlib calls and imported host functions both route through one IR node; Safe/Unsafe enforcement lives there and nowhere else. Fail closed.
7. **The standard library is defined at the IR level** (Gleam-style: tiny built-in surface, most of stdlib is a library targeting the IR), so it's identical across all frontends and swappable by security mode.
8. **Safe / Unsafe are global modes** that select stdlib implementation, the BEAM-function allowlist, optimization posture, runtime trust tier, and metering — in one switch (§6).
9. **Compiled is the primary route, not interpreted**, and compiling to *Erlang* (not a long-running NIF) is what preserves BEAM preemption (§11). Interpreted-vs-compiled stays formally open, but the spec commits to compiled with an interpreter only as a fallback for unsupported features.
10. **Runtime splits in two:** a **shared runtime** (numerics, traps, instance state, host/capability dispatch, metering, stdlib) used by every frontend, and an **optional linear-memory subsystem** (memory, tables) linked only for modules that use linear memory.

---

## 3. The shared IR (concrete design)

The IR is a structured, functional, language-neutral IR that targets the BEAM. Concrete shape:

- **Module** = functions + declarations (globals; optional memories; optional tables; imports; exports; data/element segments for memory-using modules). A module flags whether it uses the **linear-memory subsystem**; if not, it uses term values throughout and links no memory runtime.
- **Function** = name, typed params + locals, body (an expression tree), with **proper tail-call semantics** (so the backend's tail calls become constant-space BEAM loops).
- **Control flow — structured only:** `block`, `loop`, `if/else`, `switch` (multi-way), `break(label)`, `continue(label)`, `return`. Labels by name; the backend resolves them to `letrec` continuation functions.
- **Values — two first-class layers:**
  - **Term values** (default): map directly to BEAM terms — bignum ints, floats, atoms, binaries, tuples, lists, maps, closures, plus a boxed `dynamic` for JS semantics. Frontends: JS/Gleam/Erlang.
  - **Low-level numerics + linear memory** (opt-in): `i32/i64/f32/f64` with explicit wrap/overflow/trap semantics, and a byte-addressable linear memory with typed load/store. Frontends: WASM/Rust.
  - **Explicit conversions** between the two (box an `i32` into a term; read memory bytes into a binary; etc.). No implicit bridging.
- **Operations:** low-level numeric ops (width-tagged; semantics in §9.1); term construction/destructuring (cons/tuple/map build + pattern match); memory load/store (low-level path only).
- **Calls — three kinds, all first-class:**
  - `call_direct(fn, args)` — to another IR function.
  - `call_indirect(table, idx, type, args)` — dynamic dispatch with a **runtime type check** (WASM funcref, JS first-class functions/methods, closures). Mismatch ⇒ trap.
  - `call_host(capability, name, args)` — the **sole gated boundary** to anything outside the module's own values/memory: imported host functions *and* stdlib calls both lower to this. Safe/Unsafe capability checks attach here.
- **Effects:** `trap(reason)`; `charge(cost)` (metering; inserted by the middle-end when enabled).
- **Textual form (`.ir`):** a stable, human-readable, round-trippable representation (think LLVM `.ll`). It is the contract between frontends and the middle-end, makes the IR independently targetable by external tools, and lets every stage be unit-tested by feeding/dumping `.ir`.

This IR is rich enough for dynamic languages (term model, `dynamic`, closures, host calls) and low-level languages (fixed-width numerics, linear memory) without forcing either into the other's shape — decision #1/#2/#4 made concrete.

---

## 4. Pipeline & layer map

Every row is an independently-implementable, independently-auditable, independently-invokable module. The IR is the seam between frontend and middle-end.

| # | Stage / layer | Interface | Phase | Axis | Security boundary | Initial implementations |
|---|---|---|---|---|---|---|
| **Frontends** (source → IR) |
| FW | WASM frontend | `fe_wasm` | build | — | — | decode→validate→ssa→structure→IR |
| FJ | JS frontend | `fe_js` | build | — | — | *(later)* Arc-as-frontend; *(bridge)* Porffor JS→WASM→`fe_wasm` |
| FE | Erlang/Gleam frontend | `fe_beam` | build | — | **yes** (restricts unsafe) | *(later)* ingest→restrict→IR |
| **Shared middle-end** (IR → IR) |
| M1 | IR core + textual form | `ir` | build | — | — | the IR module + `.ir` reader/writer |
| M2 | Optimizer | `ir_opt` | build | optimization | — | `baseline`, `aggressive` (incl. trust-assuming passes) |
| M3 | Stdlib + capability lowering | `ir_lower` | build | **policy** | **yes** | resolves stdlib, applies allowlist, inserts metering |
| **Backend** (IR → BEAM) |
| B1 | Emitter (IR → Core Erlang) | `emit_core` | build | format+binding+instrumentation | partial | `core_text` (default), `cerl_ast` |
| B2 | Driver (.core → .beam) | `build_beam` | build | mechanism | — | `forms`, `file` |
| **Shared runtime** (linked into output) |
| R-num | Numerics | `rt_num` | run | **trust P/N** | — | `bif` (P, default), `nif` (N) |
| R-trap | Traps | `rt_trap` | run | — | — | `error` |
| R-state | Instance state | `rt_state` | run | **trust P/O** | — (sets convention) | `threaded` (P), `pdict`/`ets` (O) |
| R-host | Host/capability dispatch | `rt_host` | run | **capability** | **yes** | `deny_all` (default), `whitelist`, `open` |
| R-meter | Metering | `rt_meter` | run | **policy** | **yes** | `none`, `fuel` |
| R-std | Standard library | `rt_stdlib` | run/build | **policy** | **yes** | `own` (Safe), `passthrough` (Unsafe) |
| R-bif | BEAM-function gate | `rt_bif` | build | **capability** | **yes** | `allowlist` (Safe), `open` (Unsafe) |
| **Optional linear-memory subsystem** (only if the module uses linear memory) |
| R-mem | Memory | `rt_mem` | run | **trust P/O/N** | **yes** | `paged` (P), `atomics` (O), `nif` (N); + `rebuild` oracle |
| R-tab | Tables | `rt_table` | run | **trust P/O** | **yes** | `map` (P), `ets`/`atomics` (O) |
| **Linker** |
| I | Instantiation | `rt_instance` | run | — | — | wires chosen runtime impls per instance/mode |

Two axes of variation recur (carried from the modular design): **trust tier P/O/N** for mutable-state layers (P = pure language, no OTP-native state, no NIF, can't crash the node; O = OTP-standard native, memory-safe, no custom code; N = custom NIF, fastest, can crash the node), and **policy/capability/format** for the rest.

---

## 5. Backend: IR → Core Erlang

The backend is the existing, proven WASM→Core-Erlang machinery, now consuming the **shared IR** instead of a WASM-specific IR. It is uniform across frontends because the IR is.

- **Structured control flow → `letrec` of tail-recursive functions.** `block`→ forward-break continuation `K(vals…)`; `loop`→ body `L(vars…)` with `break`/`continue` as `apply` (tail self-call ⇒ constant-space iteration); `if`→ `case` on the condition with each arm returning the merged live-value list `<…>`; `switch`→ `case` selecting continuation functions (default arm); `return`→ return the value list; labels resolved via a compile-time label→continuation stack. Proper BEAM tail calls make loops constant-space and **preemptible** (§11).
- **Operand handling.** IR values are already named (frontends do their own SSA/stack-elimination before the IR — the WASM frontend eliminates the operand stack; JS/Gleam are already in named-variable form). The backend binds them with `let` and threads them through continuation parameters at merges (φ-nodes → arguments).
- **Calls.** `call_direct`→ `apply 'fn'/N(...)`; `call_indirect`→ `rt_table` dispatch + type check; `call_host`→ `rt_host`/`rt_stdlib` dispatch (the capability boundary).
- **Numerics** route through `rt_num` (fidelity invariants §9.1); **memory** through `rt_mem` (bounds-checked → trap); **traps** through `rt_trap`.
- **Emission.** Build a **Gleam-native Core Erlang AST as custom types, then pretty-print to `.core` text** (not the Erlang `cerl` record API — awkward over FFI, loses type safety). Small, fiddly printer for Core Erlang's lexical rules (atom quoting, variable capitalization, function-name vars `'f'/N`, `-| [...]` annotations) with **its own unit tests**; assemble with a `string_tree` builder. Compile via Gleam `@external` FFI to a `compile:forms/2`/`from_core` shim. Emitter config sub-axes: format (`core_text`/`cerl_ast`), `state_strategy` (`threaded`/`cell`, driven by the `rt_state` tier — §13), and metering instrumentation on/off.
- **Codegen security invariants** (hold in every emitter impl): every memory/table op routes through the runtime (never a raw term op); no IR node lowers to an open `apply` of an attacker-chosen module/atom (no ambient authority).

---

## 6. Security: Safe and Unsafe modes

Two named, global modes (the user's framing), each a bundle of per-layer choices applied by the middle-end (`ir_lower`) and the linker (`rt_instance`):

- **Unsafe** — *emit the fastest possible code; near-native, potentially faster than hand-written Erlang via our own optimizations.* For deployments you run yourself.
  - Optimizer `aggressive` (incl. trust-assuming passes); stdlib `passthrough` (route to BEAM stdlib/BIFs where faster); BIF gate `open` (full BEAM access); runtime tiers may be O or N; metering `none`; host `whitelist`/`open` as configured.
- **Safe** — *sandboxed.* For untrusted / multi-tenant code (the platform case).
  - **Only a vetted allowlist of BEAM functions** (`rt_bif: allowlist`); **own reimplemented stdlib** (`rt_stdlib: own` — keep a few BEAM functions, e.g. `string:split`, and reinvent the rest so the surface is auditable); host `deny_all` by default (grant capabilities explicitly via `whitelist`); runtime tiers **P or O only** (no node-crashing NIFs — tier N is forbidden in Safe); metering **on** (`fuel`); optimizer restricted to trust-neutral passes.

**Why the stdlib and BIF gate are security layers, not conveniences.** In Safe mode the threat is untrusted code reaching BEAM functionality that can escape the sandbox, exhaust the node, or read ambient state. Trusting the full BEAM stdlib defeats that. So Safe mode trusts *almost none* of it: a small audited allowlist plus an in-house stdlib whose every function we control. Because the stdlib is defined at the IR level (§7), the same Safe stdlib serves every frontend.

**Fail closed.** Defaults are the safe choice (deny-all host, allowlist BIFs, full validation, metering on for untrusted). A misconfiguration must reduce capability, never expand it. The **instance is the unit of policy** (§13): Safe and Unsafe instances coexist on one node, identical generated code, different linked runtime.

---

## 7. The standard library

Modeled on Gleam's approach — a deliberately tiny built-in surface, with most of "the standard library" being a regular library that targets the IR. Because all frontends share the IR, **one stdlib is consistent across every language** on the platform.

- **Defined at the IR level.** Stdlib functions are either expressed *in* the IR (and compiled like any module) or are vetted `call_host` entries into the runtime. Either way they're frontend-agnostic.
- **Two implementations behind `rt_stdlib`:** `own` (in-house, vetted — Safe mode) and `passthrough` (delegates to BEAM stdlib where it's faster and the function is trusted — Unsafe mode). A few BEAM functions are retained in both (e.g. `string:split`); the rest are reimplemented for Safe mode.
- **Consequence for frontends.** A JS frontend's `Array.prototype.map`, a Gleam frontend's `list.map`, and a Rust-via-WASM iterator all bottom out in the same shared IR-level primitives and the same stdlib — consistent semantics and one place to audit.

---

## 8. Frontends

### 8.1 WASM frontend (`fe_wasm`) — build now
Internal stages, each an independently-invokable interface, terminating in the shared IR (not a private IR):
- **Decode** (`wasm_frontend.decode`): WAT or `.wasm` → Module IR. Gleam's inherited Erlang bit-syntax (`<<>>` patterns with `size`/`signed`/`little`/`:bits`, constant-time `bit_array.slice`) makes the binary decoder nearly free and the natural choice; LEB128 and value bytes fall out of pattern matching.
- **Validate** (`wasm_validate`, security boundary): WASM abstract stack-typing → typed module; proves well-typedness so lowering can trust types. Implementations by verification strength: `full` (untrusted input — required), `subset`, `assume_valid` (trusted toolchains only; unsafe on untrusted input; gated behind an explicit flag).
- **Stack-elim / SSA**: eliminate the operand stack into named values (statically known stack shape; no runtime stack).
- **Structure-normalize → emit IR**: WASM is already structured, so this maps directly onto the IR's structured control flow and the **low-level numeric + linear-memory** value path. This pre-solves the relooper problem — we go structured→IR, the easy direction.

Rust→Erlang is this path plus a Rust→WASM toolchain (LLVM): real, though not native-Rust speed.

### 8.2 JS via Porffor (bridge) — this week
**Porffor** (CanadaHonk) is a from-scratch AOT JS/TS→WASM compiler that *compiles* JS rather than bundling an interpreter, so its WASM is small and fast (it also has `2c`, its own experimental Wasm→C compiler — not used by us; we take its Wasm). Chaining **Porffor (JS→WASM) → `fe_wasm` → IR → Core Erlang** yields *JS on the BEAM, fast*, this week, with no JS frontend of our own.

**Honest caveats to plan around** (verified against Porffor's current state):
- It is explicitly an experimental research project; **only a limited subset of JS is supported** (on the order of a third of ECMA-262 historically), and it tracks no particular spec version — so the bridge runs the JS Porffor can compile, not arbitrary JS.
- **Porffor's Wasm uses its own runtime ABI and custom APIs, not WASI** ("mostly unusable on its own" standalone). So `fe_wasm` must supply Porffor's expected host imports — i.e. an `rt_host` implementation that provides **Porffor's runtime ABI** (its console, memory/string helpers, intrinsics), not generic WASI. Treat "Porffor host shim" as a concrete work item.
- It deliberately avoids uncommon Wasm proposals (e.g. GC), staying in the core+common subset — which is friendly to `fe_wasm`'s Phase-1 coverage.

Use this as a fast proof-of-concept and benchmark, not a complete JS solution.

### 8.3 Arc as a native JS frontend (`fe_js`) — later
Arc is currently a JS interpreter on the BEAM. The target state: **Arc stops interpreting and becomes a frontend that emits the IR directly** (JS AST → IR, term value path + shared stdlib + `call_host`). This is strictly better than the Porffor bridge for production JS:
- It uses the **term value model** (JS objects/values as BEAM terms) instead of boxing JS through WASM linear memory — far better fit and performance on the BEAM.
- It shares the platform stdlib and Safe/Unsafe model.
- It keeps Arc's **preemptive** execution property natively (§11), now compiled rather than interpreted.
  "Transpile JS straight to Erlang rather than interpret" is exactly this, with the IR as the waypoint (so JS benefits from the shared optimizer and backend).

### 8.4 Erlang/Gleam frontend (`fe_beam`, security boundary) — later
Ingest Core Erlang / Gleam, **restrict unsafe functionality** (disallow VM-escaping BIFs, enforce the Safe-mode allowlist), and emit IR. The payoff: *write Gleam, deploy to the platform, and be provably unable to take over the VM.* The restriction pass is the security boundary; it rejects (fails closed) rather than strips-and-hopes.

---

## 9. Numeric fidelity & execution semantics

### 9.1 Numeric fidelity invariants (part of the `rt_num` contract)
Exact or computations silently corrupt — these hold in every `rt_num` implementation:
- **Integers wrap two's-complement.** Erlang ints are bignums; **every** low-level op masks to width and reinterprets signedness as required; shift counts masked mod bit-width; signed values stored as unsigned bit patterns, sign-interpreted on demand (one documented convention).
- **Division traps:** `div_s INT_MIN/-1` (overflow) and `_/0` trap.
- **Floats are IEEE-754.** `f64`→ Erlang doubles directly; **`f32` rounded to single precision after every op** (no native 32-bit float — `<<X:32/float>>` round-trip); **NaN bit-pattern propagation/canonicalization** per spec (confirm whether bit-exact NaN is required or canonical-NaN tolerance suffices); `min`/`max` differ from Erlang's on NaN; `reinterpret` is a pure bit cast.

(These are the WASM/low-level path's invariants; the term path uses BEAM-native arithmetic with its own, simpler semantics chosen by each frontend's language.)

### 9.2 Execution model — preemptive, compiled
- **Compiling to Erlang gives BEAM preemption for free.** Generated code runs as ordinary BEAM code; the scheduler preempts at reduction boundaries, and our tail-recursive loops consume reductions and yield — so even tight WASM loops are **fairly scheduled**, the same property Arc relies on for JS. This is a primary reason to compile (not interpret) and to compile **to Erlang** rather than run a long-running interpreter NIF (which would block a scheduler thread).
- **Implication for tier-N memory.** A NIF memory backend is fine because its operations are *per-access and short*; what must never exist is a *whole-program* native loop that runs uninterrupted. Keep native code at the granularity of a single memory/table op.
- **Interpreted vs compiled stays open but decided.** The compiled route is primary (near-native + preemptive). If an interpreter is ever built for not-yet-supported features, it must be process-per-instance and yield-aware so it inherits the same fairness.

---

## 10. Modularity, trust tiers & binding (carried forward)

The mechanism behind §4's layer map.

- **Trust tiers P/O/N** apply to mutable-state runtime layers (memory, tables, instance state, optionally numerics): **P** pure language (no OTP-native state, no NIF; cannot crash the node; runs anywhere — the true "no OTP, no NIF" build), **O** OTP-standard native (`atomics`/`ets`/process dict; memory-safe; no custom code), **N** custom NIF (fastest; can crash the node; permitted only where the deployment allows native code — and **never in Safe mode**). The axis is *whose native code runs and whether it can crash the node.*
- **Memory is the canonical layer** (`rt_mem`, security boundary, every access bounds-checked → trap): `rebuild` (oracle), **`paged`** immutable binaries (P, O(page), universal default, sparse-friendly), **`atomics`** (O, O(1), process-local — sharing is opt-in and we never share; the only cost is an atomic barrier, trivial vs a binary rebuild), **`nif`** (N, raw O(1), the ceiling, Unsafe-only). `grow` under `atomics` is the sharp edge (fixed-size at creation → pre-allocate to declared `max` or fall back to `paged`). Uniform behaviour signatures; build order `rebuild`→`paged`→`atomics`→`nif`.
- **Uniform-threading rule:** every mutating runtime op **returns the (possibly new) handle**; mutable backends return the same handle, immutable backends return the updated structure — one signature serves both.
- **The state layer sets the calling convention:** tier-P `rt_state` threads a purely functional instance record through every function (the zero-native build); tier-O holds handles in process-dictionary/ETS cells. So generated code is identical across memory/table/numeric tiers *given a fixed state tier*, and differs only across the state tier (`state_strategy = threaded | cell`).
- **Binding model** (how generated code stays backend-agnostic): **(B1) instance-level dispatch** (default — the instance record carries the chosen impl modules; enables different-trust instances on one node = the instance is the unit of security policy), **(B2) link-time fixed binding** (zero indirection, one tier per node), **(B3) monomorphized build** (specialize against one backend; fastest; Unsafe-perf path).

---

## 11. Correctness & conformance

- **Differential testing against a reference engine** is the top lever for the WASM frontend: the official **WASM spec test suite** (`.wast`) through the platform → BEAM, compared to a conformant engine (`wasmtime`/`wasmer`/V8). It encodes the subtle cases (NaN bits, signed/unsigned edges, wraparound, traps).
- **Interface-conformance suites make modularity safe:** every implementation of an interface passes one shared suite for that interface (the `rebuild` memory oracle and the `bif` numerics are the references the optimized/native impls are differentially tested against). "Done" = passes the interface suite, not "compiles."
- **IR-level testing:** because the IR has a textual form (§3) and every stage is independently invokable, each stage is testable in isolation — feed `.ir`, dump `.ir`, diff. Golden-file tests at the IR boundary (frontend output) and at the `.core` boundary (backend output). Dedicated pretty-printer unit tests.
- **Per-frontend conformance:** WASM → spec suite; JS-via-Porffor → a JS subset suite (bounded by Porffor); Gleam/Erlang → round-trip semantics. Property-based tests for `rt_num`.
- **Swarm angle:** spec suite, per-interface suites, and per-frontend suites are all embarrassingly parallel — partition across agents.

---

## 12. Scope, proposals, non-goals
- **WASM frontend phasing:** Phase 1 — WASM 1.0 + multi-value + sign-extension + non-trapping float-to-int. Phase 2 — bulk memory, reference types, `memory64`, multiple memories, tail-call proposal (maps beautifully to BEAM tail calls), SIMD (large; defer). Phase 3 / separate — exception-handling, GC, stack switching, component model. **WASI** is just an `rt_host` implementation (a host library), out of the core.
- **Hard non-goal: WASM threads / shared memory.** Every memory tier is single-threaded / process-local by design; cross-process shared mutable memory conflicts with one-instance-one-process and with the preemptive per-process model. Single-threaded across all tiers and modes.
- **Frontend roadmap:** WASM (now) → Rust-via-WASM (now-ish) → JS-via-Porffor (bridge, this week) → Arc native JS frontend (later) → Erlang/Gleam frontend (later).
- State proposal and frontend in/out decisions explicitly.

---

## 13. Work breakdown (interface-first, platform-shaped)

**Wave 0 — define every interface (do first; unblocks all parallel work).**
- The IR: `ir` module + the **`.ir` textual reader/writer** (this is the platform's keystone — frontends and middle-end both depend on it; build it first).
- Frontend contracts: `fe_wasm` (+ its internal `wasm_frontend`/`wasm_validate`/ssa/structure stages), `fe_js`, `fe_beam`.
- Middle-end: `ir_opt`, `ir_lower` (stdlib + capability + metering).
- Backend: `emit_core` (+ config sub-axes), `build_beam`.
- Runtime behaviours: `rt_num`, `rt_trap`, `rt_state`, `rt_host`, `rt_meter`, `rt_stdlib`, `rt_bif`, `rt_mem`, `rt_table`, `rt_instance`.
- **W0-scaffold:** Gleam project, `compile`/`file` FFI shim, build driver.

**Then each cell is an independent work item** (definition of done = its conformance suite):
- **IR:** core types; `.ir` parser/printer; round-trip tests.
- **WASM frontend:** binary decoder; WAT parser; `full`/`subset`/`assume_valid` validators; stack-elim; structure→IR.
- **Porffor bridge:** the **Porffor-ABI `rt_host` shim**; a JS-subset conformance harness; benchmark vs interpreters.
- **Optimizer:** `baseline`; `aggressive` (trust-assuming passes flagged Unsafe-only).
- **Stdlib + capability lowering (`ir_lower`):** stdlib resolution; BIF allowlist enforcement; metering insertion.
- **Backend:** Core AST + **pretty-printer** (own tests); `state_strategy` threaded/cell; `cerl_ast` alt; `forms`/`file` drivers.
- **Shared runtime:** `rt_num` `bif` (+ property tests) and `nif`; `rt_trap` `error`; `rt_state` `threaded`/`pdict`; `rt_host` `deny_all`/`whitelist`/`open`; `rt_meter` `none`/`fuel`; **`rt_stdlib` `own`/`passthrough`**; **`rt_bif` `allowlist`/`open`**.
- **Linear-memory subsystem:** `rt_mem` `rebuild`→`paged`→`atomics`→`nif`; `rt_table` `map`/`ets`.
- **Linker:** `rt_instance` + the named **Safe/Unsafe** profiles.
- **Stdlib library:** the in-house IR-level stdlib (start with the subset the WASM/Porffor paths need).
- **Conformance:** spec `.wast` runner + differential engine; per-interface suites; per-frontend suites. *Partitionable across many agents.*
- **CLI/API:** drive any stage independently (`source → .ir`, `.ir → .core`, `.core → .beam`, or end-to-end), per decision #5.

**Critical path to first end-to-end (WASM):** Wave-0 (esp. `ir` + `.ir`) → WASM decode → `full` validate → stack-elim → structure→IR → `ir_lower` (Safe defaults) → `emit_core` + printer → `forms` driver → `paged` memory + `threaded` state + `bif` numerics + `deny_all` host + `own` stdlib. Everything else lands in parallel.

---

## 14. Summary for the next agent

Build, in **Gleam**, a **multi-frontend compiler platform** that lowers several source languages into **one shared, language-neutral IR (ours)** and emits **Core Erlang**, so code runs **fast and preemptively on the BEAM** — compiled, not interpreted. **WASM is the first frontend** (transitively Rust→Erlang; via **Porffor**, a this-week JS→WASM→Erlang bridge, bounded by Porffor's experimental coverage and requiring a Porffor-ABI host shim rather than WASI); **Arc becomes a native JS frontend** later (emitting the IR directly, using the term value model rather than boxing JS through linear memory), and an **Erlang/Gleam frontend** lets people deploy Gleam that provably can't take over the VM. The decisions to lock **now**, even though most frontends are later: the **IR is language-neutral** (no WASM-isms in its core) with **linear memory as an optional feature**, **structured control flow** (no goto), a **dual value model** (BEAM-native terms + opt-in fixed-width/linear-memory) with explicit conversions, **every stage independently invokable with a canonical `.ir` textual form**, **`call_host` as the single capability boundary**, the **standard library defined at the IR level** (Gleam-style minimal-builtin, identical across frontends), and **Safe/Unsafe as global modes** — Unsafe emits the fastest possible near-native code (stdlib passthrough, full BIFs, tier-O/N runtime, no metering), Safe sandboxes (own vetted stdlib + a tiny BEAM-function allowlist, deny-all host, tier-P/O only — never NIFs, metering on). The backend is the proven structured-control→`letrec`+tail-call lowering (loops = constant-space, preemptible BEAM iteration), with numerics routed through `rt_num` (exact two's-complement/IEEE/NaN/trap **fidelity invariants**) and memory through the **canonical tiered `rt_mem`** (`paged` pure default / `atomics` O(1) process-local / `nif` ceiling, never-in-Safe), all behind interfaces validated by **interface-conformance suites** and the official WASM spec test suite. Compiling to Erlang (not a long-running NIF) is what preserves BEAM preemption; tier-N native code stays per-operation. Threads/shared memory is a hard non-goal. Work is interface-first: build the **IR and its textual form first**, then every (stage × implementation) cell is an independent, swarm-parallel work item whose definition of done is its conformance suite — and every link in the chain is independently callable.
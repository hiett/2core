# Phase 1 — Overview & Shared Contracts

> **Read this first, in full, before opening any unit doc.** Every numbered work
> unit (`01`–`11`) assumes the decisions on this page. They are the load-bearing
> foundations; deviating from them quietly will cost the swarm a retrofit.

---

## 0. What this project is (60-second bootstrap for a zero-context agent)

**2core** (Gleam package `twocore`) is a **multi-frontend compiler platform** written
in **Gleam** (which compiles to Erlang and runs on the BEAM). It takes programs
written for *other* runtimes, lowers them into **one shared, language-neutral
intermediate representation (the IR)**, and emits **Core Erlang**, which the standard
Erlang compiler turns into a loadable `.beam` module. The result runs as ordinary,
**preemptively-scheduled** BEAM code — so even a tight loop yields fairly and cannot
monopolise a scheduler. The bet: *compiling* to Erlang (rather than shipping a
long-running interpreter) is what preserves preemption while getting near-native speed.

**WASM is the first frontend.** It transitively unlocks Rust (Rust→WASM) and, later,
JS (via Porffor, JS→WASM). Later still: native JS and Gleam/Erlang frontends. All
frontends are intended to share one IR, one optimizer, one backend, one standard
library, and one security model.

The canonical architecture spec is [`specs/00-high-level.md`](../00-high-level.md).
**Read §3 (the IR), §4 (the layer map), §5 (the backend), §6 (Safe/Unsafe), and §9
(numeric fidelity) of it** — they are referenced constantly below. This `phase-1/`
directory breaks the *foundation* of that spec into concrete, independently-ownable
work units.

The repository today is a bare Gleam scaffold (`src/twocore.gleam` prints a
placeholder). **Nothing below is built yet.** You are building the foundations.

---

## 1. The Phase-1 goal (concrete and measurable)

> Compile a small but real WebAssembly module — integer arithmetic, locals, a
> structured `block`/`loop`/`if`, a direct `call`, the `i32`/`i64` op set — from a
> `.wasm` binary, through the shared IR, to a **loaded `.beam` module that produces
> spec-correct results**, and prove it with a **differential test** against the
> official WASM spec suite. Every stage in between (decode → validate → stack-elim →
> structure→IR → `.ir` round-trip → emit→`.core` → `.core`→`.beam`) is
> **independently invokable** and **independently tested against the spec**. Numeric
> fidelity holds end-to-end (two's-complement wrap; `div`/`rem` traps on zero and on
> signed overflow; shift-count masking).

**Acceptance (owned by unit `07`, run by the capstone `11`):** the following compile
and run on the BEAM with results matching the WASM spec suite's baked-in expected
values:

| Program | Exercises |
|---|---|
| `add(i32,i32)` | direct numeric op, params, export, end-to-end plumbing |
| `sum_to(n)` (loop) | `loop`/`break`/`continue` → constant-space tail-recursive BEAM loop |
| `fac`/`fib` | `if`, direct self-`call`, recursion |
| `div_s(INT_MIN,-1)` | **traps** (signed overflow) |
| `div_u(x,0)` | **traps** (divide by zero) |
| `i32` wraparound + a shift with count ≥ width | two's-complement + shift masking *through codegen* |
| one `call_host` import under deny-all | the **capability boundary** rejects, fail-closed, end-to-end |

### Honest scope (do not overstate "Safe mode") — decision **D9**

Phase 1 **wires and exercises the security *seams*** end-to-end — it is **not** a
complete sandbox. Specifically Phase 1 delivers:

- the **`call_host` capability boundary** lowered in the backend and **exercised
  end-to-end** (a host import is *rejected* through the full pipeline under deny-all);
- the **metering seam** (`charge` IR effect + emitter hook + a minimal `rt_meter`
  fuel counter), so instrumentation is never retrofitted into codegen later;
- a **minimal `own` stdlib** (one or two vetted functions) reached via `call_host`,
  plus **`rt_bif` allowlist enforcement** (a non-allowlisted call fails closed).

Phase 1 **defers** (to Phase 2): the *breadth* of the allowlist and own-stdlib, the
**Unsafe** profile (aggressive optimizer, passthrough stdlib, open BIFs, tier O/N),
linear **memory** (`rt_mem`) and tables (`rt_table`), the optimizer (`ir_opt`), the
WAT text parser, and the Porffor bridge. **Do not claim "paged memory" as a Phase-1
tier** — the corpus uses no memory. (But the IR *models* memory as optional **now**;
see **D5**.)

---

## 2. The ten load-bearing decisions (D1–D10)

These are frozen for Phase 1. If you believe one is wrong, raise it with the planner
**before** building on it — do not silently diverge.

### D1 — One owner per file; freeze interfaces first, implement in parallel

Every source file has exactly **one owning unit** (table in §4). The single biggest
lever for the swarm is **"freeze the interface, then parallelize the
implementations."** Cross-cutting *types* are published as compiling-but-empty stubs
by the Wave-0 freeze unit (`01`) **before** anyone implements against them. The
schedule is keyed on **freeze milestones**, not on whole-unit completion (§3).

### D2 — Runtime layers are Gleam modules, linked into the *output*, called at *run time*

`rt_num`, `rt_trap`, `rt_host`, `rt_meter`, … are ordinary **Gleam modules** that
compile to BEAM modules (e.g. Gleam `twocore/runtime/rt_num` → Erlang module
`twocore@runtime@rt_num`). The **generated Core Erlang calls them at run time.** This
keeps numeric/trap fidelity in *one* auditable place (the `rt_num` chokepoint) and is
what makes the trust-tier (P/O/N) and Safe/Unsafe layers swappable. Do **not** inline
numeric semantics into the emitter. *(Verified: a Gleam module path maps to an Erlang
module by replacing `/` with `@`; public function names are emitted verbatim with
arity = parameter count.)*

### D3 — Runtime binding: the second keystone (the calling convention)

How generated code reaches the runtime is **co-equal in importance to the IR itself**.
Four rules:

- **D3a — No ambient authority.** Generated code **never** performs a data-driven
  `apply(Mod, F, Args)` where `Mod` comes from program/attacker data. Every runtime
  reference resolves to a **fixed, build-controlled `twocore@runtime@*` module**.
  *(This is the §5 codegen security invariant — and it is **tested**, see `08`.)*
- **D3b — One binding chokepoint.** `emit_core` routes **every** runtime reference
  (numerics, traps, host, charge, and — later — memory/tables/stdlib) through **one**
  binding table. Phase-1 strategy = **link-time-fixed binding (B2)**: emit a direct
  `call 'twocore@runtime@<impl>':'<fn>'/<arity>(...)`, where `<impl>` is chosen by the
  build profile's `Binding` record. This is the fast path (no per-call indirection)
  and the simplest correct thing. *(Verified guidance: resolve impl modules at codegen
  time into direct `mod:fun` calls on hot paths; do not route hot numeric ops through a
  runtime closure field.)*
- **D3c — Don't preclude the other binding models.** Because binding lives in one
  chokepoint, switching later to per-instance dynamic dispatch (B1: identical
  generated code, different linked runtime, the "instance is the unit of policy"
  property) or whole-program monomorphization (B3: the Unsafe perf path) is a
  **localized** change to that one table. Never scatter runtime module names across
  the emitter.
- **D3d — No runtime record is threaded through Phase-1 code.** Phase 1 has **no
  mutable instance state** (no memory, tables, or mutable globals in the op set) and
  exactly **one policy** (Safe), so generated functions are **pure** and thread
  nothing. The `Binding` is a **build-time** input to the emitter, carrying impl
  *module names*, not embedded in generated code. The mutable instance-**state**
  convention (handles threaded-and-returned per high-level §10) is introduced in
  **Phase 2** when memory/tables/mutable-globals land — the binding chokepoint already
  exists, so that is a clean extension, not a retrofit.

### D4 — Per-stage error types, composed at the driver (not one shared enum)

Each stage owns its **own** error type — `DecodeError`, `ValidateError`, `EmitError`,
`BuildError`, … — so stages evolve independently (decision #5 of the high-level spec;
matches the `DecodeError(Truncated/Overflow)` example in `CLAUDE.md`). The top-level
driver composes them into a thin `PipelineError` sum (owned by `01`/`11`). **There is
no single shared `StageError`.** Cross-cutting helper types that are genuinely shared
(e.g. a byte/`SourceSpan` position) live in `01`'s stubs.

**Fail closed, and *test* it.** Defaults reject (deny-all host, `full` validation
required, allowlist BIFs). This is a tested property: a negative corpus must produce
typed `Error` (never a panic), and the Safe profile must not be instantiable into an
unsafe posture.

### D5 — IR value model: three orthogonal capability axes; floats are bit patterns

The IR `Module` declares **three independent capabilities**, never fused:

1. **Term values** — BEAM-native (atoms/binaries/tuples/lists/maps/closures/`dynamic`).
   Always available; the home of future JS/Gleam frontends.
2. **Fixed-width numerics** — `i32/i64/f32/f64`. **Opt-in.** WASM/Rust use this.
3. **Linear memory** — byte-addressable, typed load/store. **Opt-in, a *separate*
   per-module flag** from numerics (high-level decision #2: a module that doesn't use
   memory must not link the memory runtime). *Phase-1 WASM modules turn numerics **on**
   and memory **off**.*

Conversions between the term and numeric layers are **explicit IR ops** (no implicit
bridging). **Floats are stored as raw IEEE-754 bit patterns (an `i32`/`i64`), never as
native BEAM doubles** — BEAM doubles cannot represent NaN/Infinity (arithmetic raises
`badarith`, and `<<F:64/float>>` fails to match NaN/Inf bits). This is a **lock-now**
decision: retrofitting it means rewriting every float op and the IR's float encoding.

### D6 — IR neutrality: no WASM-isms in the keystone

The IR must be emittable by a hypothetical JS/Gleam frontend with **no WASM concept
present**. Concretely: **structured control uses *named* labels only** (never a numeric
branch *depth* — the WASM frontend resolves `br N` depth into a named label at the
frontend boundary); operation names are **neutral and width-tagged** (`IAdd(W32)`, not
the string `"i32.add"`); there is **no operand-stack typing** in the IR (the frontend
eliminated the stack). Unit `01` runs a **one-time neutrality review** against a
checklist before freezing.

### D7 — The `.ir` textual form is the inter-stage contract

The IR has a canonical, human-readable, round-trippable text form (`.ir`), the seam
between frontends and the middle-end (high-level §3). Rules:

- **One canonical printer.** `parse(print(m)) == m` for every module `m`.
- Equality for the round-trip compares **numeric literals by bit pattern** (so NaN
  payloads and `-0.0` are exact — structural `==` is wrong for floats).
- Floats are printed in a **lossless** encoding (raw bit pattern or hex-float).
- Golden `.ir` files are **hand-authored against the grammar doc** — never
  printer-generated — so a printer and parser that share the *same wrong* grammar do
  not collude to pass. The grammar (`ir-grammar.md`) is frozen **with** the types.

### D8 — Definition of done (from `CLAUDE.md`, non-negotiable)

A unit is done only when: its **conformance/interface suite passes**; tests assert
**spec behavior, not whatever the code currently emits** (no change-detector tests —
go to the WASM spec / the relevant standard and assert what it says *should* happen);
**every public function has a doc comment** stating its contract (what / parameters &
ranges / return + `Result`/`Option` semantics / failure & panic modes); `gleam format
--check src test` is clean; `gleam build` has **no warnings**. When you find a bug,
add a failing spec test first, then fix.

### D9 — Honest Phase-1 security scope

See §1 above. Wire and exercise the seams; defer the breadth. Do not label the output
"a sandbox."

### D10 — Generated modules load into the build/test VM (Phase 1)

Phase-1 end-to-end tests compile to an in-memory `.beam` binary and `code:load_binary`
it into the running build VM, then `apply` the export. *(Note for later: a production
multi-tenant sandbox may need generated code to load into a separate node; that choice
interacts with the capability boundary and is revisited in Phase 2. It does not change
the Phase-1 driver's `Result` contract.)*

---

## 3. How the work is scheduled — freeze milestones, not waves

Think of two rough timing buckets (**Wave A** foundations, **Wave B** the vertical
slice), but **gate actual work on interface-freeze milestones**, because a downstream
unit needs an upstream *type* frozen, not the whole upstream unit finished.

```
        ┌─────────────────────────────────────────────────────────────────┐
WAVE 0  │  01  INTERFACE FREEZE  (one owner, ~1 day, design+stubs only)     │
        │  freezes:  ir.gleam types  +  ir-grammar.md                       │
        │            runtime/instance.gleam (Binding + calling convention)  │
        │            runtime/rt_num.gleam   (function SIGNATURES, todo body) │
        │            twocore/pipeline.gleam (PipelineError stub)            │
        │  emits milestones:  «IR-FROZEN»  «ABI-FROZEN»  «RTNUM-SIG-FROZEN»  │
        └─────────────────────────────────────────────────────────────────┘
                 │                    │                    │
   ┌─────────────┼────────────────────┼───────────┐        │
   ▼ «IR-FROZEN» ▼                    ▼            ▼        ▼ (independent of all freezes)
 ┌──────────┐ ┌──────────┐      ┌──────────┐ ┌─────────┐ ┌──────────┐ ┌──────────┐
 │02 .ir    │ │10 wasm   │      │08 emit_  │ │06 rt_num│ │03 core   │ │05 wasm   │
 │printer/  │ │ validate │      │ core     │ │ (bif)   │ │ erlang   │ │ decoder  │
 │parser    │ │ +lower   │      │(needs IR │ │(needs   │ │ AST +    │ │ +AST     │
 │(needs IR)│ │(val:WASM-│      │ +CoreAST │ │RTNUM-SIG│ │ printer  │ │ +fuzz    │
 │          │ │ AST only;│      │ +ABI)    │ │)        │ │(self-    │ │(self-    │
 │          │ │ lower:IR)│      │          │ │         │ │ frozen)  │ │ frozen)  │
 └──────────┘ └──────────┘      └──────────┘ └─────────┘ └──────────┘ └──────────┘
   WAVE A        WAVE B            WAVE B      WAVE A       WAVE A       WAVE A
                                                              │            │
        ┌───────────────────────────────┐               «CORE-AST»   «WASM-AST»
        │ 07 conformance harness+corpus │                published    published
        │ (mostly independent; expected │                day 1 of 03  day 1 of 05
        │  values are baked into .wast) │                → unblocks 08 → unblocks 10
        └───────────────────────────────┘
                  │  (04 build_beam + FFI shim: independent, Wave A — not shown above)
        ┌────────────────▼─────────────────────────────────────────┐
WAVE B  │ 11  CAPSTONE: ir_lower (IR→IR) + linker + Safe profile +  │
CAP     │     CLI/API stage-driver + differential acceptance       │
        │     (ir_lower needs only «IR-FROZEN»; the rest need all)  │
        └──────────────────────────────────────────────────────────┘
```

**The smartest first end-to-end is not through the WASM frontend.** Hand-write an
`.ir` module → `08 emit_core` (→ `03` Core AST) → `03 core printer` (→ `.core`) →
`04 build_beam` (→ loaded `.beam`) → run, with `06 rt_num` linked. This proves the
*backend* slice (`01`→`08`→`03`→`04`→`06`) before the WASM frontend exists. Target that
integration first; it de-risks the longest poles (`08 emit_core` and
`10 validate+lower`) independently.

> Two units **publish their own type stub on day 1** so a downstream unit can start
> without waiting for the whole unit: **`03`** publishes `backend/core_erlang.gleam`
> (the AST node types) → unblocks `08`; **`05`** publishes `frontend/wasm/ast.gleam`
> (the WASM AST types, incl. a WASM `ValType`) + its `DecodeError` → unblocks `10`'s
> validator. Treat these as mini-freezes inside those units.

---

## 4. File-ownership map (D1)

> Single owner per file. "Freeze day 1" = publish the compiling type stub before
> implementing, so downstream units can target it.

| File | Owning unit | Notes |
|---|---|---|
| `src/twocore/ir.gleam` | **01** | The IR types (keystone). Frozen day 1. |
| `specs/phase-1/ir-grammar.md` | **01** | `.ir` grammar. Frozen with the types. |
| `src/twocore/runtime/instance.gleam` | **01** | `Binding` + calling convention + `safe_default()`. Frozen day 1. |
| `src/twocore/runtime/rt_num.gleam` | **01 → 06** | `01` freezes the **signatures** (`todo` bodies); ownership transfers to **06** for the bodies. |
| `src/twocore/pipeline.gleam` | **01 → 11** | `PipelineError` sum + stage-driver aliases; `01` stubs, `11` completes the driver. |
| `src/twocore/ir/printer.gleam` | **02** | IR → `.ir` text. |
| `src/twocore/ir/parser.gleam` | **02** | `.ir` text → IR. |
| `test/twocore/ir/roundtrip_test.gleam` | **02** | Round-trip + golden suite (single owner: the parser sub-task). |
| `src/twocore/backend/core_erlang.gleam` | **03** | Core Erlang AST. Frozen day 1 (`«CORE-AST»`) → unblocks 08. |
| `src/twocore/backend/core_printer.gleam` | **03** | Core AST → `.core` text (the fiddly printer). |
| `src/twocore/backend/build_beam.gleam` | **04** | Driver. **Owns `src/twocore_codegen_ffi.erl`.** Independent (Wave A). |
| `src/twocore_codegen_ffi.erl` | **04** | The `compile_core`/`load_module` FFI shim (`«FFI-SHIM»`). Shared day-1 infra. |
| `src/twocore/frontend/wasm/ast.gleam` | **05** | WASM AST (incl. a WASM `ValType`). Frozen day 1 (`«WASM-AST»`) → unblocks 10. |
| `src/twocore/frontend/wasm/decode.gleam` | **05(decode)** | Binary decoder + LEB128. |
| `src/twocore/frontend/wasm/validate.gleam` | **10(validate)** | `full` validator (security boundary). Reads `ast.gleam` only. |
| `src/twocore/frontend/wasm/lower.gleam` | **10(lower)** | stack-elim/SSA + structure→IR. |
| `src/twocore/backend/emit_core.gleam` | **08** | IR → Core AST (the binding chokepoint, D3b). |
| `src/twocore/runtime/rt_trap.gleam` | **09** | `error` impl. |
| `src/twocore/runtime/rt_host.gleam` | **09** | `deny_all` impl. |
| `src/twocore/runtime/rt_meter.gleam` | **09** | minimal `fuel` impl. |
| `src/twocore/runtime/rt_stdlib.gleam` | **09** | minimal `own` impl (1–2 fns). |
| `src/twocore/runtime/rt_bif.gleam` | **09** | `allowlist` gate. |
| `src/twocore/middle/ir_lower.gleam` | **11(ir_lower)** | IR→IR: capability/stdlib resolution + `rt_bif` allowlist (build-time) + `charge` insertion. Reads `ir.gleam` + the `Binding` type (for `mode`/policy); does **not** import the runtime impl modules. |
| `src/twocore/runtime/profiles.gleam` | **11(linker)** | Safe profile + linker. *Imports* `instance.gleam`; never edits it. |
| `src/twocore.gleam` | **11(CLI)** | CLI/API exposing **each** stage independently (decision #5). |
| `test/twocore/conformance/**` | **07** | Harness, fixtures, oracle, acceptance corpus. |

> **Numbering note.** The doc filenames `02`–`11` map to units; a few docs contain two
> tightly-related sub-units with split file ownership (e.g. `04-build-beam-driver.md`
> is the build/FFI unit; `05-wasm-decoder.md`, `10-wasm-validate-and-lower.md`,
> `11-ir-lower-linker-cli.md` each split into clearly-scoped sub-tasks that can go to
> separate agents — see each doc's "Concurrency" section).
>
> **Test files** are not all enumerated above. Each unit owns the test modules
> mirroring its `src/` files under `test/` (per §5), e.g. unit 03 owns
> `test/twocore/backend/core_printer_test.gleam`. A unit owns the tests for the files
> it owns.

---

## 5. Shared conventions (apply everywhere)

- **Module layout:** new modules under `src/twocore/…`; import as `twocore/…`.
  Tests mirror under `test/`, names ending `_test` (gleeunit auto-discovers).
- **Dependencies:** the scaffold ships only `gleam_stdlib` + `gleeunit`. The FFI/runtime
  units need `gleam_erlang` (for `gleam/erlang/atom` and BEAM interop) — add it with
  `gleam add gleam_erlang` when first required (units 04/08/09). Keep the dependency set
  minimal and justified; note any addition in `state.md`.
- **Erlang namespace hygiene (verified hazard):** generated/compiled module names live
  in one flat Erlang namespace shared with OTP. **All generated modules are prefixed
  `twocore@…`; all hand-written FFI `.erl` modules are prefixed `twocore_…`** (e.g.
  `twocore_codegen_ffi`). **Never** name anything `lists`, `maps`, `erlang`, … — a
  collision can stop the output application from starting.
- **Totality:** prefer total functions returning `Result`/`Option`. Reserve
  `let assert`/`panic` for genuinely impossible states and **document them**. A decoder
  or runtime that `let assert`s on untrusted input is a sandbox hole.
- **Doc comments:** `////` module docs at file top; `///` on every public function /
  type / constant (the contract). `//` for inline notes. (D8.)
- **The inner loop:** `edit → gleam format → gleam test`. Commit small, focused,
  logical units. **Never** add Claude/AI attribution to commits or PRs (see `CLAUDE.md`).
- **Spec-first testing:** when in doubt about behavior, cite the WASM spec
  (<https://webassembly.github.io/spec/core/>) or the relevant standard in the test,
  and assert *that*. Each unit doc lists the exact spec sections it must conform to.

---

## 6. The glossary (terms used across docs)

- **IR** — our shared, language-neutral intermediate representation (`src/twocore/ir.gleam`).
- **`.ir`** — the IR's canonical textual form (`ir-grammar.md`).
- **`.core`** — Core Erlang text; compiled to `.beam` by the Erlang compiler.
- **Binding / chokepoint** — the one place (`emit_core`) that decides how a runtime op
  becomes a concrete `call` (D3b).
- **`call_host`** — the single IR node for every call leaving the module's own
  values/memory (host imports *and* stdlib). The capability boundary (high-level §3/§6).
- **Trust tier P/O/N** — pure / OTP-native / NIF, for mutable-state runtime layers.
  Phase-1 compute (numerics, traps, host) is tier-P and threads no mutable state;
  the **only** stateful seam is the optional metering counter, which — if it accumulates
  fuel (e.g. in the process dictionary) — is tier-O. **Safe mode permits tier P *or* O,
  never N** (high-level §6), so a tier-O fuel counter is allowed. Unit 09 may instead
  ship a pure no-op `charge` (strict tier-P); it documents the choice.
- **Safe / Unsafe** — the two global modes (high-level §6). Phase 1 ships Safe only.
- **Wave 0 / A / B** — rough timing buckets; real gating is on freeze milestones (§3).

---

## 7. How to claim and complete a unit

1. Read this overview, then your unit doc, then [`specs/state.md`](../state.md).
2. In `state.md`, set your unit's status to **`in-progress`** with your name.
3. Confirm your upstream **freeze milestones** are met (your doc lists them). If a
   needed stub isn't published yet, you may start against the *strawman types in `01`*,
   but expect to re-sync when the real stub lands.
4. Build to your unit's **Definition of Done** (D8 + the unit's "Verification"
   section). Do not mark done on "it compiles" — done means **the conformance suite
   passes against the spec**.
5. Update `state.md`: status **`done`**, and fill the "what this leaves" column so the
   next agent knows what is now available.

When in doubt about a foundational decision, **stop and ask the planner** rather than
guessing — the whole point of these docs is that the foundations are shared.

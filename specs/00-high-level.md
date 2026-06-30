# Specification: Modular WebAssembly → Core Erlang Transpiler (in Gleam)

**Status:** Concrete architecture specification (pre-implementation). Supersedes all prior scope/addendum/consolidated documents — this is the canonical spec.
**Audience:** A downstream planning agent and the agent swarm that implements it.

**Goal.** Execute unmodified WebAssembly *inside* the BEAM by transpiling WAT/`.wasm` to **Core Erlang**, which the standard Erlang compiler (`from_core`) turns into a loadable BEAM module. WASM semantics are preserved exactly; no BEAM concepts leak into the WASM program; the BEAM is purely the substrate. Faithfulness beats performance; the work is executed by a large agent swarm, so breadth and parallelism matter more than minimizing effort.

**Three governing constraints:**
1. **The transpiler is written in Gleam** (build-time, on the BEAM).
2. **Generated code is pure Core Erlang.** Whether native code runs underneath is a *per-deployment, per-layer* choice, not a global property.
3. **Every component is modular** — each layer is a stable, narrow interface with **many interchangeable implementations**. This is the organizing principle of the whole system, for two reasons: it *is* the security model (narrow auditable boundaries, fail-closed defaults, per-instance policy), and it makes every component replaceable as the project evolves.

The contract is total in spirit: for a valid module M and exported function f, `M:f(Args)` on the BEAM must produce the same result and the same trap/side-effect behaviour a conformant WASM engine would.

---

## 1. The modularity principle

**Every layer is defined by its *interface*, not its implementation.** An interface is a small, fixed set of operations (an Erlang `behaviour` for run-time layers; a Gleam type / function-record for build-time layers). Any number of implementations may satisfy it. The pipeline and the generated code are written against interfaces only; concrete implementations are selected by configuration — per deployment, and for run-time layers, per *instance*.

This buys two things the project explicitly requires:

- **Security boundary.** Running untrusted WASM is a sandboxing problem. A narrow interface is itself a security property: it is small enough to audit, it can be made to *fail closed* (a missing capability denies rather than permits), and it lets a deployment swap in a *stricter* implementation (e.g. a memory backend that zeroes on free, an import dispatcher that allows only a whitelist) without touching anything else. The trust level of an instance becomes a *choice of implementations*, made at instantiation.
- **Replaceability.** Any component can be rewritten, optimized, or hardened behind its interface without disturbing the rest. The no-OTP/no-NIF build, the atomics build, and the NIF build are not forks — they are different implementations of the same interfaces, coexisting in one codebase and selectable at runtime.

### Two axes of variation

Implementations of a layer vary along one of two axes. Knowing which axis a layer is on tells you what its implementations *are*.

- **Trust tier (P / O / N)** — applies to layers that need *mutable state* (memory, tables, instance state, optionally numerics). The axis is *whose native code runs and whether it can crash the node*:
    - **Tier P (Pure).** Only the Core Erlang language plus unavoidable core BIFs (integer/bitwise arithmetic, binaries, `error`). No OTP library state, no `atomics`/`ets`/`counters`/process dictionary, no NIF. Maximum auditability and portability; runs anywhere the BEAM runs; **cannot crash or escape the VM**; slowest where mutability is needed.
    - **Tier O (OTP-native).** Adds standard OTP facilities implemented in trusted ERTS (`atomics`, `ets`, `counters`, process dictionary). **Memory-safe** — bounds-checked, cannot crash or escape the VM — and requires **no custom native code to load**. The pragmatic default for most deployments.
    - **Tier N (Native/NIF).** Adds custom NIFs. Maximum performance, but a bug can **segfault the whole node** and it requires an environment that permits loading native code.

  The selection axis is **trust**: P for untrusted / locked-down / audited, O for normal, N for fully trusted / performance-critical. "Is `atomics` a NIF?" is true-but-irrelevant — it is native, but it is *the runtime's* memory-safe native code, not *yours*; that is the boundary deployments gate on, and it is why O sits between P and N.

- **Policy / capability / format** — applies to layers that are not about mutable state but about *what is permitted* or *how output is shaped*: the validator (verification strength), host-import dispatch (capability), metering (resource policy), the emitter (output format / binding strategy), the front end (input format). These don't tier P/O/N; they enumerate policies or formats.

---

## 2. Security model

The sandbox guarantee we preserve: **WASM code can touch only its own linear memory, its own tables and globals, and the host functions it was explicitly given — nothing else on the BEAM, no other process, no ambient authority.** Each guarantee is enforced by a specific layer, and modularity lets each be tightened independently:

| Guarantee | Enforced by | How modularity strengthens it |
|---|---|---|
| Memory access stays in-bounds (OOB → trap) | **Memory backend** (every access bounds-checked) + emitter (always routes memory ops through the backend, never raw) | Swap a hardened backend (zero-on-grow, guard pages in tier N) per instance |
| No forged/escaping references; type safety | **Validator** (well-typedness) + **table backend** / `call_indirect` (runtime type-tag check) | Choose `full` validation for untrusted input; reject on mismatch fails closed |
| Side effects only through granted host functions | **Host-import dispatch** (the *sole* egress) | Default `deny_all`; deployments opt into a `whitelist`; misconfig denies rather than leaks |
| Bounded CPU/memory (no DoS) | **Metering** (fuel) + memory `max` caps in the backend | `none` for trusted, `fuel(N)` for untrusted; cap growth by policy |
| No ambient authority / no arbitrary module access | **Emitter** (generated code can only name `wasmrt` + sibling functions) | Codegen invariant: no instruction lowers to an open `apply` of attacker-chosen module/atom |

**Fail-closed is a design rule.** Interfaces default to the safe choice: imports default to deny-all, validation defaults to full, metering defaults to on for untrusted profiles. An incomplete or mistaken configuration must reduce capability, never expand it.

**The instance is the unit of policy.** Each WASM instance is instantiated with a chosen implementation per run-time layer. An untrusted instance: tier-P memory + tier-P state + `deny_all` imports + `full` validation + `fuel` metering. A trusted, hot instance on the same node: tier-N memory + `whitelist` (or WASI) imports + no metering. Same generated code, different linked backends (§4).

---

## 3. Binding model — how generated Core Erlang stays backend-agnostic

The generated module must call run-time layers without naming a concrete implementation. Three binding strategies, themselves a modular choice (a build/deploy flag), trading flexibility for speed:

- **(B1) Instance-level dispatch (default).** The instance record carries, per layer, the chosen implementation module (e.g. `mem_mod`, `host_mod`). Generated code calls a thin facade `wasmrt:store32(Instance, Addr, Val)` which does `MemMod:store32(Handle, Addr, Val)`. Cost: one indirect call per operation. Benefit: **different instances on the same node can run at different trust tiers** — this is what makes the instance the unit of security policy. Recommended default given the security goal and "performance is secondary."
- **(B2) Link-time fixed binding.** Generated code calls fixed module names (`call 'wasmrt_mem':'store32'(...)`) and the deployment loads the chosen implementation under that name. Zero indirection; one tier per node/release. Good when a node is dedicated to a single trust level.
- **(B3) Monomorphized build.** Codegen specializes the module against a chosen backend, inlining the indirection away. Fastest; reverts modularity for that build artifact. Use for the performance-critical, single-backend case (typically tier N).

**The state layer sets the calling convention** (this is the one cross-cutting coupling, and it is deliberate). If instance state is **tier P** (purely functional, no mutable cell anywhere), the instance record — including the memory/table handles — is *threaded* through every generated function as an extra argument and returned in the value list; the truly zero-native "no OTP, no NIF" build is exactly tier-P state + tier-P memory. If instance state is **tier O** (a process-dictionary or ETS cell), handles live in cells and generated functions don't thread state. So the emitter has a `state_strategy ∈ {threaded, cell}` mode driven by the state tier. Consequence: *generated code is identical across memory/table/numeric tiers given a fixed state tier*, and differs only across the **state** tier (threaded vs cell). Everything else is hidden behind the handle.

**Uniform-threading interface rule.** Because tier-P backends are immutable (return a *new* handle) while tier-O/N mutate in place (return the *same* handle), every mutating operation in every run-time interface **returns the handle**, and callers always rebind. Mutable backends return the input handle (cheap); immutable backends return the updated structure. One interface serves both. This single rule is what lets P/O/N coexist behind identical signatures.

---

## 4. Layer map

The complete component set. Each row is an independently-implementable, independently-auditable module. §6–§7 detail each.

| # | Layer | Interface | Time | Axis | Security boundary | Implementations (initial) |
|---|---|---|---|---|---|---|
| F | Front end | `wasm_frontend` | build | format | — | `binary` (.wasm), `text` (WAT) |
| V | Validator | `wasm_validate` | build | verification strength | **yes** | `full`, `subset`, `assume_valid` (trusted input only) |
| S | SSA / stack-elim | `wasm_ssa` | build | optimization | — | `baseline`, `opt` |
| C | Control-flow lowering | `wasm_cfg_lower` | build | strategy | — | `direct_letrec`, `merged` |
| E | Emitter / codegen | `wasm_emit` | build | format + binding + instrumentation | partial | `core_text` (default), `cerl_ast`; × `state_strategy`; × metering instrumentation |
| D | Driver | `wasm_build` | build | mechanism | — | `forms` (`compile:forms`), `file` (`erlc`) |
| R1 | Memory | `wasmrt_mem` | run | **trust P/O/N** | **yes** | `paged` (P), `atomics` (O), `nif` (N); + `rebuild` oracle |
| R2 | Tables | `wasmrt_table` | run | **trust P/O** | **yes** | `map` (P), `ets`/`atomics` (O) |
| R3 | Instance state | `wasmrt_state` | run | **trust P/O** | — (sets convention) | `threaded` (P), `pdict`/`ets` (O) |
| R4 | Numerics | `wasmrt_num` | run | **trust P/N** | — | `bif` (P, default), `nif` (N, accelerated) |
| R5 | Traps | `wasmrt_trap` | run | — | — | `error` (default) |
| R6 | Host imports | `wasmrt_host` | run | **capability** | **yes** | `deny_all` (default), `whitelist`, `wasi_p1` (optional), `open` (trusted only) |
| R7 | Metering | `wasmrt_meter` | run | **policy** | **yes** | `none` (default-trusted), `fuel` (untrusted) |
| I | Instantiation / linker | `wasmrt_instance` | run | — | — | assembles chosen R-layer impls per instance |

---

## 5. Pipeline overview

```
 source ──▶ [F] frontend ──▶ Module IR ──▶ [V] validate ──▶ Typed IR ──▶ [S] ssa ──▶ SSA IR
                                                                                        │
                                                                                        ▼
   .beam ◀── [D] driver ◀── .core text ◀── [E] emit ◀── Core-shaped IR ◀── [C] cfg_lower
                                              │
                                  (instrument per metering/state-strategy)

 at run time, the generated module is wired by [I] to a chosen set of run-time layers:
   [R1 mem] [R2 tables] [R3 state] [R4 num] [R5 trap] [R6 host] [R7 meter]
   selected per instance by trust profile; reached via the binding model (§3).
```

One WASM module → one BEAM module. WASM function index *i* → `'wasm_fn_i'/N`. Exports → wrapper functions that build an instance (via `[I]`, choosing run-time layers per the requested trust profile), run it, and unwrap results.

---

## 6. Build-time layers (detail)

### [F] Front end — `wasm_frontend`
**Contract:** `decode(bytes | text) -> Result(Module, DecodeError)`, producing the section-level Module IR (types, imports, funcs, tables, memories, globals, exports, elements, data, start).
**Implementations:** `binary` decodes `.wasm`; `text` parses WAT (S-expression sugar folded to flat instructions). Both emit the same Module IR.
**Gleam fit:** the decoder is nearly free — Gleam inherits Erlang bit-syntax (`<<>>` patterns with `size`/`signed`/`little`/`:bits`), compiling to BEAM bit-matching with constant-time `bit_array.slice`; LEB128 varints and value bytes fall out of pattern matching. A self-contained Gleam decoder is recommended (bounded, no external dependency). Model failures as `Result`.
**Replaceability:** a streaming decoder, a lenient/recovering decoder, or an external-tool-backed one can drop in later behind the same contract. Not a security boundary (malformed input is rejected by the contract and caught again by [V]).

### [V] Validator — `wasm_validate` — **security boundary**
**Contract:** `validate(Module) -> Result(TypedModule, ValidationError)`. Runs WASM's abstract stack-typing so every program point carries static operand types (needed downstream to pick i32/i64/f32/f64 semantics, mask widths, and block-result arity), and proves well-typedness.
**Implementations (verification-strength axis):** `full` (complete validation — **required for untrusted input**), `subset` (types/arities only), `assume_valid` (no-op — only for output of a trusted toolchain; **a security hole on untrusted input**, must be opt-in and named as unsafe).
**Why it's a boundary:** lowering relies on the typing invariant; skipping validation on untrusted input admits type-confusion. Default to `full`; `assume_valid` fails *open* by nature, so it is gated behind an explicit trusted-input flag.

### [S] SSA / stack-elimination — `wasm_ssa`
**Contract:** `to_ssa(TypedModule) -> SsaModule`, where the operand stack is eliminated into named SSA bindings. The stack shape is statically known, so no runtime stack exists: walk a compile-time abstract stack of variable names — pop consumed names, emit a `let` binding each result to a fresh variable, push it. `local.set` becomes a new variable version; merges (after `if`, at loop heads) turn live locals into explicit continuation parameters (φ-nodes → function arguments).
**Implementations:** `baseline` (straightforward) and `opt` (copy-propagation, dead-binding elimination). Internal; not a security boundary. `baseline` doubles as part of the correctness oracle (§8).

### [C] Control-flow lowering — `wasm_cfg_lower`
**Contract:** `lower(SsaModule) -> CoreShapedModule`, turning structured control flow into a `letrec` of tail-recursive local functions with the live value set passed as arguments. The recipes:
- **`block`** (forward break): continuation `K_block(vals...)`; `br k` ⇒ `apply K_block(vals...)`.
- **`loop`** (backward branch): body `L_loop(vars...)`; `br k` ⇒ `apply L_loop(newvals...)` (tail self-call ⇒ constant-space iteration).
- **`if`**: `case` on the i32 condition (`0`=false), each arm returns the merged live-value list `<...>`.
- **`br_table`**: `case` on the index selecting among continuation functions (default arm for out-of-range).
- **`return`**: return the value list; **`unreachable`**: `wasmrt_trap:trap(unreachable)`.
- **Label depth:** maintain a compile-time stack of label→continuation mappings; relative depth (0=innermost) resolves to the right `letrec` function.

This is the project's central piece of luck: WASM control flow is *already structured*, so the relooper/CFG-reconstruction problem is pre-solved — we go the easy direction, structured → functional. Proper BEAM tail calls make loops constant-space; a non-tail translation would blow the stack.
**Implementations:** `direct_letrec` (one function per construct) and `merged` (fuse trivial blocks). Strategy axis; not a security boundary.

### [E] Emitter / codegen — `wasm_emit` — partial security boundary
**Contract:** `emit(CoreShapedModule, EmitConfig) -> CoreErlangArtifact`.
**Representation decision:** build a **Gleam-native Core Erlang AST as custom types, then pretty-print to `.core` text** — *not* the Erlang `cerl` record API (awkward to construct over FFI, loses Gleam's type safety). You get exhaustiveness over your own Core AST, formatting control, and a clean string boundary to the compiler. Budget a small, fiddly pretty-printer for Core Erlang's lexical rules (atom quoting, variable capitalization, function-name vars `'f'/N`, `-| [...]` annotations) with **its own unit tests**. Assemble output with a `string_tree` builder, not `<>` concatenation.
**Modular config (three sub-axes):** output format (`core_text` default, `cerl_ast` alternative); **`state_strategy`** (`threaded` | `cell`, driven by the R3 tier, §3); metering **instrumentation** (insert `wasmrt_meter:charge` at block/loop heads and call sites, or not — §R7).
**Why partial boundary:** two sandbox invariants are *codegen invariants* — every memory/table op must route through the backend (never a raw term op), and no instruction may lower to an open `apply` of an attacker-chosen module/atom (no ambient authority). These must hold in every emitter implementation.

### [D] Driver — `wasm_build`
**Contract:** `build(CoreErlangArtifact) -> Result(BeamModule, BuildError)`. Via Gleam `@external` FFI to a thin `wasm2core_ffi.erl` shim wrapping `compile:forms/2`/`compile:file/2` (with `from_core`) and `file`. Implementations: `forms` (in-process) or `file` (emit `.core`, shell `erlc`). Mechanism axis; not a boundary.

---

## 7. Run-time layers (detail)

All run-time layers are Erlang `behaviour`s. The generated module reaches them through the binding model (§3). Every mutating callback returns the (possibly new) handle per the uniform-threading rule (§3). For each, "impl by tier" follows the P/O/N taxonomy (§1).

### [R1] Memory — `wasmrt_mem` — **security boundary** — the canonical layer
**Contract (Erlang behaviour):**
```
new(MinPages, MaxPages | infinity)        -> Mem
size(Mem)                                  -> Pages
grow(Mem, DeltaPages)                      -> {ok, OldPages, Mem} | {error, Mem}
load8_u | load8_s | load16_u | load16_s | load32 | load64 (Mem, Addr) -> Int
loadf32 | loadf64 (Mem, Addr)              -> Float
store8 | store16 | store32 | store64 (Mem, Addr, Int) -> Mem
storef32 | storef64 (Mem, Addr, Float)     -> Mem
fill(Mem, Addr, Byte, Len)                 -> Mem
copy(Mem, Dst, Src, Len)                   -> Mem
init(Mem, Addr, Bytes)                     -> Mem
```
Every access bounds-checks; violation calls `wasmrt_trap`. WASM memory is little-endian, unaligned-allowed; the implementation handles endianness once, here.
**Implementations:**
- **`rebuild` (oracle, not deployed).** Memory = one binary; each store rebuilds `<<Pre:Off/binary,New/binary,Post/binary>>`. O(n), trivially correct — the differential-test oracle (§8).
- **Tier P — `paged`.** Map of page-index → fixed-size binary (64 KiB, or smaller tunable). Store rebuilds only the touched page → **O(page)**; page-straddling access splices two pages; absent key ⇒ all-zero page (sparse memories nearly free); `grow` adds keys. Pure functional, runs everywhere, cannot crash the node. **Universal default.**
- **Tier O — `atomics`.** `atomics` array (8 B/slot; sub-word/unaligned via read-modify-write of the containing word, with masking + LE bookkeeping). **O(1)** writes, memory-safe, no custom code. `grow` is the sharp edge — atomics are fixed-size at creation, so pre-allocate to declared `max`; unbounded memory either caps by policy or falls back to `paged`. Atomics are **process-local unless the reference is shared** (we never share it), so single-threaded WASM gets private mutable memory; the only cost is an unconditional atomic barrier per access, trivial next to a binary rebuild. **Everyday default where O is permitted.**
- **Tier N — `nif`.** `malloc`'d buffer as a resource (`get_8/set_8/get_32/.../copy/fill/grow`), bounds-checked in C, `realloc`-based grow. **O(1)** raw, the performance ceiling; can crash the node, needs an environment that permits NIFs.

**Build order:** `rebuild` → `paged` → `atomics` → `nif`. Each is an independent work item validated against the oracle.

### [R2] Tables — `wasmrt_table` — **security boundary**
**Contract:** `new/2`, `size/1`, `grow/2 -> {ok|error, Tab}`, `get(Tab, Idx) -> Ref | null`, `set(Tab, Idx, Ref) -> Tab`, `copy`, `init`, and `type_of(Tab, Idx) -> TypeId` for `call_indirect`. `call_indirect` looks up the ref + stored type, **checks the expected type (mismatch ⇒ trap)**, then applies — this type check is a sandbox boundary (no forged calls).
**Implementations:** Tier P `map` (default — tables are small and reference-typed; pure map suffices); Tier O `ets`/`atomics-of-indices` if a table is large or hot. NIF rarely warranted.

### [R3] Instance state — `wasmrt_state` — sets the calling convention
**Contract:** holds globals + the memory/table handles + the chosen run-time impl modules. `global_get/2`, `global_set/3 -> State`, `get_handle/2`, `put_handle/3 -> State`.
**Implementations:**
- **Tier P — `threaded`.** No mutable cell anywhere; the state record is threaded through every generated function and returned in value lists. With tier-P memory this is the fully zero-native **"no OTP, no NIF" build**. Emitter runs in `state_strategy=threaded`.
- **Tier O — `pdict` / `ets`.** State held in process-dictionary (clean here: one instance = one process, single-threaded) or ETS cells; generated functions don't thread state. Emitter runs in `state_strategy=cell`. Note: a cell holds an *immutable* term, so it solves *plumbing*, not memory mutability — that is R1's job.

This is the layer whose tier choice changes generated-code shape (§3); all other run-time tiers are hidden behind handles.

### [R4] Numerics — `wasmrt_num`
**Contract:** the full WASM numeric surface as callbacks: `i32_add/sub/mul`, `i32_div_s/_u`, `i32_rem_s/_u`, shifts (shift-count masked mod width), rotates, `clz`/`ctz`/`popcnt`, signed vs unsigned comparisons (distinct), i64 equivalents; f32/f64 arithmetic with correct rounding and NaN behaviour, `min`/`max`, `copysign`, `trunc`/`nearest`, and conversions (`trunc_s/u`, `convert_s/u`, `reinterpret`). The **fidelity invariants in §8.1 are part of this contract** and every implementation must satisfy them.
**Implementations:** Tier P `bif` (integer masking with `band`/`bsl`, f32 rounding via `<<X:32/float>>` round-trip, bit-reinterpret via binary patterns — the default; "pure" already, since these are core BIFs not OTP libraries). Tier N `nif` (accelerated f32 rounding / bulk ops) only where a profile permits NIFs and the numeric cost is shown to matter. O adds nothing here.

### [R5] Traps — `wasmrt_trap`
**Contract:** `trap(Reason) -> no_return()` (raised value, e.g. `{wasm_trap, Reason}`), with the export wrapper `try`/`catch`ing into the embedder's convention. Trap sites: OOB access, integer div/overflow, `unreachable`, indirect-call type mismatch / null / OOB, stack exhaustion, out-of-fuel. Essentially one implementation; modular only to allow `error` vs `throw` vs a primop.

### [R6] Host imports — `wasmrt_host` — **security boundary (sole egress)**
**Contract:** `resolve(ImportSpec) -> {ok, fun()} | {error, unresolved}` at instantiation, and/or `call(HostEnv, Module, Name, Args) -> {ok, Results} | {trap, Reason}` at call time. This is the **only** channel from WASM to anything outside its own memory/tables — imports are part of WASM's own model, so supplying them is not a leak, but it is where all egress is governed.
**Implementations (capability axis):** `deny_all` (**default** — every import traps; pure computation only, maximal sandbox); `whitelist(Map)` (only explicitly granted host funcs); `wasi_p1` (an *optional, separate* library of host funcs — itself capability-scoped, e.g. a virtual FS, never ambient authority; out of scope for the core transpiler); `open` (pass-through to arbitrary Erlang — **trusted instances only**, dangerous). Defaults fail closed.

### [R7] Metering — `wasmrt_meter` — **security boundary (resource bound)**
**Contract:** `charge(Meter, Cost) -> ok | {trap, out_of_fuel}`, called at instrumentation points the emitter inserts (block/loop heads, call sites). Bounds CPU for untrusted code (DoS prevention).
**Implementations (policy axis):** `none` (no instrumentation cost — trusted/fast default for trusted profiles); `fuel(N)` (decrement, trap at zero — untrusted profile). Because instrumentation is inserted at codegen, enabling metering is also an emitter flag (§E) — a module built without charge points cannot be metered, so the *trust profile is partly fixed at build time*. Build untrusted-profile modules with instrumentation on.

### [I] Instantiation / linker — `wasmrt_instance`
**Contract:** `instantiate(BeamModule, TrustProfile) -> Instance`. Selects the concrete R1–R7 implementations per the requested **trust profile** (a named bundle, e.g. `untrusted` = {paged, map, threaded, bif, error, deny_all, fuel} vs `trusted_fast` = {nif, ets, pdict, nif, error, whitelist, none}), allocates memory/tables, runs active data/element segment init, then the `start` function, and returns a ready instance (a BEAM process, §3). Profiles are the user-facing knob; the layer map is the mechanism beneath them.

---

## 8. Correctness: fidelity invariants and conformance

### 8.1 Numeric fidelity invariants (part of the `wasmrt_num` contract)
Get these exactly right or computations silently corrupt:
- **Integers wrap two's-complement.** Erlang ints are bignums; **every** op masks to width and reinterprets signedness as required. Signed values stored as unsigned bit patterns, sign-interpreted on demand (one convention, documented). Shift counts masked mod bit-width.
- **Division traps:** `div_s INT_MIN / -1` (overflow) and `_ / 0` trap.
- **Floats are IEEE-754.** `f64` maps to Erlang doubles directly; **`f32` is rounded to single precision after every op** (no native 32-bit float). **NaN bit-pattern propagation/canonicalization** follows the spec — a known sharp edge; confirm whether bit-exact NaN is required or canonical-NaN tolerance is acceptable. `min`/`max` differ from Erlang's on NaN; `reinterpret` is a pure bit cast (`<<I:32>> = <<F:32/float>>`).

### 8.2 Conformance and interface-conformance
- **Differential testing against a reference engine** is the highest-value lever: run the official **WASM spec test suite** (`.wast`) through the transpiler → BEAM and compare results/traps against a conformant engine (`wasmtime`/`wasmer`/V8). It already encodes the subtle cases (NaN bits, signed/unsigned edges, wraparound, traps).
- **Interface-conformance suites** are what make modularity *safe*: **every implementation of a given interface must pass one shared suite for that interface.** The `rebuild` memory oracle and the `baseline`/`bif` implementations are the reference against which `paged`/`atomics`/`nif` and any optimized pass are differentially tested. A new backend is "done" when it passes the interface suite, not when it merely compiles.
- **Property-based tests** (Gleam/PropEr/QuickCheck) for `wasmrt_num` against an independent model. **Per-feature golden files** (WAT snippet → expected `.core` + result). Dedicated **pretty-printer unit tests** (§E).
- **Swarm angle:** the spec suite and the per-interface suites are embarrassingly parallel — partition across agents; each owns a slice or a backend and makes it green.

---

## 9. Scope, proposals, non-goals
- **Phase 1 (MVP):** WASM 1.0 — i32/i64/f32/f64, structured control flow, single 32-bit memory, functions, direct + indirect calls, globals, tables, data/element, start, imports/exports — plus **multi-value**, **sign-extension**, **non-trapping float-to-int** (now baseline).
- **Phase 2:** bulk memory ops, reference types, SIMD (`v128` — large, defer), `memory64`, multiple memories, tail-call proposal (maps beautifully to BEAM tail calls).
- **Phase 3 / likely separate:** exception-handling proposal, GC proposal, stack switching, component model. **WASI** is a host-import *library* (an `wasmrt_host` implementation), explicitly out of the core transpiler.
- **Hard non-goal: threads / shared memory.** It needs genuinely *shared* mutable linear memory across processes plus wasm atomic-operation semantics. Every memory tier here is deliberately single-threaded / process-local (P can't share; O uses atomics process-locally — we need speed, not sharing; N is per-instance), and sharing conflicts with one-instance-one-process. Single-threaded WASM is the target across all tiers and trust profiles.

State proposal in/out decisions explicitly; "WASM" is not one fixed target.

---

## 10. Work breakdown (interface-first, for the swarm)

**Wave 0 — define every interface (do first, unblocks everything).** Write the contracts: `wasm_frontend`, `wasm_validate`, `wasm_ssa`, `wasm_cfg_lower`, `wasm_emit` (+ its config sub-axes), `wasm_build`; and the Erlang behaviours `wasmrt_mem`, `wasmrt_table`, `wasmrt_state`, `wasmrt_num`, `wasmrt_trap`, `wasmrt_host`, `wasmrt_meter`, `wasmrt_instance`. Plus **W0-scaffold** — Gleam project, `wasm2core_ffi.erl`, the build driver. Once interfaces exist, implementations parallelize with no coordination.

**Then, each cell below is an independent work item** (interface conformance suite is the definition of done):

- **Front end:** `binary` decoder; `text`/WAT parser. (Bit-syntax makes the binary decoder notably easy.)
- **Validator:** `full`; `subset`; `assume_valid`. (`full` first — gates untrusted input.)
- **SSA:** `baseline` (also the oracle pass); `opt`.
- **CFG lowering:** `direct_letrec`; `merged`.
- **Emitter:** Core AST + **pretty-printer** (own tests); `state_strategy=threaded` and `=cell` modes; metering instrumentation; `cerl_ast` alternative.
- **Driver:** `forms`; `file`.
- **Memory:** `rebuild` oracle → `paged` (P) → `atomics` (O) → `nif` (N). *Starts day one; no front-end dependency.*
- **Tables:** `map` (P); `ets` (O).
- **State:** `threaded` (P); `pdict` (O).
- **Numerics:** `bif` (P, + property tests); `nif` (N). *Starts day one.*
- **Traps:** `error`.
- **Host imports:** `deny_all` (default); `whitelist`; (`wasi_p1` later, separate package); `open`.
- **Metering:** `none`; `fuel`.
- **Instantiation:** the linker + named trust profiles (`untrusted`, `trusted_fast`, …).
- **Conformance harness:** spec `.wast` runner + differential engine; the per-interface suites. *Partitionable across many agents.*
- **CLI/API:** `wasm2core source -> .core -> .beam`.

Critical path to a first end-to-end run: Wave-0 interfaces → `binary` front end → `full` validator → `baseline` SSA → `direct_letrec` lowering → emitter+printer → `forms` driver → `paged` memory + `threaded` state + `bif` numerics + `deny_all` imports. Everything else is breadth that lands in parallel.

---

## 11. Summary for the next agent

Build, in **Gleam**, a WASM→Core Erlang transpiler whose defining property is that **every layer is a narrow interface with many interchangeable implementations** — this is simultaneously the security model and the replaceability model. Two axes of variation: a **trust tier (P pure / O OTP-native / N custom-NIF)** for the mutable-state run-time layers, selected by how much the deployment trusts the code and whether native code may crash the node; and **policy/capability/format** axes for the validator (verification strength), host imports (capability — the sole, fail-closed egress), metering (resource policy), and the emitter (output format + binding + instrumentation). The **instance is the unit of security policy**: it is instantiated with a chosen implementation per layer (a named trust profile), so untrusted and trusted instances run side by side on one node with identical generated code. Generated Core Erlang stays backend-agnostic via instance-level dispatch (default) or link-time/monomorphized binding (speed); the one deliberate coupling is that the **state layer's tier sets the calling convention** (tier-P state threads a functional instance record — the fully zero-native "no OTP, no NIF" build — while tier-O state uses cells), and a **uniform-threading interface rule** (every mutating op returns the handle) lets immutable and mutable backends share one signature. The transpilation itself is tractable because WASM control flow is *already structured* → lower `block`/`loop`/`if`/`br*` to a `letrec` of tail-recursive functions (loops = proper BEAM tail calls = constant space), eliminate the operand stack into SSA `let` bindings, and route every numeric op through `wasmrt_num` (which must honor exact two's-complement/IEEE/NaN/trap **fidelity invariants**) and every memory op through `wasmrt_mem` (bounds-checked → trap). The canonical layer is memory, with `paged` binaries (P, universal default), process-local `atomics` (O, everyday default), and a `malloc` NIF (N, ceiling) behind one `wasmrt_mem` behaviour, all validated against a `rebuild` oracle. Modularity is kept *safe* by **interface-conformance suites**: every implementation of an interface passes one shared suite, and the whole system is differentially tested against the official WASM spec test suite. Threads/shared-memory is a hard non-goal; defer SIMD, GC, and WASI (WASI being just a host-import implementation). Work is interface-first: define all contracts in Wave 0, then every (layer × implementation) cell is an independent, swarm-parallel work item whose definition of done is its conformance suite.
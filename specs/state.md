# Implementation State — what's taken, by whom, and what it leaves

> The swarm's shared ledger. Before claiming work, read it; after finishing, update it.
> It maps the canonical spec ([`00-high-level.md`](00-high-level.md)) onto concrete work
> units and tracks their status. The detailed unit specs live in
> [`phase-1/`](phase-1/). Read [`phase-1/00-overview.md`](phase-1/00-overview.md) first.

**Legend — status:** `unclaimed` · `in-progress (name)` · `blocked (on …)` · `done`
**Legend — freeze milestone:** a published, compiling type stub that unblocks downstream
units (see overview §3). Announce milestones here the moment they land.

---

## Freeze milestones (the real scheduling gates)

| Milestone | Produced by | Status | Unblocks |
|---|---|---|---|
| `«IR-FROZEN»` — `ir.gleam` + `ir-grammar.md` | 01 | **FROZEN ✓** | 02, 08, 10, 11 |
| `«ABI-FROZEN»` — `instance.gleam` (Binding + convention) | 01 | **FROZEN ✓** | 08, 09, 11 |
| `«RTNUM-SIG-FROZEN»` — `rt_num.gleam` signatures (90 fns) | 01 | **FROZEN ✓** | 06, 08 |
| `«CORE-AST»` — `backend/core_erlang.gleam` types | 03 | **published ✓** | 08 |
| `«WASM-AST»` — `frontend/wasm/ast.gleam` types + `DecodeError` | 05 | **published ✓** | 10 (validate) |
| `«FFI-SHIM»` — `twocore_codegen_ffi.erl` (compile+load) | 04 | **published ✓** | 03 (verify), 08/10 (e2e tests) |

---

## Phase 1 — units

Phase-1 goal & honest scope: see [`phase-1/00-overview.md`](phase-1/00-overview.md) §1.

| Unit | Doc | Owner / status | Depends on (freeze) | What it leaves when `done` |
|---|---|---|---|---|
| **01** Interface freeze | [`01`](phase-1/01-interface-freeze.md) | **done** | — | IR types, `.ir` grammar, runtime ABI, rt_num signatures (90 fns, `todo` bodies → 06), PipelineError stub all frozen; neutrality review signed off; 3 golden `.ir` + strawman test green. The keystones exist. |
| **02** `.ir` printer & parser | [`02`](phase-1/02-ir-textual-form.md) | **done** | `«IR-FROZEN»` | `.ir` round-trips the full surface (`parse(print(m))==m`, incl. NaN payloads/`-0.0`/±Inf); total parser; 3 goldens parse; `ir-grammar.md` reconciled to the implementation. |
| **03** Core Erlang AST & printer | [`03`](phase-1/03-core-erlang-backend.md) | **done** | — | `.core` AST (`«CORE-AST»`) + pretty-printer; printed ASTs compile+run on real OTP-29 (add/fac/classify); atom escaping proven byte-identical to OTP `io_lib:write_string`. |
| **04** `build_beam` driver & FFI | [`04`](phase-1/04-build-beam-driver.md) | **done** | — | `.core` text → loaded `.beam` proven (hand-written `.core` compiled, loaded, ran on BEAM); the `«FFI-SHIM»`; `gleam_erlang` added. |
| **05** WASM decoder & AST | [`05`](phase-1/05-wasm-decoder.md) | **done** | — | `.wasm` → WASM AST (`«WASM-AST»`); LEB128 (spec vectors) + fail-closed/fuzz-proven decoding (no `let assert`/`panic`); 54 tests. |
| **06** `rt_num` numerics (`bif`) | [`06`](phase-1/06-rt-num-numerics.md) | **done** | `«RTNUM-SIG-FROZEN»` | All 90 bodies implemented; the numeric-fidelity reference (tier-P), 40 spec-corner/property tests. Build now **zero-warning**. |
| **07** Conformance harness & corpus | [`07`](phase-1/07-conformance-harness.md) | **done** | pipeline (committed) | Acceptance corpus green end-to-end (the Phase-1 goal proof); spec-suite runner **1699 pass / 1400 skip / 0 fail** (18 files, honest skip categories); oracle/registry/`driver.pipeline()` reusable by unit 11. |
| **08** `emit_core` (IR → Core) | [`08`](phase-1/08-emit-core.md) | **done** | `«IR-FROZEN»`,`«CORE-AST»`,`«ABI-FROZEN»`,`«RTNUM-SIG-FROZEN»` | **The backend works end-to-end:** hand-written IR → Core Erlang → loaded `.beam` → correct results (add/wrap/shift, `sum_to(100k)` constant-space, fib/fac, div traps, deny-all host, stdlib gcd); binding chokepoint + security-invariant test pass. |
| **09** Runtime defaults | [`09`](phase-1/09-runtime-defaults.md) | **done** | `«ABI-FROZEN»` | `rt_trap.raise/1`, `rt_host.call_host/3` (deny-all), `rt_meter.charge/1` (tier-O pdict fuel), `rt_stdlib.gcd/2` (own), `rt_bif` (build-time allowlist). 34 fail-closed/security tests. |
| **10** WASM validate & lower | [`10`](phase-1/10-wasm-validate-and-lower.md) | **done** | `«WASM-AST»`, `«IR-FROZEN»` | `full` validation (spec abstract-stack algorithm + local cap) rejects ill-typed; lower does stack-elim/SSA (mutable locals → `LoopParam`) with named labels. **Real `.wasm` → BEAM proven** (add/sum_to/fib via the full pipeline). |
| **11** ir_lower, linker, Safe profile, CLI (capstone) | [`11`](phase-1/11-ir-lower-linker-cli.md) | **done** | all of the above | `ir_lower` (fail-closed allowlist + metering insertion), the Safe profile/linker, the per-stage CLI (decision #5; `gleam run -- run add.wasm add 2 3` → `5`), and the acceptance corpus green **with ir_lower(Safe) in the chain**. Phase-1 goal proven. |

---

## High-level spec coverage — which §/decision each unit "takes"

> So nothing in the canonical spec is silently dropped, and so two units don't claim the
> same ground. "Taken" = an owning Phase-1 unit exists. "Deferred" = explicitly Phase-2+.

| High-level spec item | Taken by | Notes |
|---|---|---|
| §3 IR core types | 01 | Full surface frozen now (lock-now decisions #1/#2/#4). |
| §3 `.ir` textual form | 01 (grammar), 02 (impl) | The inter-stage contract (D7). |
| §3 dual value model + explicit conversions | 01 (types), 06 (numeric semantics) | Floats as bits (D5). Term layer is lock-now placeholder. |
| §3 optional linear memory | 01 (IR models it) | **Runtime deferred** — no `rt_mem` in Phase 1 (corpus has no memory). |
| §3 `call_host` capability node | 01 (IR), 08 (lowering), 09 (deny-all) | Exercised end-to-end (D9). |
| §3 `trap` / `charge` effects | 01 (IR), 08 (emit), 06 (trap raise), 09 (rt_meter) | Metering **seam** wired now (D9). |
| §4 FW WASM frontend (decode/validate/ssa/structure) | 05 (decode), 10 (validate+lower) | `full` validator only; `subset`/`assume_valid` deferred. |
| §4 M1 IR core + textual form | 01, 02 | |
| §4 M2 optimizer (`ir_opt`) | — | **Deferred to Phase 2.** |
| §4 M3 stdlib + capability lowering (`ir_lower`) | 11 (ir_lower) | Minimal: capability/stdlib resolution + `charge` insertion. |
| §4 B1 emitter (`emit_core`) | 08 | `core_text` format; `cerl_ast` alt deferred. |
| §4 B2 driver (`build_beam`) | 04 | `forms`/in-memory path (via `core_scan`/`core_parse`); `file` fallback. |
| §4 R-num numerics (`bif`) | 06 | tier-P reference impl; `nif` deferred. |
| §4 R-trap traps | 09 | `error` impl. |
| §4 R-state instance state | 01/08 (calling convention) | tier-P; **no threaded record in Phase 1** (D3d) — no mutable state. |
| §4 R-host host/capability dispatch | 09 | `deny_all` (default); `whitelist`/`open` deferred. |
| §4 R-meter metering | 09 | minimal `fuel`; `none` is the Unsafe default (deferred). |
| §4 R-std standard library | 09 (runtime), 11 (resolution) | `own` minimal (1–2 fns); breadth + `passthrough` deferred. |
| §4 R-bif BEAM-function gate | 09 | `allowlist` (enforced minimal); `open` deferred. |
| §4 R-mem / R-tab linear-memory subsystem | — | **Deferred to Phase 2.** |
| §4 I instantiation (`rt_instance`) | 11 (linker) | Safe profile only; Unsafe deferred. |
| §5 backend lowering (letrec/tail-calls, calls, numerics, traps) | 08 | Verified loop template in the unit doc. |
| §5 codegen security invariants | 08 (test) | No ambient-authority `apply` (D3a); asserted structurally. |
| §6 Safe mode | 09 + 11 (seams) | **Seams wired & exercised, not a full sandbox (D9).** |
| §6 Unsafe mode | — | **Deferred to Phase 2.** |
| §9.1 numeric fidelity invariants | 06 | Property-tested + end-to-end via the corpus. |
| §9.2 preemptive/compiled execution | 08 (tail-calls) + 04 (it's real BEAM code) | Verified: a `letrec` tail loop ran 100k iters in constant space on OTP 29. |
| §11 differential testing (spec `.wast`) | 07 | Tier-A (expected baked in `.wast`) + Tier-B (engine oracle). |
| §11 interface-conformance suites | each unit's "Verification" | Done = suite passes, not "compiles" (D8). |
| §8.2 Porffor JS→WASM bridge | — | **Deferred to Phase 2+.** |
| §8.3/§8.4 Arc/Gleam frontends | — | **Deferred (later phases).** |
| §12 WAT text parser | — | **Deferred to Phase 2** (use `wat2wasm` for fixtures). |
| §12 bulk memory / reftypes / SIMD / tail-call proposal / threads | — | Deferred / non-goal per §12/§26. |

---

## Phase 2 preview (not yet specced into units)

Once Phase 1's vertical slice is green, the natural next wave (to be broken down later):
broaden WASM 1.0 coverage (full `br_table`/`call_indirect`, globals, `memory` load/store);
the `rt_mem` tiers (`rebuild`→`paged`→`atomics`) + `rt_table`; the `baseline` optimizer;
the WAT parser; the Unsafe profile (passthrough stdlib, open BIFs, `aggressive` optimizer);
broaden the `own` stdlib + BIF allowlist; then the Porffor bridge + its ABI `rt_host` shim.

---

## Change log

- **Unit 11 landed (capstone) — PHASE 1 COMPLETE.** A real WASM binary now compiles
  through decode→validate→lower→**ir_lower(Safe)**→emit→build→run on the BEAM, driven by a
  CLI. `ir_lower` enforces the `rt_bif` allowlist fail-closed (allowlisted `("std","gcd")`
  runs; an un-allowlisted/undeclared `CallHost` → build-time `ForbiddenHost`; a declared
  host import passes to run-time deny-all) and inserts `Charge` metering (fuel accumulates
  per the cost model without changing results; `sum_to(100000)` stays constant-space with
  metering on). `profiles.safe()` + linker (fail-closed). The CLI (`src/twocore.gleam`)
  exposes every stage independently (decision #5): `decode`/`validate`/`lower`/`ir`/
  `ir-lower`/`emit`/`to-core`/`build`/`run` — verified e.g. `gleam run -- run add.wasm add
  2 3` → `5`. `pipeline.gleam` completed with the real per-stage `PipelineError`. 310 tests;
  the embedded spec-suite stays 1699/1400/0. Deps `argv` + `simplifile` added (CLI). Minor:
  `RunResult.Trapped` carries a `String` reason (reuses unit 07's trap channel + represents
  capability denials); `LowerError` gained a `ForbiddenHost` variant; a `twocore_cli_ffi.erl`
  catching-apply shim was added (unit 04's FFI is single-owned).
- **Unit 07 landed (conformance harness, oracle & corpus).** The Phase-1 acceptance
  corpus passes end-to-end through decode→validate→lower→emit→build→invoke (the goal
  proof: add/wrap, signed&unsigned div pair, INT_MIN/-1 & /0 traps, shift-mask, sum_to,
  fib/fac, an f32/f64 program, host-import deny). The Tier-A spec-suite runner over the
  pinned testsuite allowlist reports **1699 pass / 1400 skip / 0 fail** with categorized
  skips (no silent truncation). Bit-pattern/NaN-class oracle; multi-module registry; uses
  OTP `json:decode` (no new Hex dep). Pinned: testsuite SHA
  `193e551ff22663995b1ac95dc62344133669e14b`, wabt 1.0.41, wasmtime 46.0.1. **wasmtime v46
  invoke syntax** (differs from the doc's v14 assumption): `wasmtime run --invoke <fn>
  <module.wasm> <args…>` (flags+fn before the module, call args after). `driver.pipeline()`
  is a working `runner.Driver` the capstone (11) reuses unchanged. Bulk testsuite is
  gitignored; a 6-file curated fixture subset is committed (fresh-checkout CI: 466/156/0).
  - **KNOWN ISSUES surfaced by conformance (correctly SKIPPED, fail=0 — not false passes;
    follow-up fix-pass after unit 11):** (a) `emit_core` `ArityMismatch(3,1)` on
    `fac-iter`-style multi-arg calls; (b) zero-result functions → `build: return count
    mismatch`; (c) some nested control → `emit: UnboundLabel`. These are beyond the Phase-1
    acceptance corpus but are real robustness gaps in units 08/10 worth fixing.
  - 5 allowlist files (`local_tee, br_if, br_table, select, func`) are un-`wast2json`-able
    at the pinned HEAD (reference-type proposal syntax); `vendor.sh` skips them — recover
    with a wabt bump or an MVP-clean pin later.
- **Unit 02 landed (`.ir` printer & parser).** Canonical printer (floats as raw hex bits)
  + a total recursive-descent parser with its own positioned `ParseError`; round-trip
  `parse(print(m))==m` over the full IR surface (all 68 NumOps, 26 ConvOps, every Expr
  variant, NaN payloads/`-0.0`/±Inf bit-exact); the 3 hand-authored goldens parse; 25-input
  garbage battery returns typed errors without panic. 237 tests. **`ir-grammar.md`
  reconciled** to the (now-tested) implementation — notably `;` is a comment, not a
  `let`/`charge` separator (fixing a conflict in the seeded grammar), trap-reason spellings
  match the `TrapReason` ctor snake_case, and `data`/`ConvOp`/`TermOp` spellings finalized.
- **Unit 10 landed (WASM validate & lower) — FULL `.wasm` → BEAM PIPELINE WORKS.** Real
  `wat2wasm` fixtures decode → validate → lower → emit_core → build_beam → run on the
  BEAM with spec-correct results: `add(2,3)=5` (+ wrap), `sum_to(100)=5050`, `fib(10)=55`.
  212 tests, zero warnings, fail-closed (no panic on hostile input).
  - **10a validate** is a faithful transcription of the spec abstract-stack algorithm
    (vals+ctrls stacks, polymorphic-after-`unreachable`, loop label = input types, full
    br/br_table/call/index checks, else-less-`if` rule, per-function local cap 50000);
    rejects every ill-typed fixture with a spec-cited `ValidateError`; imports only
    `ast.gleam` (gates independently of the IR).
  - **10b lower**: stack-elim to compile-time `ir.Value` list (no runtime stack); WASM
    branch DEPTHS resolved to NAMED IR labels (D6); mutable locals threaded as
    `LoopParam` (loops) / block result values via a sound syntactic over-approximation
    (locals assigned anywhere in a construct); declared locals zero-init'd via `Let`.
  - **Notes for unit 11:** lower names a defined function at funcidx `f` as `"f<funcidx>"`
    (offset by `imported_func_count`); `ExportFn(export_name, "f<idx>")` (emit_core emits a
    forwarding wrapper when names differ); IR module name `"twocore@wasm@<sanitized>"`.
    `call_indirect` is rejected at validation (and guarded in lower). Rename in lower if
    the CLI/linker wants different names.
- **Unit 05 landed (WASM decoder & AST).** `decode/1`, generic `decode_u_n`/`decode_s_n`
  LEB128 (all spec vectors incl. overflow/too-long), the worked `add` fixture decodes to
  the exact AST, `wat2wasm` fixtures (loop/if/call/locals/multi-value), and a fail-closed
  fuzz suite (256×41 single-byte mutations + truncations never crash). 54 tests; the
  decoder code has no `let assert`/`panic`/`todo`. **`«WASM-AST»` published** with
  `Module(imported_func_count, types, funcs, exports)`, `Func(type_idx, locals, body)`,
  the Phase-1 `Instr` set, `ValType`, `BlockType`, and `DecodeError`. **Notes for unit 10:**
  `Func.locals` are RLE-expanded **declared-only** (params are indices 0..k-1, declared
  locals follow) — lower must zero-init each declared local as an IR `Let` (emit_core
  ignores `ir.Function.locals`); use `Module.imported_func_count` as the funcidx offset
  (don't assume funcidx==defined index); and put a **per-function local-count cap** in the
  validator (the spec sets that limit in validation — guards against RLE over-allocation).
- **Unit 08 landed (emit_core) — BACKEND PROVEN END-TO-END.** Hand-written IR compiles to
  Core Erlang and runs on the real BEAM: `add(7,35)=42`, i32 wrap & shift-masking,
  `sum_to(100000)=5000050000` in **constant space** (letrec tail-`apply` back-edge),
  `fib(20)=6765`, `fac(10)=3628800`; `div_u(_,0)`/`div_s(INT_MIN,-1)` trap as
  `{wasm_trap,…}`; a host import is rejected `{capability_denied,…}` (deny-all); and
  `CallHost("std","gcd")` → `rt_stdlib:gcd`. Binding chokepoint + the structural codegen
  security-invariant test pass. 130 tests, zero warnings. **Pinned notes for downstream:**
  - **Unit 10 (lower):** emit_core IGNORES `Function.locals` (Phase-1 corpus has none).
    Lowering must make WASM locals flow through `Let`/`LoopParam`/params — i.e. emit an
    explicit zero-init `Let` for each declared WASM local at function entry, and turn
    mutable locals that are live across control flow into `LoopParam` (SSA). Numeric
    `Convert` ops (wrap/extend/reinterpret/trunc_sat) ALREADY lower in emit_core; only the
    four term↔numeric **boxing** Converts are `UnsupportedNode` (not needed for the WASM
    numeric path).
  - **Unit 11 (ir_lower):** the `("std","gcd")→rt_stdlib:gcd` resolution currently also
    lives as a small `resolve_stdlib` table in emit_core; ir_lower's allowlist
    (`rt_bif`) must stay ALIGNED with it (same triple). `CallHost` cap/name are emitted
    as atoms (faithful for deny-all; revisit only if a permissive host needs binaries).
  - Added a test-only `test/twocore_emit_test_ffi.erl` (`catch_apply/3`) so Gleam tests
    can rescue an error-class trap without crashing the runner (gleam_erlang 1.3 has no
    generic rescue).
- **Unit 09 landed (Safe-mode runtime defaults).** `rt_trap`/`rt_host`/`rt_meter`/
  `rt_stdlib`/`rt_bif` + 34 security/fail-closed tests; zero warnings. **Pinned
  cross-unit conventions** (units 08 & 11 must follow):
  - Runtime ABI the generated code calls: `rt_trap:raise/1` (reason = the snake_case
    atom of the `TrapReason` ctor; raises error-class `{wasm_trap, Kind}`),
    `rt_host:call_host/3` (deny-all, raises `{capability_denied, Cap, Name}`),
    `rt_meter:charge/1`.
  - **`rt_meter` is tier-O** (process-dictionary fuel counter, observable via
    `fuel_consumed/0`) — confirmed in-bounds for Safe (P or O, never N).
  - **`call_host` → own-stdlib triple (PINNED):** IR `CallHost(capability:"std",
    name:"gcd")` resolves (by `ir_lower`, unit 11) to `rt_stdlib:gcd/2`; the `rt_bif`
    allowlist contains exactly `("twocore@runtime@rt_stdlib","gcd",2)`. Unit 08 emits
    the direct call; unit 11 does the rewrite.
  - `rt_trap.spec_trap_message/1` maps each `TrapReason` → the WASM spec trap-message
    substring (for the unit-07 harness): int_div_by_zero→"integer divide by zero",
    int_overflow→"integer overflow", unreachable→"unreachable".
- **Unit 06 landed (rt_num bodies).** All 90 frozen signatures implemented in pure Gleam
  over BEAM bignums + bit syntax; the numeric-fidelity reference (high-level §9.1).
  40 spec-corner/property tests (div_s INT_MIN/-1 overflow trap, rem_s INT_MIN/-1 == 0,
  /0 traps, shift-count mod N, sign-fill, extend/wrap, reinterpret, canonical-NaN,
  signed-zero min/max, trunc_sat clamps). **Build is now zero-warning** (the 90 `todo`
  warnings are gone). Verified correction to the doc: f32 bit-build *saturates* to ±Inf
  on OTP 29 (does not raise `badarith`); only f64 overflow needs the guard, handled
  exactly via the IEEE round-to-nearest threshold.
- **Unit 04 landed (build_beam + FFI shim).** A hand-written `.core` module compiled,
  loaded via `code:load_binary`, and ran on the BEAM with correct results (incl.
  hot-replace), and malformed `.core` returns a typed `BuildError` (no panic).
  `gleam_erlang v1.3.0` added. Two real bugs were corrected in the unit-doc's "verified"
  shim (they only surface when called *from Gleam*, not from an Erlang shell): the
  scan/parse error branches returned a bare binary instead of a `[Binary]` list, and
  `load_module`'s filename must be an Erlang charlist (`unicode:characters_to_list`), not
  a Gleam-`String` binary. Both fixed + documented inline in `twocore_codegen_ffi.erl`.
- **Unit 01 landed (interface freeze).** IR types, runtime `Binding` ABI + calling
  convention, the complete 90-function `rt_num` signature set (`todo` bodies, owned next
  by unit 06), and `PipelineError` are frozen. `gleam build` clean except the 90
  sanctioned `todo` warnings; `gleam test` green (7); neutrality review (D6) passed.
  Two notes for downstream: (a) the seeded `ir-grammar.md`/golden examples were corrected
  to **strict ANF** (the original nested `num` exprs in `return`/`if` operand positions,
  which the `Value`-typed fields forbid); (b) `rt_num` stub args are underscore-prefixed
  (`_a`,`_b`) to keep the build warning-free — unit 06 restores `a`/`b` with the bodies.
- **Planning, post-review reconciliation (initial drafting):** after the unit docs were
  drafted, these refinements were folded back into the frozen foundations so the
  contracts are internally consistent:
  - `Function` carries **named params** (`params: List(Local)` + `result`), with
    `signature/1` deriving the `FuncType` — closing the `%p0`/`%p1` round-trip gap
    between `ir.gleam` and `ir-grammar.md` (flagged by unit 02). Grammar updated.
  - `«RTNUM-SIG-FROZEN»` now requires the **complete** Phase-1 `rt_num` name list
    (integers + i64 mirror + conversions + floats), by a fixed naming rule — so units 06
    and 08 don't race on spellings (flagged by 06/08).
  - `CallHost` has **two fates**: `ir_lower` (11) rewrites a resolved `own`-stdlib call
    into a direct `rt_stdlib` call; a genuine host import stays a deny-all `call_host`.
    `rt_bif` is a **build-time** gate consulted by `ir_lower`, not a `Binding` field /
    runtime call — its gate shape freezes with unit 11 (flagged by 09/11).
  - Tier framing corrected: Phase-1 compute is tier-P; the **metering** counter may be
    tier-O (pdict), which Safe permits (P or O, never N) — unit 09 may instead ship a
    pure no-op `charge` (flagged by 09).
  - `ir_lower` reads `ir.gleam` **+ the `Binding` type** (for `mode`/policy); the
    ownership note was relaxed accordingly (flagged by 11).
  - Dependency note added: units 04/08/09 will `gleam add gleam_erlang` (flagged by 04).
  - `00-overview` §3 DAG/prose numbering corrected (decoder = 05, build_beam = 04,
    validate+lower = 10; `«WASM-AST»` unblocks 10) (flagged by 05).

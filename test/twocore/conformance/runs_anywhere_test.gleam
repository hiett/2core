//// Unit P4-11 — PROOF 1: the runs-anywhere HEADLINE (§C, G1/G3/G6 — the phase's proof-of-goal).
////
//// The platform's high-level pitch — *"no OTP, no NIF, runs-anywhere, provably unable to take over
//// the VM"* — is the tier-P **`portable`** posture: `Threaded` instance state (the state travels as
//// a purely-functional record threaded through generated code — no process-dictionary instance
//// cell), `Paged` linear memory (immutable BEAM binaries, no native code), `bif` numerics (pure
//// Gleam over BEAM bignums), the fail-closed **Safe** policy. This suite establishes it the two
//// ways the headline needs — because "it ran" and "it used nothing native" are DIFFERENT claims:
////
////   (a) **Grep-verified (static).** Emit the `profiles.portable()` build of state-heavy corpus
////       modules (memory + globals + a table) and grep the emitted `.core` — the one artifact that
////       names every runtime module the generated code links (the seam emits only fixed
////       `twocore@runtime@*` atoms, D3a) — asserting ZERO native/unsafe primitives
////       (`atomics`/`ets`/`persistent_term`/NIF) EVERYWHERE and ZERO `rt_state` pdict *instance
////       cell* seam (`'seed'`/`'mem_get'`/`'global_get'`), which `Threaded` genuinely eliminates.
////   (b) **Executed (dynamic).** Compile the WHOLE acceptance corpus under the REAL
////       `profiles.portable()` profile (not a test-capped variant — the exact posture a user gets)
////       and run it through `load → instantiate → invoke` on a bare BEAM, asserting each program is
////       spec-correct AND byte-identical to the `cell`/`paged` oracle.
////
//// ## The one honest caveat (stated, not hidden — §C, keystone A.3, P4)
////
//// The grep's zero-set is the NATIVE/UNSAFE primitives + the pdict *instance-state* cell — it does
//// NOT assert zero pdict. A Safe `portable` build MANDATORILY keeps `MeterFuel` (the F5 fail-closed
//// CPU bound — `MeterOff`-under-Safe is rejected), so its `.core` DOES call `rt_meter`
//// (`seed_fuel`/`charge`) and seed the `rt_host` policy cell — each a single PROCESS-LOCAL pdict
//// value: node-safe, cannot escape, cannot crash the node, present on every BEAM. The project
//// taxonomy classifies pdict as tier-O (node-safe), and Safe permits tier P or O, never N — so
//// these overlays legitimately remain. The "runs on a bare BEAM, provably unable to take over the
//// VM" property is about NO NATIVE CODE and NO CRASHABLE INSTANCE STATE, which `portable` satisfies
//// in full. This suite asserts those overlays are PRESENT (> 0) to keep the headline proof honest.
////
//// The relationship to unit 09: unit 09's `tier/runs_anywhere_test` owns the fine-grained grep over
//// the `combos.portable` (capped) test binding; THIS capstone suite re-establishes the headline as
//// the consolidated proof-of-goal over the REAL, shipped `profiles.portable()` AND adds the
//// executed byte-identity half — the phase's proof-of-goal, not a change-detector.
////
//// Spec anchors: keystone §B.1 (the seam emits fixed `twocore@runtime@*` atoms); WebAssembly spec
//// §7 *Embedding* (the memory-safety invariant holds by construction when the whole memory
//// subsystem is immutable BEAM binaries); exec/instructions (bounds/traps) cited per corpus program
//// inside each `corpus/*.expected`.

import gleam/int
import gleam/list
import gleam/result
import gleam/string
import twocore/conformance/driver
import twocore/pipeline
import twocore/runtime/instance.{Binding, Nif}
import twocore/runtime/profiles
import twocore/tier/combos

/// Compile corpus `name` to `.core` text under the REAL `profiles.portable()` profile — the exact
/// artifact `build_beam` compiles and the grep audits. The `portable` build links only pure-BEAM
/// `twocore@runtime@*` modules; the emitted text names every one, so a grep of it is an exhaustive
/// audit of the module boundary a portable instance can cross. `let assert` here documents that a
/// well-formed corpus program always compiles under `portable` (a failure is a real regression).
fn portable_core(name: String) -> String {
  let assert Ok(bytes) = combos.read_wasm(name)
  let assert Ok(m) = pipeline.source_to_ir(bytes)
  let assert Ok(core) = pipeline.ir_to_core(m, profiles.portable())
  core
}

// ─────────────────────────── PROOF 1 (a): the grep — no native code, no instance cell ───────────────────────────

/// PROOF 1a (G6 — the "no OTP, no NIF" static half). Across every state-heavy corpus module
/// (`mem` = memory, `gvar` = mutable globals, `callind` = a table + indirect dispatch, `memgrow` =
/// `memory.grow`), the `portable` `.core` links ZERO native / OTP-native / native-code state: it
/// names no module containing `atomics`, `ets`, `persistent_term`, or a NIF loader. This is the
/// structural cross-check behind "runs on a bare BEAM": nothing native is even reachable.
pub fn portable_core_links_zero_native_state_test() {
  let failures =
    list.flat_map(["mem", "gvar", "callind", "memgrow"], fn(name) {
      let core = portable_core(name)
      let check = fn(tok) {
        case combos.count_occurrences(core, tok) {
          0 -> []
          n -> [
            name
            <> " links native primitive '"
            <> tok
            <> "' × "
            <> int.to_string(n),
          ]
        }
      }
      list.flatten([
        check("atomics"),
        check("ets"),
        check("persistent_term"),
        check("nif"),
        check("load_nif"),
        check("erlang_nif"),
      ])
    })
  assert failures == []
}

/// PROOF 1a (G1 — no crashable instance state). No process-dictionary INSTANCE-STATE cell: the
/// `Threaded` build replaces the `rt_state` pdict cell (`'seed'`/`'mem_get'`/`'mem_put'`/
/// `'global_get'`/`'global_set'`) with a value threaded through generated code, so those quoted
/// atoms are ABSENT from every state-heavy portable `.core`. (The quoted-atom grep is precise:
/// `'seed'` is 0 even though `'seed_fuel'` — the tier-O fuel overlay — is present, because the
/// closing quote after `seed` never matches inside `seed_fuel`.)
pub fn portable_core_has_no_instance_cell_seam_test() {
  let cell_seam = [
    "'seed'", "'mem_get'", "'mem_put'", "'global_get'", "'global_set'",
  ]
  let failures =
    list.flat_map(["mem", "gvar", "callind", "memgrow"], fn(name) {
      let core = portable_core(name)
      list.flat_map(cell_seam, fn(tok) {
        case combos.count_occurrences(core, tok) {
          0 -> []
          n -> [
            name
            <> " emits pdict instance-cell seam '"
            <> tok
            <> "' × "
            <> int.to_string(n),
          ]
        }
      })
    })
  assert failures == []
}

/// PROOF 1a (non-vacuity). The greps above are a REAL audit, not vacuously-green string matches:
/// the `portable` build DOES route state through the threaded record — `mem` names the threaded
/// memory family (`'t_load'`/`'t_store'`), `gvar` names the threaded global accessor
/// (`'t_global_get'`), and every build names `rt_state` (the `fresh` + threaded accessors). So the
/// "no cell seam" result is a REPLACEMENT (the record-threading build), not an absence of state ops.
pub fn portable_core_uses_threaded_state_families_test() {
  let mem = portable_core("mem")
  assert combos.count_occurrences(mem, "'t_load'") > 0
  assert combos.count_occurrences(mem, "'t_store'") > 0
  assert combos.count_occurrences(mem, "rt_state") > 0

  let gvar = portable_core("gvar")
  assert combos.count_occurrences(gvar, "'t_global_get'") > 0
  assert combos.count_occurrences(gvar, "rt_state") > 0
}

/// PROOF 1a (the honest caveat, P4). The Safe `portable` build MANDATORILY keeps `MeterFuel` (the
/// F5 CPU bound), so its `.core` DOES call the node-safe, process-local tier-O overlays — `rt_meter`
/// (`seed_fuel`/`charge`) and the `rt_host` policy cell. This asserts they are PRESENT (> 0), so the
/// runs-anywhere zero-set is documented as "native/unsafe primitives + the instance cell", NOT a
/// strict-zero-pdict claim: `MeterOff`-under-Safe is rejected because it would drop the CPU bound.
/// Stating this in an assertion keeps the headline proof TRUE rather than overstated.
pub fn portable_core_keeps_node_safe_tier_o_overlays_test() {
  let core = portable_core("mem")
  // The Safe CPU-fuel counter is baked in (seed at instantiate + charge sites) — node-safe pdict.
  assert combos.count_occurrences(core, "rt_meter") > 0
  assert combos.count_occurrences(core, "seed_fuel") > 0
  // The host-policy cell is present (deny-all under Safe) — node-safe pdict.
  assert combos.count_occurrences(core, "rt_host") > 0
}

/// PROOF 1a (the grep can see what it forbids). A `ceiling`/`atomics` `.core` DOES name the tier-O
/// `rt_mem_atomics` module — proving the zero-count above is a REAL audit (the grep sees the native/
/// O(1) backend WHEN it is linked), not a match that would pass on any input. The atomics build is
/// exactly what `portable` deliberately excludes.
pub fn atomics_build_names_the_tier_o_module_test() {
  let assert Ok(bytes) = combos.read_wasm("mem")
  let assert Ok(m) = pipeline.source_to_ir(bytes)
  let assert Ok(core) =
    pipeline.ir_to_core(m, combos.binding_for(combos.cell_atomics))
  assert combos.count_occurrences(core, "rt_mem_atomics") > 0
  assert combos.count_occurrences(core, "twocore@runtime@rt_mem_atomics") > 0
}

// ─────────────────────────── PROOF 1 (b): executed — byte-identical to the cell/paged oracle ───────────────────────────

/// PROOF 1b (G3 — the "it ran" dynamic half, THE HEADLINE). The WHOLE acceptance corpus, compiled
/// under the REAL `profiles.portable()` profile and run through `load → instantiate → invoke` on a
/// bare BEAM (no `atomics`/`ets`/NIF loaded at all), is (1) spec-correct against each program's
/// `.expected` and (2) BYTE-IDENTICAL (raw bit pattern, D5/D7) to the `cell`/`paged` oracle
/// (`profiles.safe()`). This is the executed headline: the runs-anywhere build produces the same
/// answers, values and traps alike, as the tier-O reference — the trust-tier axis is proven
/// correctness-neutral for the shipped `portable` posture. `sum_to(100000)` (a constant-space loop
/// under `Threaded`, G4) and the memory/global/table programs are all in this corpus, so this
/// re-confirms unit 09's constant-space property holds in the real `portable` composition.
pub fn portable_runs_corpus_byte_identical_to_oracle_test() {
  let portable_d = driver.pipeline_with(profiles.portable())
  let oracle_d = driver.pipeline_with(profiles.safe())

  let failures =
    list.flat_map(combos.corpus_programs, fn(name) {
      let #(p_outs, p_fails) = combos.evaluate(portable_d, name)
      let #(o_outs, _) = combos.evaluate(oracle_d, name)
      list.flatten([
        // (1) portable is spec-correct against `.expected`.
        list.map(p_fails, fn(f) { "portable spec-incorrect: " <> f }),
        // (2) portable is byte-identical to the cell/paged oracle.
        case p_outs == o_outs {
          True -> []
          False -> [
            name
            <> " [portable ≢ cell/paged oracle]: "
            <> string.inspect(o_outs)
            <> " vs "
            <> string.inspect(p_outs),
          ]
        },
      ])
    })
  assert failures == []
}

// ─────────────────────────── PROOF 4 (checkpoint): the two headline profiles compose fail-closed ───────────────────────────

/// PROOF 4 checkpoint (G3/G6). The capstone-level statement of the composed axis space's
/// fail-closed status for the two HEADLINE profiles (the exhaustive per-field linker tests live in
/// unit 07's `profiles_test`; this is the end-to-end proof-of-goal checkpoint, not a re-derivation):
///   - `portable()` (Safe, tier-P on every axis) validates `Ok` — the runs-anywhere build links;
///   - an uncapped `ceiling()` (Unsafe + `Atomics`) is REJECTED `AtomicsCapRequired` (P6 — atomics
///     needs a bounded reservation cap; no silent 4 GiB pre-allocation, no silent `paged` fallback);
///   - a hand-built `Safe + Nif` is REJECTED `SafeForbidsNif` (G6 — tier-N runs custom C that can
///     crash the node, so it is Unsafe-only; there is no unsafe-by-omission path).
pub fn headline_profiles_compose_fail_closed_test() {
  // The runs-anywhere build is admissible.
  assert result.is_ok(profiles.validate_binding(profiles.portable()))
  // The uncapped perf ceiling fails closed until a bounded cap is supplied (P6/§C).
  assert profiles.validate_binding(profiles.ceiling())
    == Error(profiles.AtomicsCapRequired)
  // Safe forbids the tier-N native memory, fail-closed (G6).
  assert profiles.validate_binding(Binding(..profiles.safe(), mem_tier: Nif))
    == Error(profiles.SafeForbidsNif)
}

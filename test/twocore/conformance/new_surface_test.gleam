//// Unit P5-12 — PROOF 1 (the complete-surface backstop) + PROOF 3 (conformance-neutral),
//// the deliberately-authored half of the Phase-5 capstone.
////
//// The whole-suite matrix run (`conformance_test.gleam`) is the broad net; the per-op runtime
//// oracle differentials (units 07/08) and the tier-sweep (`refexpansion_differential_test.gleam`,
//// P5-11) are the fine-grained microscopes. This file adds the ONE thing only the terminal unit
//// makes: a small set of modules authored to exercise the new nodes DELIBERATELY, driven through
//// the REAL shipped deployment profiles (`profiles.safe()` / `profiles.unsafe()` /
//// `profiles.portable()`) so a single mis-lowered op fails on a NAMED program under a NAMED mode
//// rather than hiding in a large `.wast` file. It confirms, does not re-derive (D1): the tier-axis
//// sweep is P5-11's `refexpansion_differential_test` (every shipped `state_strategy × mem_tier`);
//// THIS file adds the orthogonal MODE axis (Safe vs Unsafe — the Baseline vs Aggressive optimizer
//// + the open-vs-fail-closed runtime) plus the real `portable` posture.
////
//// ## Proof 1 — the complete new surface, green end-to-end (H1–H4/H6/H7)
////
//// `reftab` (reference & table: `ref.func`/`ref.null`/`ref.is_null`, `table.get/set/size/grow/fill`,
//// a null-slot `call_indirect` → trap `uninitialized element`, an OOB `table.get` → trap `out of
//// bounds table access`), `bulkmem` (bulk memory: `memory.fill/copy/init` + `data.drop`, memmove
//// overlap, eager-bounds trap with NO partial write, a dropped passive segment behaving as
//// length-0), and `multimem` (two independent memories + a `memory.copy` ACROSS memory indices) each
//// run through `load → instantiate → invoke` and are (a) spec-correct against their spec-sourced
//// `.expected` under EVERY profile and (b) BYTE-IDENTICAL across `safe`/`unsafe`/`portable` (raw bit
//// pattern D5/D7 — WebAssembly is deterministic; the mode/optimizer/tier changes NO spec-observable
//// answer, H7). A wrong overlap direction, a mis-routed memory index, a partial write on an
//// eager-bounds trap, a dropped record across a table op, or an optimizer pass that reordered an
//// effectful ref/bulk node would diverge HERE on the exact program under the exact profile.
////
//// ## Proof 3 — conformance-neutral by default (H7)
////
//// A module with one 32-bit memory, funcref-only active elements, function-only imports, and no
//// bulk/ref ops compiles BYTE-IDENTICALLY to Phase-4 — the IR grew, but the defaults route the new
//// surface away. The emitter-level byte-identity (`MemLoad(0,…)` → the un-indexed Phase-4
//// `rt_mem:load` head) is unit 06's (`emit_core_test.mem_load_index_routing_test`, confirmed green
//// in `gleam test`); the WHOLE-suite behavioural neutrality is the enlarged-allowlist run staying
//// `fail == 0` with `pass` STRICTLY RISING (never a formerly-passing assert flipping to skip/fail —
//// the headline is a pass-RISE, `conformance_test.spec_suite_safe_test`/`skipcount_test`). This
//// file adds the corpus-level neutrality across the MODE axis: the entire Phase-1..4 acceptance
//// corpus produces the SAME `Outcome` under Safe and Unsafe Phase-5 code as it did under Phase-4.
//// (The `portable`-vs-`cell/paged` corpus neutrality is Phase-4's
//// `runs_anywhere_test.portable_runs_corpus_byte_identical_to_oracle_test`, still green.)
////
//// Spec anchors: §2.3.3 (reference types), §4.4.6 (table/ref instructions), §4.4.7 (bulk memory/
//// table + memidx immediate), §4.4.8 (null-slot `call_indirect` trap), §7 (embedding). The
//// `.expected` values are the spec-sourced Tier-A oracle, so "green" means every spec-observable was
//// preserved, never "it compiled".

import gleam/list
import gleam/string
import twocore/conformance/driver
import twocore/runtime/instance.{type Binding}
import twocore/runtime/profiles
import twocore/tier/combos

/// The deliberately-authored new-surface programs (authored `.wat` → `.wasm`, `.expected`
/// spec-sourced). Each uses i32-observable results (null-ness / call results / loaded bytes) so the
/// numeric `.expected` format applies while exercising the full reference / bulk / multi-memory op
/// surface (H1–H3). These are the capstone-owned corpus modules (§H — kept local to the conformance
/// corpus, not reached into `combos.corpus_programs`, which is a Phase-4 const).
const new_surface_programs: List(String) = ["reftab", "bulkmem", "multimem"]

/// The REAL shipped deployment profiles the capstone drives every program through — the exact
/// postures a user gets (not a test-capped variant). `safe` = Cell/Paged, Baseline optimizer,
/// enforcing fuel; `unsafe` = Cell/Atomics-capable base with the Aggressive optimizer + open
/// runtime (here Paged so the mode axis is isolated from the tier axis — the tier sweep is P5-11's);
/// `portable` = the tier-P runs-anywhere build (Threaded/Paged/bif, Safe). Byte-identity across all
/// three is the H7 neutrality claim over the new surface.
fn shipped_profiles() -> List(#(String, Binding)) {
  [
    #("safe", profiles.safe()),
    #("unsafe", profiles.unsafe()),
    #("portable", profiles.portable()),
  ]
}

/// PROOF 1 (complete surface, end-to-end). Every new-surface program is spec-correct against its
/// spec-sourced `.expected` under EVERY shipped profile AND byte-identical across `safe`/`unsafe`/
/// `portable`. A per-profile spec violation (a wrong result / missing / wrong trap) OR a cross-
/// profile divergence (the mode / optimizer / state-strategy changed an observable) fails naming the
/// exact program + profile. This is the fine-grained backstop behind the whole-suite matrix run
/// (`conformance_test.gleam`), over programs authored to exercise the new nodes on purpose.
pub fn new_surface_spec_correct_and_profile_neutral_test() {
  let failures = list.flat_map(new_surface_programs, check_across_profiles)
  assert failures == []
}

/// PROOF 3 (conformance-neutral, MODE axis). The entire Phase-1..4 acceptance corpus
/// (`combos.corpus_programs` — the pure-numeric, memory, table, global, and trap programs) produces
/// the SAME `Outcome` under Safe and Unsafe Phase-5 code, and each matches its spec-sourced
/// `.expected`. A Phase-5 change that perturbed a Phase-4 result (an accidental mem-index-0
/// regression, a reftype tag leaking into a funcref table, an effect-analysis miss letting the
/// Aggressive optimizer reorder a legacy state op) would diverge HERE. Together with unit 06's
/// emitter byte-identity and the whole-suite pass-rise, this is the behavioural half of H7.
pub fn phase_1_to_4_corpus_conformance_neutral_test() {
  let failures =
    list.flat_map(combos.corpus_programs, fn(name) {
      check_two_profiles(
        name,
        profiles.safe(),
        "safe",
        profiles.unsafe(),
        "unsafe",
      )
    })
  assert failures == []
}

/// Drive `name` under every shipped profile, collecting (1) per-profile spec-correctness failures
/// and (2) cross-profile byte-identity failures (baseline = the first profile). Empty ⇒ green.
fn check_across_profiles(name: String) -> List(String) {
  let runs =
    list.map(shipped_profiles(), fn(p) {
      let #(label, binding) = p
      let #(outcomes, fails) =
        combos.evaluate(driver.pipeline_with(binding), name)
      #(label, outcomes, fails)
    })
  let spec_failures = list.flat_map(runs, fn(r) { r.2 })
  let identity_runs = list.map(runs, fn(r) { #(r.0, r.1) })
  list.append(spec_failures, combos.identity_across(name, identity_runs))
}

/// Drive `name` under two named profiles, asserting spec-correctness under each and byte-identity
/// between them — the corpus-neutrality workhorse for `phase_1_to_4_corpus_conformance_neutral_test`.
fn check_two_profiles(
  name: String,
  a: Binding,
  a_label: String,
  b: Binding,
  b_label: String,
) -> List(String) {
  let #(a_outs, a_fails) = combos.evaluate(driver.pipeline_with(a), name)
  let #(b_outs, b_fails) = combos.evaluate(driver.pipeline_with(b), name)
  list.flatten([
    a_fails,
    b_fails,
    case a_outs == b_outs {
      True -> []
      False -> [
        name
        <> " ["
        <> b_label
        <> " ≢ "
        <> a_label
        <> " oracle]: "
        <> string.inspect(a_outs)
        <> " vs "
        <> string.inspect(b_outs),
      ]
    },
  ])
}

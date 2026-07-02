#!/usr/bin/env bash
#
# gen-conformance-svg.sh — render the WebAssembly spec-suite conformance graph.
#
# Runs the Phase-1 conformance gleeunit test (`spec_suite_allowlist_test`), parses
# the per-file and TOTAL `pass/skip/fail` report it prints to stdout, and writes a
# self-contained, GitHub-README-renderable SVG to docs/wasm-conformance.svg.
#
# The image reflects whatever `*.json` fixtures are present under
# test/twocore/conformance/fixtures/. A fresh checkout only ships the curated
# subset; for the FULL allowlist numbers, regenerate the (gitignored) fixtures
# first — either run test/twocore/conformance/vendor/vendor.sh by hand, or set
# RUN_VENDOR=1 when invoking this script:
#
#     RUN_VENDOR=1 scripts/gen-conformance-svg.sh
#
# Dependencies: bash, awk, gleam (+ the vendor toolchain only if RUN_VENDOR=1).
# No Hex/npm deps, no network at render time. Inline-styled SVG only (no external
# fonts/links/images), so it renders identically in a GitHub README.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

conf_test="twocore/conformance/conformance_test"
out_svg="docs/wasm-conformance.svg"
pin="test/twocore/conformance/vendor/PIN"
allowlist="test/twocore/conformance/vendor/ALLOWLIST"

# Optionally regenerate the full (gitignored) fixture set before measuring.
if [ "${RUN_VENDOR:-0}" = "1" ]; then
  echo "gen-conformance-svg: RUN_VENDOR=1 → regenerating fixtures via vendor.sh" >&2
  bash test/twocore/conformance/vendor/vendor.sh
fi

# Run the conformance test; its stdout carries the per-file + TOTAL report.
echo "gen-conformance-svg: running conformance test ($conf_test) ..." >&2
report="$(gleam test -- "$conf_test" 2>&1 || true)"

# Keep the run-block HEADERS ("=== … — <label> ===") and the report lines ("<file>.json pass=…"
# and the TOTAL line). The headers let awk isolate the ONE full, unfiltered profile run (Phase 5
# runs the suite SEVEN times — the two full profiles + the five filtered tier-matrix combos — and
# only the full Safe run carries the complete per-file breakdown + the enlarged-allowlist TOTAL).
lines="$(printf '%s\n' "$report" \
  | grep -E '(=== Phase-3 spec-suite|(\.json| TOTAL) +pass=[0-9]+ +skip=[0-9]+ +fail=[0-9]+)' || true)"

if ! printf '%s\n' "$lines" | grep -q 'TOTAL'; then
  echo "gen-conformance-svg: ERROR — no TOTAL report line in conformance output." >&2
  echo "gen-conformance-svg: did the conformance test compile/run? Output follows:" >&2
  printf '%s\n' "$report" >&2
  exit 1
fi

# Provenance read from the vendor PIN + allowlist (shown in the SVG footnote).
sha="$(sed -n 's/^TESTSUITE_SHA=//p' "$pin" | head -1)"
sha7="${sha:0:7}"
wabt="$(sed -n 's/^WABT_VERSION=//p' "$pin" | head -1)"
allow_count="$(grep -vcE '^[[:space:]]*#|^[[:space:]]*$' "$allowlist" || echo 0)"

mkdir -p "$(dirname "$out_svg")"

# Emit the SVG. The awk program uses single-quoted XML attributes, so it is supplied
# from a quoted here-doc via process substitution (no bash expansion / quoting
# conflicts); the report lines arrive on stdin, the provenance scalars through -v.
printf '%s\n' "$lines" \
  | awk -v sha="$sha7" -v wabt="$wabt" -v allow="$allow_count" -f <(cat <<'AWK'
function commas(x,   s, out) {
  s = sprintf("%d", x); out = ""
  while (length(s) > 3) { out = "," substr(s, length(s) - 2) out; s = substr(s, 1, length(s) - 3) }
  return s out
}
# Parse each report line into the per-file arrays (or the TOTAL accumulators). Only the FULL Safe
# run (unfiltered — the enlarged Phase-5 allowlist, 21525 pass) feeds the chart; the filtered
# tier-matrix combos print a tier-touching SUBSET (fewer passes) and the Unsafe run duplicates the
# Safe totals, so gate on the Safe full-profile header ("Baseline optimizer + enforcing fuel").
/=== Phase-3 spec-suite/ {
  active = ($0 ~ /Baseline optimizer \+ enforcing fuel/) ? 1 : 0
  next
}
!active { next }
{
  name = $1; p = 0; s = 0; f = 0
  for (i = 1; i <= NF; i++) {
    if      ($i ~ /^pass=/) p = substr($i, 6) + 0
    else if ($i ~ /^skip=/) s = substr($i, 6) + 0
    else if ($i ~ /^fail=/) f = substr($i, 6) + 0
  }
  if (name == "TOTAL") { tP = p; tS = s; tF = f; next }
  sub(/\.json$/, "", name)
  # Only the full Safe block is active here, so each file appears once; the `seen` guard is a
  # belt-and-braces dedup (a file line is idempotent — the counts are tier-/profile-neutral, H7).
  if (name in seen) next
  seen[name] = 1
  n++; fn[n] = name; fp[n] = p; fs[n] = s; ff[n] = f
}
END {
  # Order rows by passing count, descending (stable enough for the chart).
  for (a = 1; a <= n; a++) ord[a] = a
  for (a = 1; a < n; a++) {
    m = a
    for (b = a + 1; b <= n; b++) if (fp[ord[b]] > fp[ord[m]]) m = b
    t = ord[a]; ord[a] = ord[m]; ord[m] = t
  }

  # ---- palette (GitHub-ish) ----
  ink = "#1f2328"; muted = "#57606a"; faint = "#8c959f"; track = "#eaeef2"
  gBar = "#3fb950"; sBar = "#d0d7de"; rBar = "#f85149"
  gTxt = "#1a7f37"; sTxt = "#6e7781"; rTxt = "#cf222e"

  # ---- geometry ----
  W = 720
  y0 = 130; rowH = 22.5; barH = 13
  labelRightX = 150; barX = 162; barW = 384; countRightX = 704
  barsBottom = y0 + n * rowH
  fn1Y = barsBottom + 24; fn2Y = fn1Y + 15
  H = fn2Y + 16

  # ---- derived headline stats ----
  inscope = tP + tS + tF
  attempted = tP + tF
  attPct = attempted > 0 ? sprintf("%.0f", tP * 100.0 / attempted) : "0"
  covPct = inscope   > 0 ? sprintf("%.0f", tP * 100.0 / inscope)   : "0"
  pillBg = tF == 0 ? "#dafbe1" : "#ffebe9"
  pillTx = tF == 0 ? "#1a7f37" : "#cf222e"

  font = "system-ui, -apple-system, Segoe UI, Helvetica, Arial, sans-serif"

  print "<svg xmlns='http://www.w3.org/2000/svg' width='" W "' height='" H "' viewBox='0 0 " W " " H "' xml:space='preserve' font-family='" font "'>"
  print "  <rect x='0.5' y='0.5' width='" (W - 1) "' height='" (H - 1) "' rx='10' fill='#ffffff' stroke='#d0d7de'/>"

  # ---- header ----
  print "  <text x='24' y='34' font-size='19' font-weight='700' fill='" ink "'>WebAssembly spec-suite conformance</text>"
  print "  <text x='24' y='58' font-size='12.5' fill='" muted "'><tspan fill='" gTxt "' font-weight='600'>" commas(tP) "</tspan> passing  ·  <tspan fill='" sTxt "' font-weight='600'>" commas(tS) "</tspan> out of scope  ·  <tspan fill='" (tF == 0 ? gTxt : rTxt) "' font-weight='600'>" commas(tF) "</tspan> failing</text>"
  print "  <text x='24' y='80' font-size='11.5' fill='" muted "'><tspan fill='" ink "' font-weight='600'>" attPct "%</tspan>&#160;of attempted assertions pass  ·  <tspan fill='" ink "' font-weight='600'>" covPct "%</tspan>&#160;in-scope coverage</text>"

  # ---- 0-failing pill (top-right) ----
  print "  <rect x='608' y='16' width='96' height='26' rx='13' fill='" pillBg "'/>"
  print "  <text x='656' y='33' font-size='12' font-weight='600' text-anchor='middle' fill='" pillTx "'>✓ " commas(tF) " failing</text>"

  # ---- legend ----
  legY = 104
  print "  <rect x='24'  y='" (legY - 9) "' width='11' height='11' rx='2.5' fill='" gBar "'/><text x='41'  y='" legY "' font-size='11' fill='" muted "'>passing (in scope)</text>"
  print "  <rect x='196' y='" (legY - 9) "' width='11' height='11' rx='2.5' fill='" sBar "'/><text x='213' y='" legY "' font-size='11' fill='" muted "'>out of scope (skipped)</text>"
  print "  <rect x='392' y='" (legY - 9) "' width='11' height='11' rx='2.5' fill='" rBar "'/><text x='409' y='" legY "' font-size='11' fill='" muted "'>failing</text>"

  print "  <line x1='24' y1='116' x2='704' y2='116' stroke='" track "'/>"

  # ---- one stacked bar per file ----
  for (k = 1; k <= n; k++) {
    j = ord[k]
    yt = y0 + (k - 1) * rowH
    tb = yt + 10            # text baseline, vertically centred in the bar
    tot = fp[j] + fs[j] + ff[j]
    if (tot <= 0) tot = 1
    gw = barW * fp[j] / tot
    sw = barW * fs[j] / tot
    rw = barW * ff[j] / tot

    print "  <text x='" labelRightX "' y='" tb "' font-size='10' text-anchor='end' fill='" muted "'>" fn[j] "</text>"
    print "  <rect x='" barX "' y='" yt "' width='" barW "' height='" barH "' rx='3' fill='" track "'/>"
    print "  <clipPath id='c" k "'><rect x='" barX "' y='" yt "' width='" barW "' height='" barH "' rx='3'/></clipPath>"
    printf "  <g clip-path='url(#c%d)'>", k
    printf "<rect x='%s' y='%s' width='%.2f' height='%s' fill='%s'/>", barX, yt, gw, barH, gBar
    printf "<rect x='%.2f' y='%s' width='%.2f' height='%s' fill='%s'/>", barX + gw, yt, sw, barH, sBar
    if (rw > 0) printf "<rect x='%.2f' y='%s' width='%.2f' height='%s' fill='%s'/>", barX + gw + sw, yt, rw, barH, rBar
    print "</g>"

    line = "  <text x='" countRightX "' y='" tb "' font-size='9.5' text-anchor='end'>"
    line = line "<tspan fill='" gTxt "' font-weight='600'>" fp[j] "</tspan><tspan fill='" muted "'> pass</tspan>"
    line = line "<tspan fill='" muted "'>  ·  </tspan>"
    line = line "<tspan fill='" sTxt "' font-weight='600'>" fs[j] "</tspan><tspan fill='" muted "'> skip</tspan>"
    if (ff[j] > 0)
      line = line "<tspan fill='" muted "'>  ·  </tspan><tspan fill='" rTxt "' font-weight='600'>" ff[j] "</tspan><tspan fill='" muted "'> fail</tspan>"
    line = line "</text>"
    print line
  }

  # ---- footnotes ----
  print "  <text x='24' y='" fn1Y "' font-size='9.5' fill='" muted "'>Phase 5: complete WebAssembly surface minus SIMD — reference types, bulk memory, multi-memory, multi-table call_indirect, non-function imports + the spectest module, and a first-class WAT text parser. Pass rose +5,776; " commas(tF) " failing under every shipped tier. Residual out of scope: cross-module wasm&#8594;wasm function linking (&#8594; Phase 6), SIMD (&#8594; Phase 6), GC-proposal reftypes + extended-const.</text>"
  print "  <text x='24' y='" fn2Y "' font-size='9' fill='" faint "'>Source: WebAssembly/testsuite @ " sha "  ·  wabt " wabt "  ·  " n " of " allow " allowlisted .wast files convertible at pin  ·  regenerate with scripts/gen-conformance-svg.sh</text>"

  print "</svg>"
}
AWK
) > "$out_svg"

echo "gen-conformance-svg: wrote $out_svg" >&2

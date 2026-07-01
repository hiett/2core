//// Unit 11c — the 2core **CLI**, exposing EVERY pipeline stage independently (high-level
//// decision #5) plus the end-to-end `run`. `gleam run -- <subcommand> …` dispatches here.
////
//// The stage wiring and per-stage error mapping (D4) live in `twocore/pipeline`; this
//// module only does argument parsing, file IO, and printing. Every subcommand is total:
//// bad input prints its typed error to **stderr** and the process halts **non-zero**
//// (`halt(1)`) — it never panics.
////
//// ## Subcommands
////
//// | Subcommand                         | Pipeline                                              |
//// |------------------------------------|-------------------------------------------------------|
//// | `decode   <in.wasm>`               | decode → print the WASM AST                            |
//// | `validate <in.wasm>`               | decode → validate → print `valid`                     |
//// | `lower    <in.wasm>` (= `to-ir`,`ir`) | decode → validate → lower(10) → print `.ir`        |
//// | `ir-lower <in.ir>`                 | parse `.ir` → ir_lower(Safe) → print `.ir`            |
//// | `emit     <in.ir>`                 | parse `.ir` → emit_core(Safe) → print `.core`         |
//// | `to-core  <in.ir>`                 | parse `.ir` → ir_lower(Safe) → emit_core → print `.core` |
//// | `to-beam  <in.core> [out.beam]` (= `build`) | parse+build `.core` → write `.beam`         |
//// | `run      <in.wasm> <export> <args…>` | source → … → ir_lower(Safe) → load → invoke → print |
////
//// ## Value convention (the run/invoke ABI — `pipeline.gleam`)
////
//// `run`'s arguments and results are **raw UNSIGNED bit patterns in decimal**: an i32 in
//// `[0, 2^32)`, an i64 in `[0, 2^64)`, a float as its raw IEEE-754 bits (D5). So
//// `gleam run -- run add.wasm add 2 3` prints `5`, and an i32 `-1` argument is written
//// `4294967295`. A trap (e.g. divide-by-zero) prints `trap: <reason>` to stderr and halts
//// non-zero — a trap is a runtime outcome, surfaced as a CLI failure.

import argv
import gleam/bit_array
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import simplifile
import twocore/backend/build_beam
import twocore/backend/core_printer
import twocore/backend/emit_core
import twocore/frontend/wasm/decode
import twocore/frontend/wasm/validate
import twocore/ir/printer as ir_printer
import twocore/pipeline
import twocore/runtime/profiles

/// CLI entry point. Reads the subcommand + operands from `argv`, runs the matching stage,
/// and prints the result to stdout (exit 0) or the typed error to stderr (exit non-zero).
/// Never panics on bad input.
pub fn main() -> Nil {
  case run(argv.load().arguments) {
    Ok(out) -> io.println(out)
    Error(msg) -> {
      io.println_error(msg)
      halt(1)
    }
  }
}

/// `erlang:halt/1` — stop the VM with exit status `code`. Used to make a failing subcommand
/// exit non-zero. Never returns (typed generically so the caller's `case` arms unify).
@external(erlang, "erlang", "halt")
fn halt(code: Int) -> a

/// Dispatch a parsed argument vector to its subcommand, returning the text to print on
/// success or the diagnostic to print to stderr on failure. Pure of IO except the file
/// reads/writes each subcommand performs; total — an unrecognised command yields the usage
/// text as `Error`. Exposed so CLI behaviour is unit-testable without spawning a process.
pub fn run(args: List(String)) -> Result(String, String) {
  case args {
    ["decode", path] -> cmd_decode(path)
    ["validate", path] -> cmd_validate(path)
    ["lower", path] | ["to-ir", path] | ["ir", path] -> cmd_to_ir(path)
    ["ir-lower", path] -> cmd_ir_lower(path)
    ["emit", path] -> cmd_emit(path)
    ["to-core", path] -> cmd_to_core(path)
    ["to-beam", input] | ["build", input] ->
      cmd_to_beam(input, default_beam(input))
    ["to-beam", input, output] | ["build", input, output] ->
      cmd_to_beam(input, output)
    ["run", path, export, ..arg_strs] -> cmd_run(path, export, arg_strs)
    ["exec", "-n", n, path, export, ..arg_strs]
    | ["exec", "--repeat", n, path, export, ..arg_strs] ->
      cmd_exec(path, export, arg_strs, n)
    ["exec", path, export, ..arg_strs] -> cmd_exec(path, export, arg_strs, "1")
    _ -> Error(usage())
  }
}

// ─────────────────────────────── subcommands ───────────────────────────────

/// `decode <in.wasm>` — decode the binary and dump the WASM AST (unit 05). Inspect text.
fn cmd_decode(path: String) -> Result(String, String) {
  use bytes <- result.try(read_bits(path))
  case decode.decode(bytes) {
    Ok(m) -> Ok(string.inspect(m))
    Error(e) -> Error("decode: " <> string.inspect(e))
  }
}

/// `validate <in.wasm>` — decode then `full`-validate (unit 10a). Prints `valid` or the
/// rejecting stage's typed error.
fn cmd_validate(path: String) -> Result(String, String) {
  use bytes <- result.try(read_bits(path))
  case decode.decode(bytes) {
    Error(e) -> Error("decode: " <> string.inspect(e))
    Ok(m) ->
      case validate.validate(m) {
        Error(e) -> Error("validate: " <> string.inspect(e))
        Ok(_typed) -> Ok("valid")
      }
  }
}

/// `lower`/`to-ir`/`ir <in.wasm>` — decode → validate → frontend-lower → print `.ir`
/// (unit 02's printer). The source→IR end-to-end view.
fn cmd_to_ir(path: String) -> Result(String, String) {
  use bytes <- result.try(read_bits(path))
  case pipeline.source_to_ir(bytes) {
    Error(e) -> Error(pipeline.describe(e))
    Ok(m) -> Ok(ir_printer.print_module(m))
  }
}

/// `ir-lower <in.ir>` — parse `.ir` (unit 02) → run the Safe policy pass (unit 11a) →
/// print the rewritten `.ir` (CallHosts gated, metering inserted).
fn cmd_ir_lower(path: String) -> Result(String, String) {
  use text <- result.try(read_text(path))
  case pipeline.parse_ir(text) {
    Error(e) -> Error("parse .ir: " <> string.inspect(e))
    Ok(m) ->
      case pipeline.lower_ir(m, profiles.safe()) {
        Error(e) -> Error(pipeline.describe(e))
        Ok(lowered) -> Ok(ir_printer.print_module(lowered))
      }
  }
}

/// `emit <in.ir>` — parse `.ir` → `emit_core` ALONE (no policy pass) → print `.core`. The
/// finer backend-only stage, for inspecting raw codegen.
fn cmd_emit(path: String) -> Result(String, String) {
  use text <- result.try(read_text(path))
  case pipeline.parse_ir(text) {
    Error(e) -> Error("parse .ir: " <> string.inspect(e))
    Ok(m) ->
      case emit_core.emit_module(m, profiles.safe()) {
        Error(e) -> Error("emit: " <> string.inspect(e))
        Ok(cmod) -> Ok(core_printer.print_module(cmod))
      }
  }
}

/// `to-core <in.ir>` — parse `.ir` → ir_lower(Safe) → emit_core → print `.core` (the policy
/// pass IS in this chain, unlike `emit`).
fn cmd_to_core(path: String) -> Result(String, String) {
  use text <- result.try(read_text(path))
  case pipeline.parse_ir(text) {
    Error(e) -> Error("parse .ir: " <> string.inspect(e))
    Ok(m) ->
      case pipeline.ir_to_core(m, profiles.safe()) {
        Error(e) -> Error(pipeline.describe(e))
        Ok(core) -> Ok(core)
      }
  }
}

/// `to-beam`/`build <in.core> [out.beam]` — compile `.core` to a `.beam` binary (unit 04)
/// and write it to `output`. Prints a confirmation line.
fn cmd_to_beam(input: String, output: String) -> Result(String, String) {
  use text <- result.try(read_text(input))
  case build_beam.compile_core(bit_array.from_string(text)) {
    Error(e) -> Error("build: " <> string.inspect(e))
    Ok(#(_mod_atom, beam)) ->
      case simplifile.write_bits(output, beam) {
        Error(fe) ->
          Error("write " <> output <> ": " <> simplifile.describe_error(fe))
        Ok(Nil) -> Ok("wrote " <> output)
      }
  }
}

/// `run <in.wasm> <export> <args…>` — compile through the Safe pipeline and invoke `export`
/// on the BEAM (D10). Prints the result value(s) (raw bit patterns, space-separated); a
/// trap prints `trap: <reason>` as an error (exit non-zero).
fn cmd_run(
  path: String,
  export: String,
  arg_strs: List(String),
) -> Result(String, String) {
  use bytes <- result.try(read_bits(path))
  use args <- result.try(parse_args(arg_strs))
  case pipeline.run_source(bytes, profiles.safe(), export, args) {
    Error(e) -> Error(pipeline.describe(e))
    Ok(pipeline.Returned(values)) -> Ok(format_values(values))
    Ok(pipeline.Trapped(reason)) -> Error("trap: " <> reason)
  }
}

/// `exec [-n COUNT] <in.beam> <export> <args…>` — load a PREBUILT `.beam` (no compile step)
/// and invoke `export` on the BEAM `COUNT` times (default 1), timing only the invocations. For
/// benchmarking the emitted code in isolation. Prints the (last) result value(s) then a timing
/// line; a trap prints `trap: <reason>` (exit non-zero).
fn cmd_exec(
  path: String,
  export: String,
  arg_strs: List(String),
  count_str: String,
) -> Result(String, String) {
  use beam <- result.try(read_bits(path))
  use args <- result.try(parse_args(arg_strs))
  use repeat <- result.try(parse_count(count_str))
  case pipeline.exec_beam(beam, export, args, repeat) {
    Error(e) -> Error(e)
    Ok(#(_micros, pipeline.Trapped(reason))) -> Error("trap: " <> reason)
    Ok(#(micros, pipeline.Returned(values))) ->
      Ok(format_values(values) <> "\n" <> timing_line(repeat, micros))
  }
}

// ─────────────────────────────── helpers ───────────────────────────────

/// Render the `exec` benchmark timing: total microseconds and nanoseconds-per-call.
fn timing_line(repeat: Int, micros: Int) -> String {
  let ns_per = micros * 1000 / repeat
  int.to_string(repeat)
  <> " call(s) · "
  <> int.to_string(micros)
  <> " us total · "
  <> int.to_string(ns_per)
  <> " ns/call"
}

/// Parse the `exec -n` repeat count — a positive integer.
fn parse_count(s: String) -> Result(Int, String) {
  case int.parse(s) {
    Ok(n) if n >= 1 -> Ok(n)
    _ -> Error("-n expects a positive integer, got: " <> s)
  }
}

/// Parse each `run` argument string as a decimal integer (a raw unsigned bit pattern).
/// Returns `Error` naming the first non-integer token.
fn parse_args(arg_strs: List(String)) -> Result(List(Int), String) {
  list.try_map(arg_strs, fn(s) {
    int.parse(s) |> result.replace_error("not an integer argument: " <> s)
  })
}

/// Render a result value list as space-separated decimals (`[5] → "5"`, `[] → ""`).
fn format_values(values: List(Int)) -> String {
  values |> list.map(int.to_string) |> string.join(" ")
}

/// Default `.beam` output path for `to-beam`: swap a trailing `.core` for `.beam`, else
/// append `.beam`.
fn default_beam(input: String) -> String {
  case string.ends_with(input, ".core") {
    True -> string.drop_end(input, 5) <> ".beam"
    False -> input <> ".beam"
  }
}

/// Read a file's raw bytes, mapping any IO error to a diagnostic string.
fn read_bits(path: String) -> Result(BitArray, String) {
  simplifile.read_bits(path)
  |> result.map_error(fn(e) {
    "read " <> path <> ": " <> simplifile.describe_error(e)
  })
}

/// Read a file's UTF-8 text, mapping any IO error to a diagnostic string.
fn read_text(path: String) -> Result(String, String) {
  simplifile.read(path)
  |> result.map_error(fn(e) {
    "read " <> path <> ": " <> simplifile.describe_error(e)
  })
}

/// The usage text printed (to stderr) for an unrecognised invocation.
fn usage() -> String {
  string.join(
    [
      "2core — WASM → Core Erlang compiler (Phase 2). Usage:",
      "  gleam run -- decode   <in.wasm>                 dump the WASM AST",
      "  gleam run -- validate <in.wasm>                 full-validate; print 'valid'",
      "  gleam run -- lower    <in.wasm>                 source → .ir (alias: to-ir, ir)",
      "  gleam run -- ir-lower <in.ir>                   Safe policy pass → .ir",
      "  gleam run -- emit     <in.ir>                   emit_core only → .core",
      "  gleam run -- to-core  <in.ir>                   ir_lower(Safe) + emit_core → .core",
      "  gleam run -- to-beam  <in.core> [out.beam]      compile → .beam (alias: build)",
      "  gleam run -- run      <in.wasm> <export> <args…>  compile + invoke on the BEAM",
      "  gleam run -- exec     [-n N] <in.beam> <export> <args…>  invoke a prebuilt .beam (bench, no compile)",
      "",
      "Values are raw unsigned bit patterns in decimal (i32 -1 is 4294967295).",
    ],
    "\n",
  )
}

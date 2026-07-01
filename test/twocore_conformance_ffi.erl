%% Test-only FFI shim for the unit-07 conformance harness.
%%
%% Hand-written Erlang, so it carries the `twocore_` namespace prefix (overview §5).
%% It lives under `test/` and exists ONLY to give the Gleam conformance harness the
%% few host capabilities Gleam's stdlib does not provide: invoking a freshly-loaded
%% generated module while catching a trap, reading fixture files from disk, parsing
%% JSON (via OTP's built-in `json`), listing a directory, and shelling out to the
%% Tier-B reference engine. It touches no unit-owned source file.
-module(twocore_conformance_ffi).
-export([catch_apply/3, read_file/1, parse_json/1, list_dir/1, run/2,
         find_executable/1, unique_int/0,
         start_instance/1, call_instance/3, stop_instance/1, gc_and_memory/1,
         spy_reset/0, spy_mark/0, spy_called/0]).

%% Force a garbage collection on process Pid, then report its total memory in bytes
%% (heap + stack + message queue + pdict). Used by the constant-space store-loop test to
%% assert the `cell` state strategy does not accumulate per-iteration memory — after GC,
%% a constant-space loop's live memory is bounded by the (constant) page-map, not the
%% iteration count. Returns 0 for a dead process.
gc_and_memory(Pid) ->
    erlang:garbage_collect(Pid),
    case erlang:process_info(Pid, memory) of
        {memory, M} -> M;
        undefined -> 0
    end.

%% ── one-instance-one-process run-ABI (unit 11, E1/E5) ───────────────────────
%%
%% The instance's mutable state (memory page-map, mutable globals, table) lives in
%% the process dictionary of ONE owned process (the `cell` strategy). So an
%% instance's `instantiate/0` AND every one of its invokes must run in that SAME
%% process, or an export reads the caller's empty pdict and returns garbage. These
%% three functions give the Gleam driver/pipeline that owned process:
%%
%%   start_instance(Module) -> {ok, Pid} | {error, Reason}
%%       spawn a process; run Module:instantiate() IN it (seeds ITS pdict cell).
%%       An instantiation-time trap (OOB active segment / trapping start) replies
%%       {error, RenderedReason} and the process exits. On success the process
%%       enters a receive loop holding the cell for the instance's lifetime.
%%   call_instance(Pid, Fun, Args) -> {ok, V} | {error, Reason}
%%       message round-trip: the instance process runs apply(Module, Fun, Args) in
%%       ITS OWN process (reads ITS cell) and replies. A trap is {error, Reason}.
%%   stop_instance(Pid) -> nil
%%       ask the process to exit; its pdict cell is auto-GC'd with it.
%%
%% (Re)instantiating a module starts a FRESH process → a FRESH zeroed cell, so
%% per-instance isolation + reset-on-(re)instantiation are automatic, and
%% cross-invoke state PERSISTS because successive invokes hit the same process.

%% Spawn the instance process and run instantiate/0 in it, blocking until the
%% process reports whether instantiation succeeded or trapped.
start_instance(Module) ->
    Parent = self(),
    Pid = spawn(fun() ->
        Outcome =
            try Module:instantiate() of
                _ -> ok
            catch
                _Class:Reason -> {error, render_reason(Reason)}
            end,
        case Outcome of
            ok ->
                Parent ! {started, self(), ok},
                instance_loop(Module);
            {error, _} = Err ->
                Parent ! {started, self(), Err}
        end
    end),
    receive
        {started, Pid, ok} -> {ok, Pid};
        {started, Pid, {error, Why}} -> {error, Why}
    end.

%% Run apply(Module, Fun, Args) inside the instance's own process and return its
%% outcome to the caller; a trap surfaces as {error, RenderedReason}.
call_instance(Pid, Fun, Args) ->
    Ref = make_ref(),
    Pid ! {invoke, Fun, Args, self(), Ref},
    receive
        {result, Ref, Result} -> Result
    end.

%% Ask the instance process to exit (its pdict cell is GC'd with it).
stop_instance(Pid) ->
    Pid ! stop,
    nil.

%% The instance process's receive loop: it owns the seeded cell and runs every
%% invoke in-process so each one reads ITS state.
instance_loop(Module) ->
    receive
        {invoke, Fun, Args, From, Ref} ->
            Result =
                try erlang:apply(Module, Fun, Args) of
                    V -> {ok, V}
                catch
                    _Class:Reason -> {error, render_reason(Reason)}
                end,
            From ! {result, Ref, Result},
            instance_loop(Module);
        stop ->
            ok
    end.

%% Render a caught trap/exit reason as a UTF-8 binary so the Gleam caller can
%% substring-match the spec trap phrase (e.g. `{wasm_trap, memory_out_of_bounds}`).
render_reason(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Reason])).

%% A one-bit per-process spy used by the routing self-test to PROVE the partition:
%% `assert_invalid`/`assert_malformed` must reach only `check_frontend`, never
%% `instantiate`. `spy_mark/0` is wired into a spy driver's `instantiate`; after a run
%% the test asserts `spy_called/0` is still `false`. Process-local (gleeunit runs each
%% test synchronously in one process), so no cross-test bleed.
spy_reset() -> erlang:put(twocore_spy_instantiate, false), nil.
spy_mark() -> erlang:put(twocore_spy_instantiate, true), nil.
spy_called() -> erlang:get(twocore_spy_instantiate) =:= true.

%% A process-independent strictly-positive unique integer. The harness appends it to
%% a generated module's name so that loading many modules from one `.wast` file (a
%% multi-module fixture, e.g. const/traps) does not collide on a single BEAM module
%% name and clobber earlier loads (`code:load_binary` replaces by name).
unique_int() ->
    erlang:unique_integer([positive, monotonic]).

%% Apply M:F(Args). On a normal return yield `{ok, V}` (a Gleam `Ok`); if the call
%% raises/exits/throws, yield `{error, Reason}` (a Gleam `Error`) with `Reason`
%% rendered as a UTF-8 binary so the caller can substring-match the trap text (e.g.
%% that a div-by-zero surfaced as `{wasm_trap, int_div_by_zero}`). `V` is whatever
%% the generated function returned — for the Phase-1 numeric surface that is an
%% Erlang integer (the raw value/bit pattern, per D5); the Gleam caller only reads it
%% as an integer when the spec expects a single numeric result.
catch_apply(M, F, Args) ->
    try erlang:apply(M, F, Args) of
        V -> {ok, V}
    catch
        _Class:Reason ->
            {error, unicode:characters_to_binary(io_lib:format("~0p", [Reason]))}
    end.

%% Read a file's raw bytes. `{ok, Binary}` (a Gleam `Ok(BitArray)`) or `{error, Msg}`
%% (a Gleam `Error(String)`) with the POSIX reason rendered as text. Used to load the
%% vendored `.wasm`/`.json` fixtures and the corpus `.wasm`/`.expected` files.
read_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> {ok, Bin};
        {error, Reason} ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Parse a JSON binary into an Erlang term (maps with binary keys, lists, binaries,
%% integers) using OTP's built-in `json:decode/1`. `{ok, Term}` (a Gleam
%% `Ok(Dynamic)`) or `{error, Msg}` on malformed JSON. wast2json output is well-formed
%% and keeps every numeric value as a STRING, so numbers never lose precision here.
parse_json(Bin) ->
    try json:decode(Bin) of
        Term -> {ok, Term}
    catch
        _Class:Reason ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% List a directory's entries (file names only, not full paths). `{ok, [Binary]}` or
%% `{error, Msg}`. Used to discover which `*.json` fixtures are present so the runner
%% adapts to the committed curated subset or a freshly re-vendored full set.
list_dir(Dir) ->
    case file:list_dir(Dir) of
        {ok, Names} ->
            {ok, [unicode:characters_to_binary(N) || N <- Names]};
        {error, Reason} ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Resolve an executable's absolute path via PATH. `{ok, PathBinary}` if found,
%% `{error, <<"not found">>}` otherwise. Lets the Tier-B wasmtime adapter SKIP
%% gracefully (rather than fail the suite) when the engine is not installed.
find_executable(Name) ->
    case os:find_executable(unicode:characters_to_list(Name)) of
        false -> {error, <<"not found">>};
        Path -> {ok, unicode:characters_to_binary(Path)}
    end.

%% Run an external program with a list of string arguments, capturing combined
%% stdout+stderr and the exit status. Returns `#{exit => Int, output => Binary}` as a
%% 2-tuple `{Exit, Output}` (a Gleam `#(Int, String)`). stderr is folded into stdout
%% so a `wasmtime` trap line ("wasm trap: ...") and a normal result line are both
%% visible to the Tier-B adapter. Tier-B only — never on the Tier-A path.
run(Program, Args) ->
    Exe = unicode:characters_to_list(Program),
    ArgL = [unicode:characters_to_list(A) || A <- Args],
    Port = erlang:open_port(
        {spawn_executable, Exe},
        [{args, ArgL}, exit_status, stderr_to_stdout, binary, hide]),
    collect(Port, <<>>).

collect(Port, Acc) ->
    receive
        {Port, {data, Bytes}} -> collect(Port, <<Acc/binary, Bytes/binary>>);
        {Port, {exit_status, Code}} -> {Code, Acc}
    end.

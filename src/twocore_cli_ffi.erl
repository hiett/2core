%% Unit 11c — CLI / run-invoke FFI shim (the catching-apply seam for `pipeline:invoke`).
%%
%% Hand-written Erlang, so it carries the `twocore_` namespace prefix (overview §5), never
%% `lists`/`maps`/`erlang`. It exists only so the run/invoke ABU (`pipeline.gleam`) can
%% apply a freshly-loaded generated export and capture a trap / capability-denial WITHOUT
%% crashing the calling process — Gleam on OTP 29 has no generic exception rescue in this
%% dependency set (gleam_erlang 1.3), so the catch must live in Erlang.
%%
%% The doc (11d) asked unit 04 to add a catching-apply path to its `twocore_codegen_ffi`
%% shim; that seam was not present and 04's file is single-owned (D1, must not be edited),
%% so the seam is provided here instead. It touches no unit-owned source file.
-module(twocore_cli_ffi).
-export([catch_apply/3, start_instance/1, call_instance/3, stop_instance/1]).

%% Apply Mod:Fun(Args) on the loaded generated module. On a normal return yield
%% `{ok, V}` (a Gleam `Ok(Int)`) where V is the result rendered as an integer (the raw
%% value / IEEE-754 bit pattern, per D5). If the call raises/exits/throws — a trap raised
%% by `rt_trap` as error-class `{wasm_trap, Kind}`, or a deny-all `{capability_denied,
%% Cap, Name}` — yield `{error, Reason}` (a Gleam `Error(String)`) with Reason rendered as
%% a UTF-8 binary so the caller can substring-match the spec trap phrase. Never crashes the
%% caller.
catch_apply(Mod, Fun, Args) ->
    try erlang:apply(Mod, Fun, Args) of
        V -> {ok, V}
    catch
        _Class:Reason ->
            {error, unicode:characters_to_binary(io_lib:format("~0p", [Reason]))}
    end.

%% ── one-instance-one-process run-ABI (unit 11, E1/E5) ───────────────────────
%%
%% The instance's mutable state (memory page-map, mutable globals, table) lives in
%% the process dictionary of ONE owned process (the `cell` strategy). So `run`'s
%% `load → instantiate → invoke` must run instantiate/0 AND the invoke in that SAME
%% process, or the export reads the caller's empty pdict. These three functions
%% give `pipeline.gleam` that owned process (same shape as the conformance shim).
%%
%%   start_instance(Module) -> {ok, Pid} | {error, Reason}   %% spawn + instantiate IN it
%%   call_instance(Pid, Fun, Args) -> {ok, V} | {error, Reason}   %% apply IN it
%%   stop_instance(Pid) -> nil.                              %% exit → cell auto-GC'd

%% Spawn the instance process and run instantiate/0 in it; block until it reports
%% success or an instantiation-time trap.
start_instance(Module) ->
    Parent = self(),
    Pid = spawn(fun() ->
        Outcome =
            try Module:instantiate() of
                _ -> ok
            catch
                _Class:Reason:Stack -> {error, render_reason(Reason, Stack)}
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

%% Run apply(Module, Fun, Args) inside the instance's own process; a trap surfaces
%% as {error, RenderedReason}.
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

render_reason(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
render_reason(Reason, Stack) ->
    Top = case Stack of [F|_] -> F; _ -> none end,
    unicode:characters_to_binary(io_lib:format("~0p @ ~0p", [Reason, Top])).

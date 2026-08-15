-module(vouch_ffi).
-export([
    find_test_files/0,
    exported_zero_arity/1,
    run_test/3,
    catch_panic/1,
    decode_panic/1,
    now_microseconds/0,
    is_stdout_tty/0,
    env/1,
    redirect_diagnostics_to_stderr/0,
    write_file/2,
    halt/1,
    file_snapshot/1,
    run_passthrough/2,
    sleep_ms/1,
    install_quit_hooks/0,
    start_test/3,
    await_test/1,
    schedulers_online/0
]).

write_file(Path, Content) ->
    case file:write_file(unicode:characters_to_list(Path), Content) of
        ok -> {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end.

now_microseconds() ->
    erlang:monotonic_time(microsecond).

is_stdout_tty() ->
    case io:columns() of
        {ok, _} -> true;
        _ -> false
    end.

env(Name) ->
    case os:getenv(unicode:characters_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

%% Route BEAM diagnostics (e.g. crash reports from processes that tests
%% spawned) to stderr, so stdout stays a clean stream for reporters. They
%% remain visible in a terminal; they no longer corrupt piped output.
%% logger_std_h does not honour a runtime `type` change, so the handler is
%% removed and re-added with its filters and formatter preserved. Note the
%% reports are asynchronous and can be lost entirely if the VM halts first.
redirect_diagnostics_to_stderr() ->
    catch case logger:get_handler_config(default) of
        {ok, #{module := Module, config := HConfig} = Cfg} ->
            NewCfg0 = Cfg#{config := HConfig#{type => standard_error}},
            NewCfg = maps:remove(id, maps:remove(module, NewCfg0)),
            logger:remove_handler(default),
            logger:add_handler(default, Module, NewCfg);
        _ ->
            ok
    end,
    nil.

%% Paths of .gleam files under test/, relative to test/.
find_test_files() ->
    Files = filelib:wildcard("**/*.gleam", "test"),
    [unicode:characters_to_binary(F) || F <- Files].

%% Names of the zero-arity exported functions of a module. Module names arrive
%% in Gleam form ("foo/bar_test"); nested modules compile to foo@bar_test.
exported_zero_arity(ModuleName) ->
    Module = binary_to_atom(beam_name(ModuleName), utf8),
    case code:ensure_loaded(Module) of
        {module, _} ->
            [atom_to_binary(Name, utf8)
             || {Name, Arity} <- Module:module_info(exports), Arity =:= 0];
        _ ->
            []
    end.

%% Run one test by name in its own monitored process. The test process
%% catches its own panic and sends the payload back, so decoding never
%% depends on exit-reason fidelity; the DOWN branch only fires when the
%% process died without reporting (exit signal, linked crash), and a test
%% that outlives the timeout is killed. Return values are the constructors
%% of vouch/internal/outcome.Invocation.
run_test(ModuleName, FunctionName, TimeoutMs) ->
    Module = binary_to_atom(beam_name(ModuleName), utf8),
    Function = binary_to_atom(FunctionName, utf8),
    Self = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        Self ! {vouch_result, self(), catch_panic(fun() -> Module:Function() end)}
    end),
    receive
        {vouch_result, Pid, {ok, nil}} ->
            erlang:demonitor(Ref, [flush]),
            passed;
        {vouch_result, Pid, {error, Reason}} ->
            erlang:demonitor(Ref, [flush]),
            {panicked, Reason};
        {'DOWN', Ref, process, Pid, Reason} ->
            %% decode_panic's recursive search handles {Reason, Stacktrace}
            %% and OTP wrappers, so the reason is passed through raw.
            {died, Reason}
    after TimeoutMs ->
        erlang:demonitor(Ref, [flush]),
        exit(Pid, kill),
        receive
            {vouch_result, Pid, _} -> ok
        after 0 -> ok
        end,
        {timed_out, TimeoutMs}
    end.


%% Parallel execution: start one test without blocking on it. The spawned
%% middleman runs the same run_test/3 as the sequential path — identical
%% isolation and timeout semantics — measures the duration, and posts the
%% result back tagged with a unique ref. The monitor covers the
%% theoretical case of the middleman dying before it reports.
start_test(Module, Function, TimeoutMs) ->
    Self = self(),
    Ref = make_ref(),
    {_Pid, MonRef} = spawn_monitor(fun() ->
        Started = erlang:monotonic_time(microsecond),
        Result = run_test(Module, Function, TimeoutMs),
        Duration = erlang:monotonic_time(microsecond) - Started,
        Self ! {vouch_parallel, Ref, Result, Duration}
    end),
    {Ref, MonRef}.

await_test({Ref, MonRef}) ->
    receive
        {vouch_parallel, Ref, Result, Duration} ->
            erlang:demonitor(MonRef, [flush]),
            {Result, Duration};
        {'DOWN', MonRef, process, _Pid, Reason} ->
            {{died, Reason}, 0}
    end.

schedulers_online() ->
    erlang:system_info(schedulers_online).

%% Call a function, capturing anything it throws. The raw reason is returned
%% for Gleam-side decoding; a Gleam panic's reason is a map tagged
%% gleam_error.
catch_panic(F) ->
    try
        F(),
        {ok, nil}
    catch
        error:Reason -> {error, Reason};
        Class:Reason -> {error, {Class, Reason}}
    end.

%% Decode a raw error term into vouch's GleamPanic type, or error for
%% anything that is not a Gleam panic. The panic map is searched for
%% recursively through nested tuples, because OTP wraps exit reasons: a todo
%% inside a gen_server callback reaches the caller as
%% {{Map, Stacktrace}, {gen_server, call, [...]}}, a plain error exit as
%% {Map, Stacktrace}, and vouch's own catch wrapper adds {Class, Reason}.
%% Tuple shapes must match the constructor definitions in
%% src/vouch/internal/gleam_panic.gleam.
decode_panic(Term) ->
    case find_panic(Term, 6) of
        {ok, Map} -> panic_from_map(Map);
        error -> {error, nil}
    end.

find_panic(#{gleam_error := _} = Map, _Depth) ->
    {ok, Map};
find_panic(Term, Depth) when is_tuple(Term), Depth > 0 ->
    find_panic_in(tuple_to_list(Term), Depth - 1);
find_panic(_, _) ->
    error.

find_panic_in([], _Depth) ->
    error;
find_panic_in([Head | Tail], Depth) ->
    case find_panic(Head, Depth) of
        {ok, Map} -> {ok, Map};
        error -> find_panic_in(Tail, Depth)
    end.

panic_from_map(#{
    gleam_error := assert,
    start := Start,
    'end' := End,
    expression_start := EStart
} = E) ->
    wrap(E, {assert, Start, End, EStart, assert_kind(E)});
panic_from_map(#{
    gleam_error := let_assert,
    start := Start,
    'end' := End,
    pattern_start := PStart,
    pattern_end := PEnd,
    value := Value
} = E) ->
    wrap(E, {let_assert, Start, End, PStart, PEnd, Value});
panic_from_map(#{gleam_error := panic} = E) ->
    wrap(E, panic);
panic_from_map(#{gleam_error := todo} = E) ->
    wrap(E, todo);
panic_from_map(_) ->
    {error, nil}.

assert_kind(#{kind := binary_operator, left := L, right := R, operator := O}) ->
    {binary_operator, atom_to_binary(O, utf8), expression(L), expression(R)};
assert_kind(#{kind := function_call, arguments := Arguments}) ->
    {function_call, lists:map(fun expression/1, Arguments)};
assert_kind(#{kind := expression, expression := Expression}) ->
    {other_expression, expression(Expression)}.

expression(#{start := S, 'end' := E, kind := literal, value := Value}) ->
    {asserted_expression, S, E, {literal, Value}};
expression(#{start := S, 'end' := E, kind := expression, value := Value}) ->
    {asserted_expression, S, E, {expression, Value}};
expression(#{start := S, 'end' := E, kind := unevaluated}) ->
    {asserted_expression, S, E, unevaluated}.

wrap(#{
    file := File,
    message := Message,
    module := Module,
    function := Function,
    line := Line
}, Kind) ->
    {ok, {gleam_panic, Message, File, Module, Function, Line, Kind}}.

halt(Code) ->
    erlang:halt(Code),
    nil.

%% Watch-mode primitives. One row per file under the given roots (a root may
%% be a file or a directory, searched recursively): path, mtime in gregorian
%% seconds, size in bytes. Sorted so two snapshots of an unchanged tree
%% compare equal regardless of traversal order.
file_snapshot(Roots) ->
    lists:sort(lists:flatmap(fun snapshot_root/1, Roots)).

snapshot_root(Root) ->
    Path = unicode:characters_to_list(Root),
    case filelib:is_dir(Path) of
        true ->
            filelib:fold_files(Path, ".*", true, fun(File, Acc) ->
                [snapshot_entry(File) | Acc]
            end, []);
        false ->
            case filelib:is_regular(Path) of
                true -> [snapshot_entry(Path)];
                false -> []
            end
    end.

snapshot_entry(Path) ->
    Seconds = case filelib:last_modified(Path) of
        0 -> 0;
        DateTime -> calendar:datetime_to_gregorian_seconds(DateTime)
    end,
    {unicode:characters_to_binary(Path), Seconds, filelib:file_size(Path)}.

%% Spawn a command with its stdout streamed through to ours as chunks
%% arrive; stderr is inherited by the child directly, so build-tool
%% diagnostics keep their usual destination. Returns the exit code.
run_passthrough(Command, Args) ->
    case os:find_executable(unicode:characters_to_list(Command)) of
        false ->
            {error, nil};
        Exe ->
            Port = open_port({spawn_executable, Exe}, [
                {args, [unicode:characters_to_list(A) || A <- Args]},
                exit_status,
                binary,
                hide
            ]),
            stream_through(Port)
    end.

stream_through(Port) ->
    receive
        {Port, {data, Data}} ->
            io:put_chars(Data),
            stream_through(Port);
        {Port, {exit_status, Code}} ->
            drain_through(Port),
            {ok, Code}
    end.

drain_through(Port) ->
    receive
        {Port, {data, Data}} ->
            io:put_chars(Data),
            drain_through(Port)
    after 0 ->
        ok
    end.

sleep_ms(Ms) ->
    receive after Ms -> nil end.

%% Quitting the watch loop: a stdin listener that halts on "q" + Enter.
%% This is the only clean quit the BEAM allows a long-running foreground
%% program: SIGINT belongs to the emulator's break handler and cannot be
%% taken over (os:set_signal(sigint, handle) is badarg), and booting with
%% +Bd/+Bi merely turns Ctrl+C into a no-op, so Ctrl+C either opens the
%% BREAK menu or does nothing. The inner runs never contend for stdin —
%% their ports get pipes. eof means stdin is not interactive (piped or
%% closed), so the listener just retires rather than treating it as a
%% quit.
install_quit_hooks() ->
    spawn(fun quit_listener/0),
    nil.

quit_listener() ->
    case io:get_line("") of
        eof ->
            ok;
        {error, _} ->
            ok;
        Line ->
            case string:trim(unicode:characters_to_list(Line)) of
                "q" -> erlang:halt(0);
                "quit" -> erlang:halt(0);
                _ -> quit_listener()
            end
    end.

beam_name(ModuleName) ->
    binary:replace(ModuleName, <<"/">>, <<"@">>, [global]).

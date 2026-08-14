-module(vouch_ffi).
-export([
    find_test_files/0,
    exported_zero_arity/1,
    run_test/3,
    catch_panic/1,
    decode_panic/1,
    now_microseconds/0,
    write_file/2,
    halt/1
]).

write_file(Path, Content) ->
    case file:write_file(unicode:characters_to_list(Path), Content) of
        ok -> {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end.

now_microseconds() ->
    erlang:monotonic_time(microsecond).

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
            {died, normalize_exit_reason(Reason)}
    after TimeoutMs ->
        erlang:demonitor(Ref, [flush]),
        exit(Pid, kill),
        receive
            {vouch_result, Pid, _} -> ok
        after 0 -> ok
        end,
        {timed_out, TimeoutMs}
    end.

%% Error exits carry {Reason, Stacktrace}; unwrap so a linked Gleam panic's
%% payload map is decodable.
normalize_exit_reason({Reason, Stack}) when is_list(Stack) -> Reason;
normalize_exit_reason(Reason) -> Reason.

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
%% anything that is not a Gleam panic. Tuple shapes must match the
%% constructor definitions in src/vouch/internal/panic.gleam.
decode_panic(#{
    gleam_error := assert,
    start := Start,
    'end' := End,
    expression_start := EStart
} = E) ->
    wrap(E, {assert, Start, End, EStart, assert_kind(E)});
decode_panic(#{
    gleam_error := let_assert,
    start := Start,
    'end' := End,
    pattern_start := PStart,
    pattern_end := PEnd,
    value := Value
} = E) ->
    wrap(E, {let_assert, Start, End, PStart, PEnd, Value});
decode_panic(#{gleam_error := panic} = E) ->
    wrap(E, panic);
decode_panic(#{gleam_error := todo} = E) ->
    wrap(E, todo);
decode_panic(_) ->
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

beam_name(ModuleName) ->
    binary:replace(ModuleName, <<"/">>, <<"@">>, [global]).

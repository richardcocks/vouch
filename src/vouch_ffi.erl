-module(vouch_ffi).
-export([find_test_files/0, exported_zero_arity/1, run_test/2, halt/1]).

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

%% Run one test, capturing anything it throws. The raw reason is returned for
%% Gleam-side decoding; a Gleam panic's reason is a map tagged gleam_error.
run_test(ModuleName, FunctionName) ->
    Module = binary_to_atom(beam_name(ModuleName), utf8),
    Function = binary_to_atom(FunctionName, utf8),
    try
        Module:Function(),
        {ok, nil}
    catch
        error:Reason -> {error, Reason};
        Class:Reason -> {error, {Class, Reason}}
    end.

halt(Code) ->
    erlang:halt(Code),
    nil.

beam_name(ModuleName) ->
    binary:replace(ModuleName, <<"/">>, <<"@">>, [global]).

%% Test-only helper: run a command in a directory, capturing stdout and the
%% exit code. stderr is deliberately not captured — the e2e tests assert
%% that stdout alone is a clean stream.
-module(vouch_e2e_ffi).
-export([run_command/3]).

run_command(Command, Args, Dir) ->
    case os:find_executable(unicode:characters_to_list(Command)) of
        false ->
            {error, nil};
        Exe ->
            Port = open_port({spawn_executable, Exe}, [
                {args, [unicode:characters_to_list(A) || A <- Args]},
                {cd, unicode:characters_to_list(Dir)},
                exit_status,
                binary,
                hide
            ]),
            collect(Port, [])
    end.

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect(Port, [Data | Acc]);
        {Port, {exit_status, Code}} ->
            Output = drain(Port, Acc),
            {ok, {Code, unicode:characters_to_binary(lists:reverse(Output))}}
    end.

drain(Port, Acc) ->
    receive
        {Port, {data, Data}} -> drain(Port, [Data | Acc])
    after 0 ->
        Acc
    end.

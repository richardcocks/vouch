%% Watch mode's SIGINT handler: once vouch_ffi:install_quit_hooks/0 has
%% routed SIGINT here (Unix-like systems only), Ctrl+C halts the watcher
%% outright with the shell's 128+2 convention, instead of dropping into
%% the emulator's BREAK menu.
-module(vouch_signal_handler).
-behaviour(gen_event).
-export([
    init/1,
    handle_event/2,
    handle_call/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

init(_) -> {ok, nostate}.

handle_event(sigint, State) ->
    io:put_chars("\n"),
    erlang:halt(130),
    {ok, State};
handle_event(_, State) ->
    {ok, State}.

handle_call(_, State) -> {ok, ok, State}.
handle_info(_, State) -> {ok, State}.
terminate(_, _) -> ok.
code_change(_, State, _) -> {ok, State}.

-module(playground_ffi).
-export([sleep/1, spawn/1]).

sleep(Ms) ->
    timer:sleep(Ms),
    nil.

%% Unlinked on purpose: the crash must not take the caller down.
spawn(Job) ->
    erlang:spawn(Job),
    nil.

-module(pforeach).
-export([pforeach/2]).

worker_proc(Fun, Arg) ->
    receive
        start ->
            Fun(Arg)
    end.

spawn_workers(_Fun, [], Refs) ->
    Refs;
spawn_workers(Fun, [H|R], Refs) ->
    Pid = spawn_link(fun() -> worker_proc(Fun, H) end),
    Ref = monitor(process, Pid),
    Pid ! start,
    spawn_workers(Fun, R, [Ref|Refs]).

mon_loop([]) ->
    ok;
mon_loop([Ref|Rest]) ->
    receive
        {'DOWN', Ref, process, _Pid, _Reason} ->
            mon_loop(Rest)
    end.

mon_start(Fun, List) ->
    Workers = spawn_workers(Fun, List, []),
    mon_loop(Workers).

pforeach(Fun, List) ->
    {MonWorker, MRef} = spawn_monitor(fun() -> mon_start(Fun, List) end),
    receive
        {'DOWN', MRef, process, MonWorker, normal} ->
            ok;
        {'DOWN', MRef, process, MonWorker, Reason} ->
            {error, Reason}
    end.

-module(user_worker_sup).
-export([start_link/0, start_link/1, init/1]).

start_link(Name) ->
    supervisor:start_link(Name, user_worker_sup, []).

start_link() ->
    supervisor:start_link(user_worker_sup, []).

init(_Args) ->
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 0,
                 period => 1},
    ChildSpecs = [#{id => user_worker,
                    start => {user_worker, start_link, []},
                    restart => temporary,
                    shutdown => brutal_kill}],
    {ok, {SupFlags, ChildSpecs}}.

-module(conn_worker_sup).
-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link(?MODULE, []).

init(_Args) ->
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 0,
                 period => 1},
    ChildSpecs = [#{id => conn_worker,
                    start => {conn_worker, start_link, []},
                    restart => temporary}],
    {ok, {SupFlags, ChildSpecs}}.

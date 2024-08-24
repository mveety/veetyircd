-module(conns_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link(?MODULE, []).

init(_Args) ->
    SupFlags = #{strategy => one_for_all,
                 intensity => 1,
                 period => 5},
    ChildSpecs = [ #{
                     id => conn_worker_sup,
                     start => {conn_worker_sup, start_link, []},
                     type => supervisor
                    }
                 , #{
                     id => conn_server,
                     start => {conn_server, start_link, []},
                     type => worker
                    }
                 ],
    {ok, {SupFlags, ChildSpecs}}.

-module(users_sup).
-behaviour(supervisor).
-export([init/1, start_link/0]).

start_link() ->
    supervisor:start_link(?MODULE, []).

init(_Args) ->
    SupFlags = #{strategy => one_for_all,
                 intensity => 1,
                 period => 5},
    ChildSpecs = [ #{
                     id => user_worker_sup,
                     start => {user_worker_sup, start_link, []},
                     type => supervisor
                    }
                 , #{
                     id => user_server,
                     start => {user_server, start_link, []},
                     type => worker
                    }
                 ],
    {ok, {SupFlags, ChildSpecs}}.

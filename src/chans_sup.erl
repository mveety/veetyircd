-module(chans_sup).
-behaviour(supervisor).
-export([init/1, start_link/0]).

start_link() ->
    supervisor:start_link(?MODULE, []).

init(_Args) ->
    SupFlags = #{strategy => one_for_all,
                 intensity => 10,
                 period => 5},
    ChildSpecs = [ #{
                     id => channel_worker_sup,
                     start => {channel_worker_sup, start_link, []},
                     type => supervisor
                    }
                 , #{
                     id => channel_server,
                     start => {channel_server, start_link, []},
                     type => worker
                    }
                 ],
    {ok, {SupFlags, ChildSpecs}}.

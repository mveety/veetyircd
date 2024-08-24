-module(channel_worker_sup).
-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link(channel_worker_sup, []).

init(_Args) ->
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 0,
                 period => 1},
    ChildSpecs =[#{id => channel_worker,
                   type => supervisor,
                   start => {channel, start_link, []},
                   restart => temporary}],
    {ok, {SupFlags, ChildSpecs}}.

-module(channel_sup).
-behaviour(supervisor).
-export([start_link/1, init/1]).

start_link(Name) ->
    supervisor:start_link(channel_sup, [Name]).

init([Name]) ->
    Args = [self(), Name],
    Workers = cfg:config(chan_broadcast_workers, 4),
    SupFlags = #{strategy => rest_for_one,
                 auto_shutdown => any_significant,
                 intensity => 10,
                 period => 5},
    ChildSpecs = [
                  #{id => broadcast,
                    start => {broadcast, start_link, [Workers]},
                    restart => temporary,
                    significant => true,
                    type => supervisor},
                  #{id => channel,
                    start => {channel, server_start, Args},
                    restart => transient,
                    significant => true,
                    type => worker}
                  ],
    {ok, {SupFlags, ChildSpecs}}.

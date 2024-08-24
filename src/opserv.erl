-module(opserv).
-export([start_link/0, init/1, parse_message/4, message/4]).

start_link() ->
    veetyircd_bot:start_link(?MODULE, []).

init([]) ->
    {failover, []}.

parse_message0(Msg0) ->
    [Msg|_] = string:split(Msg0, " ", leading),
    Msg.

to_reply(Forms) ->
    list_to_binary(io_lib:format("~p", [Forms])).

parse_message(Msg, _From = {user, Nick, _}, self, _State) ->
    case irc_auth:check_flags(Nick, global, [owner, operator]) of
        false -> {ok, no_permissions};
        true ->
            case parse_message0(Msg) of
                <<"help">> -> {ok, help};
                <<"version">> -> {ok, version};
                <<"stats">> -> {ok, stats};
                <<"init_stop">> -> {ok, init_stop};
                <<"move_channels">> -> {ok, move_channels};
                <<"takeback_channels">> -> {ok, takeback_channels};
                <<"distribute_channels">> -> {ok, distribute_channels};
                <<"save_channels">> -> {ok, save_channels};
                <<"save_cluster_channels">> -> {ok, save_cluster_channels};
                <<"takeback_cluster_channels">> -> {ok, takeback_cluster_channels};
                <<"uptime">> -> {ok, uptime};
                <<"node">> -> {ok, node};
                <<"node_uptimes">> -> {ok, node_uptimes};
                <<"node_versions">> -> {ok, node_versions};
                <<"all_nodes">> -> {ok, all_nodes};
                <<"cluster_uptime">> -> {ok, cluster_uptime};
                _ -> {ok, {error, Msg}}
            end
    end;
parse_message(_Msg, _From, _To, _State) ->
    {ok, skip_message}.

message(help, From, self, State) ->
    Reply = [ <<"help                      -- display this message">>
            , <<"version                   -- display node's version">>
            , <<"stats                     -- display the system stats">>
            , <<"init_stop                 -- init:stop() on this node">>
            , <<"move_channels             -- move channels to other nodes">>
            , <<"takeback_channels         -- take channels back from other nodes">>
            , <<"distribute_channels       -- distribute channels to other nodes">>
            , <<"save_channels             -- save channel list on node">>
            , <<"save_cluster_channels     -- save channel list cluster-wide">>
            , <<"takeback_cluster_channels -- take channels back cluster-wide">>
            , <<"uptime                    -- show node uptime">>
            , <<"node                      -- show node name">>
            , <<"node_uptimes              -- show node uptimes">>
            , <<"node_versions             -- show node versions">>
            , <<"all_nodes                 -- list of all nodes">>
            , <<"cluster_uptime            -- cluster's uptime">>
            ],
    {ok, {reply, From, Reply}, State};

message(no_permissions, From, self, State) ->
    {ok, {reply, From, <<"access denied">>}, State};

message(version, From, self, State) ->
    {ok, {reply, From, ircctl:version_string()}, State};

message(stats, From, self, State) ->
    {ok, Stats} = ircctl:stats(),
    LocalStats = proplists:get_value(local, Stats),
    Local = io_lib:format("local: connections = ~p, users = ~p, channels = ~p",
                          [ proplists:get_value(connections, LocalStats)
                          , proplists:get_value(users, LocalStats)
                          , proplists:get_value(channels, LocalStats)]),
    case proplists:get_value(global, Stats) of
        undefined ->
            {ok, {reply, From, list_to_binary(Local)}, State};
        GlobalStats ->
            Global = io_lib:format("global: nodes = ~p, users = ~p, channels = ~p",
                                   [ proplists:get_value(nodes, GlobalStats)
                                   , proplists:get_value(users, GlobalStats)
                                   , proplists:get_value(channels, GlobalStats)
                                   ]),
            Reply = [ list_to_binary(Local)
                    , list_to_binary(Global)
                    ],
            {ok, {reply, From, Reply}, State}
    end;

message(init_stop, From, self, State) ->
    init:stop(),
    {ok, {reply, From, <<"ok">>}, State}; %% this is a pipedream

message(move_channels, From, self, State) ->
    Reply = to_reply(ircctl:move_channels()),
    {ok, {reply, From, Reply}, State};

message(takeback_channels, From, self, State) ->
    Reply = to_reply(ircctl:takeback_channels()),
    {ok, {reply, From, Reply}, State};

message(distribute_channels, From, self, State) ->
    Reply = to_reply(ircctl:distribute_channels()),
    {ok, {reply, From, Reply}, State};

message(save_channels, From, self, State) ->
    Reply = to_reply(ircctl:save_channels()),
    {ok, {reply, From, Reply}, State};

message(save_cluster_channels, From, self, State) ->
    Reply = to_reply(ircctl:save_cluster_channels()),
    {ok, {reply, From, Reply}, State};

message(takeback_cluster_channels, From, self, State) ->
    Reply = to_reply(ircctl:takeback_cluster_channels()),
    {ok, {reply, From, Reply}, State};

message(uptime, From, self, State) ->
    Reply = ircctl:uptime_string(ircctl:uptime()),
    {ok, {reply, From, Reply}, State};

message(node, From, self, State) ->
    Reply = atom_to_binary(node()),
    {ok, {reply, From, Reply}, State};

message(node_uptimes, From, self, State) ->
    Uptimes = ircctl:uptime_string(ircctl:node_uptimes()),
    FmtUptimes = fun({Node, Str}) ->
                         Node0 = atom_to_binary(Node),
                         <<Node0/binary, ": ", Str/binary>>
                 end,
    Reply = [FmtUptimes(X) || X <- Uptimes],
    {ok, {reply, From, Reply}, State};

message(node_versions, From, self, State) ->
    GetVersion = fun(N) -> {N, rpc:call(N, ircctl, version_string, [])} end,
    FmtVersions = fun({Node, Str}) ->
                         Node0 = atom_to_binary(Node),
                         <<Node0/binary, ": ", Str/binary>>
                 end,
    Reply = [FmtVersions(Y) || Y <- [GetVersion(X) || X <- element(2, ircctl:all_nodes())]],
    {ok, {reply, From, Reply}, State};

message(all_nodes, From, self, State) ->
    {ok, Nodes} = ircctl:all_nodes(),
    FmtNodes = fun (N, <<"">>) ->
                       N0 = atom_to_binary(N),
                       <<N0/binary>>;
                   (N, Acc0) ->
                       N0 = atom_to_binary(N),
                       <<Acc0/binary, ", ", N0/binary>>
               end,
    Reply = lists:foldl(FmtNodes, <<"">>, Nodes),
    {ok, {reply, From, Reply}, State};

message(cluster_uptime, From, self, State) ->
    Reply = ircctl:uptime_string(ircctl:cluster_uptime()),
    {ok, {reply, From, Reply}, State};

message({error, _Msg}, From, self, State) ->
    {ok, {reply, From, <<"error: unknown message">>}, State};

message(Msg, From, To, State) ->
    logger:info("opserv: unhandled message. Msg = ~p, From = ~p, To = ~p", [Msg, From, To]),
    {ok, noreply, State}.

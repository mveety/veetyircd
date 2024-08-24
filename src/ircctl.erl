-module(ircctl).
%% this is misc functions to help in administering the server
%% bit of a grab bag.

-export([stats/0, debug/1, version_info/0,object/1, setup_mnesia/0,
         add_node/1, add_satellite_node/1, channel/1, user/1,
         full_mnesia_setup/0, setup_mnesia_tables/0, version_string/0,
         take_channels_from/1, stats/1, cluster_version_info/0]).
-export([make_channels/1, make_channels/2, cluster_make_channels/1,
         cluster_make_channels/2]).
-export([move_channels/0, takeback_channels/0, all_nodes/0,
         distribute_channels/0, save_channels/0, save_cluster_channels/0,
         takeback_cluster_channels/0]).
-export([uptime/0, uptime_string/1, node_uptimes/0, cluster_uptime/0]).
-export([changed_modules/0, reload_modules/1, purge_modules/1, change_code/4]).
-export([restart_server/0, remove_node/1, remove_running_node/1]).
-export([start/0, stop/0]).

stats() ->
    {ok, #{nconns := NConns}} = gen_server:call(conn_server, stats),
    {ok, NUsers} = gen_server:call(user_server, stats),
    {ok, NChans} = gen_server:call(channel_server, stats),
    {ok, Nodes} = channel_server:all_nodes(),
    case names:alive() of
        true ->
            GNUsers = length(element(2, names:get_all(user))),
            GNChans = length(element(2, names:get_all(channel))),
            {ok, [{local, [{connections, NConns},
                           {users, NUsers},
                           {channels, NChans}]},
                  {global, [{nodes, length(Nodes)},
                            {users, GNUsers},
                            {channels, GNChans}]}]};
        false ->
            {ok, [{local, [{connections, NConns},
                           {users, NUsers},
                           {channels, NChans}]}]}
    end.
stats(Node) ->
    erpc:call(Node, ircctl, stats, []).

debug(true) ->
    logger:set_primary_config(level, info),
    ok;
debug(false) ->
    logger:set_primary_config(level, notice),
    ok.

%% this is, I swear, the like 10th object function
object({_Type, _Name, Pid}) ->
    {ok, Pid};
object(Tuple = {user, _}) ->
    object1(Tuple);
object(Tuple = {channel, _}) ->
    object1(Tuple);
object({Type, _}) ->
    {error, {unknown_object, Type}};
object(_) ->
    {error, badarg}.

object1({Type, Name}) when is_atom(Name) ->
    object1({Type, atom_to_binary(Name)});
object1({Type, Name}) when is_list(Name) ->
    object1({Type, list_to_binary(Name)});
object1(Tuple = {Type, Name}) ->
    case names:lookup(Tuple) of
        {ok, {Type, Name, Pid}} ->
            {ok, Pid};
        Err = {error, _} ->
            Err
    end.

channel(Name) ->
    {ok, Pid} = object({channel, Name}),
    Pid.

user(Name) ->
    {ok, Pid} = object({user, Name}),
    Pid.

%% these two are call veetyircd to reduce frustration
version_info() ->
    veetyircd:version_info().

cluster_version_info() ->
    {ok, Nodes} = channel_server:all_nodes(),
    Fmtfn = fun(N) -> {N, erpc:call(N, ircctl, version_info, [])} end,
    [Fmtfn(X) || X <- Nodes].

version_string() ->
    veetyircd:version_string().

setup_mnesia() ->
    full_mnesia_setup().

full_mnesia_setup() ->
    %% this is to be run on a bare, totally unconfigured node without
    %% veetyircd running. see also: bin/veetyircd console_clean
    mnesia:create_schema([node()]),
    mnesia:start(),
    setup_mnesia_tables().

setup_mnesia_tables() ->
    %% userinfo contains global state about existing users (used by name_server)
    mnesia:create_table(userinfo, [{type, set},
                                   {attributes, [name, node, pid, ref, aux]}]),
    mnesia:add_table_index(userinfo, node),
    mnesia:add_table_index(userinfo, ref),
    %% chaninfo contains global state about existing channels (used by name_server)
    mnesia:create_table(chaninfo, [{type, set},
                                   {attributes, [name, node, pid, ref, aux]}]),
    mnesia:add_table_index(chaninfo, node),
    mnesia:add_table_index(chaninfo, ref),
    %% nodeinfo holds transient and node specific channel data (used by channel_server).
    %% nodeinfo can/is used everywhere but under the auspices of channel_server for
    %% historical reasons. likely this should be changed.
    mnesia:create_table(nodeinfo, [{type, set},
                                    {attributes, [key, node, value]}]),
    mnesia:add_table_index(nodeinfo, node),
    %% permachan holds configuration about permanent channels (used by channel_server)
    mnesia:create_table(permachan, [{type, set},
                                    {attributes, [name, topic, node, aux]},
                                    {disc_copies, [node()]}]),
    %% account holds authentication and account data (used by auth_server)
    mnesia:create_table(account, [{type, set},
                                  {attributes, [name, password, salt, hash, group, 
                                                enabled, flags, chanflags, aux]},
                                  {disc_copies, [node()]}]),
    mnesia:add_table_index(account, group).

add_node(Node) ->
    %% when executing this be sure that mnesia is running, but veetyircd is not on
    %% the remote node. veetyircd can be running on the node executing this.
    %% see also bin/veetyircd console_clean
    mnesia:change_config(extra_db_nodes, [Node]),
    mnesia:change_table_copy_type(schema, Node, disc_copies),
    mnesia:add_table_copy(userinfo, Node, ram_copies),
    mnesia:add_table_copy(chaninfo, Node, ram_copies),
    mnesia:add_table_copy(nodeinfo, Node, ram_copies),
    mnesia:add_table_copy(permachan, Node, disc_copies),
    mnesia:add_table_copy(account, Node, disc_copies),
    ok.

add_satellite_node(Node) ->
    %% satellite nodes are normal, but don't save data to disk.
    mnesia:change_config(extra_db_nodes, [Node]),
    mnesia:change_table_copy_type(schema, Node, disc_copies),
    mnesia:add_table_copy(userinfo, Node, ram_copies),
    mnesia:add_table_copy(chaninfo, Node, ram_copies),
    mnesia:add_table_copy(nodeinfo, Node, ram_copies),
    ok.

remove_node(Node) ->
    mnesia:del_table_copy(schema, Node).

remove_running_node(Node) ->
    ok = rpc:call(Node, application, stop, [veetyircd]),
    stopped = rpc:call(Node, mnesia, stop, []),
    remove_node(Node).

take_channels_from(Node) ->
    %% this takes all of the channels from another node. good for
    %% emergencies, but clean up can be a hassle.
    ThisNode = node(),
    Takeover = fun({channel, _, Pid}) -> channel:takeover(Pid) end,
    case Node of
        ThisNode -> {error, takeover_from_self};
        _ ->
            {ok, Channels} = channel_server:all_channels(Node),
            [Takeover(X) || X <- Channels]
    end.

%% for abuse
make_channels(_, 0) ->
    ok;
make_channels(Prefix, N) ->
    Nstr = integer_to_binary(N),
    ChanName = <<Prefix/binary, Nstr/binary>>,
    {ok, _} = channel_server:create(ChanName, <<"a testing channel!">>),
    make_channels(Prefix, N-1).
make_channels(N) ->
    make_channels(<<"tc">>, N).

cluster_make_channels(_, 0) ->
    ok;
cluster_make_channels(Prefix, N) ->
    Nstr = integer_to_binary(N),
    ChanName = <<Prefix/binary, Nstr/binary>>,
    {ok, _} = channel_server:cluster_create(ChanName, <<"a cluster testing channel!">>),
    cluster_make_channels(Prefix, N-1).
cluster_make_channels(N) ->
    cluster_make_channels(<<"ctc">>, N).

move_channels() ->
    channel_server:move_channels().

takeback_channels() ->
    channel_server:takeback_channels().

all_nodes() ->
    channel_server:all_nodes().

distribute_channels() ->
    channel_server:distribute_channels().

save_channels() ->
    channel_server:save_channels().

save_cluster_channels() ->
    {ok, Nodes} = all_nodes(),
    [erpc:call(N, ircctl, save_channels, []) || N <- Nodes].

takeback_cluster_channels() ->
    {ok, Nodes} = all_nodes(),
    [erpc:call(N, ircctl, takeback_channels, []) || N <- Nodes].

uptime() ->
    Rt = erlang:monotonic_time() - erlang:system_info(start_time),
    RtSec = erlang:convert_time_unit(Rt, native, seconds),
    calendar:seconds_to_daystime(RtSec).

uptime_string(L) when is_list(L) ->
    [uptime_string(X) || X <- L];
uptime_string({Node, DayTime = {_, {_, _, _}}}) ->
    {Node, uptime_string(DayTime)};
uptime_string({D, {H, M, S}}) ->
    list_to_binary(io_lib:format("~p days ~2..0B:~2..0B:~2..0B", [D, H, M, S])).

node_uptimes() ->
    {ok, Nodes} = channel_server:all_nodes(),
    Fmtfn = fun(N) -> {N, erpc:call(N, ircctl, uptime, [])} end,
    [Fmtfn(X) || X <- Nodes].

cluster_uptime() ->
    NowToSec = fun({M, S, _}) -> (M * 1000000) + S end,
    case cfg:config(chan_database_backend, dets) of
        dets -> uptime();
        mnesia ->
            {ok, StartTimeNow} = channel_server:get_data(start_time),
            StartTime = NowToSec(StartTimeNow),
            NowTime = NowToSec(erlang:timestamp()),
            calendar:seconds_to_daystime(NowTime - StartTime)
    end.

changed_modules() ->
    code:modified_modules().

reload_modules(Modules) ->
    code:atomic_load(Modules).

purge_modules(Modules) ->
    [code:purge(X) || X <- Modules].

change_code(Pid, Module, OldVsn, Extra) ->
    sys:suspend(Pid),
    sys:change_code(Pid, Module, OldVsn, Extra),
    sys:resume(Pid).

restart_server() ->
    case proplists:lookup(veetyircd, application:which_applications()) of
        none ->
            mnesia:stop(),
            mnesia:start(),
            application:start(veetyircd),
            ok;
        _ ->
            {error, running}
    end.

start() ->
    application:start(veetyircd).

stop() ->
    application:stop(veetyircd).

-module(exp_name_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3,
         terminate/2, start_link/0]).
-export([delete_by_node/1, crash_me/0]).
%% these are only available with this name_server
-export([nodes/1, delete_by_ref/2]).
-record(objectinfo, {name, node, pid, ref, aux = none}).

do_register(Table, Node, Ref, {Type, Name, Pid}) ->
    Objectinfo = #objectinfo{ name = {Type, Name}
                            , node = Node
                            , pid = Pid
                            , ref = Ref
                            , aux = none},
    true = ets:insert(Table, Objectinfo),
    ok.

do_register(Table, Node, Object) ->
    do_register(Table, Node, make_ref(), Object).

do_register(Table, Object = {_Type, _Name, Pid}) ->
    Ref = monitor(process, Pid),
    Node = node(),
    do_register(Table, Node, Ref, Object).

do_unregister(Table, {Type, Name, _Pid}) ->
    do_unregister(Table, {Type, Name});
do_unregister(Table, {Type, Name}) ->
    ets:delete(Table, {Type, Name}).

do_lookup(Table, {Type, Name, _Pid}) ->
    do_lookup(Table, {Type, Name});
do_lookup(Table, {Type, Name}) ->
    case ets:lookup(Table, {Type, Name}) of
        [#objectinfo{name = {Type, Name}, pid = Pid}] ->
            {ok, {Type, Name, Pid}};
        [] ->
            {error, case Type of
                        user -> no_user;
                        channel -> no_channel
                    end}
    end.

delete_by_ref(Table, Ref) ->
    MS = {objectinfo, '_', '_', '_', Ref, '_'},
    X = ets:match_object(Table, MS),
    logger:info("name_server: delete_by_ref: ref = ~p, X = ~p", [Ref, X]),
    case X of
        [#objectinfo{name = Id, pid = Pid}] ->
            do_unregister(Table, Id),
            {Type, Name} = Id,
            {ok, {Type, Name, Pid}};
        [] ->
            {error, not_found}
    end.

delete_by_node(Table, Node) ->
    MS = {objectinfo, '_', Node, '_', '_', '_'},
    Objects = ets:match_object(Table, MS),
    ObjRes = [ets:delete_object(Table, X) || X <- Objects],
    {ok, [{objects, length(ObjRes)}]}.

delete_by_node(_) ->
    ok.

do_get_all(Table, any) ->
    FoldFn = fun(#objectinfo{name = {Type, Name}, pid = Pid}, Acc0) ->
                     [{Type, Name, Pid}|Acc0]
             end,
    Res = ets:foldl(FoldFn, [], Table),
    {ok, Res};
do_get_all(Table, Objtype) ->
    FoldFn = fun (#objectinfo{name = {Type, Name}, pid = Pid}, {Type, Acc0}) ->
                     {Type, [{Type, Name, Pid}|Acc0]};
                 (_, {Type, Acc0}) ->
                     {Type, Acc0}
             end,
    {_, Res} = ets:foldl(FoldFn, {Objtype, []}, Table),
    {ok, Res}.

reconnect_proc(Parent, Node, 120) ->
    logger:warning("name_server: properly lost node ~p", [Node]),
    unlink(Parent),
    exit(shutdown);
reconnect_proc(Parent, Node, N) ->
    case net_adm:ping(Node) of
        pong ->
            gen_server:cast(self(), {do_sync, Node}),
            unlink(Parent),
            exit(shutdown);
        _ ->
            timer:sleep(60000),
            reconnect_proc(Parent, Node, N+1)
    end.

spawn_reconnect(Node) ->
    Self = self(),
    spawn_link(fun() -> reconnect_proc(Self, Node, 0) end).

sync_alarm_proc(Parent, ReSyncTime) ->
    timer:sleep(ReSyncTime),
    gen_server:cast(Parent, {do_sync, all}),
    sync_alarm_proc(Parent, ReSyncTime).

spawn_sync_alarm(ReSyncTime) ->
    Self = self(),
    spawn_link(fun() -> sync_alarm_proc(Self, ReSyncTime) end).

try_connect([], Acc0) ->
    Acc0;
try_connect([Node|R], Acc0) ->
    case net_adm:ping(Node) of
        pong ->
            Acc = sets:add_element(Node, Acc0),
            try_connect(R, Acc);
        _ -> try_connect(R, Acc0)
    end.

start_link() ->
    gen_server:start_link({local, name_server}, ?MODULE, [], []).

init(_Args) ->
    logger:notice("name_server: starting"),
    logger:warning("name_server: experimental name_server. use caution"),
    {ok, SeedNodes0} = cfg:config(name_exp_seed_nodes),
    SeedNodes = lists:delete(node(), SeedNodes0),
    Table = ets:new(name_server_objects, [ set
                                         , public %% so the cleaner can modify it
                                         , {keypos, #objectinfo.name}]),
    ok = net_kernel:monitor_nodes(true),
    WaitTime = cfg:config(name_cleanup_wait, 1000),
    ReSyncTime = cfg:config(name_exp_resync_time, 120)*1000,
    ReSyncAlarm = spawn_sync_alarm(ReSyncTime),
    logger:notice("name_server: trying seed nodes ~p", [SeedNodes]),
    Nodes = try_connect(SeedNodes, sets:new()),
    gen_server:abcast(nodes(), name_server, {new_node, node()}),
    State = #{ table => Table
             , wait_time => WaitTime
             , nodes => Nodes
             , resync_time => ReSyncTime
             , resync_alarm => ReSyncAlarm
             },
    {ok, State}.

handle_info({nodeup, Node}, State = #{table := Table, nodes := Nodes0}) ->
    logger:notice("name_server: nodeup for ~p", [Node]),
    Nodes = sets:add_element(Node, Nodes0),
    {ok, Objects} = do_get_all(Table, any),
    gen_server:cast({name_server, Node}, {sync, node(), Objects}),
    {noreply, State#{nodes => Nodes}};

handle_info({nodedown, Node}, State = #{table := Table, wait_time := WaitTime, nodes := Nodes0}) ->
    case sets:is_element(Node, Nodes0) of
        true ->
            Self = self(),
            Cleaner = fun(Parent) ->
                              timer:sleep(WaitTime), %% let things settle down, but don't wait too long
                              Res = delete_by_node(Table, Node),
                              logger:notice("name_server: nodedown cleaned up: node = ~p, status = ~p", [Node, Res]),
                              unlink(Parent)
                      end,
            Pid = spawn_link(fun() -> Cleaner(Self) end),
            ReconPid = spawn_reconnect(Node),
            logger:notice("name_server: nodedown cleanup started on pid ~p for node ~p", [Pid, Node]),
            logger:notice("name_server: starting reconnect proc ~p for node ~p", [ReconPid, Node]),
            Nodes = sets:del_element(Node, Nodes0),
            {noreply, State#{node => Nodes}};
        false ->
            {noreply, State}
    end;

handle_info({'DOWN', Ref, process, _Pid, _Reason}, State = #{table := Table, nodes := Nodes}) ->
    case delete_by_ref(Table, Ref) of
        {ok, Record} ->
            gen_server:abcast(sets:to_list(Nodes), name_server, {del_object, node(), Record}),
            logger:info("name_server: removed record ~p", [Record]);
        {error, not_found} ->
            logger:info("name_server: attempted removal of non-existent record", [])
    end,
    {noreply, State};

handle_info(Msg, State) ->
    case cfg:config(name_unhandled_msg, log) of
        log ->
            logger:notice("name_server info: unhandled message: ~p", [Msg]);
        {log, Level} ->
            logger:log(Level, "name_server info: unhandled message: ~p", [Msg]);
        crash ->
            logger:error("name_server info: unhandled message: ~p", [Msg]),
            exit(unhandled_message);
        silent ->
            ok
    end,
    {noreply, State}.

handle_cast({sync, Node, Objects}, State = #{table := Table, nodes := Nodes0}) ->
    Nodes = sets:add_element(Node, Nodes0),
    Foldfn = fun(Object, Acc0) ->
                     do_register(Table, Node, Object),
                     Acc0
             end,
    %% delete_by_node(Table, Node),
    ok = lists:foldl(Foldfn, ok, Objects),
    logger:info("name_server: got sync from ~p", [Node]),
    {noreply, State#{nodes => Nodes}};

handle_cast({new_node, Node}, State = #{table := Table, nodes := Nodes0}) ->
    logger:notice("name_server: new_node for ~p", [Node]),
    Nodes = sets:add_element(Node, Nodes0),
    {ok, Objects} = do_get_all(Table, any),
    gen_server:cast({name_server, Node}, {sync, node(), Objects}),
    {noreply, State#{nodes => Nodes}};

handle_cast({add_object, Node, Object}, State = #{table := Table}) ->
    do_register(Table, Node, Object),
    logger:info("name_server: registering ~p from node ~p", [Object, Node]),
    {noreply, State};

handle_cast({del_object, Node, Object}, State = #{table := Table}) ->
    do_unregister(Table, Object),
    logger:info("name_server: unregistering ~p from node ~p", [Object, Node]),
    {noreply, State};

handle_cast({node_shutdown, Node}, State) ->
    self() ! {nodedown, Node},
    {noreply, State};

handle_cast({do_sync, all}, State = #{table := Table, nodes := Nodes}) ->
    {ok, Objects} = do_get_all(Table, any),
    gen_server:abcast(sets:to_list(Nodes), name_server, {sync, node(), Objects}),
    logger:info("name_server: syncing with nodes ~p", [sets:to_list(Nodes)]),
    {noreply, State};

handle_cast({do_sync, Node}, State = #{table := Table}) ->
    {ok, Objects} = do_get_all(Table, any),
    gen_server:cast({name_server, Node}, {sync, node(), Objects}),
    {noreply, State};

handle_cast({demonitor, Ref}, State) ->
    demonitor(Ref),
    {noreply, State}; %% rpc call for remote unregisters

handle_cast(crash_me, _State) ->
    logger:error("name_server: crashing"),
    exit(induced_crash);

handle_cast(Msg, State) ->
    case cfg:config(name_unhandled_msg, log) of
        log ->
            logger:notice("name_server cast: unhandled message: ~p", [Msg]);
        {log, Level} ->
            logger:log(Level, "name_server cast: unhandled message: ~p", [Msg]);
        crash ->
            logger:error("name_server cast: unhandled message: ~p", [Msg]),
            exit(unhandled_message);
        silent ->
            ok
    end,
    {noreply, State}.

handle_call({lookup_user, Name}, _From, State = #{table := Table}) ->
    {reply, do_lookup(Table, {user, Name}), State};

handle_call({lookup_channel, Name}, _From, State = #{table := Table}) ->
    {reply, do_lookup(Table, {channel, Name}), State};

handle_call({lookup, Tuple}, _From, State = #{table := Table}) ->
    {reply, do_lookup(Table, Tuple), State};

handle_call({register, Tuple}, _From, State = #{table := Table, nodes := Nodes}) ->
    Res = do_register(Table, Tuple),
    gen_server:abcast(sets:to_list(Nodes), name_server, {add_object, node(), Tuple}),
    {reply, Res, State};

handle_call({unregister, Tuple}, _From, State = #{table := Table, nodes := Nodes}) ->
    Res = do_unregister(Table, Tuple),
    gen_server:abcast(sets:to_list(Nodes), name_server, {del_object, node(), Tuple}),
    {reply, Res, State};

handle_call({get_all, Type}, _From, State = #{table := Table}) ->
    {reply, do_get_all(Table, Type), State};

handle_call({demonitor, Ref}, _From, State) ->
    {reply, demonitor(Ref), State}; %% rpc call for remote unregisters

handle_call(mnesia_crash_me, _From, _State) ->
    logger:error("name_server: restarting"),
    exit(induced_crash);
handle_call(crash_me, _From, _State) ->
    logger:error("name_server: restarting"),
    exit(induced_crash);

handle_call(nodes, _From, State = #{nodes := Nodes}) ->
    {reply, sets:to_list(Nodes), State};

handle_call(Msg, From, State) ->
    case cfg:config(name_unhandled_msg, log) of
        log ->
            logger:notice("name_server call: unhandled message: ~p, from: ~p", [Msg, From]);
        {log, Level} ->
            logger:log(Level, "name_server call: unhandled message: ~p, from ~p", [Msg, From]);
        crash ->
            logger:error("name_server call: unhandled message: ~p, from: ~p", [Msg, From]),
            exit(unhandled_message);
        silent ->
            ok
    end,
    {noreply, State}.

code_change(_, State, _) ->
    {ok, State}.

terminate(_, #{nodes := Nodes}) ->
    gen_server:abcast(Nodes, {node_shutdown, node()}),
    logger:notice("name_server: shutting down"),
    ok.

crash_me() ->
    gen_server:cast(name_server, crash_me).

nodes(self) ->
    gen_server:call(name_server, nodes);
nodes(Node) ->
    gen_server:call({name_server, Node}, nodes).

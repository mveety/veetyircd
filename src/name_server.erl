-module(name_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3,
         terminate/2, start_link/0]).
-export([delete_by_node/1, crash_me/0]).
-record(userinfo, {name, node, pid, ref, aux = none}).
-record(chaninfo, {name, node, pid, ref, aux = none}).

do_register({user, Name, Pid}) ->
    Userinfo = #userinfo { name = Name
                         , node = node(Pid)
                         , pid = Pid
                         , ref = monitor(process, Pid)
                         , aux = none},
    {atomic, ok} = mnesia:transaction(fun() -> mnesia:write(Userinfo) end),
    ok;
do_register({channel, Name, Pid}) ->
    Chaninfo = #chaninfo { name = Name
                         , node = node(Pid)
                         , pid = Pid
                         , ref = monitor(process, Pid)
                         , aux = none},
    {atomic, ok} = mnesia:transaction(fun() -> mnesia:write(Chaninfo) end),
    ok.

do_unregister({Type, Name, _}) ->
    do_unregister({Type, Name});
do_unregister({user, Name}) ->
    do_unregister1(userinfo, Name);
do_unregister({channel, Name}) ->
    do_unregister1(chaninfo, Name).

do_unregister1(Table, Name) ->
    ThisNode = node(),
    Transop = fun() ->
                      mnesia:lock({table, Table}, write),
                      case mnesia:read({Table, Name}) of
                          [] ->
                              {error, not_found};
                          [{_, _, _, _, Ref, _}] ->
                              case node(Ref) of
                                  ThisNode ->
                                      demonitor(Ref);
                                  OtherNode ->
                                      gen_server:cast({name_server, OtherNode}, {demonitor, Ref})
                              end,
                              mnesia:delete({Table, Name})
                      end
              end,
    {atomic, Res} = mnesia:transaction(Transop),
    Res.

do_lookup({Type, Name, _}) ->
    do_lookup({Type, Name});
do_lookup({user, Name}) ->
    case mnesia:transaction(fun() -> mnesia:read({userinfo, Name}) end) of
        {atomic, [#userinfo{name = Name, pid = Pid}]} ->
            {ok, {user, Name, Pid}};
        {atomic, []} ->
            {error, no_user};
        {aborted, Reason} ->
            {error, {mnesia, Reason}}
    end;
do_lookup({channel, Name}) ->
    case mnesia:transaction(fun() -> mnesia:read({chaninfo, Name}) end) of
        {atomic, [#chaninfo{name = Name, pid = Pid}]} ->
            {ok, {channel, Name, Pid}};
        {atomic, []} ->
            {error, no_channel};
        {aborted, Reason} ->
            {error, {mnesia, Reason}}
    end.

delete_by_ref(Ref) ->
    Userlookup = fun(R) -> mnesia:index_read(userinfo, R, #userinfo.ref) end,
    Chanlookup = fun(R) -> mnesia:index_read(chaninfo, R, #chaninfo.ref) end,
    Reflookup = fun(R) ->
                        case {Userlookup(R), Chanlookup(R)} of
                            {[Userrec], []} -> {ok, Userrec};
                            {[], [Chanrec]} -> {ok, Chanrec};
                            {[], []} -> {error, not_found}
                        end
                end,
    Transfun = fun () ->
                       mnesia:lock({table, userinfo}, write),
                       mnesia:lock({table, chaninfo}, write),
                       case Reflookup(Ref) of
                           {ok, Record} ->
                               mnesia:delete_object(Record),
                               {ok, Record};
                           Res = {error, _} -> Res
                       end
               end,
    {atomic, Res} = mnesia:transaction(Transfun),
    Res.

delete_by_node(Node) ->
    Trans = fun() ->
                    mnesia:lock({table, userinfo}, write),
                    mnesia:lock({table, chaninfo}, write),
                    Users =  mnesia:match_object(#userinfo{node = Node, _ = '_'}),
                    Chans =  mnesia:match_object(#chaninfo{node = Node, _ = '_'}),
                    Userres = [mnesia:delete_object(X) || X <- Users],
                    Chanres = [mnesia:delete_object(X) || X <- Chans],
                    [{users, length(Userres)}, {channels, length(Chanres)}]
            end,
    case mnesia:transaction(Trans) of
        {atomic, Res} -> {ok, Res};
        {aborted, Reason} -> {error, Reason}
    end.

get_node_state(Node) ->
    Trans = fun() ->
                    { mnesia:match_object(#userinfo{node = Node, _ = '_'})
                    , mnesia:match_object(#chaninfo{node = Node, _ = '_'}) }
            end,
    {atomic, Res} = mnesia:transaction(Trans),
    Res.

put_node_state({Users, Chans}) ->
    Trans = fun() ->
                    mnesia:lock({table, userinfo}, write),
                    mnesia:lock({table, chaninfo}, write),
                    lists:foreach(fun(X) -> mnesia:write(X) end, Users),
                    lists:foreach(fun(X) -> mnesia:write(X) end, Chans),
                    %% lists:foreach({mnesia, write}, Users),
                    %% lists:foreach({mnesia, write}, Chans),
                    ok
            end,
    {atomic, ok} = mnesia:transaction(Trans),
    ok.

do_get_all(user) ->
    do_get_all({user, userinfo});
do_get_all(channel) ->
    do_get_all({channel, chaninfo});
do_get_all({Type, Table}) ->
    FoldFn = fun({Tbl, Name, _, Pid, _, _}, {Acc0, TargetType, Tbl}) ->
                     Id = {TargetType, Name, Pid},
                     {[Id|Acc0], TargetType, Tbl}
             end,
    Trans = fun() -> mnesia:foldl(FoldFn, {[], Type, Table}, Table) end,
    case mnesia:transaction(Trans) of
        {atomic, {Res, _, _}} -> {ok, Res};
        {aborted, Reason} -> {error, Reason}
    end.

reconnect_proc(Parent, Node, 120) ->
    logger:warning("name_server: properly lost node ~p", [Node]),
    unlink(Parent),
    exit(shutdown);
reconnect_proc(Parent, Node, N) ->
    case net_adm:ping(Node) of
        pong ->
            unlink(Parent),
            exit(shutdown);
        _ ->
            timer:sleep(60000),
            reconnect_proc(Parent, Node, N+1)
    end.

spawn_reconnect(Node) ->
    Self = self(),
    spawn_link(fun() -> reconnect_proc(Self, Node, 0) end).

start_link() ->
    gen_server:start_link({local, name_server}, ?MODULE, [], []).

init(_Args) ->
    logger:notice("name_server: starting"),
    mnesia:start(),
    case mnesia:wait_for_tables([userinfo, chaninfo, nodeinfo, permachan, account], 10000) of
        {timeout, Tables} ->
            logger:error("name_server: tables timed out. trying again. tables = ~p", [Tables]),
            mnesia:stop(),
            exit(mnesia_tables_timeout);
        _ ->
            ok
    end,
    delete_by_node(node()), %% clean out any rubbish
    ok = net_kernel:monitor_nodes(true),
    WaitTime = cfg:config(name_cleanup_wait, 1000),
    mnesia:subscribe(system),
    {ok, {state, WaitTime}}.

handle_info({nodeup, Node}, State) ->
    logger:notice("name_server: nodeup for ~p", [Node]),
    {noreply, State};

handle_info({nodedown, Node}, State = {state, WaitTime}) ->
    Self = self(),
    Cleaner = fun(Parent) ->
                      timer:sleep(WaitTime), %% let things settle down, but don't wait too long
                      Res = delete_by_node(Node),
                      logger:notice("name_server: nodedown cleaned up: node = ~p, status = ~p", [Node, Res]),
                      unlink(Parent)
              end,
    Pid = spawn_link(fun() -> Cleaner(Self) end),
    ReconPid = spawn_reconnect(Node),
    logger:notice("name_server: nodedown cleanup started on pid ~p for node ~p", [Pid, Node]),
    logger:notice("name_server: starting reconnect proc ~p for node ~p", [ReconPid, Node]),
    {noreply, State};

handle_info({'DOWN', Ref, process, _Pid, _Reason}, State) ->
    case delete_by_ref(Ref) of
        {ok, Record} ->
            logger:info("name_server: removed record ~p", [Record]);
        {error, not_found} ->
            logger:info("name_server: attempted removal of non-existent record", [])
    end,
    {noreply, State};

handle_info({mnesia_system_event, {inconsistent_database, Context, Node}}, State) ->
    logger:error("name_server: inconsistent database: context = ~p, node = ~p", [Context, Node]),
    [sys:suspend(X) || X <- [channel_server, auth_server]],
    StartTime = channel_server:get_data(start_time),
    NodeState = get_node_state(node()),
    mnesia:stop(),
    mnesia:start(),
    mnesia:wait_for_tables([userinfo, chaninfo, nodeinfo, permachan, account], infinity),
    put_node_state(NodeState),
    channel_server:put_data(start_time, StartTime),
    [sys:resume(X) || X <- [channel_server, auth_server]],
    logger:error("name_server: trying to continue"),
    {noreply, State};
    %% {stop, {restart, mnesia_inconsistent_database}, State};

handle_info({mnesia_system_event, {mnesia_fatal, _Format, _Args, _Core}}, State) ->
    logger:error("name_server: fatal mnesia event"),
    logger:error("name_server: suicide"),
    {stop, {shutdown, mnesia_fatal}, State};

handle_info({mnesia_system_event, {mnesia_user, crash_me}}, State) ->
    logger:error("name_server: crash me from mnesia!"),
    logger:error("name_server: suicide"),
    {stop, {shutdown, mnesia_crash_me}, State};

handle_info({mnesia_system_event, _Event}, State) ->
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

handle_cast({demonitor, Ref}, State) ->
    demonitor(Ref),
    {noreply, State}; %% rpc call for remote unregisters

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

handle_call({lookup_user, Name}, _From, State) ->
    {reply, do_lookup({user, Name}), State};

handle_call({lookup_channel, Name}, _From, State) ->
    {reply, do_lookup({channel, Name}), State};

handle_call({lookup, Tuple}, _From, State) ->
    {reply, do_lookup(Tuple), State};

handle_call({register, Tuple}, _From, State) ->
    {reply, do_register(Tuple), State};

handle_call({unregister, Tuple}, _From, State) ->
    {reply, do_unregister(Tuple), State};

handle_call({get_all, Type}, _From, State) ->
    {reply, do_get_all(Type), State};

handle_call({demonitor, Ref}, _From, State) ->
    {reply, demonitor(Ref), State}; %% rpc call for remote unregisters

handle_call(mnesia_crash_me, _From, _State) ->
    mnesia:stop(),
    timer:sleep(5000),
    mnesia:start(),
    mnesia:wait_for_tables([userinfo, chaninfo, nodeinfo, permachan, account], infinity),
    logger:error("name_server: restarting"),
    exit(induced_crash);

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

terminate(_, _) ->
    delete_by_node(node()),
    logger:notice("name_server: shutting down"),
    ok.

crash_me() ->
    mnesia:report_event(crash_me).

-module(channel_server).
-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3,
         terminate/2, start_link/0]).
-export([create/2, create/3, lookup/1, delete/1, update_topic/2,
         make_permanent/1, all_channels/0, topic/1, is_permachan/1, flags/1,
         update_flags/2, create_takeover/0, all_channels/1,
         update_permanent_node/2, cluster_create/2]).
-export([do_takeover/5, disown/3]).
-export([move_channels/0, takeback_channels/0, all_nodes/0,
         distribute_channels/0, save_channels/0, active_nodes/0]).
%% anyone can use these functions, but they're here for historical
%% reason
-export([put_nodedata/2, get_nodedata/1, put_data/2, get_data/1,
         put_missing_data/2]).
-include("records.hrl").

make_nodedata(Name, Value) ->
    #nodeinfo{ name = Name,
               node = node(),
               value = Value}.

put_nodedata(Name, Value) ->
    Nd = make_nodedata({Name, node()}, Value),
    {atomic, ok} = mnesia:transaction(fun() -> mnesia:write(Nd) end),
    ok.

get_nodedata(Name) ->
    Transop = fun () ->
                      case mnesia:read({nodeinfo, {Name, node()}}) of
                          [] ->
                              {error, not_found};
                          [#nodeinfo{value = Value}] ->
                              {ok, Value}
                      end
              end,
    {atomic, Res} = mnesia:transaction(Transop),
    Res.

put_data(Name, Value) ->
    Nd = make_nodedata(Name, Value),
    {atomic, ok} = mnesia:transaction(fun() -> mnesia:write(Nd) end),
    ok.

get_data(Name) ->
    Transop = fun() ->
                      case mnesia:read({nodeinfo, Name}) of
                          [] ->
                              {error, not_found};
                          [#nodeinfo{value = Value}] ->
                              {ok, Value}
                      end
              end,
    {atomic, Res} = mnesia:transaction(Transop),
    Res.

put_missing_data(Name, Value) ->
    case get_data(Name) of
        {error, not_found} ->
            put_data(Name, Value);
        {ok, _} ->
            ok
    end.

put_node_channels(Fullchans) ->
    Unqual_chans = fun({channel, Name, _Pid}, Acc0) ->
                           [{channel, Name}|Acc0]
                   end,
    Partchans = lists:foldl(Unqual_chans, [], Fullchans),
    put_nodedata(channels, Partchans),
    Fullchans.

get_node_channels() ->
    {ok, Partchans} = get_nodedata(channels),
    Partchans.

start_channel_worker(Sup, Name) ->
    {ok, Pid} = supervisor:start_child(Sup, [Name]),
    Pid.

channel(Name, SupPid) ->
    SupChildren = supervisor:which_children(SupPid),
    {_, Pid, _, _} = lists:keyfind(channel, 1, SupChildren),
    {channel, Name, Pid}.

lookup_channel(Name, Chans) ->
    case maps:is_key(Name, Chans) of
        true ->
            #{Name := ChanRec} = Chans,
            #channel{pid = Pid} = ChanRec,
            {ok, channel(Name, Pid)};
        false ->
            {error, no_channel}
    end.

lookup_channel_topic(Name, Chans) ->
    case maps:is_key(Name, Chans) of
        true ->
            #{Name := Channel} = Chans,
            {ok, Channel#channel.topic};
        false ->
            {error, no_channel}
    end.

lookup_channel_flags(Name, Chans) ->
    case maps:is_key(Name, Chans) of
        true ->
            #{Name := Channel} = Chans,
            {ok, Channel#channel.flags};
        false ->
            {error, no_channel}
    end.

do_all_channels(Chans) ->
    ToTuple = fun(#channel{name = Name, pid = Pid}) ->
                     channel(Name, Pid)
              end,
    [ToTuple(X) || X <- maps:values(Chans)].

update_chan_topic(Name, Topic, State0 = #{channels := Chans0}) ->
    #{Name := ChanRec0} = Chans0,
    Chans = Chans0#{Name => ChanRec0#channel{topic = Topic}},
    State0#{channels := Chans}.

update_chan_flags(Name, Flags, State0 = #{channels := Chans0}) ->
    #{Name := ChanRec0} = Chans0,
    Chans = Chans0#{Name => ChanRec0#channel{flags = Flags}},
    State0#{channels := Chans}.

do_create_channel(takeover, takeover, State = #{workersup := Sup}) ->
    ChanPid = start_channel_worker(Sup, takeover),
    {State, ChanPid};
do_create_channel(Name, Topic, State0 = #{workersup := Sup, channels := Chans0}) ->
    ChanPid = start_channel_worker(Sup, Name),
    MRef = monitor(process, ChanPid),
    ChanRec = #channel{name = Name,
                       topic = Topic,
                       ref = MRef,
                       pid = ChanPid,
                       flags = #{}},
    Chans = Chans0#{Name => ChanRec},
    State = State0#{channels := Chans},
    {State, ChanPid}.

do_takeover_channel(TargetPid, Name, ChanSupPid, Topic, Userflags, State0 = #{channels := Chans0}) ->
    ThisNode = node(),
    case node(TargetPid) of
        ThisNode ->
            {channel, _, ChanPid} = channel(Name, ChanSupPid),
            logger:notice("channel_server: losing channel ~p (~p -> ~p)", [Name, TargetPid, ChanPid]),
            #{Name := #channel{ref = OldMRef}} = Chans0,
            demonitor(OldMRef);
        _ ->
            ok
    end,
    MRef = monitor(process, ChanSupPid),
    ChanRec = #channel{name = Name,
                       topic = Topic,
                       ref = MRef,
                       pid = ChanSupPid,
                       flags = Userflags},
    Chans = Chans0#{Name => ChanRec},
    State = State0#{channels := Chans},
    channel_server:disown(Name, TargetPid, ChanSupPid),
    {State, ChanSupPid}.

channel_exists(Name, Chans) ->
    case names:alive() of
        false ->
            maps:is_key(Name, Chans);
        true ->
            case names:server_lookup({channel, Name}) of
                {ok, _} -> true;
                {error, _} -> false
            end
    end.

permachan_add(mnesia, ChanRec) ->
    Transfn = fun() -> mnesia:write(ChanRec) end,
    case mnesia:transaction(Transfn) of
        {atomic, _} -> ok;
        Res -> {error, Res}
    end;
permachan_add(Chandb, ChanRec) ->
    dets:insert(Chandb, ChanRec).

migrate_flags(Parent, Channel, AllFlags) ->
    FoldFn = fun(User, Flags, Acc) ->
                     case irc_auth:update_flags(User, Channel, Flags) of
                         ok -> Acc;
                         Err = _ -> Err
                     end
             end,
    true = channel_server:is_permachan(Channel), %% double-check!
    ok = maps:fold(FoldFn, ok, AllFlags),
    unlink(Parent),
    ok.

permachan_update_topic(mnesia, Name, Topic) ->
    Trans = fun() ->
                    case mnesia:read({permachan, Name}) of
                        [Chanrec0] ->
                            Chanrec = Chanrec0#permachan{topic = Topic},
                            mnesia:write(Chanrec);
                        [] ->
                            ok
                    end
            end,
    {atomic, Res} = mnesia:transaction(Trans),
    Res;
permachan_update_topic(Chandb, Name, Topic) ->
    case dets:lookup(Chandb, Name) of
        [Chanrec0] ->
            Chanrec = Chanrec0#permachan{topic = Topic},
            dets:insert(Chandb, Chanrec);
        [] ->
            ok
    end.

permachan_update_node(mnesia, Name, Node) ->
    Trans = fun() ->
                    case mnesia:read({permachan, Name}) of
                        [Chanrec0] ->
                            Chanrec = Chanrec0#permachan{node = Node},
                            mnesia:write(Chanrec);
                        [] ->
                            ok
                    end
            end,
    {atomic, Res} = mnesia:transaction(Trans),
    Res;
permachan_update_node(Chandb, Name, Topic) ->
    case dets:lookup(Chandb, Name) of
        [Chanrec0] ->
            Chanrec = Chanrec0#permachan{topic = Topic},
            dets:insert(Chandb, Chanrec);
        [] ->
            ok
    end.

is_permachan(mnesia, Name) ->
    Trans = fun() ->
                    case mnesia:read({permachan, Name}) of
                        [#permachan{}] ->
                            true;
                        [] ->
                            false
                    end
            end,
    {atomic, Res} = mnesia:transaction(Trans),
    Res;
is_permachan(Chandb, Name) ->
    case dets:lookup(Chandb, Name) of
        [#permachan{}] ->
            true;
        [] ->
            false
    end.

permachan_delete(mnesia, Name) ->
    mnesia:transaction(fun() -> mnesia:delete({permachan, Name}) end);
permachan_delete(Chandb, Name) ->
    dets:delete(Chandb, Name).

permachan_takeback_proc(Parent, Name) ->
    logger:notice("channel_server: repossessing channel ~p", [Name]),
    {ok, Channel} = names:lookup({channel, Name}),
    ThisNode = node(),
    case node(element(3,Channel)) of
        ThisNode ->
            ok;
        _ ->
            {ok, _} = channel:takeover(Channel)
    end,
    unlink(Parent),
    ok.

takeback_channel(Chan0) ->
    {ok, Chan} = names:lookup(Chan0),
    ThisNode = node(),
    ChanNode = node(element(3,Chan)),
    %% be sure to only try channels that are on other nodes
    %% should be find, but it's good to check
    case ChanNode of
        ThisNode -> ok;
        _ -> channel:takeover(Chan)
    end.

foreach(Fun, List) ->
    case cfg:config(chan_concurrent_dist, false) of
        true -> pforeach:pforeach(Fun, List);
        false -> lists:foreach(Fun, List)
    end.

gather_chans([], ChanMap) ->
    ChanMap;
gather_chans([Chan0|R], ChanMap0) ->
    {ok, Chan} = names:lookup(Chan0),
    Node = node(element(3, Chan)),
    case maps:is_key(Node, ChanMap0) of
        true ->
            #{Node := Chans0} = ChanMap0,
            Chans = [Chan|Chans0],
            ChanMap = ChanMap0#{Node => Chans},
            gather_chans(R, ChanMap);
        false ->
            ChanMap = ChanMap0#{Node => [Chan]},
            gather_chans(R, ChanMap)
    end.

do_takeback_channels_seq(Partchans) ->
    lists:foreach(fun(Chan) -> takeback_channel(Chan) end, Partchans).

do_takeback_channels_para(Partchans) ->
    ThisNode = node(),
    ChanMap = gather_chans(Partchans, #{}),
    FeFun = fun({N, Chans}) ->
                    case N of
                        ThisNode ->
                            ok;
                        _ ->
                            lists:foreach(fun(C) -> channel:takeover(C) end, Chans)
                    end
            end,
    pforeach:pforeach(FeFun, maps:to_list(ChanMap)).

do_takeback_channels() ->
    Partchans = get_node_channels(),
    case cfg:config(chan_concurrent_dist, false) of
        true -> do_takeback_channels_para(Partchans);
        false -> do_takeback_channels_seq(Partchans)
    end.

is_node_active(Node) ->
    case rpc:call(Node, erlang, whereis, [channel_server]) of
        X when is_pid(X) -> true;
        _ -> false
    end.

do_active_nodes() ->
    Foldfn = fun(Nd, Acc0) ->
                     case is_node_active(Nd) of
                         true -> [Nd|Acc0];
                         false -> Acc0
                     end
             end,
    lists:foldl(Foldfn, [], nodes()).

%% these three were nicked from somewhere. likely the mailing list.
%% who knows.
split_list(List, Max) ->
    element(1, lists:foldl(fun (E, {[Buff|Acc], C}) when C < Max ->
                                   {[[E|Buff]|Acc], C+1};
                               (E, {[Buff|Acc], _}) ->
                                   {[[E],Buff|Acc], 1};
                               (E, {[], _}) ->
                                   {[[E]], 1}
                           end, {[], 0}, List)).

part_list(List, Parts) ->
    Len0 = length(List),
    Len = case Len0 rem Parts of
              0 -> Len0;
              X -> Len0 + (Parts - X)
          end,
    Max = Len div Parts,
    split_list(List, Max).

%% pad_list(List, Len, Elem) when length(List) < Len ->
%%     pad_list(List ++ [Elem], Len, Elem);
%% pad_list(List, _, _) ->
%%     List.

takeover_to(Node, Chans) ->
    Foldfn = fun (Chan, Acc) ->
                     erpc:call(Node, channel, takeover, [Chan]),
                     Acc
             end,
    {Node, ok} = lists:foldl(Foldfn, {Node, ok}, Chans),
    ok.

part_work(Nodes, Chans) ->
    ChansList = part_list(Chans, length(Nodes)),
    lists:zip(Nodes, ChansList).

distribute_channels([]) ->
    ok;
distribute_channels(AllChans) ->
    case do_active_nodes() of
        [] -> {error, no_nodes};
        Nodes ->
            WorkList = part_work(Nodes, AllChans),
            foreach(fun({N, C}) -> takeover_to(N, C) end, WorkList),
            ok
    end.

do_move_channels(AllChans) ->
    put_node_channels(AllChans),
    distribute_channels(AllChans).

start_link() ->
    gen_server:start_link({local, channel_server}, ?MODULE, [], []).

init(_Args) ->
    logger:notice("channel_server: starting"),
    gen_server:cast(self(), initialize),
    {ok, []}.

handle_cast(initialize, _) ->
    ParentSibs = supervisor:which_children(veetyircd_sup),
    {_, ChansSup, _, _} = lists:keyfind(chans_sup, 1, ParentSibs),
    Siblings = supervisor:which_children(ChansSup),
    {_, ChanWorkSup, _, _} = lists:keyfind(channel_worker_sup, 1, Siblings),
    Detsload = fun() ->
                       {ok, Database} = cfg:config(chan_database),
                       {ok, Chandb} = dets:open_file(make_ref(), [ {auto_save, 5000}
                                                                 , {file, Database}
                                                                 , {keypos, #permachan.name}
                                                                 , {type, set}]),
                       dets:safe_fixtable(Chandb, true),
                       case cfg:config(chan_load_permanent, false) of
                           true -> 
                               CreateChannel = fun(#permachan{name = Name, topic = Topic}, N) ->
                                                       gen_server:cast(self(), {create_channel, Name, Topic}),
                                                       N+1;
                                                  (_, N) ->
                                                       N
                                               end,
                               NChans = dets:foldl(CreateChannel, 0, Chandb),
                               logger:notice("channel_server: requested creation of ~p permanent channels", [NChans]);
                           false ->
                               ok
                       end,
                       Chandb
               end,
    Mnesiaload = fun() ->
                         put_missing_data(start_time, erlang:timestamp()),
                         case cfg:config(chan_load_permanent, false) of
                             true ->
                                 Node = node(),
                                 CreateChannel =
                                     fun(#permachan{name = Name, topic = Topic, node = Nd}, {N, Nd}) ->
                                             gen_server:cast(self(), {create_channel, Name, Topic}),
                                             logger:info("channel_server: requesting of channel #~s", [Name]),
                                             {N+1, Nd};
                                        (_, St) ->
                                             St
                                     end,
                                 Transfn = fun() -> mnesia:foldl(CreateChannel, {0, Node}, permachan) end,
                                 {atomic, {NChans, _}} = mnesia:transaction(Transfn),
                                 logger:notice("channel_server: requested creation of ~p permanent channels",
                                               [NChans]);
                             false ->
                                 ok
                         end,
                         mnesia
                 end,
    State = case cfg:config(chan_allow_permanent, false) of
                true ->
                    Chandb = case cfg:config(chan_database_backend, dets) of
                                 dets -> Detsload();
                                 mnesia -> Mnesiaload()
                             end,
                    #{workersup => ChanWorkSup,
                      channels => #{},
                      permachan => true,
                      chan_db => Chandb};
                false ->
                    #{workersup => ChanWorkSup,
                      channels => #{},
                      permachan => false,
                      chan_db => none}
            end,
    {noreply, State};

handle_cast({update_topic, Name, Topic},
            State0 = #{permachan := false}) ->
    State = update_chan_topic(Name, Topic, State0),
    {noreply, State};
handle_cast({update_topic, Name, Topic},
            State0 = #{permachan := true, chan_db := Chandb}) ->
    State = update_chan_topic(Name, Topic, State0),
    permachan_update_topic(Chandb, Name, Topic),
    {noreply, State};

handle_cast({update_flags, Name, Flags}, State0) ->
    State = update_chan_flags(Name, Flags, State0),
    {noreply, State};

handle_cast({create_channel, Name, Topic}, State0 = #{channels := Chans0}) ->
    case channel_exists(Name, Chans0) of
        false ->
            {State, _} = do_create_channel(Name, Topic, State0),
            logger:notice("channel_server: channel #~s created", [Name]),
            {noreply, State};
        true ->
            case cfg:check({chan_take_back_permanent, true}) of
                true ->
                    Self = self(),
                    spawn_link(fun() -> permachan_takeback_proc(Self, Name) end),
                    {noreply, State0};
                false ->
                    {noreply, State0}
            end
    end;

handle_cast(Msg, State) ->
    case cfg:config(chan_unhandled_msg, log) of
        log ->
            logger:notice("channel_server cast: unhandled message: ~p", [Msg]);
        {log, Level} ->
            logger:log(Level, "channel_server cast: unhandled message: ~p", [Msg]);
        crash ->
            logger:error("channel_server cast: unhandled message: ~p", [Msg]),
            exit(unhandled_message);
        silent ->
            ok
    end,
    {noreply, State}.

handle_call({create_channel, Name, Topic}, _From, State0 = #{channels := Chans0}) ->
    case channel_exists(Name, Chans0) of
        false ->
            {State, ChanPid} = do_create_channel(Name, Topic, State0),
            {reply, {ok, channel(Name, ChanPid)}, State};
        true ->
            case names:alive() of
                false ->
                    {reply, {ok, lookup_channel(Name, Chans0)}, State0};
                true ->
                    {ok, Channel} = names:server_lookup({channel, Name}),
                    {reply, {ok, Channel}, State0}
            end
    end;

handle_call({lookup_channel, Name}, _From, State = #{channels := Chans}) ->
    {reply, lookup_channel(Name, Chans), State};

handle_call(all_channels, _From, State = #{channels := Chans}) ->
    {reply, {ok, do_all_channels(Chans)}, State};

handle_call({delete_channel, Name}, _From,
            State0 = #{workersup := Sup, channels := Chans0,
                      permachan := Permachan, chan_db := Chandb}) ->
    #{Name := ChanRec} = Chans0,
    names:unregister(channel(Name, ChanRec#channel.pid)),
    demonitor(ChanRec#channel.ref, [flush]),
    ok = supervisor:terminate_child(Sup, ChanRec#channel.pid),
    State = State0#{channels := maps:remove(Name, Chans0)},
    case Permachan of
        true -> permachan_delete(Chandb, Name);
        false -> ok
    end,
    {reply, ok, State};

handle_call({make_permanent, _Name}, _From, State = #{permachan := false}) ->
    {reply, ok, State};
%%% this would have been nice
%% handle_call({make_permanent, Name}, _From,
%%             State = #{channels := #{Name := ChanRec}, permachan := true, chan_db := Chandb}) ->
%%     Chandets = #permachan{name = ChanRec#channel.name,
%%                           topic = ChanRec#channel.topic,
%%                           node = node()},
%%     {channel, _, ChanPid} = channel(none, ChanRec#channel.pid),
%%     {ok, AllFlags} = channel:all_flags(ChanPid),
%%     ok =  permachan_add(Chandb, Chandets),
%%     Self = self(),
%%     spawn_link(fun() -> migrate_flags(Self, Name, AllFlags) end),
%%     {reply, ok, State};
%% handle_call({make_permanent, _Name}, _From, State = #{permachan := true}) ->
%%     {reply, {error, no_channel}, State};
handle_call({make_permanent, Name}, _From,
            State = #{channels := Chans, permachan := true, chan_db := Chandb}) ->
    case Chans of
        #{Name := ChanRec} ->
            Chandets = #permachan{name = ChanRec#channel.name,
                                  topic = ChanRec#channel.topic,
                                  node = node()},
            {channel, _, ChanPid} = channel(none, ChanRec#channel.pid),
            {ok, AllFlags} = channel:all_flags(ChanPid),
            ok =  permachan_add(Chandb, Chandets),
            Self = self(),
            spawn_link(fun() -> migrate_flags(Self, Name, AllFlags) end),
            {reply, ok, State};
        _ ->
            {reply, {error, no_channel}, State}
    end;

handle_call({is_permachan, _Name}, _From, State = #{permachan := false}) ->
    {reply, false, State};
handle_call({is_permachan, Name}, _From, State = #{permachan := true, chan_db := Chandb}) ->
    {reply, is_permachan(Chandb, Name), State};

handle_call({permanent_change_node, _Name, _Node}, _From, State = #{permachan := false}) ->
    {reply, ok, State};
handle_call({permanent_change_node, Name, Node}, _From, State = #{permachan := true, chan_db := Chandb}) ->
    case is_permachan(Chandb, Name) of
        true -> {reply, permachan_update_node(Chandb, Name, Node), State};
        _ -> {reply, {error, not_permachan}, State}
    end;

handle_call({topic, Name}, _From, State = #{channels := Chans}) ->
    {reply, lookup_channel_topic(Name, Chans), State};

handle_call({flags, Name}, _From, State = #{channels := Chans}) ->
    {reply, lookup_channel_flags(Name, Chans), State};

handle_call(stats, _From, State = #{channels := Chans}) ->
    NChans = length(maps:keys(Chans)),
    {reply, {ok, NChans}, State};

handle_call({do_takeover, TargetPid, Name, Sup, Topic, UserFlags}, _From, State0) ->
    {State, _} = do_takeover_channel(TargetPid, Name, Sup, Topic, UserFlags, State0),
    {reply, ok, State};

handle_call({disown, Name, TargetPid, ChanSupPid}, _From, State0 = #{channels := Chans0}) ->
    {channel, _, ChanPid} = channel(Name, ChanSupPid),
    logger:notice("channel_server: losing channel ~p (~p -> ~p)", [Name, TargetPid, ChanPid]),
    #{Name := #channel{ref = MRef}} = Chans0,
    demonitor(MRef),
    Chans = maps:remove(Name, Chans0),
    {reply, ok, State0#{channels := Chans}};

handle_call(save_node_data, _From, State = #{channels := Chans}) ->
    put_node_channels(do_all_channels(Chans)),
    {reply, ok, State};

handle_call({takeback_channels, Proc}, _From, State) ->
    Parent = self(),
    Takeproc = fun() ->
                       receive
                           {start, Proc} -> ok
                       end,
                       do_takeback_channels(),
                       unlink(Parent)
               end,
    {reply, {ok, spawn(Takeproc)}, State};

handle_call({move_channels, Proc}, _From, State = #{channels := Chans}) ->
    AllChans = do_all_channels(Chans),
    Parent = self(),
    Moveproc = fun() ->
                       receive
                           {start, Proc} -> ok
                       end,
                       do_move_channels(AllChans),
                       unlink(Parent)
               end,
    {reply, {ok, spawn(Moveproc)}, State};

handle_call({distribute_channels, Proc}, _From, State = #{channels := Chans}) ->
    AllChans = do_all_channels(Chans),
    Parent = self(),
    Moveproc = fun() ->
                       receive
                           {start, Proc} -> ok
                       end,
                       distribute_channels(AllChans),
                       unlink(Parent)
               end,
    {reply, {ok, spawn(Moveproc)}, State};

handle_call({chan_takeover, Chan}, _From, State) ->
    {ok, _} = channel:takeover(Chan),
    {reply, ok, State};

handle_call(active_nodes, _From, State) ->
    {reply, {ok, do_active_nodes()}, State};

handle_call(Msg, From, State) ->
    case cfg:config(chan_unhandled_msg, log) of
        log ->
            logger:notice("channel_server call: unhandled message: ~p, from: ~p", [Msg, From]);
        {log, Level} ->
            logger:log(Level, "channel_server call: unhandled message: ~p, from: ~p", [Msg, From]);
        crash ->
            logger:error("channel_server call: unhandled message: ~p, from: ~p", [Msg, From]),
            exit(unhandled_message);
        silent ->
            ok
    end,
    {noreply, State}.

handle_info({'DOWN', Ref, process, _Pid, _Reason},
            State0 = #{channels := Chans}) ->
    Pred = fun(_K, #channel{ref = R}) when R == Ref ->
                   true;
              (_, _) ->
                   false
           end,
    [#channel{name = Name}] = maps:values(maps:filter(Pred, Chans)),
    State = State0#{channels := maps:remove(Name, Chans)},
    {noreply, State};

handle_info(Msg, State) ->
    case cfg:config(chan_unhandled_msg, log) of
        log ->
            logger:notice("channel_server info: unhandled message: ~p", [Msg]);
        {log, Level} ->
            logger:log(Level, "channel_server info: unhandled message: ~p", [Msg]);
        crash ->
            logger:error("channel_server info: unhandled message: ~p", [Msg]),
            exit(unhandled_message);
        silent ->
            ok
    end,
    {noreply, State}.

code_change(_, State, _) ->
    {ok, State}.

terminate(_, _) ->
    ok.

channel_load(Nodes) ->
    GetLoad = fun(N) ->
                     {ok, NChans} = gen_server:call({channel_server, N}, stats),
                     {N, NChans}
             end,
    [GetLoad(X) || X <- Nodes].

do_cluster_create(Name, Topic) ->
    {ok, Nodes} = all_nodes(),
    ChanLoad0 = channel_load(Nodes),
    SortFn = fun({_, L0}, {_, L1}) when L0 =< L1 -> true;
                (_, _) -> false
             end,
    ChanLoad = lists:sort(SortFn, ChanLoad0),
    {Node, _} = hd(ChanLoad),
    create(Node, Name, Topic).

create(Name, Topic) ->
    gen_server:call(channel_server, {create_channel, Name, Topic}).

create(Node, Name, Topic) ->
    gen_server:call({channel_server, Node}, {create_channel, Name, Topic}).

create_takeover() ->
    gen_server:call(channel_server, {create_channel, takeover, takeover}).

cluster_create(Name, Topic) ->
    case cfg:config(chan_balance_cluster, false) of
        true -> do_cluster_create(Name, Topic);
        false -> create(Name, Topic)
    end.

lookup(Name) ->
    gen_server:call(channel_server, {lookup_channel, Name}).

delete(Name) ->
    gen_server:call(channel_server, {delete_channel, Name}).

make_permanent(Name) ->
    gen_server:call(channel_server, {make_permanent, Name}).

is_permachan(Name) ->
    gen_server:call(channel_server, {is_permachan, Name}).

update_permanent_node(Name, Node) ->
    gen_server:call(channel_server, {permanent_change_node, Name, Node}).

all_channels() ->
    gen_server:call(channel_server, all_channels).

all_channels(Node) ->
    gen_server:call({channel_server, Node}, all_channels).

%%% these functions below are really only for channels to give their state
%%% to channel_server and to fetch it on initialize. If you want this info
%%% it's best to ask the channel.

topic(Name) ->
    gen_server:call(channel_server, {topic, Name}).

flags(Name) ->
    gen_server:call(channel_server, {flags, Name}).

update_flags(Name, Flags) ->
    gen_server:cast(channel_server, {update_flags, Name, Flags}).

update_topic(Name, Topic) ->
    gen_server:cast(channel_server, {update_topic, Name, Topic}).

%% these are for takeovers

do_takeover(TargetPid, Name, Sup, Topic, Userflags) ->
    %% 60 second timeout so we can handle lots of load
    gen_server:call(channel_server, {do_takeover, TargetPid, Name, Sup, Topic, Userflags}, 60000).

disown(Name, TargetPid, ChanPid) ->
    TargetNode = node(TargetPid),
    case node() of
        TargetNode ->
            ok; %% do nothing if we're disowning our own channel
        _ ->
            gen_server:call({channel_server, TargetNode}, {disown, Name, TargetPid, ChanPid})
    end.

move_channels() ->
    Self = self(),
    {ok, Pid} = gen_server:call(channel_server, {move_channels, Self}),
    Ref = monitor(process, Pid),
    Pid ! {start, Self},
    receive
        {'DOWN', Ref, process, Pid, normal} ->
            ok;
        {'DOWN', Ref, process, Pid, Reason} ->
            {error, Reason}
    end.

distribute_channels() ->
    Self = self(),
    {ok, Pid} = gen_server:call(channel_server, {distribute_channels, Self}),
    Ref = monitor(process, Pid),
    Pid ! {start, Self},
    receive
        {'DOWN', Ref, process, Pid, normal} ->
            ok;
        {'DOWN', Ref, process, Pid, Reason} ->
            {error, Reason}
    end.

save_channels() ->
    gen_server:call(channel_server, save_node_data).

takeback_channels() ->
    %% takeback_channels can only be used if the channels were moved by
    %% move_channels. channel_server save those results and uses them for this
    %% function. do note, though, if you call this it might be using stale
    %% data. be careful.
    Self = self(),
    {ok, Pid} = gen_server:call(channel_server, {takeback_channels, self()}),
    Ref = monitor(process, Pid),
    Pid ! {start, Self},
    receive
        {'DOWN', Ref, process, Pid, normal} ->
            ok;
        {'DOWN', Ref, process, Pid, Reason} ->
            {error, Reason}
    end.

active_nodes() ->
    gen_server:call(channel_server, active_nodes).

all_nodes() ->
    {ok, OtherNodes} = active_nodes(),
    {ok, [node()|OtherNodes]}.

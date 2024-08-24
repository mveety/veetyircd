-module(conn_server).
-behaviour(gen_server).
%% otp functions
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3,
         terminate/2, start_link/0]).
%% module functions
-export([allow_conns/1]).
-include_lib("stdlib/include/ms_transform.hrl").
-record(conn, { ref
              , sock
              , pid
              , status
              , type
              , userproc
              }).

accepter(Listen, Parent, Type) ->
    {ok, Accept} = gen_tcp:accept(Listen),
    gen_tcp:controlling_process(Accept, Parent),
    gen_server:call(Parent, {accept, Type, Accept}),
    accepter(Listen, Parent, Type).

spawn_accepter(Listen, Type) ->
    Me = self(),
    AcceptPid = spawn_link(fun() -> accepter(Listen, Me, Type) end),
    AcceptPid.

do_worker_code_change(Conns, Module, OldVsn, Extra) ->
    Foldfn = fun(#conn{pid = Pid}, Acc) -> [Pid|Acc] end,
    CodeChange = fun(Pid) ->
                         sys:suspend(Pid),
                         sys:change_code(Pid, Module, OldVsn, Extra),
                         sys:resume(Pid)
                 end,
    ConnPids = ets:foldl(Foldfn, [], Conns),
    lists:foreach(CodeChange, ConnPids).

start_link() ->
    gen_server:start_link({local, conn_server}, ?MODULE, [], []).

init([]) ->
    process_flag(trap_exit, true),
    {ok, Port} = cfg:config(net_port),
    {ok, Ip} = cfg:config(net_ipaddr),
    {ok, Listen} = gen_tcp:listen(Port, [{ip, Ip}
                                        ,{active, false}
                                        ,{keepalive, true}
                                        ,{reuseaddr, true}
                                        ,{packet, line}
                                        ,binary]),
    AcceptPid = spawn_accepter(Listen, tcp),
    logger:notice("conn_server: tcp listener started on port ~p", [Port]),
    Conns = ets:new(connections, [set, {keypos, #conn.ref}]),
    State0 = #{ state => start
              , accept => true
              , ip => Ip
              , port => Port
              , listener => Listen
              , acceptpid => AcceptPid
              , conns => Conns
              , nconns => 0
              , tls_port => none
              , tls_listener => none
              , tls_acceptpid => none
             },
    State = case cfg:config(net_tls_enable, false) of
                false ->
                    State0;
                true ->
                    %% we care about their existence and want things to die here, not after a user
                    %% connects. (thanks kaitie)
                    {ok, Cacerts} = cfg:config(net_tls_cacerts),
                    {ok, Certfile} = cfg:config(net_tls_certfile),
                    {ok, Keyfile} = cfg:config(net_tls_keyfile),
                    true = filelib:is_regular(Cacerts),
                    true = filelib:is_regular(Certfile),
                    true = filelib:is_regular(Keyfile),
                    {ok, TlsPort} = cfg:config(net_tls_port),
                    {ok, TlsListen} = gen_tcp:listen(TlsPort, [{ip, Ip}, {reuseaddr, true}, {active, false}]),
                    TlsAcceptPid = spawn_accepter(TlsListen, tls),
                    logger:notice("conn_server: tls listener started on port ~p", [TlsPort]),
                    State0#{tls_port := TlsPort, tls_listener := TlsListen, tls_acceptpid := TlsAcceptPid}
            end,
    gen_server:cast(self(), initialize),
    {ok, State}.

handle_cast(initialize, State0 = #{state := start}) ->
    ParentSibs = supervisor:which_children(veetyircd_sup),
    {_, ConnsSup, _, _} = lists:keyfind(conns_sup, 1, ParentSibs),
    Siblings = supervisor:which_children(ConnsSup),
    {_, WorkerSup, _, _} = lists:keyfind(conn_worker_sup, 1, Siblings),
    State = State0#{ state => run
                   , workersup => WorkerSup
                   },
    {noreply, State};

handle_cast({connected, MRef, Userproc}, State = #{conns := Conns}) ->
    [ConnRec0] = ets:lookup(Conns, MRef),
    ConnRec = ConnRec0#conn{userproc = Userproc, status = connected},
    ets:insert(Conns, ConnRec),
    logger:info("conn_server: new connection"),
    {noreply, State};

handle_cast(Msg, State) ->
    case cfg:config(net_unhandled_msg, log) of
        log ->
            logger:notice("conn_server cast: unhandled message: ~p", [Msg]);
        {log, Level} ->
            logger:log(Level, "conn_server cast: unhandled message: ~p", [Msg]);
        crash ->
            logger:error("conn_server cast: unhandled message: ~p", [Msg]),
            exit(unhandled_message);
        silent ->
            ok
    end,
    {noreply, State}.

handle_info({'EXIT', AcceptPid, Reason}, State = #{acceptpid := AcceptPid}) ->
    {stop, Reason, State};

handle_info({'EXIT', TlsAcceptPid, Reason}, State = #{tls_acceptpid := TlsAcceptPid})->
    {stop, Reason, State};

handle_info({'DOWN', MRef, process, _Pid, _Reason}, State0 = #{conns := Conns, nconns := Nconns}) ->
    ets:delete(Conns, MRef),
    State = State0#{nconns => Nconns - 1},
    {noreply, State};

handle_info(Msg, State) ->
    case cfg:config(net_unhandled_msg, log) of
        log ->
            logger:notice("conn_server info: unhandled message: ~p", [Msg]);
        {log, Level} ->
            logger:log(Level, "conn_server info: unhandled message: ~p", [Msg]);
        crash ->
            logger:error("conn_server info: unhandled message: ~p", [Msg]),
            exit(unhandled_message);
        silent ->
            ok
    end,
    {noreply, State}.

handle_call({accept, Type, Socket}, _From,
            State0 = #{accept := true, workersup := WorkerSup,
                       conns := Conns, nconns := Nconns}) ->
    {ok, Worker} = supervisor:start_child(WorkerSup, []),
    MRef = monitor(process, Worker),
    ConnRec = #conn{ref = MRef,
                    sock = Socket,
                    pid = Worker,
                    status = starting,
                    type = Type,
                    userproc = none},
    gen_tcp:controlling_process(Socket, Worker),
    Worker ! {initialize, Type, self(), MRef, Socket},
    true = ets:insert(Conns, ConnRec),
    State = State0#{nconns => Nconns + 1},
    {reply, ok, State};

handle_call({accept, _Type, Socket}, _From, State = #{accept := false}) ->
    gen_tcp:close(Socket),
    {reply, ok, State};

handle_call(stats, _From, State) ->
    {reply, {ok, State}, State};

handle_call(worker_code_change, _From, State = #{conns := Conns}) ->
    do_worker_code_change(Conns, conn_worker, undefined, undefined),
    {reply, ok, State};

handle_call({allow_conns, Bool}, _From, State) ->
    {reply, ok, State#{accept => Bool}};

handle_call(Msg, From, State) ->
    case cfg:config(net_unhandled_msg, log) of
        log ->
            logger:notice("conn_server call: unhandled message: ~p, from: ~p", [Msg, From]);
        {log, Level} ->
            logger:log(Level, "conn_server call: unhandled message: ~p, from: ~p", [Msg, From]);
        crash ->
            logger:error("conn_server call: unhandled message: ~p, from: ~p", [Msg, From]),
            exit(unhandled_message);
        silent ->
            ok
    end,
    {noreply, State}.

code_change(OldVsn, State = #{conns := Conns, acceptpid := AcceptPid0, listener := Listener,
                              tls_acceptpid := none, tls_listener := none}, Extra) ->
    do_worker_code_change(Conns, conn_worker, OldVsn, Extra),
    unlink(AcceptPid0),
    exit(AcceptPid0, kill),
    AcceptPid = spawn_accepter(Listener, tcp),
    {ok, State#{acceptpid := AcceptPid}};
code_change(OldVsn, State = #{conns := Conns, acceptpid := AcceptPid0, listener := Listener,
                              tls_acceptpid := TlsAcceptPid0, tls_listener := TlsListener}, Extra) ->
    do_worker_code_change(Conns, conn_worker, OldVsn, Extra),
    unlink(AcceptPid0),
    unlink(TlsAcceptPid0),
    exit(AcceptPid0, kill),
    exit(TlsAcceptPid0, kill),
    AcceptPid = spawn_accepter(Listener, tcp),
    TlsAcceptPid = spawn_accepter(TlsListener, tls),
    {ok, State#{acceptpid => AcceptPid, tls_acceptpid => TlsAcceptPid}}.

terminate(_Reason, _State = #{acceptpid := AcceptPid, listener := Listener,
                             tls_acceptpid := none, tls_listener := none}) ->
    unlink(AcceptPid),
    exit(AcceptPid, kill),
    gen_tcp:close(Listener),
    ok;
terminate(_Reason, _State = #{acceptpid := AcceptPid, listener := Listener,
                              tls_acceptpid := TlsAcceptPid, tls_listener := TlsListen}) ->
    unlink(AcceptPid),
    unlink(TlsAcceptPid),
    exit(AcceptPid, kill),
    exit(TlsAcceptPid, kill),
    gen_tcp:close(Listener),
    gen_tcp:close(TlsListen),
    ok.

allow_conns(true) ->
    gen_server:call(conn_server, {allow_conns, true});
allow_conns(false) ->
    gen_server:call(conn_server, {allow_conns, false}).

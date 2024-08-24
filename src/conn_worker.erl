-module(conn_worker).
%% otp functions
-export([init/1, system_continue/3, system_terminate/4, system_code_change/4,
         system_replace_state/2, system_get_state/1]).
%% module functions
-export([start_link/0, main_loop/3]).

%% otp stuff

handle_system_msg({system, From, Request}, {Parent, Debug}, Stage, State) ->
    sys:handle_system_msg(Request, From, Parent, ?MODULE, Debug, {Stage, State}).

system_continue(Parent, Debug, {Stage, State}) ->
    ?MODULE:main_loop({Parent, Debug}, Stage, State).

system_terminate(Reason, _, _, _) ->
    exit(Reason).

system_code_change(State, _Module, _OldVsn, _Extra) ->
    {ok, State}.

system_replace_state(StateFun, State) ->
    NState = StateFun(State),
    {ok, NState, NState}.

system_get_state(State) ->
    {ok, State}.

%% program

start_link() ->
    proc_lib:start_link(?MODULE, init, [self()]).

init(Parent) ->
    Debug = sys:debug_options([]),
    proc_lib:init_ack(Parent, {ok, self()}),
    ?MODULE:main_loop({Parent, Debug}, start, none).

make_user_proc() ->
    {ok, UserProc} = user_server:create(),
    process_flag(trap_exit, true),
    link(UserProc),
    Ref = monitor(process, UserProc),
    UserProc ! {conn, Ref, self()},
    receive
        {ok, Ref, UserProc} ->
            demonitor(Ref),
            {ok, UserProc};
        {'DOWN', Ref, process, UserProc, Reason} ->
            {error, Reason}
    after
        5000 ->
            {error, timeout}
    end.

coding_fail(Format, Args) ->
    case cfg:config(user_coding_failure, log) of
        log ->
            logger:notice(Format, Args);
        {log, Level} ->
            logger:log(Level, Format, Args);
        crash ->
            logger:error(Format, Args),
            exit(irc_coding_failure);
        silent ->
            ok
    end.

sock_send(Socket = {sslsocket, _}, Data) ->
    ssl:send(Socket, Data);
sock_send(Socket, Data) ->
    gen_tcp:send(Socket, Data).

sendmsg(Socket, IrcMsg) ->
    case irc:encode(IrcMsg) of
        {ok, IrcData} when is_list(IrcData) ->
            logger:info("encoded: irc msgs ~p", [IrcData]),
            [sock_send(Socket, X) || X <- IrcData],
            ok;
        {ok, IrcData} ->
            logger:info("encoded: irc msg ~p", [IrcData]),
            sock_send(Socket, IrcData),
            ok;
        {error, Reason} ->
            coding_fail("encode error: message: ~p, reason: ~p", [IrcMsg, Reason]),
            ok
    end.

to_old_mode(tcp) -> tcp;
to_old_mode(tls) -> ssl.

mode_socket(tcp, Socket) -> Socket;
mode_socket(tls, _) -> none.

main_loop(Pinfo, start, _) ->
    receive
        {initialize, Mode, Parent, Ref, Socket} ->
            {ok, UserProc} = make_user_proc(),
            State = #{ ref => Ref
                     , parent => Parent
                     , socket => mode_socket(Mode, Socket)
                     , tcp_socket => Socket
                     , tls_socket => none
                     , userproc => UserProc
                     , mode => to_old_mode(Mode)
                     },
            ?MODULE:main_loop(Pinfo, {connect, Mode}, State);
        SysMsg = {system, _, _} ->
            handle_system_msg(SysMsg, Pinfo, start, none)
    end;

main_loop(Pinfo, {connect, tcp}, State = #{socket := Socket}) ->
    inet:setopts(Socket, [{active, true}]),
    SockRef = inet:monitor(Socket),
    ?MODULE:main_loop(Pinfo, run, State#{sockref => SockRef});

main_loop(Pinfo, {connect, tls}, State = #{tcp_socket := TcpSocket, parent := Parent,
                                         ref := Ref, userproc := UserProc}) ->
    SockRef = inet:monitor(TcpSocket),
    {ok, Cacerts} = cfg:config(net_tls_cacerts),
    {ok, Certfile} = cfg:config(net_tls_certfile),
    {ok, Keyfile} = cfg:config(net_tls_keyfile),
    {ok, TlsSocket} = ssl:handshake(TcpSocket, [{cacertfile, Cacerts},
                                                {certfile, Certfile},
                                                {keyfile, Keyfile}],
                                   60000),
    ssl:setopts(TlsSocket, [binary, {packet, line}, {keepalive, true}, {active, true}]),
    gen_server:cast(Parent, {connected, Ref, UserProc}),
    ?MODULE:main_loop(Pinfo, run, State#{sockref => SockRef, tls_socket => TlsSocket, socket => TlsSocket});

main_loop(Pinfo, run, State = #{socket := Socket, userproc := UserProc,
                                sockref := SockRef, tcp_socket := TcpSocket,
                                mode := Mode}) ->
    receive
        SysMsg = {system, _, _} ->
            handle_system_msg(SysMsg, Pinfo, run, State);
        {'EXIT', SrcPid, Reason} ->
            ?MODULE:main_loop(Pinfo, {force_quit, SrcPid, Reason}, State);
        {Mode, Socket, Data} ->
            case irc:decode(Data) of
                {ok, {ping, Arg}} ->
                    {ok, Pongmsg} = irc:encode({pong, Arg}),
                    sock_send(Socket, Pongmsg);
                {ok, IrcMsg} ->
                    logger:info("~p decoded: user msg ~p", [Mode, IrcMsg]),
                    UserProc ! IrcMsg;
                {error, Reason} ->
                    coding_fail("~p decode error: message: ~p, reason: ~p", [Mode, Data, Reason])
            end,
            ?MODULE:main_loop(Pinfo, run, State);
        {ircmultipart, IrcMsgs} ->
            [sendmsg(Socket, X) || X <- IrcMsgs],
            ?MODULE:main_loop(Pinfo, run, State);
        {verify, Rts, {ircmultipart, IrcMsgs}} ->
            [sendmsg(Socket, X) || X <- IrcMsgs],
            irc_verify:reply(Rts),
            ?MODULE:main_loop(Pinfo, run, State);
        {ircmsg, IrcMsg} ->
            sendmsg(Socket, IrcMsg),
            ?MODULE:main_loop(Pinfo, run, State);
        {verify, Rts, {ircmsg, IrcMsg}} ->
            sendmsg(Socket, IrcMsg),
            irc_verify:reply(Rts),
            ?MODULE:main_loop(Pinfo, run, State);
        {quit, Quitref, UserProc} ->
            case Mode of
                ssl -> ssl:shutdown(Socket, write);
                tcp -> gen_tcp:shutdown(Socket, write)
            end,
            ?MODULE:main_loop(Pinfo, quitting, State#{quitref => Quitref});
        {lost_sock, Quitref, UserProc} ->
            ?MODULE:main_loop(Pinfo, quitting, State#{quitref => Quitref});
        {'DOWN', SockRef, _Type, TcpSocket, _Reason} ->
            UserProc ! {lost_sock, self()},
            ?MODULE:main_loop(Pinfo, run, State);
        {tcp_closed, TcpSocket} ->
            UserProc ! {lost_sock, self()},
            ?MODULE:main_loop(Pinfo, run, State);
        Msg ->
            case cfg:config(net_unhandled_msg, log) of
                log ->
                    logger:notice("conn_worker ~p: unhandled message: ~p", [self(), Msg]),
                    ?MODULE:main_loop(Pinfo, run, State);
                {log, Level} ->
                    logger:log(Level, "conn_worker ~p: unhandled message: ~p", [self(), Msg]),
                    ?MODULE:main_loop(Pinfo, run, State);
                crash ->
                    logger:error("conn_worker ~p: unhandled message: ~p", [self(), Msg]),
                    exit(unhandled_message);
                silent ->
                    ?MODULE:main_loop(Pinfo, run, State)
            end
    end;

main_loop(_Pinfo, {force_quit, SrcPid, Reason}, #{tls_socket := Socket, mode := ssl}) ->
    logger:info("ssl conn_worker: exit: SrcPid = ~p, Reason = ~p", [SrcPid, Reason]),
    ssl:close(Socket),
    exit(Reason);

main_loop(_Pinfo, {force_quit, SrcPid, Reason}, #{tcp_socket := Socket, mode := tcp}) ->
    logger:info("conn_worker: exit: SrcPid = ~p, Reason = ~p", [SrcPid, Reason]),
    gen_tcp:close(Socket),
    exit(Reason);
main_loop(_Pinfo, quitting, #{tcp_socket := TcpSocket, tls_socket := TlsSocket, mode := Mode}) ->
    case Mode of
        tcp -> 
            gen_tcp:close(TcpSocket);
        ssl -> 
            ssl:close(TlsSocket)
    end,
    exit(shutdown).

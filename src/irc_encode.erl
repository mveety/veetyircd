-module(irc_encode).
-export([encode/1, object/1, modes/1, msg/1, valid_reply/1]).

encode(Msg) ->
    try msg(Msg) of
        Response -> {ok, Response}
    catch
        error:Reason:Stacktrace -> {error, Reason, Stacktrace}
    end.

object({user, Name, _}) -> object({user, Name});
object({channel, Name, _}) -> object({channel, Name});
object({user, Name}) -> Name;
object({userhost, Name}) -> Name;
object({userhost, Name, Pid}) when is_pid(Pid) ->
    %% this might be hackish
    case rpc:call(node(Pid), erlang, is_process_alive, [Pid]) of
        true ->
            case cfg:config(user_bullshit_node, false) of
                false ->
                    {ok, Node} = user_worker:getnode(Pid),
                    NodeName = atom_to_binary(Node);
                true ->
                    NodeName = atom_to_binary(node())
            end,
            <<Name/binary, "!", NodeName/binary>>;
        _ ->
            object({userfakehost, Name})
    end;
object({userfakehost, Name, _}) -> object({userfakehost, Name});
object({userfakehost, Name}) -> <<Name/binary,"!noname@nohost">>;
object({channel, Name}) -> <<"#", Name/binary>>;
object(Modes = {add, _}) -> modes(Modes);
object(Modes = {remove, _}) -> modes(Modes);
object(Modes = {list, _}) -> modes(Modes);
object(system) -> object({user, <<"system">>});
object(any) -> <<"*">>;
object(host) ->
    {ok, Host0} = inet:gethostname(),
    list_to_binary(Host0);
object(_) -> <<"none">>.

name({_Type, Name, _Pid}) -> Name;
name({_Type, Name}) -> Name;
name(_) -> error(bad_name_tuple).

mode(operator) -> $o;
mode(ban) -> $b;
mode(speak) -> $v;
mode(secret) -> $s;
mode(_) ->
    error(unknown_mode).

modestring([], Acc) ->
    Acc;
modestring([Mode|Rest], Acc) ->
    modestring(Rest, [mode(Mode)|Acc]).
modestring(ModeList) ->
    list_to_binary(modestring(ModeList, [])).

modes({add, ModeList}) ->
    Modestring = modestring(ModeList),
    <<"+", Modestring/binary>>;
modes({remove, ModeList}) ->
    Modestring = modestring(ModeList),
    <<"-", Modestring/binary>>;
modes({list, ModeList}) ->
    modestring(ModeList);
modes(_) ->
    error(invalid_modes).

stat(uptime) -> $u;
stat(links) -> $l;
stat(_) -> error(unknown_stat).

statstring([], Acc) ->
    Acc;
statstring([Stat|Rest], Acc) ->
    statstring(Rest, [stat(Stat)|Acc]).
stats(StatList) ->
    list_to_binary(statstring(StatList, [])).

reply0(R) -> irc_numeric:reply0(R).

reply1(privmsg) -> <<"PRIVMSG">>;
reply1(join) -> <<"JOIN">>;
reply1(part) -> <<"PART">>;
reply1(pong) -> <<"PONG">>;
reply1(ping) -> <<"PING">>;
reply1(mode) -> <<"MODE">>;
reply1(topic) -> <<"TOPIC">>;
reply1(kick) -> <<"KICK">>;
reply1(cap) -> <<"CAP">>;
reply1(R) when is_integer(R) ->
    Rs = integer_to_list(R),
    list_to_binary(Rs);
reply1(R) ->
    reply0(R).

valid_reply(R) ->
    try reply(R) of
        R0 when is_binary(R0) -> ok
    catch
        error:Reason -> {error, Reason}
    end.

reply(R) ->
    reply1(R).

name_and_version() ->
    Apps = application:loaded_applications(),
    {Server0, _, Version0} = lists:keyfind(veetyircd, 1, Apps),
    Server = atom_to_binary(Server0),
    Version = case Version0 of
                  X when is_atom(X) -> atom_to_binary(X);
                  X when is_list(X) -> list_to_binary(X);
                  X when is_binary(X) -> X;
                  _ -> error(version_format)
              end,
    {Server, Version}.

replytext(join, _) ->
    <<"">>;
replytext(part, none) ->
    <<"">>;
replytext(part, Msg) when is_binary(Msg) ->
    Msg;
replytext(part, _) ->
    <<"">>;
replytext(topic, _) ->
    <<"">>;
replytext(kick, {User, none}) ->
    Nick = object(User),
    <<Nick/binary>>;
replytext(kick, {User, Msg}) ->
    Nick = object(User),
    <<Nick/binary, " :", Msg/binary>>;

replytext(rpl_welcome, {msg, Msg, User}) ->
    Nick = object(User),
    <<Msg/binary, " ", Nick/binary>>;
replytext(rpl_welcome, User) ->
    Nick = object(User),
    Node = atom_to_binary(node()),
    <<"Welcome to veetyircd node ", Node/binary, ", ", Nick/binary, "!">>;
replytext(rpl_yourhost, _) ->
    {Server, Version} = name_and_version(),
    <<"Your host is ", Server/binary, ", running version ", Version/binary>>;
replytext(rpl_created, _) ->
    <<"This server was created 01-01-01">>;
replytext(rpl_myinfo, _) ->
    {Server, Version} = name_and_version(),
    <<Server/binary, " ", Version/binary, " none, none">>;
replytext(rpl_topic, [Chan, Topic]) ->
    Chan0 = object(Chan),
    <<Chan0/binary, " :", Topic/binary>>;
replytext(rpl_notopic, Chan) ->
    Chan0 = object(Chan),
    <<Chan0/binary, " :No topic is set">>;
replytext(rpl_namreply, {Chan, Nicks}) ->
    Chan0 = object(Chan),
    ChanName = name(Chan),
    PrefixOp = cfg:config(user_names_show_ops, true),
    Objects = case PrefixOp of
                  false ->
                      fun Objects([], Acc) ->
                              Acc;
                          Objects([H|Rest], Acc) ->
                              H0 = object(H),
                              Objects(Rest, <<Acc/binary, H0/binary, " ">>)
                      end;
                  true ->
                      fun Objects([], Acc) ->
                              Acc;
                          Objects([H|Rest], Acc) ->
                              H0 = object(H),
                              HN = name(H),
                              Prefix = case irc_auth:check_flags(HN, ChanName, [operator, owner]) of
                                           true -> <<"@">>;
                                           false -> <<"">>
                                       end,
                              Objects(Rest, <<Acc/binary, Prefix/binary, H0/binary, " ">>)
                      end
              end,
    Nicks0 = Objects(Nicks, <<"">>),
    Resp0 = <<"= ", Chan0/binary, " :", Nicks0/binary>>,
    string:trim(Resp0, both, " ");
replytext(rpl_endofnames, Chan) ->
    Chan0 = object(Chan),
    <<Chan0/binary, " :End of NAMES list">>;
replytext(rpl_motdstart, Server) ->
    <<":- ", Server/binary, " Message of the day - ">>;
replytext(rpl_motd, Line) ->
    <<":- ", Line/binary>>;
replytext(rpl_endofmotd, _) ->
    <<"End of MOTD command">>;
replytext(rpl_time, TimeStr) ->
    Host0 = object(host),
    <<Host0/binary, " :", TimeStr/binary>>;
replytext(rpl_banlist, {Chan, Banmask}) ->
    Chan0 = object(Chan),
    <<Chan0/binary, " ", Banmask/binary>>;
replytext(rpl_endofbanlist, Chan) ->
    Chan0 = object(Chan),
    <<Chan0/binary, " :End of channel ban list">>;
replytext(rpl_list, {Chan, Nuser, Topic}) ->
    Chan0 = object(Chan),
    Nuser0 = integer_to_binary(Nuser),
    <<Chan0/binary, " ", Nuser0/binary, " :", Topic/binary>>;
replytext(rpl_listend, _) ->
    <<"End of LIST">>;
replytext(rpl_statsuptime, UptimeString) ->
    <<":Server Up ", UptimeString/binary>>;
replytext(rpl_endofstats, Stats) ->
    Stats0 = stats(Stats),
    <<Stats0/binary, " :End of STATS report">>;
replytext(rpl_statslinkinfo, {Node0, Sendq, Sentmsgs,
                              Sentkb, Recvmsgs, Recvkb, Linktime}) ->
    Sendq0 = integer_to_binary(Sendq),
    Sentmsgs0 = integer_to_binary(Sentmsgs),
    Sentkb0 = integer_to_binary(Sentkb),
    Recvmsgs0 = integer_to_binary(Recvmsgs),
    Recvkb0 = integer_to_binary(Recvkb),
    Linktime0 = integer_to_binary(Linktime),
    << Node0/binary, " "
     , Sendq0/binary, " "
     , Sentmsgs0/binary, " "
     , Sentkb0/binary, " "
     , Recvmsgs0/binary, " "
     , Recvkb0/binary, " "
     , Linktime0/binary>>;
replytext(rpl_whoreply, {Chan, Node, Nick, Op}) ->
    Op0 = case Op of
              true -> <<"@">>;
              false -> <<"">>
          end,
    [User0, Host0] = string:split(atom_to_binary(Node), "@", all),
    Chan0 = object(Chan),
    << Chan0/binary, " " %% channel
     , User0/binary, " " %% username
     , Host0/binary, " " %% host
     , Host0/binary, " " %% server
     , Nick/binary, " " %% nick
     , "H", " " %% always here
     , Op0/binary, " "
     , ":0 Anonymous">>;
replytext(rpl_endofwho, Object) ->
    Object0 = object(Object),
    <<Object0/binary, " :End of WHO list">>;

replytext(err_restricted, _) ->
    <<"Your connection is restricted!">>;
replytext(err_noprivileges, _) ->
    <<"Permission Denied- You're not an IRC operator">>;
replytext(err_chanoprivsneeded, Chan) ->
    Chan0 = object(Chan),
    <<Chan0/binary, " :You're not channel operator">>;
replytext(err_nosuchchannel, Chan) ->
    Chan0 = object(Chan),
    <<Chan0/binary, " :No such channel">>;
replytext(err_bannedfromchan, Chan) ->
    Chan0 = object(Chan),
    <<Chan0/binary, " :cannot join channel (+b)">>;
replytext(err_cannotsendtochan, Chan) ->
    Chan0 = object(Chan),
    <<Chan0/binary, " :Cannot send to channel">>;
replytext(err_nosuchnick, User) ->
    User0 = object(User),
    <<User0/binary, " :No such nick/channel">>;
replytext(err_nochanmodes, Chan) ->
    Chan0 = object(Chan),
    <<Chan0/binary, " :Channel doesn't support modes">>;
replytext(err_nicknameinuse, Nick0) when is_binary(Nick0) ->
    <<Nick0/binary, " :Nickname is already in use">>;
replytext(err_nicknameinuse, Nick) when is_tuple(Nick) ->
    replytext(err_nicknameinuse, object(Nick));
replytext(err_unknownmode, _) ->
    <<":Unknown mode">>;

replytext(_, _) ->
    error(no_default_text).

msg({Reply, Arg}) ->
    Reply0 = reply(Reply),
    <<Reply0/binary, " ", Arg/binary, "\r\n">>;
msg({mode, From, Modes}) ->
    Reply0 = reply(mode),
    From0 = object(From),
    Modestr = object(Modes),
    <<":", From0/binary,
      " ", Reply0/binary,
      " ", Modestr/binary,
      "\r\n">>;
msg({Reply, From, To}) ->
    msg({Reply, From, To, replytext(Reply, To)});
msg({mode, From, To, Modes}) ->
    Reply0 = reply(mode),
    From0 = object(From),
    To0 = object(To),
    Modestr = object(Modes),
    <<Reply0/binary,
      " ", From0/binary,
      " ", Modestr/binary,
      " ", To0/binary,
      "\r\n">>;
msg({Reply, From, To, {default, Msg}}) ->
    Reply0 = reply(Reply),
    From0 = object(From),
    To0 = object(To),
    Msg0 = replytext(Reply, Msg),
    <<":", From0/binary,
      " ", Reply0/binary,
      " ", To0/binary,
      " ", Msg0/binary,
      "\r\n">>;
msg({Reply, From, To, {mfa, Mod, Fun, Args}}) ->
    Reply0 = reply(Reply),
    From0 = object(From),
    To0 = object(To),
    Msg0 = apply(Mod, Fun, Args),
    <<":", From0/binary,
      " ", Reply0/binary,
      " ", To0/binary,
      " ", Msg0/binary,
      "\r\n">>;
msg({Reply, From, To, {fn, Fun, Args}}) ->
    Reply0 = reply(Reply),
    From0 = object(From),
    To0 = object(To),
    Msg0 = apply(Fun, Args),
    <<":", From0/binary,
      " ", Reply0/binary,
      " ", To0/binary,
      " ", Msg0/binary,
      "\r\n">>;
msg({Reply, From, To, Msg}) ->
    Reply0 = reply(Reply),
    From0 = object(From),
    To0 = object(To),
    Msg0 = <<":",Msg/binary>>,
    <<":", From0/binary,
      " ", Reply0/binary,
      " ", To0/binary,
      " ", Msg0/binary,
      "\r\n">>;
msg(_) ->
    error(invalid_message).

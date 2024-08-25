-module(irc_decode).
-export([decode/1, object/1, objects/1, modes/1, parse_modes/2, modeatom/1]).

decode(Msg0) when is_list(Msg0) ->
    decode(list_to_binary(Msg0));
decode(Msg0) when is_binary(Msg0) ->
    Msg = string:chomp(Msg0),
    [Head, Tail] = case string:split(Msg, " ", leading) of
                       [H,T] -> [H, string:trim(T, leading)];
                       [H] -> [H,<<"">>]
                   end,
    try msg(Head, Tail) of
        Reply -> {ok, Reply}
    catch
        error:Reason:Stacktrace -> {error, Reason, Stacktrace}
    end.

object1(<<"#",Name/binary>>) -> {channel, Name};
object1(<<"&",Name/binary>>) -> {channel, Name};
object1(Name) ->
    case string:find(Name, "!", leading) of
        nomatch ->
            case string:find(Name, "@", leading) of
                nomatch -> {user, Name};
                _ -> none
            end;
        _ ->
            [Nick, _] = string:split(Name, "!", leading),
            {user, Nick}
    end.

object(Obj0) ->
    object1(string:trim(Obj0, both, " \t")).

objects([], Acc) ->
    lists:delete(none, Acc);
objects([H|T], Acc) ->
    NewObj = object(H),
    objects(T, Acc ++ [NewObj]).
objects(Objs0) when is_binary(Objs0) ->
    Objs = string:split(Objs0, ",", all),
    objects(Objs);
objects(Objs) when is_list(Objs) ->
    objects(Objs, []).

modeatom($o) -> {ok, operator};
modeatom($b) -> {ok, ban};
modeatom($v) -> {ok, speak};
modeatom($s) -> {ok, secret};
modeatom($i) -> {ok, invisible};
modeatom(_) ->
    {error, unknown_mode}.

parse_modes([], Acc) ->
    Acc;
parse_modes([Mode|Rest], Acc) ->
    case modeatom(Mode) of
        {ok, ModeAtom} ->
            parse_modes(Rest, [ModeAtom|Acc]);
        {error, unknown_mode} ->
            logger:notice("irc_decode: unknown mode ~c", [Mode]),
            parse_modes(Rest, Acc)
    end.
parse_modes(Modes) ->
    ModesList = binary_to_list(Modes),
    parse_modes(ModesList, []).

modes(<<"+", Rest/binary>>) ->
    {add, parse_modes(Rest)};
modes(<<"-", Rest/binary>>) ->
    {remove, parse_modes(Rest)};
modes(<<Rest/binary>>) ->
    {list, parse_modes(Rest)};
modes(Modes) when is_list(Modes) ->
    modes(list_to_binary(Modes));
modes(_) ->
    error(malformed_modestring).

statsatom($u) -> {ok, uptime};
statsatom($l) -> {ok, links};
statsatom(_) -> {error, unknown_stats}.

parse_stats([], Acc) ->
    Acc;
parse_stats([Stat|Rest], Acc) ->
    case statsatom(Stat) of
        {ok, StatAtom} ->
            parse_stats(Rest, [StatAtom|Acc]);
        {error, unknown_stats} ->
            logger:notice("irc_decode: unknown stats ~c", [Stat]),
            parse_stats(Rest, Acc)
    end.
parse_stats(Stats) ->
    StatsList = binary_to_list(Stats),
    parse_stats(StatsList, []).

stats(Stats) ->
    parse_stats(Stats).

msg(<<"PASS">>, Tail) ->
    [Pass|_] = string:split(Tail, " ", leading),
    {pass, Pass};

msg(<<"QUIT">>, Tail) ->
    {quit, case Tail of
               <<":",Msg/binary>> -> Msg;
               _ -> none
           end};

msg(<<"NICK">>, Tail) ->
    [Nick|_] = string:split(Tail, " ", leading),
    {nick, Nick};

msg(<<"USER">>, Tail) ->
    [User, R0] = string:split(Tail, " ", leading),
    [Mode, R1] = string:split(R0, " ", leading),
    [ClientNode, R2] = string:split(R1, " ", leading),
    %% Possible change to allow faster and looser clients
    %% Realname = case R2 of
    %%                <<":",Rn/binary>> -> Rn;
    %%                <<Rn/binary>> -> Rn;
    %%                _ -> none
    %%            end,
    <<":",Realname/binary>> = R2,
    {user, User, Mode, ClientNode, Realname};

msg(<<"JOIN">>, Tail) ->
    [Chanstr0|_] = string:split(Tail, " ", leading),
    Chanstr1 = string:split(Chanstr0, ",", all),
    Chans = objects(Chanstr1),
    {join, Chans, []};

msg(<<"PART">>, Tail) ->
    [Chanstr0|Msg] = string:split(Tail, " ", leading),
    Chanstr1 = string:split(Chanstr0, ",", all),
    Chans = objects(Chanstr1),
    {part, Chans, Msg};

msg(<<"PRIVMSG">>, Tail) ->
    [Victim0, R0] = string:split(Tail, " ", leading),
    Victim = object(Victim0),
    <<":",Msg/binary>> = R0,
    {privmsg, Victim, Msg};

msg(<<"PING">>, Tail) ->
    [Arg|_] = string:split(Tail, " ", leading),
    {ping, Arg};

msg(<<"PONG">>, Tail) ->
    [Arg|_] = string:split(Tail, " ", leading),
    {pong, Arg};

msg(<<"MODE">>, Tail) ->
    case string:split(Tail, " ", leading) of
        [Victim0, R0] ->
            case string:split(R0, " ", leading) of
                [Modes0, R1] ->
                    [Target0] = string:split(R1, " ", leading),
                    Victim = object(Victim0),
                    Modes = modes(Modes0),
                    Target = object(Target0),
                    {mode, Victim, Modes, Target};
                [Modes0] ->
                    Victim = object(Victim0),
                    Modes = modes(Modes0),
                    {mode, Victim, Modes, none}
            end;
        [Victim0] ->
            Victim = object(Victim0),
            {mode, Victim, none, none}
    end;

msg(<<"TOPIC">>, Tail) ->
    case string:split(Tail, " ", leading) of
        [Victim0, R0] ->
            Victim = object(Victim0),
            <<":",Msg/binary>> = R0,
            {topic, Victim, Msg};
        [Victim0] ->
            Victim = object(Victim0),
            {topic, Victim, query}
    end;

msg(<<"VERSION">>, _Tail) ->
    {version};
msg(<<"version">>, _Tail) ->
    {version};

msg(<<"NAMES">>, Tail) ->
    case string:split(Tail, " ", leading) of
        [] ->
            {names, []};
        [Chanstr0|_] ->
            Chanstr1 = string:split(Chanstr0, ",", all),
            Chans = objects(Chanstr1),
            {names, Chans}
    end;

msg(<<"LIST">>, Tail) ->
    case string:split(Tail, " ", leading) of
        [] ->
            {list, []};
        [<<"">>|_] ->
            {list, []};
        [Chanstr0|_] ->
            Chanstr1 = string:split(Chanstr0, ",", all),
            Chans = objects(Chanstr1),
            {list, Chans}
    end;

msg(<<"KICK">>, Tail) ->
    case string:split(Tail, ":", all) of
        [ChanUsers0, <<>>] ->
            [Chan0, Users0, <<"">>] = string:split(ChanUsers0, " ", all),
            Chan = object(Chan0),
            Users = objects(Users0),
            {kick, Chan, Users, none};
        [ChanUsers0, Comment] ->
            [Chan0, Users0, <<"">>] = string:split(ChanUsers0, " ", all), 
            Chan = object(Chan0),
            Users = objects(Users0),
            {kick, Chan, Users, Comment}
    end;

msg(<<"MOTD">>, _Tail) ->
    {motd};
msg(<<"motd">>, _Tail) ->
    {motd};

msg(<<"TIME">>, _Tail) ->
    {time};
msg(<<"time">>, _Tail) ->
    {time};

msg(<<"STATS">>, Tail) ->
    Stats = stats(Tail),
    {stats, Stats};
msg(<<"stats">>, Tail) ->
    msg(<<"STATS">>, Tail);

msg(<<"WHO">>, Tail) ->
    case string:split(Tail, " ", leading) of
        [Object0|_] -> {who, object(Object0)};
        _ -> error(malformed_message)
    end;

msg(<<"CAP">>, Tail) ->
    case string:split(Tail, " ", leading) of
        [<<"LS">>|Rest] -> {cap, ls, Rest};
        [<<"END">>|_Rest] -> {cap, endcap};
        X -> {cap, {other, X}}
    end;

msg(_Cmd, _Tail) ->
    error(unknown_message).

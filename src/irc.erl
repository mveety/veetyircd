-module(irc).
-export([decode/1, encode/1, encode_object/1, decode_object/1, modes/1, decode_modes/1]).

coding_fail(Format, Args) ->
    case cfg:config(irc_coding_stacktrace, silent) of
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

decode(Msg) ->
    logger:info("decode: irc msg ~p", [Msg]),
    case irc_decode:decode(Msg) of
        {error, Reason, Stacktrace} ->
            coding_fail("irc: decode fail: message = ~p, reason = ~p, stacktrace = ~p",
                        [Msg, Reason, Stacktrace]),
            {error, Reason};
        R -> R
    end.

encode(Msg) ->
    logger:info("encode: user msg ~p", [Msg]),
    case irc_encode:encode(Msg) of
        {error, Reason, Stacktrace} ->
            coding_fail("irc: encode fail: message = ~p, reason = ~p, stacktrace = ~p",
                        [Msg, Reason, Stacktrace]),
            {error, Reason};
        R -> R
    end.

encode_object(Object) ->
    irc_encode:object(Object).

decode_object(Object) ->
    irc_decode:object(Object).

modes(Modes) ->
    irc_encode:modes(Modes).

decode_modes(Modestring) ->
    irc_decode:modes(Modestring).

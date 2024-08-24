-module(veetyircd).
-behaviour(application).
-export([start/2, prep_stop/1, stop/1, start_link/0, version_info/0,
         version/0, version_string/0]).

start(_Type, _Args) ->
    ok = cfg:check(), % this one checks the env vars against cfg:defs()
    case cfg:check({start, true}) of
        true ->
            logger:notice("starting ~s", [version_string()]),
            ok = start_mnesia(),  %% better safe than sorry
            veetyircd_sup:start_link();
        false -> ok
    end.

start_link() ->
    veetyircd_sup:start_link().

prep_stop(State) ->
    logger:notice("shutting down veetyircd"),
    conn_server:allow_conns(false),
    State.

stop(_State) ->
    name_server:delete_by_node(node()),
    ok.

start_mnesia() ->
    case cfg:or_check([ {name_server, enabled}
                      , {auth, enabled}
                      , {auth_server, mnesia}
                      , {chan_database_backend, mnesia}
                      , {node_server, enabled}]) of
        true ->
            mnesia:wait_for_tables([userinfo, chaninfo, nodeinfo, permachan, account], infinity),
            ok;
        false -> ok
    end.

version_info() ->
    Appfilter = fun({veetyircd, _Description, _Version}) -> true;
                   (_) -> false
                end,
    Apps = application:loaded_applications(),
    [{veetyircd, _, IrcdVersion}] = lists:filter(Appfilter, Apps),
    [{erts, erlang:system_info(version)},
     {otp, erlang:system_info(otp_release)},
     {veetyircd, IrcdVersion}].

version() ->
    version_info().

version_string() ->
    [{erts, ErtsVersion},
     {otp, OtpVersion},
     {veetyircd, IrcdVersion}] = version_info(),
    ErtsVersion0 = list_to_binary(ErtsVersion),
    OtpVersion0 = list_to_binary(OtpVersion),
    IrcdVersion0 = list_to_binary(IrcdVersion),
    << "veetyircd ", IrcdVersion0/binary
     , " ("
     , "Erlang/OTP ", OtpVersion0/binary
     , ", "
     ,  "erts-", ErtsVersion0/binary
     , ")">>.

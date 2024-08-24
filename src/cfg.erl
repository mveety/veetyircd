-module(cfg).
-export([defs/0, check/0]).
-export([config/1, config/2, config_check/1, config_return/3,
         or_config_check/1, or_config_return/3, check/1, or_check/1]).

%% these guys are a first pass check on the config to make sure we don't
%% screw it up. (this is more or less dead. superceded by adding defaults.
%% still kinda okay i guess. doesn't really hurt anything.)
defs() ->
    %% {variable, type}
    LogLevels = {atom, [alert, critical, debug, emergency, error, warning, notice, info]},
    LogType = [{atom, [crash, log, silent]}, {tuple, 2, {{atom, [log]}, LogLevels}}],
    AuthFailType = [LogType, {tuple, 2, {{tuple, 2, {{atom, [log]}, LogLevels}}, {atom, [state]}}}],
    Hashes = {atom, [sha, sha224, sha256, sha384, sha512, sha3_224, sha3_256, sha3_384, sha3_512,
                     blake2b, blake2s, md5, md4, ripemd160]},
    WelMsgType = [{atom, [none]}, binary, list, {tuple, 2, {[binary, list], {atom, [user]}}}],
    [ {start, boolean}
    , {net, {atom, [enabled, disabled]}}
    , {net_ipaddr, {tuple, 4, {integer, integer, integer, integer}}}
    , {net_port, integer}
    , {net_tls_enable, boolean}
    , {net_tls_port, integer}
    , {net_tls_cacerts, list}
    , {net_tls_certfile, list}
    , {net_tls_keyfile, list}
    , {net_unhandled_msg, LogType}
    , {name_server, {atom, [enabled, disabled, experimental]}}
    , {name_unhandled_msg, LogType}
    , {name_cache, {atom, [disabled, map, list]}}
    , {name_cache_max, integer}
    , {name_cleanup_wait, integer}
    , {name_exp_resync_time, integer}
    , {name_exp_seed_nodes, list}
    , {chan_create_missing, boolean}
    , {chan_allow_permanent, boolean}
    , {chan_load_permanent, boolean}
    , {chan_take_back_permanent, boolean}
    , {chan_database_backend, {atom, [dets, mnesia]}}
    , {chan_database, list}
    , {chan_send_join_names, boolean}
    , {chan_unhandled_msg, LogType}
    , {chan_gc_empty_channels, boolean}
    , {chan_broadcast_workers, integer}
    , {chan_concurrent_dist, boolean}
    , {chan_balance_cluster, boolean}
    , {auth, {atom, [enabled, disabled]}}
    , {auth_server, {atom, [dets, mnesia]}}
    , {auth_policy, {atom, [open, verify, closed]}}
    , {auth_hashinfo, {tuple, 2, {Hashes, integer}}}
    , {auth_database, list}
    , {auth_failure, AuthFailType}
    , {auth_unhandled_msg, LogType}
    , {user_error_spurious_modes, boolean}
    , {user_coding_failure, LogType}
    , {user_unhandled_msg, LogType}
    , {user_bullshit_node, boolean}
    , {user_names_show_ops, boolean}
    , {user_welcome_message, WelMsgType}
    , {user_print_login_motd, boolean}
    , {user_timezone, {atom, [utc, local]}}
    , {user_uptime, {atom, [node, cluster]}}
    , {user_kick_old_session, boolean}
    , {data_store_motd, boolean}
    , {data_motd_file, list}
    , {data_unhandled_msg, LogType}
    , {irc_coding_stacktrace, LogType}
    , {bots, {atom, [enabled, disabled]}}
    , {bots_authserv, {atom, [enabled, disabled]}}
    , {bots_authserv_allow_registrations, boolean}
    , {bots_echobot, {atom, [enabled, disabled]}}
    , {bots_opserv, {atom, [enabled, disabled]}}
    ].

check() ->
    EnvVars = application:get_all_env(veetyircd),
    EnvDefs = defs(),
    case cfg_check:member_check(EnvVars, EnvDefs) of
        Err = {error, _} ->
            Err;
        ok ->
            cfg_check:type_check(EnvDefs)
    end.

config(Name) ->
    application:get_env(veetyircd, Name).

config(Name, Default) ->
    application:get_env(veetyircd, Name, Default).

do_check({Name, Value}) ->
    case config(Name) of
        {ok, Value} -> true;
        _ -> false
    end;
do_check({Name, is_not, Value}) ->
    case config(Name) of
        {ok, Value} -> false;
        _ -> true
    end.

do_checks([]) ->
    true;
do_checks([CT|Rest]) ->
    case do_check(CT) of
        true -> do_checks(Rest);
        false -> false
    end.

do_or_checks([]) ->
    false;
do_or_checks([CT|Rest]) ->
    case do_check(CT) of
        false -> do_or_checks(Rest);
        true -> true
    end.

config_check(CT) when is_tuple(CT) ->
    do_check(CT);
config_check(CTL) when is_list(CTL) ->
    do_checks(CTL);
config_check(_) ->
    error(bad_config_tuple).

or_config_check(CT) when is_tuple(CT) ->
    do_or_checks([CT]);
or_config_check(CTL) when is_list(CTL) ->
    do_or_checks(CTL);
or_config_check(_) ->
    error(bad_config_tuple).

check(Arg) -> config_check(Arg).
or_check(Arg) -> or_config_check(Arg).

config_return(CT, True, False) ->
    case config_check(CT) of
        true -> True;
        false -> False
    end.

or_config_return(CT, True, False) ->
    case or_config_check(CT) of
        true -> True;
        false -> False
    end.

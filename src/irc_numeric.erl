-module(irc_numeric).
-export([reply/1, reply0/1]).

reply(R) ->
    L = binary_to_list(reply0(R)),
    list_to_integer(L).

%% names for numericals

reply0(rpl_welcome) -> <<"001">>;
reply0(rpl_yourhost) -> <<"002">>;
reply0(rpl_created) -> <<"003">>;
reply0(rpl_myinfo) -> <<"004">>;
reply0(rpl_bounce) -> <<"005">>;
reply0(rpl_away) -> <<"301">>;
reply0(rpl_userhost) -> <<"302">>;
reply0(rpl_ison) -> <<"303">>;
reply0(rpl_unaway) -> <<"305">>;
reply0(rpl_nowaway) -> <<"306">>;
reply0(rpl_whoisuser) -> <<"311">>;
reply0(rpl_whoisserver) -> <<"312">>;
reply0(rpl_whoisoperator) -> <<"313">>;
reply0(rpl_whoisidle) -> <<"317">>;
reply0(rpl_endofwhois) -> <<"318">>;
reply0(rpl_whoischannels) -> <<"319">>;
reply0(rpl_whowasuser) -> <<"314">>;
reply0(rpl_endofwhowas) -> <<"369">>;
reply0(rpl_list) -> <<"322">>;
reply0(rpl_listend) -> <<"323">>;
reply0(rpl_uniqopis) -> <<"325">>;
reply0(rpl_channelmodeis) -> <<"324">>;
reply0(rpl_notopic) -> <<"331">>;
reply0(rpl_topic) -> <<"332">>;
reply0(rpl_inviting) -> <<"341">>;
reply0(rpl_summoning) -> <<"342">>;
reply0(rpl_invitelist) -> <<"346">>;
reply0(rpl_endofinvitelist) -> <<"347">>;
reply0(rpl_exceptlist) -> <<"348">>;
reply0(rpl_endofexceptlist) -> <<"349">>;
reply0(rpl_version) -> <<"351">>;
reply0(rpl_whoreply) -> <<"352">>;
reply0(rpl_endofwho) -> <<"315">>;
reply0(rpl_namreply) -> <<"353">>;
reply0(rpl_endofnames) -> <<"366">>;
reply0(rpl_links) -> <<"364">>;
reply0(rpl_endoflinks) -> <<"365">>;
reply0(rpl_banlist) -> <<"367">>;
reply0(rpl_endofbanlist) -> <<"368">>;
reply0(rpl_info) -> <<"371">>;
reply0(rpl_endofinfo) -> <<"374">>;
reply0(rpl_motdstart) -> <<"375">>;
reply0(rpl_motd) -> <<"372">>;
reply0(rpl_endofmotd) -> <<"376">>;
reply0(rpl_youreoper) -> <<"381">>;
reply0(rpl_rehashing) -> <<"382">>;
reply0(rpl_youreservice) -> <<"383">>;
reply0(rpl_time) -> <<"391">>;
reply0(rpl_userstart) -> <<"392">>;
reply0(rpl_users) -> <<"393">>;
reply0(rpl_endofusers) -> <<"394">>;
reply0(rpl_nousers) -> <<"395">>;
%%% skipping trace*. they don't make sense here
reply0(rpl_statslinkinfo) -> <<"211">>;
reply0(rpl_statscommands) -> <<"212">>;
reply0(rpl_endofstats) -> <<"219">>;
reply0(rpl_statsuptime) -> <<"242">>;
reply0(rpl_statsoline) -> <<"243">>;
reply0(rpl_umodeis) -> <<"221">>;
reply0(rpl_servlist) -> <<"234">>;
reply0(rpl_servlistend) -> <<"235">>;
reply0(rpl_luserclient) -> <<"251">>;
reply0(rpl_luserop) -> <<"252">>;
reply0(rpl_luserunknown) -> <<"253">>;
reply0(rpl_luserchannels) -> <<"254">>;
reply0(rpl_luserme) -> <<"255">>;
reply0(rpl_adminme) -> <<"256">>;
reply0(rpl_adminloc1) -> <<"257">>;
reply0(rpl_adminloc2) -> <<"258">>;
reply0(rpl_adminemail) -> <<"259">>;
reply0(rpl_tryagain) -> <<"263">>;

%% errors

reply0(err_nosuchnick) -> <<"401">>;
reply0(err_nosuchserver) -> <<"402">>;
reply0(err_nosuchchannel) -> <<"403">>;
reply0(err_cannotsendtochan) -> <<"404">>;
reply0(err_toomanychannels) -> <<"405">>;
reply0(err_wasnosuchnick) -> <<"406">>;
reply0(err_toomanytargets) -> <<"407">>;
reply0(err_nosuchservice) -> <<"408">>;
reply0(err_noorigin) -> <<"409">>;
reply0(err_norecipient) -> <<"411">>;
reply0(err_notexttosend) -> <<"412">>;
reply0(err_notoplevel) -> <<"413">>;
reply0(err_wildtoplevel) -> <<"414">>;
reply0(err_badmask) -> <<"415">>;
reply0(err_unknowncommand) -> <<"421">>;
reply0(err_nomotd) -> <<"422">>;
reply0(err_noadmininfo) -> <<"423">>;
reply0(err_fileerror) -> <<"424">>;
reply0(err_nonicknamegiven) -> <<"431">>;
reply0(err_erroneousnickname) -> <<"432">>;
reply0(err_nicknameinuse) -> <<"433">>;
reply0(err_nickcollision) -> <<"436">>;
reply0(err_unavailresource) -> <<"437">>;
reply0(err_usernotinchannel) -> <<"441">>;
reply0(err_notonchannel) -> <<"442">>;
reply0(err_useronchannel) -> <<"443">>;
reply0(err_nologin) -> <<"444">>;
reply0(err_summondisabled) -> <<"445">>;
reply0(err_userdisabled) -> <<"446">>;
reply0(err_notregistered) -> <<"451">>;
reply0(err_needmoreparams) -> <<"461">>;
reply0(err_alreadyregistered) -> <<"462">>;
reply0(err_nopermforhost) -> <<"463">>;
reply0(err_passwdmismatch) -> <<"464">>;
reply0(err_yourebannedcreep) -> <<"465">>;
reply0(err_youwillbebanned) -> <<"466">>;
reply0(err_keyset) -> <<"467">>;
reply0(err_channelisfull) -> <<"471">>;
reply0(err_unknownmode) -> <<"472">>;
reply0(err_inviteonlychan) -> <<"473">>;
reply0(err_bannedfromchan) -> <<"474">>;
reply0(err_badchannelkey) -> <<"475">>;
reply0(err_badchanmask) -> <<"476">>;
reply0(err_nochanmodes) -> <<"477">>;
reply0(err_banlistfull) -> <<"478">>;
reply0(err_noprivileges) -> <<"481">>;
reply0(err_chanoprivsneeded) -> <<"482">>;
reply0(err_cantkillserver) -> <<"483">>;
reply0(err_restricted) -> <<"484">>;
reply0(err_uniqopprivsneeded) -> <<"485">>;
reply0(err_nooperhost) -> <<"491">>;
reply0(err_umodeunknownflag) -> <<"501">>;
reply0(err_usersdontmatch) -> <<"502">>;

reply0(_) -> error(unknown_reply).

-module(sm_SUITE).
-compile(export_all).

-include_lib("exml/include/exml.hrl").
-include_lib("escalus/include/escalus.hrl").
-include_lib("common_test/include/ct.hrl").

-define(MOD_SM, mod_stream_management).
-define(CONSTRAINT_CHECK_TIMEOUT, 5000).

-import(vcard_update, [discard_vcard_update/1,
                       has_mod_vcard_xupdate/0,
                       server_string/1]).
-import(escalus_stanza, [setattr/3]).

-define(SHORT_RESUME_TIMEOUT, 5).
-define(SMALL_SM_BUFFER, 3).

%%--------------------------------------------------------------------
%% Suite configuration
%%--------------------------------------------------------------------

all() ->
    [{group, parallel},
     {group, parallel_manual_ack_freq_1},
     server_requests_ack_freq_2
     ].

groups() ->
    [{parallel, [parallel], parallel_test_cases()},
     {parallel_manual_ack_freq_1, [parallel], parallel_manual_ack_test_cases()},
     {manual_ack_freq_long_session_timeout, [parallel], [preserve_order]}
    ].

parallel_test_cases() ->
    [server_announces_sm,
     server_enables_sm_before_session,
     server_enables_sm_after_session,
     server_returns_failed_after_start,
     server_returns_failed_after_auth,
     server_enables_resumption,
     basic_ack,
     h_ok_before_session,
     h_ok_after_session_enabled_before_session,
     h_ok_after_session_enabled_after_session,
     h_ok_after_a_chat,
     resend_unacked_on_reconnection,
     session_established,
     wait_for_resumption,
     resume_session,
     resume_session_with_wrong_h_does_not_leak_sessions,
     resume_session_with_wrong_sid_returns_item_not_found,
     resume_session_with_wrong_namespace_is_a_noop,
     resume_dead_session_results_in_item_not_found,
     aggressively_pipelined_resume
    ].

parallel_manual_ack_test_cases() ->
    [client_acks_more_than_sent,
     too_many_unacked_stanzas,
     resend_unacked_after_resume_timeout,
     resume_session_state_send_message,
     resume_session_state_stop_c2s,
     server_requests_ack_after_session,
     resend_more_offline_messages_than_buffer_size,
     server_requests_ack
     ].


suite() ->
    escalus:suite().

%%--------------------------------------------------------------------
%% Init & teardown
%%--------------------------------------------------------------------

init_per_suite(Config) ->
    NewConfig1 = escalus_ejabberd:setup_option(ack_freq(never), Config),
    NewConfig = escalus_ejabberd:setup_option(buffer_max(?SMALL_SM_BUFFER), NewConfig1),
    NewConfigWithSM = escalus_users:update_userspec(NewConfig, alice, stream_management, true),
    escalus:init_per_suite(NewConfigWithSM).

end_per_suite(Config) ->
    NewConfig = escalus_ejabberd:reset_option(ack_freq(never), Config),
    NewConfig1 = escalus_ejabberd:reset_option(buffer_max(?SMALL_SM_BUFFER), NewConfig),
    escalus_fresh:clean(),
    escalus:end_per_suite(NewConfig1).

init_per_group(manual_ack_freq_long_session_timeout, Config) ->
    true = escalus_ejabberd:rpc(?MOD_SM, set_ack_freq, [1]),
    escalus_users:update_userspec(Config, alice, manual_ack, true);
init_per_group(parallel_manual_ack_freq_1, Config) ->
    true = escalus_ejabberd:rpc(?MOD_SM, set_ack_freq, [1]),
    escalus_ejabberd:rpc(?MOD_SM, set_resume_timeout, [?SHORT_RESUME_TIMEOUT]),
    escalus_users:update_userspec(Config, alice, manual_ack, true);
init_per_group(_GroupName, Config) ->
    Config.

end_per_group(manual_ack_freq_long_session_timeout, Config) ->
    true = escalus_ejabberd:rpc(?MOD_SM, set_ack_freq, [never]),
    Config;
end_per_group(parallel_manual_ack, Config) ->
    true = escalus_ejabberd:rpc(?MOD_SM, set_ack_freq, [never]),
    escalus_ejabberd:rpc(?MOD_SM, set_resume_timeout, [600]),
    Config;
end_per_group(_GroupName, Config) ->
    Config.

init_per_testcase(server_requests_ack_freq_2, Config) ->
    true = escalus_ejabberd:rpc(?MOD_SM, set_ack_freq, [2]),
    Config;
init_per_testcase(CaseName, Config) ->
    escalus:init_per_testcase(CaseName, Config).

end_per_testcase(server_requests_ack_freq_2, Config) ->
    true = escalus_ejabberd:rpc(?MOD_SM, set_ack_freq, [never]),
    Config;
end_per_testcase(CaseName, Config) ->
    escalus:end_per_testcase(CaseName, Config).

%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------

server_announces_sm(Config) ->
    AliceSpec = given_fresh_spec(Config, alice),
    {ok, #client{props = Props}, Features} = escalus_connection:start(AliceSpec,
                                                                      [start_stream]),
    true = escalus_session:can_use_stream_management(Props, Features).


server_enables_sm_before_session(Config) ->
    AliceSpec = given_fresh_spec(Config, alice),
    Steps = connection_steps_to_enable_stream_mgmt(after_bind),
    {ok, _, _} = escalus_connection:start(AliceSpec, Steps).

server_enables_sm_after_session(Config) ->
    AliceSpec = given_fresh_spec(Config, alice),
    Steps = connection_steps_to_enable_stream_mgmt(after_session),
    {ok, _, _} = escalus_connection:start(AliceSpec, Steps).

server_returns_failed_after_start(Config) ->
    server_returns_failed(Config, []).

server_returns_failed_after_auth(Config) ->
    server_returns_failed(Config, [authenticate]).

server_enables_resumption(Config) ->
    AliceSpec = given_fresh_spec(Config, alice),
    %% Assert matches {ok, _, _, _}
    Steps = connection_steps_to_enable_stream_resumption(),
    {ok, Alice, _} = escalus_connection:start(AliceSpec, Steps),
    escalus_connection:stop(Alice).

server_returns_failed(Config, ConnActions) ->
    AliceSpec = given_fresh_spec(Config, alice),
    {ok, Alice, _} = escalus_connection:start(AliceSpec,
                                                 [start_stream,
                                                  stream_features,
                                                  maybe_use_ssl]
                                                 ++ ConnActions),
    escalus_connection:send(Alice, escalus_stanza:enable_sm()),
    escalus:assert(is_sm_failed, [<<"unexpected-request">>],
                   escalus_connection:get_stanza(Alice, enable_sm_failed)).


basic_ack(Config) ->
    AliceSpec = given_fresh_spec(Config, alice),
    Steps = connection_steps_to_enable_stream_mgmt(after_session),
    {ok, Alice, _} = escalus_connection:start(AliceSpec, Steps),
    escalus_connection:send(Alice, escalus_stanza:roster_get()),
    escalus:assert(is_roster_result,
                   escalus_connection:get_stanza(Alice, roster_result)),
    escalus_connection:send(Alice, escalus_stanza:sm_request()),
    escalus:assert(is_sm_ack,
                   escalus_connection:get_stanza(Alice, stream_mgmt_ack)).

%% Test that "h" value is valid when:
%% - SM is enabled *before* the session is established
%% - <r/> is sent *before* the session is established
h_ok_before_session(Config) ->
    AliceSpec = given_fresh_spec(Config, alice),
    Steps = connection_steps_to_enable_stream_mgmt(after_bind),
    {ok, Alice, _} = escalus_connection:start(AliceSpec,
                                                 Steps),
    escalus_connection:send(Alice, escalus_stanza:sm_request()),
    escalus:assert(is_sm_ack, [0],
                   escalus_connection:get_stanza(Alice, stream_mgmt_ack)).

%% Test that "h" value is valid when:
%% - SM is enabled *before* the session is established
%% - <r/> is sent *after* the session is established
h_ok_after_session_enabled_before_session(Config) ->
    AliceSpec = given_fresh_spec(Config, alice),
    Steps = connection_steps_to_enable_stream_mgmt(after_bind) ++ [session],
    {ok, Alice, _} = escalus_connection:start(AliceSpec, Steps),
    escalus_connection:send(Alice, escalus_stanza:sm_request()),
    escalus:assert(is_sm_ack, [1],
                   escalus_connection:get_stanza(Alice, stream_mgmt_ack)).

%% Test that "h" value is valid when:
%% - SM is enabled *after* the session is established
%% - <r/> is sent *after* the session is established
h_ok_after_session_enabled_after_session(Config) ->
    AliceSpec = given_fresh_spec(Config, alice),
    Steps = connection_steps_to_enable_stream_mgmt(after_session),
    {ok, Alice, _} = escalus_connection:start(AliceSpec, Steps),
    escalus_connection:send(Alice, escalus_stanza:roster_get()),
    escalus:assert(is_roster_result,
                   escalus_connection:get_stanza(Alice, roster_result)),
    escalus_connection:send(Alice, escalus_stanza:sm_request()),
    escalus:assert(is_sm_ack, [1],
                   escalus_connection:get_stanza(Alice, stream_mgmt_ack)).

%% Test that "h" value is valid after exchanging a few messages.
h_ok_after_a_chat(ConfigIn) ->
    Config = escalus_users:update_userspec(ConfigIn, alice,
                                           stream_management, true),
    escalus:fresh_story(Config, [{alice,1}, {bob,1}], fun(Alice, Bob) ->
        NDiscarded = discard_vcard_update(Alice),
        escalus:send(Alice, escalus_stanza:chat_to(Bob, <<"Hi, Bob!">>)),
        escalus:assert(is_chat_message, [<<"Hi, Bob!">>],
                       escalus:wait_for_stanza(Bob)),
        escalus:send(Bob, escalus_stanza:chat_to(Alice, <<"Hi, Alice!">>)),
        escalus:assert(is_chat_message, [<<"Hi, Alice!">>],
                       escalus:wait_for_stanza(Alice)),
        escalus:send(Bob, escalus_stanza:chat_to(Alice, <<"How's life?">>)),
        escalus:assert(is_chat_message, [<<"How's life?">>],
                       escalus:wait_for_stanza(Alice)),
        escalus:send(Alice, escalus_stanza:chat_to(Bob, <<"Pretty !@#$%^$">>)),
        escalus:assert(is_chat_message, [<<"Pretty !@#$%^$">>],
                       escalus:wait_for_stanza(Bob)),
        escalus:send(Alice, escalus_stanza:sm_request()),
        escalus:assert(is_sm_ack, [3], escalus:wait_for_stanza(Alice)),
        %% Ack, so that unacked messages don't go into offline store.
        escalus:send(Alice, escalus_stanza:sm_ack(3 + NDiscarded))
    end).

client_acks_more_than_sent(Config) ->
    AliceSpec = given_fresh_spec(Config, alice),
    {ok, Alice, _} = escalus_connection:start(AliceSpec),
    escalus:send(Alice, escalus_stanza:sm_ack(5)),
    escalus:assert(is_stream_error, [<<"policy-violation">>,
                                     <<"h attribute too big">>],
                   escalus:wait_for_stanza(Alice)).

too_many_unacked_stanzas(Config) ->
    %escalus:story(Config, [{alice,1}, {bob,1}], fun(Alice, Bob) ->
    {Bob, _} = given_fresh_user(Config, bob),
    {Alice, _} = given_fresh_user(Config, alice),
    escalus:wait_for_stanza(Alice), %% wait for ack request
    Msg = escalus_stanza:chat_to(Alice, <<"Hi, Alice!">>),
    [escalus:send(Bob, Msg) || _ <- lists:seq(1,?SMALL_SM_BUFFER)],
    escalus:wait_for_stanzas(Alice, ?SMALL_SM_BUFFER * 2), % messages and ack requests
    escalus:assert(is_stream_error, [<<"resource-constraint">>,
                                     <<"too many unacked stanzas">>],
                   %% wait for deffered buffer check
                   escalus:wait_for_stanza(Alice, ?CONSTRAINT_CHECK_TIMEOUT + 1000)).

server_requests_ack(Config) ->
    server_requests_ack(Config, 1).

server_requests_ack(Config, N) ->
    {Bob, _} = given_fresh_user(Config, bob),
    {Alice, _} = given_fresh_user(Config, alice),
    %% ack request after initial presence
    maybe_assert_ack_request(1, N, Alice),
    StanzasRec = maybe_discard_vcard_update(1, N, Alice),
    ct:print("discarded"),
    escalus:send(Bob, escalus_stanza:chat_to(Alice, <<"Hi, Alice!">>)),
    escalus:assert(is_chat_message, [<<"Hi, Alice!">>],
                   escalus:wait_for_stanza(Alice)),
    maybe_assert_ack_request(StanzasRec + 1, N, Alice).

maybe_assert_ack_request(StanzasRec, AckRequests, Alice) ->
    ct:print("StanzasRec: ~p, AckRequests: ~p", [StanzasRec, AckRequests]),
    case StanzasRec rem AckRequests of
        0 ->
            escalus:assert(is_sm_ack_request, escalus:wait_for_stanza(Alice));
        _ ->
            ok
    end,
    StanzasRec.

maybe_discard_vcard_update(StanzasRec, AckFreq, Alice) ->
    case discard_vcard_update(Alice) of
        0 ->
            StanzasRec;
        1 ->
            maybe_assert_ack_request(StanzasRec + 1, AckFreq, Alice)
    end.

server_requests_ack_freq_2(Config) ->
    Config1 = escalus_users:update_userspec(Config, alice, manual_ack, true),
    server_requests_ack(Config1, 2).

server_requests_ack_after_session(Config) ->
    AliceSpec = given_fresh_spec(Config, alice),
    Steps = connection_steps_to_enable_stream_mgmt(after_bind) ++ [session],
    {ok, Alice, _} = escalus_connection:start(AliceSpec, Steps),
    escalus:assert(is_sm_ack_request, escalus_connection:get_stanza(Alice, stream_mgmt_req)).


resend_more_offline_messages_than_buffer_size(Config) ->
    ConnSteps = connection_steps_to_session(),

    %% connect bob and alice
    BobSpec = given_fresh_spec(Config, bob),
    {ok, Bob, _} = escalus_connection:start(BobSpec),
    escalus_connection:send(Bob, escalus_stanza:presence(<<"available">>)),
    escalus_connection:get_stanza(Bob, presence),
    AliceSpec = given_fresh_spec(Config, alice),

    % sent some messages - more than unacked buffer size
    MessagesToSend = ?SMALL_SM_BUFFER + 1,
    JID = get_bjid(AliceSpec),
    [escalus_connection:send(Bob, escalus_stanza:chat_to(JID, integer_to_binary(I)))
     || I <- lists:seq(1, MessagesToSend)],

    % connect alice who wants to receive all messages from offline storage
    {ok, Alice, _} = escalus_connection:start(AliceSpec, ConnSteps++[stream_management]),
    escalus_connection:send(Alice, escalus_stanza:presence(<<"available">>)),

    escalus:wait_for_stanzas(Alice, MessagesToSend * 2), %messages and ack requests

    escalus_connection:get_stanza(Alice, presence),
    escalus:wait_for_stanza(Alice), % ack request

    % confirm messages + presence
    escalus_connection:send(Alice, escalus_stanza:sm_ack(4)),
    % wait for check constraint message on server side
    ct:sleep(?CONSTRAINT_CHECK_TIMEOUT+1000),

    % should not receive anything especially any stream errors
    false = escalus_client:has_stanzas(Alice),

    escalus_connection:stop(Alice),
    escalus_connection:stop(Bob).

resend_unacked_on_reconnection(Config) ->
    Messages = [<<"msg-1">>, <<"msg-2">>, <<"msg-3">>],
    {Bob, _} = given_fresh_user(Config, bob),
    {Alice, AliceSpec0} = given_fresh_user(Config, alice),
        discard_vcard_update(Alice),
        %% Bob sends some messages to Alice.
        [escalus:send(Bob, escalus_stanza:chat_to(Alice, Msg))
         || Msg <- Messages],
        %% Alice receives the messages.
        Stanzas = escalus:wait_for_stanzas(Alice, length(Messages)),
        [escalus:assert(is_chat_message, [Msg], Stanza)
         || {Msg, Stanza} <- lists:zip(Messages, Stanzas)],
        %% Alice disconnects without acking the messages.
    escalus_connection:stop(Alice),
    escalus_connection:stop(Bob),
    wait_until_disconnected(AliceSpec0, 1000),

    %% Messages go to the offline store.
    %% Alice receives the messages from the offline store.
    AliceSpec = [{manual_ack, true} | AliceSpec0],
    {ok, NewAlice, _} = escalus_connection:start(AliceSpec),
    escalus_connection:send(NewAlice, escalus_stanza:presence(<<"available">>)),
    OfflineMsgs = [escalus_connection:get_stanza(NewAlice, {msg, I})
                   || I <- lists:seq(1, length(Messages))],
    [escalus:assert(is_chat_message, [Msg], Stanza)
     || {Msg, Stanza} <- lists:zip(Messages, OfflineMsgs)],
    %% Alice acks the delayed messages so they won't go again
    %% to the offline store.
    escalus_connection:send(NewAlice, escalus_stanza:sm_ack(3)).

preserve_order(Config) ->
    ConnSteps = connection_steps_to_session(),

    %% connect bob and alice
    BobSpec = given_fresh_spec(Config, bob),
    {ok, Bob, _} = escalus_connection:start(BobSpec),
    escalus_connection:send(Bob, escalus_stanza:presence(<<"available">>)),
    escalus_connection:get_stanza(Bob, presence),

    AliceSpec = given_fresh_spec(Config, alice),
    {ok, Alice, _} = escalus_connection:start(AliceSpec, ConnSteps++[stream_resumption]),
    escalus_connection:send(Alice, escalus_stanza:presence(<<"available">>)),
    escalus_connection:get_stanza(Alice, presence),

    escalus:assert(is_sm_ack_request, escalus_connection:get_stanza(Alice, ack)),
    escalus_connection:send(Bob, escalus_stanza:chat_to(get_bjid(AliceSpec), <<"1">>)),

    %% kill alice connection
    escalus_connection:kill(Alice),
    wait_until_disconnected(AliceSpec, 1000),

    escalus_connection:send(Bob, escalus_stanza:chat_to(get_bjid(AliceSpec), <<"2">>)),
    escalus_connection:send(Bob, escalus_stanza:chat_to(get_bjid(AliceSpec), <<"3">>)),

    {ok, NewAlice, _} = escalus_connection:start(AliceSpec, ConnSteps),
    escalus_connection:send(NewAlice, escalus_stanza:enable_sm([resume])),

    escalus_connection:send(Bob, escalus_stanza:chat_to(get_bjid(AliceSpec), <<"4">>)),
    escalus_connection:send(Bob, escalus_stanza:chat_to(get_bjid(AliceSpec), <<"5">>)),

    escalus_connection:send(NewAlice, escalus_stanza:presence(<<"available">>)),
    escalus_connection:send(Bob, escalus_stanza:chat_to(get_bjid(AliceSpec), <<"6">>)),

    receive_all_ordered(NewAlice,1),

    % replace connection
    {ok, NewAlice2, _} = escalus_connection:start(AliceSpec, ConnSteps),
    % allow messages to go to the offline storage
    ct:sleep(1000),

    escalus_connection:send(NewAlice2, escalus_stanza:presence(<<"available">>)),

    % receves messages in correct order
    receive_all_ordered(NewAlice2, 1),

    escalus_connection:stop(Bob),
    escalus_connection:stop(NewAlice2).

receive_all_ordered(Conn, N) ->
    case catch escalus_connection:get_stanza(Conn, msg) of
        #xmlel{} = Stanza ->
	    NN = case Stanza#xmlel.name of
        <<"message">> ->
%% 		    ct:pal("~p~n", [Stanza]),
            escalus:assert(is_chat_message, [list_to_binary(integer_to_list(N))], Stanza),
            N+1;
		_ ->
		    N
	    end,
            receive_all_ordered(Conn, NN);
        _Error ->
            ok
    end.

resend_unacked_after_resume_timeout(Config) ->
    ConnSteps = connection_steps_to_session(),

    %% connect bob and alice
    BobSpec = given_fresh_spec(Config, bob),
    {ok, Bob, _} = escalus_connection:start(BobSpec),
    escalus_connection:send(Bob, escalus_stanza:presence(<<"available">>)),
    escalus_connection:get_stanza(Bob, presence),

    AliceSpec = given_fresh_spec(Config, alice),
    {ok, Alice, _} = escalus_connection:start(AliceSpec, ConnSteps++[stream_resumption]),
    escalus_connection:send(Alice, escalus_stanza:presence(<<"available">>)),
    escalus_connection:get_stanza(Alice, presence),

    escalus:assert(is_sm_ack_request, escalus_connection:get_stanza(Alice, ack)),

    escalus_connection:send(Bob, escalus_stanza:chat_to(get_bjid(AliceSpec), <<"msg-1">>)),
    %% kill alice connection
    escalus_connection:kill(Alice),

    U = proplists:get_value(username, AliceSpec),
    S = proplists:get_value(server, AliceSpec),
    1 = length(escalus_ejabberd:rpc(ejabberd_sm, get_user_resources, [U, S])),
    %% wait 2 times longer to be sure that c2s is dead
    ct:sleep({seconds, 2 * ?SHORT_RESUME_TIMEOUT}),
    %% ensure there is no session
    0 = length(escalus_ejabberd:rpc(ejabberd_sm, get_user_resources, [U, S])),

    %% alice come back and receives unacked message
    {ok, NewAlice, _} = escalus_connection:start(AliceSpec, ConnSteps),
    escalus_connection:send(NewAlice, escalus_stanza:presence(<<"available">>)),

    Stanzas =[escalus_connection:get_stanza(NewAlice, msg),
              escalus_connection:get_stanza(NewAlice, msg)],

    escalus_new_assert:mix_match([is_presence,
                                  is_chat(<<"msg-1">>)],
                                 Stanzas),

    escalus_connection:stop(Bob),
    escalus_connection:stop(NewAlice).

resume_session_state_send_message(Config) ->
    ConnSteps = connection_steps_to_session(),

    %% connect bob and alice

    BobSpec = given_fresh_spec(Config, bob),
    {ok, Bob, _} = escalus_connection:start(BobSpec),
    escalus_connection:send(Bob, escalus_stanza:presence(<<"available">>)),
    escalus_connection:get_stanza(Bob, presence),

    AliceSpec = given_fresh_spec(Config, alice),
    {ok, Alice, _} = escalus_connection:start(AliceSpec, ConnSteps++[stream_resumption]),
    escalus_connection:send(Alice, escalus_stanza:presence(<<"available">>)),
    escalus_connection:get_stanza(Alice, presence),

    escalus:assert(is_sm_ack_request, escalus_connection:get_stanza(Alice, ack)),

    escalus_connection:send(Bob, escalus_stanza:chat_to(get_bjid(AliceSpec), <<"msg-1">>)),
    %% kill alice connection
    escalus_connection:kill(Alice),
    ct:sleep(1000), %% alice should be in resume_session_state

    U = proplists:get_value(username, AliceSpec),
    S = proplists:get_value(server, AliceSpec),
    1 = length(escalus_ejabberd:rpc(ejabberd_sm, get_user_resources, [U, S])),

    %% send some messages and check if c2s can handle it
    escalus_connection:send(Bob, escalus_stanza:chat_to(get_bjid(AliceSpec), <<"msg-2">>)),
    escalus_connection:send(Bob, escalus_stanza:chat_to(get_bjid(AliceSpec), <<"msg-3">>)),

    %% alice comes back and receives unacked message
    {ok, NewAlice, _} = escalus_connection:start(AliceSpec, ConnSteps),
    escalus_connection:send(NewAlice, escalus_stanza:presence(<<"available">>)),

    Stanzas = [escalus_connection:get_stanza(NewAlice, msg) || _ <- lists:seq(1,4) ],

    % what about order ?
    escalus_new_assert:mix_match([is_presence,
                                  is_chat(<<"msg-1">>),
                                  is_chat(<<"msg-2">>),
                                  is_chat(<<"msg-3">>)],
                                 Stanzas),
    escalus_connection:stop(Bob),
    escalus_connection:stop(NewAlice).

%%for instance it can be done by mod ping
resume_session_state_stop_c2s(Config) ->
    ConnSteps = connection_steps_to_session(),

    %% connect bob and alice
    BobSpec = given_fresh_spec(Config, bob),
    {ok, Bob, _} = escalus_connection:start(BobSpec, ConnSteps),
    escalus_connection:send(Bob, escalus_stanza:presence(<<"available">>)),
    escalus_connection:get_stanza(Bob, presence),

    AliceSpec = given_fresh_spec(Config, alice),
    {ok, Alice, _} = escalus_connection:start(AliceSpec, ConnSteps++[stream_resumption]),
    escalus_connection:send(Alice, escalus_stanza:presence(<<"available">>)),
    escalus_connection:get_stanza(Alice, presence),

    escalus:assert(is_sm_ack_request, escalus_connection:get_stanza(Alice, ack)),
    escalus_connection:send(Bob, escalus_stanza:chat_to(get_bjid(AliceSpec), <<"msg-1">>)),

    % kill alice connection
    escalus_connection:kill(Alice),
    ct:sleep(1000), %% alice should be in resume_session_state
    % session should be  alive
    U = proplists:get_value(username, AliceSpec),
    S = proplists:get_value(server, AliceSpec),
    [Res] = escalus_ejabberd:rpc(ejabberd_sm, get_user_resources, [U, S]),
    %% get pid of c2s and stop him !
    C2SRef = escalus_ejabberd:rpc(ejabberd_sm, get_session_pid, [U, S, Res]),
    escalus_ejabberd:rpc(ejabberd_c2s, stop, [C2SRef] ),
    ct:sleep(1000), %% c2s should be in resume_session_state

    %% alice comes back and receives unacked message
    {ok, NewAlice, _} = escalus_connection:start(AliceSpec, ConnSteps),
    escalus_connection:send(NewAlice, escalus_stanza:presence(<<"available">>)),

    Stanzas = [escalus_connection:get_stanza(NewAlice, msg),
               escalus_connection:get_stanza(NewAlice, msg)],

    escalus_new_assert:mix_match([is_presence,
                                  is_chat(<<"msg-1">>)],
                                 Stanzas),

    escalus_connection:stop(NewAlice),
    escalus_connection:stop(Bob).

%% This test only verifies the validity of helpers (get_session_pid,
%% assert_no_offline_msgs, assert_c2s_state) written for wait_for_resumption
%% testcase.
session_established(Config) ->
    AliceSpec = [{manual_ack, true}
                 | given_fresh_spec(Config, alice)],
    {Alice, _} = given_fresh_user_with_spec(AliceSpec),
    {ok, C2SPid} = get_session_pid(AliceSpec, server_string("escalus-default-resource")),
    assert_no_offline_msgs(AliceSpec),
    assert_c2s_state(C2SPid, session_established),
    escalus_connection:stop(Alice).

%% Ensure that after a violent disconnection,
%% the c2s waits for resumption (but don't resume yet).
wait_for_resumption(Config) ->
    AliceSpec = [{manual_ack, true}
                 | given_fresh_spec(Config, alice)],
    {Bob, _} = given_fresh_user(Config, bob),
    Messages = [<<"msg-1">>, <<"msg-2">>, <<"msg-3">>],
    {C2SPid, _} = buffer_unacked_messages_and_die(Config, AliceSpec, Bob, Messages),
    %% Ensure the c2s process is waiting for resumption.
    assert_no_offline_msgs(AliceSpec),
    wait_for_c2s_state_change(C2SPid, session_established, resume_session).

resume_session(Config) ->
    AliceSpec = [{manual_ack, true}
                 | given_fresh_spec(Config, alice)],
    Messages = [<<"msg-1">>, <<"msg-2">>, <<"msg-3">>],
    escalus:fresh_story(Config, [{bob, 1}], fun(Bob) ->
        {_, SMID} = buffer_unacked_messages_and_die(Config, AliceSpec, Bob, Messages),
        %% Resume the session.
        Steps = connection_steps_to_stream_resumption(SMID, 2),
        {ok, Alice, _} = escalus_connection:start(AliceSpec, Steps),
        NDiscarded = discard_vcard_update(Alice),
        %% Alice receives the unacked messages from the previous
        %% interrupted session.
        Stanzas = [escalus_connection:get_stanza(Alice, {msg, I})
                   || I <- lists:seq(1, 3)],
        [escalus:assert(is_chat_message, [Msg], Stanza)
         || {Msg, Stanza} <- lists:zip(Messages, Stanzas)],
        %% Alice acks the received messages.
        escalus_connection:send(Alice, escalus_stanza:sm_ack(5 + NDiscarded)),
        escalus_connection:stop(Alice)
    end).

resume_session_with_wrong_h_does_not_leak_sessions(Config) ->
    AliceSpec = [{manual_ack, true}
                 | given_fresh_spec(Config, alice)],
    Messages = [<<"msg-1">>, <<"msg-2">>, <<"msg-3">>],
    escalus:fresh_story(Config, [{bob, 1}], fun(Bob) ->

        {_, SMID} = buffer_unacked_messages_and_die(Config, AliceSpec, Bob, Messages),
        %% Resume the session.
        Steps = connection_steps_to_authenticate(),
        {ok, Alice, _} = escalus_connection:start(AliceSpec, Steps),
        Resumed = try_to_resume_stream(Alice, SMID, 30),
        escalus:assert(is_stream_error, [<<"policy-violation">>,
                                         <<"h attribute too big">>], Resumed),

        [] = get_user_resources(AliceSpec),
        [] = get_sid_by_stream_id(SMID),
        escalus_connection:wait_for_close(Alice, timer:seconds(5))
    end).

resume_session_with_wrong_sid_returns_item_not_found(Config) ->
    session_resumption_expects_item_not_found(Config, <<"wrong-sid">>).

resume_session_with_wrong_namespace_is_a_noop(Config) ->
    AliceSpec = given_fresh_spec(Config, alice),
    Steps = connection_steps_to_authenticate(),
    {ok, Alice, _} = escalus_connection:start(AliceSpec, Steps),
    #xmlel{attrs = Attrs} = Resume = escalus_stanza:resume(<<"doesnt_matter">>, 4),
    Attrs2 = lists:keyreplace(<<"xmlns">>, 1, Attrs, {<<"xmlns">>, <<"not-stream-mgnt">>}),
    escalus_connection:send(Alice, Resume#xmlel{attrs = Attrs2}),
    escalus_assert:has_no_stanzas(Alice),
    [] = get_user_resources(AliceSpec),
    true = escalus_connection:is_connected(Alice),
    escalus_connection:stop(Alice).

resume_dead_session_results_in_item_not_found(Config) ->
    SMID = base64:encode(crypto:strong_rand_bytes(21)),
    SID = {os:timestamp(), undefined},
    escalus_ejabberd:rpc(mod_stream_management, register_smid, [SMID, SID]),
    session_resumption_expects_item_not_found(Config, SMID).

session_resumption_expects_item_not_found(Config, SMID) ->
    AliceSpec = given_fresh_spec(Config, alice),
    Steps = connection_steps_to_authenticate(),
    {ok, Alice, _} = escalus_connection:start(AliceSpec, Steps),
    Resumed = try_to_resume_stream(Alice, SMID, 2),
    escalus:assert(is_sm_failed, [<<"item-not-found">>], Resumed),
    [] = get_user_resources(AliceSpec),
    true = escalus_connection:is_connected(Alice),
    escalus_connection:stop(Alice).


connection_steps_to_authenticate() ->
    [start_stream,
     stream_features,
     maybe_use_ssl,
     authenticate].

connection_steps_to_bind() ->
    connection_steps_to_authenticate() ++ [bind].

connection_steps_to_session() ->
    connection_steps_to_bind() ++ [session].

connection_steps_to_enable_stream_mgmt(after_session) ->
    connection_steps_to_session() ++ [stream_management];
connection_steps_to_enable_stream_mgmt(after_bind) ->
    connection_steps_to_bind() ++ [stream_management].

connection_steps_to_enable_stream_resumption() ->
    connection_steps_to_bind() ++ [session, stream_resumption].

connection_steps_to_stream_resumption(SMID, H) ->
    connection_steps_to_authenticate() ++ [mk_resume_stream(SMID, H)].

mk_resume_stream(SMID, PrevH) ->
    fun (Conn = #client{props = Props}, Features) ->
            Resumed = try_to_resume_stream(Conn, SMID, PrevH),
            true = escalus_pred:is_sm_resumed(SMID, Resumed),
            {Conn#client{props = [{smid, SMID} | Props]}, Features}
    end.

try_to_resume_stream(Conn, SMID, PrevH) ->
    escalus_connection:send(Conn, escalus_stanza:resume(SMID, PrevH)),
    escalus_connection:get_stanza(Conn, get_resumed).

buffer_unacked_messages_and_die(Config, AliceSpec, Bob, Messages) ->
    Steps = connection_steps_to_enable_stream_resumption(),
    {ok, Alice = #client{props = Props}, _} = escalus_connection:start(AliceSpec, Steps),
    JID = get_bjid(Props),
    InitialPresence = setattr(escalus_stanza:presence(<<"available">>),
                              <<"id">>, <<"presence1">>),
    escalus_connection:send(Alice, InitialPresence),
    Presence = escalus_connection:get_stanza(Alice, presence1),
    escalus:assert(is_presence, Presence),
    Res = server_string("escalus-default-resource"),
    {ok, C2SPid} = get_session_pid(AliceSpec, Res),
    escalus_connection:send(Alice, escalus_stanza:presence(<<"available">>)),
    _Presence = escalus_connection:get_stanza(Alice, presence2),
    discard_vcard_update(Alice),
    %% Bobs sends some messages to Alice.
    [escalus:send(Bob, escalus_stanza:chat_to(JID, Msg))
     || Msg <- Messages],
    %% Alice receives them, but doesn't ack.
    Stanzas = [escalus_connection:get_stanza(Alice, {msg, I})
               || I <- lists:seq(1, 3)],
    [escalus:assert(is_chat_message, [Msg], Stanza)
     || {Msg, Stanza} <- lists:zip(Messages, Stanzas)],
    %% Alice's connection is violently terminated.
    escalus_client:kill_connection(Config, Alice),
    {C2SPid, proplists:get_value(smid, Props)}.

aggressively_pipelined_resume(Config) ->
    AliceSpec = [{manual_ack, true}, {parser_opts, [{start_tag, <<"stream:stream">>}]}
                 | given_fresh_spec(Config, alice)],
    UnackedMessages = [<<"msg-1">>, <<"msg-2">>, <<"msg-3">>],
    escalus:fresh_story(Config, [{bob, 1}], fun(Bob) ->
        {_, SMID} = buffer_unacked_messages_and_die(Config, AliceSpec, Bob, UnackedMessages),
        %% Resume the session.
        Alice = escalus_connection:connect(AliceSpec),

        Username = proplists:get_value(username, AliceSpec),
        Password = proplists:get_value(password, AliceSpec),
        Payload = <<0:8,Username/binary,0:8,Password/binary>>,
        Server = proplists:get_value(server, AliceSpec),

        Stream = escalus_stanza:stream_start(Server, <<"jabber:client">>),
        Auth = escalus_stanza:auth(<<"PLAIN">>, [#xmlcdata{content = base64:encode(Payload)}]),
        AuthStream = escalus_stanza:stream_start(Server, <<"jabber:client">>),
        Resume = escalus_stanza:resume(SMID, 2),

        escalus_client:send(Alice, [Stream, Auth, AuthStream, Resume]),
        Messages = [escalus_connection:get_stanza(Alice, {get_resumed, I}) || I <- lists:seq(1, 6)],
        escalus:assert(is_sm_resumed, [SMID], lists:last(Messages)),

        escalus_connection:stop(Alice)
    end).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

discard_offline_messages(Config, UserName) ->
    discard_offline_messages(Config, UserName, 1).

discard_offline_messages(Config, UserName, H) when is_atom(UserName) ->
    Spec = escalus_users:get_options(Config, UserName),
    {ok, User, _} = escalus_connection:start(Spec),
    escalus_connection:send(User, escalus_stanza:presence(<<"available">>)),
    discard_offline_messages(Config, User, H);
discard_offline_messages(Config, User, H) ->
    Stanza = escalus_connection:get_stanza(User, maybe_offline_msg),
    escalus_connection:send(User, escalus_stanza:sm_ack(H)),
    case escalus_pred:is_presence(Stanza) of
        true ->
            ok;
        false ->
            discard_offline_messages(Config, User, H+1)
    end.

buffer_max(BufferMax) ->
    {buffer_max,
     fun () ->
             escalus_ejabberd:rpc(?MOD_SM, get_buffer_max, [unset])
     end,
     fun (unset) ->
             ct:pal("buffer_max was not set - setting to 'undefined'"),
             escalus_ejabberd:rpc(?MOD_SM, set_buffer_max, [undefined]);
         (V) ->
             escalus_ejabberd:rpc(?MOD_SM, set_buffer_max, [V])
     end,
     BufferMax}.

ack_freq(AckFreq) ->
    {ack_freq,
     fun () ->
             escalus_ejabberd:rpc(?MOD_SM, get_ack_freq, [unset])
     end,
     fun (unset) ->
             ct:pal("ack_freq was not set - setting to 'undefined'"),
             escalus_ejabberd:rpc(?MOD_SM, set_ack_freq, [undefined]);
         (V) ->
             escalus_ejabberd:rpc(?MOD_SM, set_ack_freq, [V])
     end,
     AckFreq}.

assert_no_offline_msgs(Spec) ->
    Username = escalus_utils:jid_to_lower(proplists:get_value(username, Spec)),
    Server = proplists:get_value(server, Spec),
    0 = mongoose_helper:total_offline_messages({Username, Server}).

assert_no_offline_msgs() ->
    0 = mongoose_helper:total_offline_messages().

wait_for_c2s_state_change(C2SPid, StateName, NewStateName) ->
    wait_for_c2s_state_change(C2SPid, StateName, NewStateName, 5000).

wait_for_c2s_state_change(C2SPid, StateName, NewStateName, TimeLeft) when TimeLeft =< 0 ->
    error({c2s_state_change_timeout, C2SPid, StateName, NewStateName});
wait_for_c2s_state_change(C2SPid, StateName, NewStateName, TimeLeft) ->
    case get_c2s_state(C2SPid) of
        StateName ->
            timer:sleep(100),
            wait_for_c2s_state_change(C2SPid, StateName, NewStateName, TimeLeft - 100);
        NewStateName ->
            ok
    end.

assert_c2s_state(C2SPid, StateName) ->
    StateName = get_c2s_state(C2SPid).

get_c2s_state(C2SPid) when is_pid(C2SPid) ->
    SysStatus = escalus_ejabberd:rpc(sys, get_status, [C2SPid]),
    extract_state_name(SysStatus).

extract_state_name(SysStatus) ->
    {status, _Pid, {module, _},
     [_, _, _, _, [_, {data, FSMData} | _]]} = SysStatus,
    proplists:get_value("StateName", FSMData).

wait_until_disconnected(UserSpec, Timeout) when Timeout =< 0 ->
    error({disconnect_timeout, UserSpec});
wait_until_disconnected(UserSpec, Timeout) ->
    case get_user_resources(UserSpec) of
        [] -> ok;
        [_|_] ->
            ct:sleep(200),
            wait_until_disconnected(UserSpec, Timeout - 200)
    end.

get_session_pid(UserSpec, Resource) ->
    {U, S} = get_us_from_spec(UserSpec),
    case escalus_ejabberd:rpc(ejabberd_sm, get_session_pid, [U, S, server_string(Resource)]) of
        none ->
            {error, no_found};
        C2SPid ->
            {ok, C2SPid}
    end.

get_user_resources(UserSpec) ->
    {U, S} = get_us_from_spec(UserSpec),
    escalus_ejabberd:rpc(ejabberd_sm, get_user_present_resources, [U, S]).

get_sid_by_stream_id(SMID) ->
    escalus_ejabberd:rpc(mod_stream_management, get_sid, [SMID]).

get_us_from_spec(UserSpec) ->
    ConfigUS = [proplists:get_value(username, UserSpec),
                proplists:get_value(server, UserSpec)],
    [U, S] = [server_string(V) || V <- ConfigUS],
    {U, S}.

clear_session_table() ->
    Node = ct:get_config({hosts, mim, node}),
    SessionBackend  = escalus_ejabberd:rpc(ejabberd_sm_backend, backend, []),
    escalus_ejabberd:rpc(SessionBackend, cleanup, [Node]).

clear_sm_session_table() ->
    escalus_ejabberd:rpc(mnesia, clear_table, [sm_session]).

is_chat(Content) ->
    fun(Stanza) -> escalus_pred:is_chat_message(Content, Stanza) end.

get_bjid(UserSpec) ->
    User = proplists:get_value(username, UserSpec),
    Server = proplists:get_value(server, UserSpec),
    <<User/binary,"@",Server/binary>>.

given_fresh_spec(Config, User) ->
    NewConfig = escalus_fresh:create_users(Config, [{User, 1}]),
    escalus_users:get_userspec(NewConfig, User).

given_fresh_user(Config, UserName) ->
    Spec = given_fresh_spec(Config, UserName),
    given_fresh_user_with_spec(Spec).

given_fresh_user_with_spec(Spec) ->
    {ok, User = #client{props = Props}, _} = escalus_connection:start(Spec),
    escalus:send(User, escalus_stanza:presence(<<"available">>)),
    escalus:wait_for_stanza(User),
    JID = get_bjid(Props),
    {User#client{jid  = JID}, Spec}.

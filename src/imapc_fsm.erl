-module(imapc_fsm).

-include("imap.hrl").

-behaviour(gen_fsm).

%% api
% -export([connect/2, connect_ssl/2, login/3, logout/1, noop/1, disconnect/1,
%          list/3, status/3,
%          select/2, examine/2, append/4, expunge/1,
%          search/2, fetch/3, store/4, copy/3
%         ]).

%% callbacks
-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3,
         code_change/4, terminate/3]).

%% state funs
-export([server_greeting/2, server_greeting/3, not_authenticated/2,
         not_authenticated/3, authenticated/2, authenticated/3,
         logout/2, logout/3]).

%%%--- TODO TODO TODO -------------------------------------------------------------------
%%% Objetivos:
%%%
%%% Escanear INBOX, listar mensajes, coger un mensaje entero, parsear MIME y generar JSON
%%%--------------------------------------------------------------------------------------

%%%--- TODO TODO TODO -------------------------
%%% 1. Implementar LIST, SELECT, ...
%%% 2. Implementar la respuesta con LOGIN: "* CAPABILITY IMAP4rev1 UNSELECT ..."
%%% 3. Filtrar mensajes de error_logger para desactivar los de este modulo, desactivar por defecto el logger?
%%%--------------------------------------------

%%%-----------------
%%% Client functions
%%%-----------------

% connect(Host, Port) ->
%   gen_fsm:start_link(?MODULE, {tcp, Host, Port}, []).

% connect_ssl(Host, Port) ->
%   gen_fsm:start_link(?MODULE, {ssl, Host, Port}, []).

% login(Conn, User, Pass) ->
%   gen_fsm:sync_send_event(Conn, {command, login, {User, Pass}}).

% logout(Conn) ->
%   gen_fsm:sync_send_event(Conn, {command, logout, {}}).

% noop(Conn) ->
%   gen_fsm:sync_send_event(Conn, {command, noop, {}}).

% disconnect(Conn) ->
%   gen_fsm:sync_send_all_state_event(Conn, {command, disconnect, {}}).

% list(Conn, RefName, Mailbox) ->
%   gen_fsm:sync_send_event(Conn, {command, list, [RefName, imapc_util:quote_mbox(Mailbox)]}).

% status(Conn, Mailbox, StatusDataItems) ->
%   gen_fsm:sync_send_event(Conn, {command, status, [imapc_util:quote_mbox(Mailbox), StatusDataItems]}).

% select(Conn, Mailbox) ->
%   gen_fsm:sync_send_event(Conn, {command, select, imapc_util:quote_mbox(Mailbox)}).

% examine(Conn, Mailbox) ->
%   gen_fsm:sync_send_event(Conn, {command, examine, Mailbox}).

% append(Conn, Mailbox, Flags, Message) ->
%   gen_fsm:sync_send_event(Conn, {command, append, [Mailbox, Flags, Message]}).

% expunge(Conn) ->
%   gen_fsm:sync_send_event(Conn, {command, expunge, []}).

% search(Conn, SearchKeys) ->
%   gen_fsm:sync_send_event(Conn, {command, search, SearchKeys}).

% fetch(Conn, SequenceSet, MsgDataItems) ->
%   gen_fsm:sync_send_event(Conn, {command, fetch, [SequenceSet, MsgDataItems]}, infinity).

% copy(Conn, SequenceSet, Mailbox) ->
%   gen_fsm:sync_send_event(Conn, {command, copy, [SequenceSet, Mailbox]}).

% store(Conn, SequenceSet, Flags, Action) ->
%   gen_fsm:sync_send_event(Conn, {command, store, [SequenceSet, Flags, Action]}).

% fsm_state(Conn) ->
%   gen_fsm:sync_send_all_state_event(Conn, fsm_state).

%%%-------------------
%%% Callback functions
%%%-------------------

init({SockType, Host, Port}) ->
  case imapc_util:sock_connect(SockType, Host, Port, [list, {packet, line}]) of
    {ok, Sock} ->
      ?LOG_INFO("IMAP connection open", []),
      {ok, server_greeting, #state_data{socket = Sock, socket_type = SockType}};
    {error, Reason} ->
      {stop, Reason}
  end.

server_greeting(Command = {command, _, _}, From, StateData) ->
  NewStateData = StateData#state_data{enqueued_commands =
    [{Command, From} | StateData#state_data.enqueued_commands]},
  ?LOG_DEBUG("command enqueued: ~p", [Command]),
  {next_state, server_greeting, NewStateData}.

server_greeting(_Response={response, untagged, "OK", Capabilities}, StateData) ->
  %%?LOG_DEBUG("greeting received: ~p", [Response]),
  EnqueuedCommands = lists:reverse(StateData#state_data.enqueued_commands),
  NewStateData = StateData#state_data{server_capabilities = Capabilities,
                                      enqueued_commands = []},
  lists:foreach(fun({Command, From}) ->
    gen_fsm:send_event(self(), {enqueued_command, Command, From})
  end, EnqueuedCommands),
  {next_state, not_authenticated, NewStateData};
server_greeting(_Response = {response, _, _, _}, StateData) ->
  %%?LOG_ERROR(server_greeting, "unrecognized greeting: ~p", [Response]),
  {stop, unrecognized_greeting, StateData}.

%% TODO: hacer un comando `tag CAPABILITY' si tras hacer login no hemos
%%       recibido las CAPABILITY, en el login con el OK
not_authenticated(Command = {command, _, _}, From, StateData) ->
  handle_command(Command, From, not_authenticated, StateData).

not_authenticated({enqueued_command, Command, From}, StateData) ->
  ?LOG_DEBUG("command dequeued: ~p", [Command]),
  handle_command(Command, From, not_authenticated, StateData);
not_authenticated(Response = {response, _, _, _}, StateData) ->
  handle_response(Response, not_authenticated, StateData).

authenticated(Command = {command, _, _}, From, StateData) ->
  handle_command(Command, From, authenticated, StateData).

authenticated(Response = {response, _, _, _}, StateData) ->
  handle_response(Response, authenticated, StateData).

logout(Command = {command, _, _}, From, StateData) ->
  handle_command(Command, From, logout, StateData).

logout(Response = {response, _, _, _}, StateData) ->
  handle_response(Response, logout, StateData).

%% TODO: reconexion en caso de desconexion inesperada
handle_info({SockTypeClosed, Sock}, StateName,
            StateData = #state_data{socket = Sock}) when
    SockTypeClosed == tcp_closed; SockTypeClosed == ssl_closed ->
  NewStateData = StateData#state_data{socket = closed},
  case StateName of
    logout ->
      ?LOG_INFO("IMAP connection closed", []),
      {next_state, logout, NewStateData};
    StateName ->
      ?LOG_ERROR(handle_info, "IMAP connection closed unexpectedly", []),
      {next_state, logout, NewStateData}
  end;
handle_info({SockType, Sock, Line}, StateName,
            StateData = #state_data{socket = Sock}) when
    SockType == tcp; SockType == ssl ->
  ?LOG_DEBUG("line received: ^~s$", [Line]),
  case imapc_resp:parse_response(Line) of
    {ok, Response} ->
      ?MODULE:StateName(Response, StateData);
    {error, nomatch} ->
      ?LOG_ERROR(handle_info, "unrecognized response: ~p",
                 [Line]),
      {stop, unrecognized_response, StateData}
  end.

handle_event(_Event, StateName, StateData) ->
  %?LOG_WARNING(handle_event, "fsm handle_event ignored: ~p", [Event]),
  {next_state, StateName, StateData}.

handle_sync_event({command, disconnect, {}}, _From, _StateName, StateData) ->
  case StateData#state_data.socket of
    closed ->
      true;
    Sock ->
      ok = imapc_util:sock_close(StateData#state_data.socket_type, Sock),
      ?LOG_INFO("IMAP connection closed", [])
  end,
  {stop, normal, ok, StateData};
handle_sync_event(fsm_state, _From, StateName, S) ->
  io:format("fsm: ~p~n", [self()]), 
  io:format("socket: ~p~n", [{S#state_data.socket_type, S#state_data.socket}]), 
  io:format("enqueued_commands: ~p~n", [S#state_data.enqueued_commands]), 
  io:format("server_capabilities: ~p~n", [S#state_data.server_capabilities]), 
  io:format("commands_pending_response: ~p~n", [S#state_data.commands_pending_response]), 
  io:format("untagged_responses_received: ~p~n", [S#state_data.untagged_responses_received]), 
  {reply,ok,StateName,S}.

code_change(_OldVsn, StateName, StateData, _Extra) ->
  {ok, StateName, StateData}.

terminate(normal, _StateName, _StateData) ->
  ?LOG_DEBUG("gen_fsm terminated normally", []),
  ok;
terminate(Reason, _StateName, _StateData) ->
  ?LOG_DEBUG("gen_fsm terminated because an error occurred", []),
  {error, Reason}.

%%%--------------------------------------
%%% Commands/Responses handling functions
%%%--------------------------------------

handle_response(Response = {response, untagged, _, _}, StateName, StateData) ->
  NewStateData = StateData#state_data{untagged_responses_received =
    [Response | StateData#state_data.untagged_responses_received]},
  {next_state, StateName, NewStateData};
handle_response(Response = {response, Tag, _, _}, StateName, StateData) ->
  ResponsesReceived =
    case StateData#state_data.untagged_responses_received of
      [] ->
        [Response];
      UntaggedResponsesReceived ->
        lists:reverse([Response | UntaggedResponsesReceived])
    end,
  {ok, {Command, From}, CommandsPendingResponse} =
    imapc_util:extract_dict_element(Tag,
       StateData#state_data.commands_pending_response),
  NewStateData = StateData#state_data{
                   commands_pending_response = CommandsPendingResponse
                  },
  NextStateName = imapc_resp:analyze_response(StateName, ResponsesReceived,
                                             Command, From),
  {next_state, NextStateName, NewStateData#state_data{untagged_responses_received = []}}.

handle_command(Command, From, StateName, StateData) ->
  ?LOG_DEBUG("handle command: ~p~n", [Command]),
  case imapc_cmd:send_command(StateData#state_data.socket_type,
                             StateData#state_data.socket, Command) of
    {ok, Tag} ->
      NewStateData = StateData#state_data{commands_pending_response =
        dict:store(Tag, {Command, From},
                   StateData#state_data.commands_pending_response)},
      {next_state, StateName, NewStateData};
    {error, Reason} ->
      {stop, Reason, StateData}
  end.

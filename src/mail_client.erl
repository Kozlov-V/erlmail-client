-module(mail_client).
-behaviour(gen_server).

%%
%% Include files
%%

%% @headerfile "../include/client.hrl"
-include("client.hrl").
%% @headerfile "../include/imap.hrl"
-include("imap.hrl").
-include("mimemail.hrl").

%%
%% Exported Functions
%%
%% Open and close POP3/IMAP4v1 retrieve session.
-export([open_retrieve_session/5, close_retrieve_session/1 ]).

%% SMTP ONLY
-export([open_send_session/5,
         close_send_session/1,
         send/8,
         send/7
        ]).

%% POP ONLY
-export([pop_capabilities/1, %% Recommended
         pop_list_size/1,
         pop_list/1,
         pop_retrieve/2,
         pop_retrieve/3,
         pop_list_top/1,
         pop_top/2,

         capabilities/1, %% Old pop3 API names
         list_size/1,
         list/1,
         retrieve/2,
         retrieve/3,
         list_top/1,
         top/2
    ]).

%% IMAP ONLY
-export([imap_list_mailbox/1, imap_list_mailbox/2,
         imap_select_mailbox/1, imap_select_mailbox/2, imap_select_mailbox/3,
         imap_save_draft/2]).
-export([imap_list_message/2, imap_list_message/3,
         imap_retrieve_message/2, imap_retrieve_message/3,
         imap_retrieve_part/3,
         imap_seen_message/2,
         imap_trash_message/2,
         imap_move_message/3,
         imap_clear_mailbox/1
         ]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3,
         terminate/2]).

-record(state, {fsm, handler}).

%%
%% API Functions
%%


%% @spec (Host::string(), Port::integer(), User::string(),
%%        Passwd::string(), Options::openopt()) -> {ok, pid()}
%% @type openopt() = [imap | ssl | {timeout, integer()}]
%% 
%% @doc Open pop/imap connection for operation later.
open_retrieve_session(Host, Port, User, Passwd, Options) ->
    process_flag(trap_exit, true), 
    gen_server:start_link(?MODULE, {Host, Port, User, Passwd, Options}, []).

%% @spec (pid()) -> ok 
%% @doc Close pop/imap connection.
close_retrieve_session(Pid) ->
    case erlang:is_process_alive(Pid) of
        true -> gen_server:call(Pid, close);
            %popc:quit(Pid);
        _ -> ok
    end.


%% @spec (Pid::pid()) -> {ok, integer()}
%% @equiv pop_list_size(Pid)
%% @deprecated Use pop_list_size/1 instead.
list_size(Pid) ->
    pop_list_size(Pid).

%% @spec (Pid::pid()) -> {ok, integer()}
%% @doc Return the size of mails on pop server.
pop_list_size(Pid) ->
    gen_server:call(Pid, pop_list_size). 

%% @spec (Pid::pid()) -> {ok, proplist()}
%% @equiv pop_list_top(Pid)
%% @deprecated Use pop_list_top/1 instead.
list_top(Pid) ->
    pop_list_top(Pid).

%% @spec (Pid::pid()) -> {ok, proplist()}
%% @doc Return the headers of the message on pop
%% server.
pop_list_top(Pid) ->
    gen_server:call(Pid, pop_list_top). 

%% @spec (Pid::pid()) -> {ok, proplist()} 
%% @equiv pop_list(Pid)
%% @deprecated Use pop_list/1 instead.
list(Pid) ->
    pop_list(Pid).

%% @spec (Pid::pid()) -> {ok, proplist()} 
%% @doc Retrieve all mails on pop server.
pop_list(Pid) ->
    gen_server:call(Pid, pop_list). 

%% @spec (Pid::pid(), MessageID::integer()) -> {ok, mail()}
%% @equiv pop_retrieve(Pid, MessageID)
%% @deprecated Use pop_retrieve/2 instead.
retrieve(Pid, MessageID) ->
    pop_retrieve(Pid, MessageID).

%% @spec (Pid::pid(), MessageID::integer(),
%%        Type::type()) -> {ok, mail()}
%% @equiv pop_retrieve(Pid, MessageID, Type) 
%% @deprecated Use pop_retrieve/3 instead.
%% @see pop_retrieve/3
retrieve(Pid, MessageID, Type) ->
    pop_retrieve(Pid, MessageID, Type).

%% @spec (Pid::pid(), MessageID::integer()) -> {ok, mail()}
%% @equiv pop_retrieve(Pid, MessageID, plain)
%% @see pop_retrieve/3
pop_retrieve(Pid, MessageID) ->
    pop_retrieve(Pid, MessageID, plain).

%% @spec (Pid::pid(), MessageID::integer(),
%%	  Type::type()) -> {ok, mail()}
%% @type type() = plain
%% @doc Retrieve the message specified by `MessageID'.
%% Only support text/plain type currently. 
pop_retrieve(Pid, MessageID, Type) ->
    gen_server:call(Pid, {pop_retrieve, MessageID, Type}). 

%% @spec (Pid::pid(), MessageID::integer()) -> proplist()
%% @equiv list_top(Pid, MessageID)
%% @deprecated Use pop_top/2 instead.
top(Pid, MessageID) ->
    pop_top(Pid, MessageID).

%% @spec (Pid::pid(), MessageID::integer()) -> proplist()
%% @doc Return headers of specified message by `MessageID'.
pop_top(Pid, MessageID) ->
    gen_server:call(Pid, {pop_top, MessageID}). 

%% @spec (Pid::pid()) -> {ok, list()}
%% @deprecated Use pop_capabilities/1 instead.
capabilities(Pid) ->
    pop_capabilities(Pid).

%% @spec (Pid::pid()) -> {ok, list()}
%% @doc Return capabilities of pop server.
pop_capabilities(Pid) ->
    gen_server:call(Pid, pop_capabilities).


%% @spec (Server::string(), Port::integer(), User::string(),
%%	  Passwd::string(), Options::list()) -> {ok, pid()}
%% @doc Open smtp connection to send mails later.
open_send_session(Server, Port, User, Passwd, Options) ->    
    {ok, Fsm} = smtpc:connect(Server, Port, Options),
    smtpc:ehlo(Fsm, "localhost"),
    ok = smtpc:auth(Fsm, User, Passwd),
    {ok, Fsm}.

%% @spec (Fsm::pid()) -> ok
%% @doc Close smtp connection.
close_send_session(Fsm) ->
    case erlang:is_process_alive(Fsm) of
        true ->
            smtpc:quit(Fsm),
            ok;
        _ ->
            ok
    end.

%% @spec (Fsm::pid(), From::string(), To::list(), Cc::list(),
%%  	  Subject::list(), Body::list(), Attatchments::list())-> ok
%% @equiv send(Fsm, From, To, Cc, [], Subject, Body, Attatchments)
%% @see send/8.
send(Fsm, From, To, Cc, Subject, Body, Attatchments) ->
    send(Fsm, From, To, Cc, [], Subject, Body, Attatchments).

%% @spec (Fsm::pid(), From::string(), To::list(), Cc::list(), Bcc::list(),
%%  	  Subject::list(), Body::list(), Attatchments::list())-> ok
%% @doc Send mail to receivers specified by `To',`Cc',`Bcc'.
%% @see send_util:encode_mail/7.
send(Fsm, From, To, Cc, Bcc, Subject, Body, Attatchments) ->
    ?D(From),
    smtpc:mail(Fsm, From),
    [smtpc:rcpt(Fsm, Address)|| Address<-To],
    [smtpc:rcpt(Fsm, Address)|| Address<-Cc],
    [smtpc:rcpt(Fsm, Address)|| Address<-Bcc],
    Mail = send_util:encode_mail(From, To, Cc, Bcc, Subject, Body, Attatchments),
    ?D(Mail),
    smtpc:data(Fsm, binary_to_list(Mail)),
    ok.


%% @spec (Pid::pid()) -> {ok, list()}
%% @see imap_list_mailbox/2
imap_list_mailbox(Pid) ->
    imap_list_mailbox(Pid, "\"\"").

%% @spec (Pid::pid(), RefName::string()) -> {ok, list()}
%% @doc Return a subset of mailbox names with its utf8 name
%% and essential info from the complete set of all names
%% available to the client filtered by `RefName'.
%%
%% See [http://tools.ietf.org/html/rfc3501#section-6.3.8] for
%% more information about `RefName'.
imap_list_mailbox(Pid, RefName) when is_list(RefName)->
    gen_server:call(Pid, {imap_list_mailbox, RefName}). 

%% @spec (Pid::pid()) -> {ok, mailbox(), list()}
%% @equiv imap_select_mailbox(Pid, "INBOX")
imap_select_mailbox(Pid) ->
    imap_select_mailbox(Pid, "INBOX").

%% @spec (Pid::pid(), Mailbox::list()) -> {ok, mailbox(), list()}
%% @equiv imap_select_mailbox(Pid, Mailbox, 5)
imap_select_mailbox(Pid, Mailbox) when is_list(Mailbox) -> 
    imap_select_mailbox(Pid, Mailbox, 5).

%% @spec (Pid::pid(), Mailbox::list(),
%%        Size::integer()) -> {ok, mailbox(), list()}
%% @doc Enter selected state, and return `Size' messages.
%% See [http://tools.ietf.org/html/rfc3501#section-3.3] for
%% more information about `Selected State'.
imap_select_mailbox(Pid, Mailbox, Size) when is_list(Mailbox),
					is_integer(Size), Size > 0 ->
    gen_server:call(Pid, {imap_select_mailbox, Mailbox, Size}). 

%% @spec (Pid::pid(), Seq::integer()) -> {ok, list()}
%% @equiv imap_list_message(Pid, Seq, Seq)
imap_list_message(Pid, Seq) when is_integer(Seq) ->
    imap_list_message(Pid, Seq, Seq). 

%% @spec (Pid::pid(), FromSeq::integer(), ToSeq::integer()) -> {ok, list()}
%% @doc Return headers and bodystructures of messages
%% specified by `FromSeq' and `ToSeq'.
imap_list_message(Pid, FromSeq, ToSeq) when is_integer(FromSeq), is_integer(ToSeq), FromSeq =< ToSeq->
    gen_server:call(Pid, {imap_list_message, FromSeq, ToSeq}). 

%% @spec (Pid::pid(), MsgSeq::integer()) -> {ok, list()}
%% @equiv imap_retrieve_message(Pid, MsgSeq, MsgSeq)
imap_retrieve_message(Pid, MsgSeq) when is_integer(MsgSeq)->
    imap_retrieve_message(Pid, MsgSeq, MsgSeq).

%% @spec (Pid::pid(), FromSeq::integer(), ToSeq::integer()) -> {ok, list()}
%% @doc Return the entire raw messages specified by `FromSeq'
%% and `ToSeq'.
imap_retrieve_message(Pid, FromSeq, ToSeq) when is_integer(FromSeq), is_integer(ToSeq)->
    gen_server:call(Pid, {imap_retrieve_message, FromSeq, ToSeq}, infinity). 

%% @spec (Pid::pid(), Section::string(), Seq::integer()) -> {ok, list()}
%% @equiv imap_retrieve_part(Pid, [Section], Seq)
imap_retrieve_part(Pid, Section, Seq) when is_list(Section), is_integer(hd(Section))->
    imap_retrieve_part(Pid, [Section], Seq);
%% @spec (Pid::pid(), Section::list(), Seq::integer()) -> {ok, list()}
%% @doc Return parts of message specified by `Seq' and `Section'.
imap_retrieve_part(Pid, Section, Seq) when is_integer(Seq) ->
    gen_server:call(Pid, {imap_retrieve_part, Section, Seq}, infinity).

%% @spec (Pid::pid(), RFC2822Msg::list()) -> ok
%% @doc Save draft message into `draft' mailbox. The RFC2822Msg
%% should be in RFC-2822 format.
%% See [http://tools.ietf.org/html/rfc3501#section-6.3.11] for
%% more information.
imap_save_draft(Pid, RFC2822Msg) when is_list(RFC2822Msg) ->
    gen_server:call(Pid, {imap_save_draft, RFC2822Msg}). 

%% @spec (Pid::pid(), MsgSeq::integer()) -> ok
%% @doc Set the \Seen flag on `MsgSeq' message.
imap_seen_message(Pid, MsgSeq) when is_integer(MsgSeq)->
    SeqSet = lists:concat([MsgSeq, ":", MsgSeq]),
    imap_seen_message(Pid, SeqSet);
%% @spec (Pid::pid(), SeqSet::string()) -> ok
%% @doc Set the \Seen flag on messages specified by SeqSet.
%% See [http://tools.ietf.org/html/rfc3501#section-6.4.6] for
%% more information about `SeqSet'.
imap_seen_message(Pid, SeqSet) when is_list(SeqSet) ->
    gen_server:call(Pid, {imap_seen_message, SeqSet}). 

%% @spec (Pid::pid(), MsgSeq::integer()) -> ok
%% @doc Move `MsgSeq' message to `Trash' mailbox.
imap_trash_message(Pid, MsgSeq) when is_integer(MsgSeq)->
    SeqSet = lists:concat([MsgSeq, ":", MsgSeq]),
    imap_trash_message(Pid, SeqSet);
%% @spec (Pid::pid(), SeqSet::string()) -> ok
%% @doc Move messages specified by `SeqSet' to `Trash' mailbox.
imap_trash_message(Pid, SeqSet) when is_list(SeqSet) ->
    gen_server:call(Pid, {imap_trash_message, SeqSet}). 

%% @spec (Pid::pid(), MsgSeq::integer(), Mailbox::list()) -> ok
%% @doc Move message specified by `MsgSeq' to mailbox specified
%% by `Mailbox'.
imap_move_message(Pid, MsgSeq, Mailbox) when is_integer(MsgSeq), is_list(Mailbox)->
    SeqSet = lists:concat([MsgSeq, ":", MsgSeq]),
    imap_move_message(Pid, SeqSet, Mailbox);
%% @spec (Pid::pid(), SeqSet::string(), Mailbox::list()) -> ok
%% @doc Move message specified by `SeqSet' to mailbox specified
%% by `Mailbox'.
imap_move_message(Pid, SeqSet, Mailbox) when is_list(SeqSet), is_list(Mailbox) ->
    gen_server:call(Pid, {imap_move_message, SeqSet, Mailbox}). 

%% Delete Mails that marked \Deleted.
%% @spec (Pid::pid()) -> ok
%% @doc Permanently removes all messages that have the
%% \Deleted flag set from the currently selected mailbox.
%% See [http://tools.ietf.org/html/rfc3501#section-6.4.3]
%% for more information.
imap_clear_mailbox(Pid) ->
    gen_server:call(Pid, imap_clear_mailbox). 

%%%-------------------
%%% Callback functions
%%%-------------------

init({Host, Port, User, Pass, Options}) ->
  try
    Handler = case lists:member(imap, Options) of
                true -> imapc;
                false -> popc
              end,
    {ok, Fsm} = Handler:connect(Host, Port, Options),
    ok = Handler:login(Fsm, User, Pass),
    {ok, #state{fsm=Fsm, handler=Handler}}
  catch
    error:{badmatch, {error, Reason}} -> {stop, Reason}
  end.

handle_call(close, _From, State = #state{fsm=Fsm, handler=Handler}) ->
  try
    ok = Handler:quit(Fsm),
    {stop, normal, ok, State}
  catch
    error:{badmatch, {error, Reason}} -> {stop, Reason, {error, Reason}, State}
  end;
handle_call(pop_list_size, _From, State = #state{fsm=Fsm, handler=Handler}) ->
    Reply = 
        case Handler:list(Fsm) of
            {ok, RawList} ->
                {ok, get_total_number(RawList)};
            Err ->
                ?D(Err),
                Err
        end,
    {reply, Reply, State};
handle_call(pop_list_top, _From, State = #state{fsm=Fsm, handler=Handler}) ->
    Reply = 
        case Handler:list(Fsm) of
            {ok, RawList} ->
                Num = get_total_number(RawList),
                ?D(Num),
                lists:map(fun(I) ->
                                  {ok, C} = popc:top(Fsm, I, 0),
                                  ?D({id, I}),
                                  {I, mimemail:decode_headers(C, <<"utf8">>)}
                          end, lists:seq(1, Num));
            Err ->
                ?D(Err),
                Err
        end,
    {reply, Reply, State};
handle_call(pop_list, _From, State = #state{fsm=Fsm, handler=Handler}) ->
    Reply = 
        case Handler:list(Fsm) of
            {ok, RawList} ->
                Num = get_total_number(RawList),
                ?D(Num),
                lists:map(fun(I) ->
                                  {ok, C} = popc:retrieve(Fsm, I),
                                  ?D({id, I}),
                                  {I, retrieve_util:raw_message_to_mail(C)}
                          end, lists:seq(1, Num));
            Err ->
                ?D(Err),
                Err
        end,
    {reply, Reply, State};
handle_call({pop_retrieve, MessageID, Type}, _From, State = #state{fsm=Fsm, handler=Handler}) ->
    Reply = 
        case Handler:retrieve(Fsm, MessageID) of
            {ok, RawMessage} ->
                retrieve_util:raw_message_to_mail(RawMessage, Type);
            Err ->
                ?D(Err),
                Err
        end,
    {reply, Reply, State};
handle_call({pop_top, MessageID}, _From, State = #state{fsm=Fsm, handler=Handler}) ->
    Reply = 
        case Handler:top(Fsm, MessageID, 0) of
            {ok, RawMessage} ->
                mimemail:decode_headers(RawMessage, <<"utf8">>);
            Err ->
                ?D(Err),
                Err
        end,
    {reply, Reply, State};
handle_call(pop_capabilities, _From, State = #state{fsm=Fsm, handler=Handler}) ->
    Reply = 
        case Handler:capa(Fsm) of
            {ok, RawList} ->
                {ok, parse_raw_list(RawList)};
            Err ->
                ?D(Err),
                Err
        end,
    {reply, Reply, State};
handle_call({imap_list_mailbox, RefName}, _From, State = #state{fsm=Fsm, handler=Handler}) ->
    {ok, Mailboxes} = Handler:list(Fsm, RefName, "%"),
    Reply = {ok, lists:foldl(
        fun({Mailbox, Attrs}, Acc) ->
            {ok, [{Name, Value}]} = Handler:status(Fsm, Mailbox, "(unseen messages)"),
            [{imapc_util:mailbox_to_utf8(Mailbox), Name, [{attributes, Attrs}|Value]} | Acc]
        end, [], Mailboxes)}, 
    {reply, Reply, State};
handle_call({imap_select_mailbox, Mailbox, Num}, _From, State = #state{fsm=Fsm, handler=Handler}) ->
    {ok, SelectedMailbox} = Handler:select(Fsm, Mailbox), 
    case SelectedMailbox#mailbox.exists of
        0 -> {reply, {ok, {SelectedMailbox, []}}, State};
        MsgSize ->
            FromSeq =
                if
                    MsgSize =< Num -> 1;
                    true -> (MsgSize - Num + 1)
                end,
            {ok, MessageList} = do_imap_list_message(Fsm, FromSeq, MsgSize),
            {reply, {ok, {SelectedMailbox, MessageList}}, State}
    end;
handle_call({imap_list_message, FromSeq, ToSeq}, _From, State = #state{fsm=Fsm}) ->
    {reply, do_imap_list_message(Fsm, FromSeq, ToSeq), State};
handle_call({imap_retrieve_message, FromSeq, ToSeq}, _From, State = #state{fsm=Fsm, handler=Handler}) ->
    SeqSet = lists:concat([FromSeq, ":", ToSeq]),
    {ok, RawMessageList} = Handler:fetch(Fsm, SeqSet, "rfc822"),
    ?LOG_DEBUG("~nFetch resp:~p~n", [RawMessageList]),
    ParsedMessageList = lists:map(
        fun({Seq, Content}) ->
            {match, [Raw]} = re:run(Content, "\\(RFC822 {\\d+}(?<RAW>.*)\\)", [{capture, ["RAW"], list}, dotall]),
            %{Seq, retrieve_util:raw_message_to_mail(Raw)}
            {Seq, Raw}
        end, RawMessageList), 
    {reply, {ok, ParsedMessageList}, State};
handle_call({imap_retrieve_part, Sections, Seq}, _From, State = #state{fsm=Fsm, handler=Handler}) ->
    %SeqSet = lists:concat([FromSeq, ":", ToSeq]),
    BodyPart = tl(lists:concat([" "++Section || Section <- Sections])), 
    {ok, [{_, Resp}]} = Handler:fetch(Fsm, integer_to_list(Seq), lists:concat(["(",BodyPart,")"])),
    ParsedBodyParts = imapc_util:parse_fetch_result(Resp), 
    ?LOG_DEBUG("~nFetch part:~p~n", [Resp]),
    {reply, {ok, ParsedBodyParts}, State};
handle_call({imap_save_draft, MailText}, _From, State = #state{fsm=Fsm, handler=Handler}) ->
    Reply = Handler:append(Fsm, "Drafts", "()", MailText),
    {reply, Reply, State};
handle_call({imap_seen_message, SeqSet}, _From, State = #state{fsm=Fsm, handler=Handler}) ->
    Reply = Handler:store(Fsm, SeqSet, "+FLAGS", "(\\Seen)"),
    {reply, Reply, State};
handle_call({imap_trash_message, SeqSet}, _From, State = #state{fsm=Fsm}) ->
    Reply = do_imap_trash_message(Fsm, SeqSet),
    {reply, Reply, State};
handle_call({imap_move_message, SeqSet, Mailbox}, _From, State = #state{fsm=Fsm, handler=Handler}) ->
    Handler:copy(Fsm, SeqSet, Mailbox),
    do_imap_trash_message(Fsm, SeqSet),
    Reply = do_imap_clear_mailbox(Fsm),
    {reply, Reply, State};
handle_call(imap_clear_mailbox, _From, State = #state{fsm=Fsm}) ->
    Reply = do_imap_clear_mailbox(Fsm),
    {reply, Reply, State};

handle_call(_, _From, Fsm) ->
  {reply, ignored, Fsm}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(normal, _State) ->
  ok;
terminate(Reason, _State) ->
  {error, Reason}.

%%
%% Local Functions
%%

get_total_number(Raw) ->
    Index = string:str(Raw, ?CRLF),
    [Num|_] = string:tokens(string:substr(Raw, 1, Index -1), " "),
    list_to_integer(Num).

parse_raw_list(Raw) ->
    string:tokens(Raw, "\r\n").

do_imap_list_message(Fsm, FromSeq, ToSeq) ->
    SeqSet = lists:concat([FromSeq, ":", ToSeq]),
    DataItems = "(flags envelope bodystructure rfc822.size)",
    {ok, MessageList} = imapc:fetch(Fsm, SeqSet, DataItems),
    MessageList2 = lists:map(
        fun({Seq, Content}) ->
            ParsedRlt = imapc_util:parse_fetch_result(Content), 
            Envelope = imapc_util:make_envelope(proplists:get_value('ENVELOPE', ParsedRlt)),
            %HasAttachment = imapc_util:parse_fetch_result("HAS_ATTACHEMENT", Content),
            {Seq, [{"SIZE", proplists:get_value('RFC822.SIZE', ParsedRlt)},
                   {"FLAGS", proplists:get_value('FLAGS', ParsedRlt)},
                   {"ENVELOPE", Envelope},
                   %{"B", imapc_util:parse_bodystructure(proplists:get_value('BODYSTRUCTURE', ParsedRlt))},
                   {"BODYSTRUCTURE", proplists:get_value('BODYSTRUCTURE', ParsedRlt)}]}
        end, MessageList), 
    {ok, MessageList2}.

do_imap_trash_message(Fsm, SeqSet) ->
    imapc:store(Fsm, SeqSet, "+FLAGS", "(\\Deleted)").

do_imap_clear_mailbox(Fsm) ->
    imapc:expunge(Fsm).


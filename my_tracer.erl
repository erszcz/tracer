-module(my_tracer).

-compile([export_all]).

-define(il2b, iolist_to_binary).

-ifdef(OTP_RELEASE).
	%% For some time this clause will be implicit, since OTP_RELEASE was introduced in 21.
	-if(?OTP_RELEASE >= 21).
    -define(STACKTRACE(Type, Reason, Stacktrace), Type:Reason:Stacktrace ->).
	-endif.
-else.
    %% OTP 20 or lower.
    -define(STACKTRACE(Type, Reason, Stacktrace), Type:Reason -> Stacktrace = erlang:get_stacktrace(), ).
-endif.

%% Default dbg:dhandler/2 is nice,
%% but when you want to use domain knowledge
%% or discard some of the data (like too long arg lists / retvals)
%% it might be convenient to write your own dbg handler function.
%% However, this is error prone and since you can't trace your trace function
%% (d'oh!) hard to debug.
%%
%% The way to go is to setup a monitor on the trace handler process.
%% When the trace function errors and kills the tracer process,
%% you'll be notified.
%% Still, if the monitor is setup by the shell, the 'DOWN' message
%% might simply end up in the message queue of the shell
%% and never be received - you won't know a crash happened.
%%
%% So, it's best to setup a process which will monitor the trace handler
%% and print any 'DOWN' messages it receives.
%% This will be done in my_tracer:start/0.
start() ->
    %% If you want to trace from a `mongooseimctl debug` shell,
    %% then use this variant.
    %% Otherwise, the traces will go to log/erlang.log.* files,
    %% not to the console.
    %{ok, Tracer} = dbg:tracer(process, {fun ?MODULE:handler/2, standard_io}),
    {ok, Tracer} = dbg:tracer(process, {fun ?MODULE:handler/2, user}),
    { {tracer, Tracer},
      {tracer_monitor, spawn_link(?MODULE, tracer_monitor, [Tracer])} }.

tracer_monitor(Pid) ->
    MRef = erlang:monitor(process, Pid),
    receive
        {'DOWN', MRef, process, Pid, Info} ->
            io:format("process ~p exited with info: ~p~n",
                      [Pid, Info])
    end.

handler(Trace, Out) ->
    try
        print(Out, "~s\n", [handler_(Trace)]),
        Out
    catch ?STACKTRACE(E, R, Stacktrace)
        exit({E, R, Stacktrace})
    end.

handler_(TS, {trace, _, call, _} = Trace0) ->
    Trace = translate_args(Trace0),
    [ [ [format_timestamp(TS), " "] || TS /= no_ts ], format_call(Trace) ];
handler_(TS, {trace, _Pid, return_from, _MFA, _Ret} = Trace0) ->
    Trace = translate_ret(Trace0),
    [ [ [format_timestamp(TS), " "] || TS /= no_ts ], format_return_from(Trace)].

handler_({trace_ts, _Pid, call, _MFA, TS} = Trace) ->
    handler_(TS, strip_ts(Trace));
handler_({trace, _Pid, call, _MFA} = Trace) ->
    handler_(no_ts, Trace);

handler_({trace_ts, _Pid, return_from, _MFA, _Ret, TS} = Trace) ->
    handler_(TS, strip_ts(Trace));
handler_({trace, _Pid, return_from, _MFA, _Ret} = Trace) ->
    handler_(no_ts, Trace);

handler_(Trace) ->
    io_lib:format("~p", [Trace]).

strip_ts({trace_ts, Pid, call, MFA, _TS})             -> {trace, Pid, call, MFA};
strip_ts({trace_ts, Pid, return_from, MFA, Ret, _TS}) -> {trace, Pid, return_from, MFA, Ret}.

format_call({trace, Pid, call, {M, F, Args}}) ->
    [ io_lib:format("~p call ~s:~s/~b:\n", [Pid, M, F, length(Args)]),
      [ io_lib:format("  arg ~b: ~p\n", [I, A]) || {I, A} <- enum(Args) ] ].

format_return_from({trace, Pid, return_from, {M, F, Arity}, Ret}) ->
    [ io_lib:format("~p returned from ~s:~s/~b\n  -> ~p\n",
                    [Pid, M, F, Arity, Ret]) ].

translate_args({trace, Pid, call, {M, F, Args}}) ->
    NewArgs = [ translate_one(Arg) || Arg <- Args ],
    {trace, Pid, call, {M, F, NewArgs}}.

translate_ret({trace, Pid, return_from, MFA, Ret}) ->
    {trace, Pid, return_from, MFA, translate_one(Ret)}.

translate_one(Val) ->
    lists:foldl(fun (F, AccV) -> F(AccV) end, Val, translations()).

translations() ->
    [
     %fun flatten_if_state/1,
     %fun flatten_if_fsm_next_state4/1,
     %fun flatten_if_jid/1,
     %fun flatten_if_sending_iolist/1
    ].

flatten_if_state(State) when is_tuple(State), element(1, State) == state ->
    StateL = erlang:tuple_to_list(State),
    [JID] = [ Field || Field = {jid, _, _, _, _, _, _} <- StateL ],
    {state, flatten_if_jid(JID)};
flatten_if_state(State) when is_tuple(State), element(1, State) == state -> state;
flatten_if_state(Arg) -> Arg.

flatten_if_fsm_next_state4({next_state, StateName, State, Timeout}) ->
    {next_state, StateName, flatten_if_state(State), Timeout};
flatten_if_fsm_next_state4(Arg) -> Arg.

flatten_if_jid({jid, _, _, _, _, _, _} = JID) ->
    <<"jid:", (jid_to_binary(JID))/bytes>>;
flatten_if_jid(NotAJID) -> NotAJID.

flatten_if_sending_iolist({trace, Pid, call, {ejabberd_c2s, send_text, [A1, IOList]}}) ->
    {trace, Pid, call, {ejabberd_c2s, send_text, [A1, iolist_to_binary(IOList)]}};
flatten_if_sending_iolist(Arg) -> Arg.

pass_to_dbg(Trace, Out) ->
    dbg:dhandler(Trace, Out),
    io:format("~n", []),
    Out.

%% {M,F,[A1, A2, ..., AN]} -> "M:F(A1, A2, ..., AN)"
%% {M,F,A}                 -> "M:F/A"
ffunc({M,F,Argl}) when is_list(Argl) ->
    io_lib:format("~p:~p(~s)", [M, F, fargs(Argl)]);
ffunc({M,F,Arity}) ->
    io_lib:format("~p:~p/~p", [M,F,Arity]);
ffunc(X) -> io_lib:format("~p", [X]).

%% Integer           -> "Integer"
%% [A1, A2, ..., AN] -> "A1, A2, ..., AN"
fargs(Arity) when is_integer(Arity) -> integer_to_list(Arity);
fargs([]) -> [];
fargs([A]) -> io_lib:format("~p", [A]);  %% last arg
fargs([A|Args]) -> [io_lib:format("~p,", [A]) | fargs(Args)];
fargs(A) -> io_lib:format("~p", [A]). % last or only arg

print(Handle, Fmt, Args) ->
    io:format(Handle, Fmt, Args).

enum(L) ->
    lists:zip(lists:seq(1, length(L)), L).

format_timestamp(TS) -> format_timestamp(TS, micro).

format_timestamp({_, _, Micro} = TS, Precision) ->
    {_, {H,M,S}} = calendar:now_to_local_time(TS),
    [io_lib:format("~2.10B:~2.10.0B:~2.10.0B", [H, M, S]),
     case Precision of
         seconds -> "";
         milli   -> io_lib:format( ".~3.10.0B", [erlang:round(Micro / 1000)]);
         micro   -> io_lib:format( ".~6.10.0B", [Micro])
     end].

jid_to_binary({jid, _, _, _, LUser, LServer, LRes}) ->
    <<LUser/bytes, "@", LServer/bytes, "/", LRes/bytes>>.

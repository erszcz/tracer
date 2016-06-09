-module(my_tracer).

-compile([export_all]).

-define(il2b, iolist_to_binary).

%% Listen carefully, since I won't repeat.
%%
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

handler({trace, _Pid, call, _MFA} = Trace, Out) ->
    print(Out, "~s", [format_call(Trace)]),
    Out;

handler({trace, _Pid, return_from, _MFA, _Ret} = Trace, Out) ->
    print(Out, "~s", [format_return_from(Trace)]),
    Out;

handler(Trace, Out) ->
    pass_to_dbg(Trace, Out).

format_call({trace, Pid, call, {M, F, Args}} = Trace) ->
    [ io_lib:format("~p call ~s:~s/~b:\n", [Pid, M, F, length(Args)]),
      [ io_lib:format("  arg ~b: ~p\n", [I, A]) || {I, A} <- enum(Args) ] ].

format_return_from({trace, Pid, return_from, {M, F, Arity}, Ret} = Trace) ->
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
    [fun flatten_if_state/1,
     fun flatten_if_fsm_next_state4/1,
     fun flatten_if_jid/1,
     fun flatten_if_sending_iolist/1].

flatten_if_state(State) when is_tuple(State), element(1, State) == state -> state;
flatten_if_state(Arg) -> Arg.

flatten_if_fsm_next_state4({next_state, StateName, State, Timeout}) ->
    {next_state, StateName, flatten_if_state(State), Timeout};
flatten_if_fsm_next_state4(Arg) -> Arg.

flatten_if_jid({jid, _, _, _, _, _, _} = JID) ->
    <<"jid:", (jlib:jid_to_binary(JID))/bytes>>;
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
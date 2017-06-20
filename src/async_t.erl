%%%-------------------------------------------------------------------
%%% @author Chen Slepher <slepher@issac.local>
%%% @copyright (C) 2017, Chen Slepher
%%% @doc
%%%
%%% @end
%%% Created :  9 Jun 2017 by Chen Slepher <slepher@issac.local>
%%%-------------------------------------------------------------------
-module(async_t).
-compile({parse_transform, do}).
-behaviour(monad_trans).

-export_type([async_t/5]).

%% API
-export([new/1, '>>='/3, return/2, fail/2, lift/2]).
-export([get/1, put/2, callCC/2, lift_reply/2]).
-export([promise/2, promise/3, then/3, par/2]).
-export([run/5, wait_receive/4, wait/4, handle_message/3, handle_info/4]).


%% Type constructors in erlang is not supported, I clould not implement type of async_t by other monad_t
%% TODO: expand it
-opaque async_t(_C, _S, _R, _M, _A) :: any().

%%%===================================================================
%%% API
%%%===================================================================

-spec new(M) -> TM when TM :: monad:monad(), M :: monad:monad().
new(M) ->
    {?MODULE, M}.

-spec '>>='(async_t(C, S, R, M, A), fun( (A) -> async_t(C, S, R, M, B) ), M) -> async_t(C, S, R, M, B).
'>>='(X, Fun, {?MODULE, M}) ->
    Monad = real(M),
    Monad:'>>='(X, Fun).

-spec return(A, M) -> async_t(_C, _S, _R, M, A).
return(A, {?MODULE, M}) ->
    Monad = real(M),
    Monad:return(A).

-spec fail(any(), M) -> async_t(_C, _S, _R, M, _A).
fail(X, {?MODULE, M}) ->
    Monad = real(M),
    Monad:fail(X).

-spec lift(monad:monadic(M, A), M) -> async_t(_C, _S, _R, M, A).
lift(F, {?MODULE, M}) ->
    MR = result_t:new(M),
    M1 = cont_t:new(MR),
    M2 = reply_t:new(M1),
    M2:lift(M1:lift(MR:lift(F))).

-spec get(M) -> async_t(S, S, _R, M, _A).
get({?MODULE, M}) ->
    MR = result_t:new(M),
    M1 = cont_t:new(MR),
    M2 = reply_t:new(M1),
    M2:lift(M1:lift(MR:get())).

-spec put(S, M) -> async_t(ok, S, _R, M, _A).
put(State, {?MODULE, M}) ->
    MR = result_t:new(M),
    M1 = cont_t:new(MR),
    M2 = reply_t:new(M1),
    M2:lift(M1:lift(MR:put(State))).

-spec lift_reply(async_t(C, S, R, M, A), M) -> async_t(C, S, R, M, reply_t:reply_t(identity_m, A)).
lift_reply(F, {?MODULE, M}) ->
    Monad = real(M),
    Monad:lift_reply(F).

-spec callCC(fun((fun( (A) -> async_t(C, S, R, M, _B) ))-> async_t(C, S, R, M, A)), M) -> async_t(C, S, R, M, A).
callCC(F,  {?MODULE, M}) ->
    MR = result_t:new(M),
    M1 = cont_t:new(MR),
    M2 = reply_t:new(M1),
    M2:lift(M1:callCC(F)).

-spec promise(any(), M) -> async_t(_C, _S, _R, M, _A).
promise(MRef, {?MODULE, _M} = Monad) ->
    promise(MRef, infinity, Monad).

-spec promise(any(), integer(), M) -> async_t(_C, _S, _R, M, _A).
promise(MRef, Timeout, {?MODULE, M} = Monad) ->
    MR = result_t:new(M),
    fun(K) ->
            do([MR || 
                   {CallbackGetter, CallbackSetter} <- MR:ask(),
                   State <- MR:get(),
                   begin 
                       NK = callback_with_timeout(K, MRef, Timeout, Monad),
                       Callbacks = CallbackGetter(State),
                       NCallbacks = maps:put(MRef, NK, Callbacks),
                       NState = CallbackSetter(NCallbacks, State),
                       MR:put(NState)
                   end
               ])
    end.

-spec then(async_t(C, S, R, M, A), fun((A) -> async_t(C, S, R, M, B)), M) -> async_t(C, S, R, M, B).
then(X, Then, {?MODULE, M}) ->
    Monad = real(M),
    Monad:'>>='(Monad:lift(X), Then).

par(Promises, {?MODULE, M}) ->
    MR = result_t:new(M),
    fun(K) ->
            do([MR ||
                   CallbacksGS <- MR:ask(),
                   State <- MR:get(),
                   begin 
                       NState = 
                           lists:foldl(
                             fun(Promise, S) ->
                                     MR:exec(Promise(K), S, CallbacksGS)
                             end, State, Promises),
                       MR:put(NState)
                   end
               ])
    end.

handle_message(X, MessageHandler, {?MODULE, M}) ->
    NMessageHandler = callback_to_k(MessageHandler, {?MODULE, M}),
    then(X, 
         fun({message, Message}) ->
                 fun(_K) ->
                         NMessageHandler(Message)
                 end;
            (Reply) ->
                 fun(K) ->
                         (K)(Reply)
                 end
         end, {?MODULE, M}).

wait(X, Callback, Timeout, {?MODULE, _M} = Monad) ->
    State = run(X, Callback, 2, {state, maps:new()}, Monad),
    wait_receive(2, State, Timeout, Monad).

run(X, Callback, Offset, State, {?MODULE, M} = Monad) ->
    MR = result_t:new(M),
    K = callback_to_k(Callback, Monad),
    CallbacksGS = state_callbacks_gs(Offset),
    MR:exec(X(K), State, CallbacksGS).

wait_receive(Offset, State, Timeout, {?MODULE, _M} = Monad) ->
    {CallbacksG, _CallbacksS} = state_callbacks_gs(Offset),
    Callbacks = CallbacksG(State),
    case maps:size(Callbacks) of
        0 ->
            State;
        _ ->
            receive 
                Info ->
                    case handle_info(Info, Offset, State, Monad) of
                        unhandled ->
                            wait_receive(Offset, State, Timeout, Monad);
                        NState ->
                            wait_receive(Offset, NState, Timeout, Monad)
                    end
            after Timeout ->
                    lists:foldl(
                      fun(MRef, S) ->
                              case handle_info({MRef, {error, timeout}}, Offset, S, Monad) of
                                  unhandled ->
                                      S;
                                  NS ->
                                      NS
                              end
                      end, State, maps:keys(Callbacks))
            end
    end.
                    
handle_info(Info, Offset, State, {?MODULE, M}) ->
    MR = result_t:new(M),
    {CallbacksG, CallbacksS} = state_callbacks_gs(Offset),
    Callbacks = CallbacksG(State),
    case info_to_a(Info) of
        {MRef, A} ->
            case handle_a(MRef, A, Callbacks) of
                {Callback, NCallbacks} ->
                    NState = CallbacksS(NCallbacks, State),
                    MR:exec(Callback(A), NState, {CallbacksG, CallbacksS});
                error ->
                    M:return(State)
            end;
        unhandled ->
            unhandled
    end.
%%--------------------------------------------------------------------
%% @doc
%% @spec
%% @end
%%--------------------------------------------------------------------

%%%===================================================================
%%% Internal functions
%%%===================================================================
real(M) ->
    reply_t:new(cont_t:new(result_t:new(M))).

callback_to_k(Callback, {?MODULE, M} = Monad) ->
    MR = result_t:new(M),
    fun(A) ->
            do([MR || 
                   State <- MR:get(),
                   NState <- MR:lift(execute_callback(Callback, A, State, Monad)),
                   MR:put(NState)
               ])
    end.

info_to_a({message, MRef, Message}) when is_reference(MRef) ->
    {MRef, {message, Message}};
info_to_a({MRef, Reply}) when is_reference(MRef) ->
    {MRef, Reply};
info_to_a({'DOWN', MRef, _, _, Reason}) when is_reference(MRef) ->
    {MRef, {error, {process_down, Reason}}};
info_to_a(_Info) ->
    unhandled.

handle_a(MRef, {message, _Message}, Callbacks) when is_reference(MRef) ->
    case maps:find(MRef, Callbacks) of
        {ok, Callback} ->
            {Callback, Callbacks};
        error ->
            error
    end;
handle_a(MRef, _Reply, Callbacks) when is_reference(MRef) ->
    erlang:demonitor(MRef, [flush]),
    case maps:find(MRef, Callbacks) of
        {ok, Callback} ->
            NCallbacks = maps:remove(MRef, Callbacks),
            {Callback, NCallbacks};
        error ->
            error
    end.

callback_with_timeout(Callback, MRef, Timeout, {?MODULE, _M}) when is_integer(Timeout) ->
    Timer = erlang:send_after(Timeout, self(), {MRef, {error, wait_timeout}}),
    fun(A) ->
            erlang:cancel_timer(Timer),
            Callback(A)
    end;
callback_with_timeout(Callback, _MRef, _Timeout, {?MODULE, _M}) ->
    Callback.

execute_callback(Callback, Value, State, {?MODULE, M}) when is_function(Callback) ->
    case erlang:fun_info(Callback, arity) of
        {arity, 0} ->
            Callback(),
            M:return(State);
        {arity, 1} ->
            Callback(Value),
            M:return(State);
        {arity, 2} ->
            Callback(Value, State);
        {arity, N} ->
            M:fail({invalid_callback, Callback, N})
    end;
execute_callback(Callback, _Value, _State, {?MODULE, M}) ->
    M:fail({invalid_callback, Callback}).

state_callbacks_gs(Offset) ->
    {fun(State) ->
             element(Offset, State)
     end,
     fun(Callbacks, State) ->
             setelement(Offset, State, Callbacks)
     end}.

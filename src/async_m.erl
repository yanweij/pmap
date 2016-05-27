%%%-------------------------------------------------------------------
%%% @author Chen Slepher <slepher@issac.local>
%%% @copyright (C) 2016, Chen Slepher
%%% @doc
%%%
%%% @end
%%% Created : 26 May 2016 by Chen Slepher <slepher@issac.local>
%%%-------------------------------------------------------------------

-module(async_m).

-behaviour(monad).

-export(['>>='/2, return/1, fail/1]).
-export([promise/1, promise/2]).
-export([get_state/0, put_state/1, update_state/1]).
-export([exec/4]).
-export([message/2]).
-export([then/4, handle_info/3]).
-export([wait/1, wait/3]).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% @spec
%% @end
%%--------------------------------------------------------------------
'>>='(M, Fun) ->
    fun(Callback, StoreCallbacks, State) ->
            M(
              fun({error, Reason}, NState) ->
                      execute_callback(Callback, {error, Reason}, NState);
                 ({message, Message}, NState) ->
                      execute_callback(Callback, {message, Message}, NState);
                 (Reply, NState) ->
                      Val = 
                          case Reply of
                              {ok, R} ->
                                  R;
                              ok ->
                                  ok;
                              Other -> 
                                  Other
                          end,
                      (Fun(Val))(
                        fun(NReply, NNState) ->
                                execute_callback(Callback, NReply, NNState)
                        end, StoreCallbacks, NState)
              end, StoreCallbacks, State)
    end.

return(A) -> 
    fun(Callback, _StoreCallback, State) -> 
            execute_callback(Callback, A, State)
    end.
                       
fail(X) -> 
    fun(Callback, _StoreCallback, State) ->
            execute_callback(Callback, {error, X}, State)
    end.

get_state() ->
    fun(Callback, _StoreCallback, State) ->
            execute_callback(Callback, State, State)
    end.

put_state(State) ->
    fun(Callback, _StoreCallback, _State) ->
            execute_callback(Callback, ok, State)
    end.

update_state(Fun) ->
    fun(Callback, _StoreCallback, State) ->
            NState = Fun(State),
            execute_callback(Callback, ok, NState)
    end.

promise(MRef) ->
    promise(MRef, infinity).

promise(MRef, Timeout) when is_reference(MRef) ->
    fun(Callback, StoreCallback, State) ->
            NCallback = callback_with_timeout(MRef, Callback, Timeout),
            StoreCallback(MRef, NCallback, State)
    end;
promise(Reply, _Timeout) ->
    fun(Callback, _StoreCallbacks, State) ->
            execute_callback(Callback, Reply, State)
    end.

exec(M, Callback, StoreCallback, State) ->
    M(Callback, StoreCallback, State).

then(Monad, Callback, Offset, State) ->
    StoreCallback = state_store_callback(Offset),
    exec(Monad, Callback, StoreCallback, State).

handle_info(Info, Offset, State) ->
    Callbacks = element(Offset, State),
    case handle_reply(Info, Callbacks) of
        error ->
            State;
        unhandled ->
            unhandled;
        {Reply, Callback, NCallbacks}  ->
            NState = setelement(Offset, State, NCallbacks),
            execute_callback(Callback, Reply, NState)
    end.

wait(Monad) ->
    wait(Monad,
         fun({message, _Message}, S) ->
                 S;
            (Reply, _S) ->
                 Reply
         end, ok).
            
wait(Monad, Callback, State) ->
    StoreCallbacks = wait_store_callbacks(),
    NState = exec(Monad, Callback, StoreCallbacks, State),
    wait_receive(NState).

wait_receive({store, MRef, Callback, State}) ->
    receive 
        Msg ->
            Callbacks = maps:from_list([{MRef, Callback}]),
            case handle_reply(Msg, Callbacks) of
                unhandled ->
                    wait_receive({store, MRef, Callback, State});
                error ->
                    wait_receive({store, MRef, Callback, State});
                {Reply, Callback, NCallbacks} ->
                    case maps:to_list(NCallbacks) of
                        [] ->
                            NState = execute_callback(Callback, Reply, State),
                            wait_receive(NState);
                        _ ->
                            wait_receive({store, MRef, Callback, State})
                    end
            end
    end;
wait_receive(State) ->
    State.

message({PId, MRef}, Message) ->
    catch PId ! {message, MRef, Message}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
callback_with_timeout(MRef, Callback, Timeout) 
  when is_integer(Timeout), is_reference(MRef), is_function(Callback) ->
    Timer = erlang:send_after(Timeout, self(), {MRef, {error, wait_timeout}}),
    fun(Reply, State) ->
            erlang:cancel_timer(Timer),
            execute_callback(Callback, Reply, State)
    end;
callback_with_timeout(_Async, Callback, infinity) when is_function(Callback) ->
    Callback;
callback_with_timeout(_Async, Callback, _Timeout) ->
    Callback.

execute_callback(Callback, Value, State) when is_function(Callback) ->
    case erlang:fun_info(Callback, arity) of
        {arity, 0} ->
            Callback(),
            State;
        {arity, 1} ->
            Callback(Value),
            State;
        {arity, 2} ->
            Callback(Value, State);
        {arity, N} ->
            exit({invalid_callback, Callback, N})
    end;
execute_callback(Callback, _Value, _State) ->
    exit({invalid_callback, Callback}).

handle_reply({message, MRef, Message}, Callbacks) when is_reference(MRef) ->
    case find(MRef, Callbacks) of
        {ok, Callback} ->
            {{message, Message}, Callback, Callbacks};
        error ->
            error
    end;
handle_reply({MRef, Reply}, Callbacks) when is_reference(MRef) ->
    erlang:demonitor(MRef, [flush]),
    case find(MRef, Callbacks) of
        {ok, Callback} ->
            NCallbacks = remove(MRef, Callbacks),
            {Reply, Callback, NCallbacks};
        error ->
            error
    end;
handle_reply({'DOWN', MRef, _, _, Reason}, Callbacks) when is_reference(MRef) ->
    handle_reply({MRef, {error, {process_down, Reason}}}, Callbacks);
handle_reply(_Info, _Callbacks) ->
    unhandled.

state_store_callback(Offset) ->
    fun(MRef, Callback, State) ->
            Callbacks = element(Offset, State),
            NCallbacks = store(MRef, Callback, Callbacks),
            setelement(Offset, State, NCallbacks)
    end.

wait_store_callbacks() ->
    fun(MRef, Callback, State) ->
            {store, MRef, Callback, State}
    end.

store(Key, Value, Dict) when is_map(Dict) ->
    maps:put(Key, Value, Dict);
store(Key, Value, Dict) when is_list(Dict) ->
    orddict:store(Key, Value, Dict);
store(Key, Value, Dict) ->
    dict:store(Key, Value, Dict).

find(Key, Dict) when is_map(Dict) ->
    maps:find(Key, Dict);
find(Key, Dict) when is_list(Dict) ->
    orddict:find(Key, Dict);
find(Key, Dict) ->
    dict:find(Key, Dict).

remove(Key, Dict) when is_map(Dict) ->
    maps:remove(Key, Dict);
remove(Key, Dict) when is_list(Dict) ->
    orddict:erase(Key, Dict);
remove(Key, Dict) ->
    dict:erase(Key, Dict).

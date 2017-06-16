%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is Erlando.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2011-2013 VMware, Inc.  All rights reserved.
%%

-module(reply_t).
-compile({parse_transform, do}).

-export_type([reply_t/2]).

-behaviour(monad_trans).
-export([new/1, '>>='/3, return/2, fail/2, run/2, lift/2, lift_reply/2]).

-opaque reply_t(M, A) :: monad:monadic(M, ok | {ok, A} | {error, any()} | A).


-spec new(M) -> TM when TM :: monad:monad(), M :: monad:monad().
new(M) ->
    {?MODULE, M}.


-spec '>>='(reply_t(M, A), fun( (A) -> reply_t(M, B) ), M) -> reply_t(M, B).
'>>='(X, Fun, {?MODULE, M}) ->
    do([M || R <- X,
             case R of
                 {error, _Err} = Error -> return(Error);
                 {message, _Msg} = Message -> return(Message);
                 {ok,  Result}         -> Fun(Result);
                 Result                -> Fun(Result)
             end
       ]).


-spec return(A, M) -> reply_t(M, A).
return(ok, {?MODULE, M}) -> M:return(ok);
return(X , {?MODULE, M}) -> M:return({ok, X}).

%% This is the equivalent of
%%     fail msg = ErrorT $ return (Left (strMsg msg))
%% from the instance (Monad m, Error e) => Monad (ErrorT e m)
%%
%% http://hackage.haskell.org/packages/archive/mtl/1.1.0.2/doc/html/src/Control-Monad-Error.html#ErrorT
%%
%% I.e. note that calling fail on the outer monad is not a failure of
%% the inner monad: it is success of the inner monad, but the failure
%% is encapsulated.
-spec fail(any(), M) -> reply_t(M, _A).
fail(E, {?MODULE, M}) ->
    M:return({error, E}).


-spec run(reply_t(M, A), M) -> monad:monadic(M, ok | {ok, A} | {error, any()} | {message, any()}).
run(EM, _M) -> EM.


-spec lift(monad:monadic(M, A), M) -> reply_t(M, A).
lift(X, {?MODULE, M}) ->
    do([M || A <- X,
             return({ok, A})]).

-spec lift_reply(reply_t(M, A), M) -> reply_t(M, reply_t(identity_m, A)).
lift_reply(X, {?MODULE, M}) ->
    do([M || A <- X,
             case A of
                 {message, M} = Message ->
                     return(Message);
                 A ->
                     return({ok, A})
             end]).
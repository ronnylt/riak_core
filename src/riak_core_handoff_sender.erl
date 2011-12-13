%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
%%
%% @doc Handoff partition data.

-module(riak_core_handoff_sender).
-behavior(gen_server).

%% API
-export([get_handoff_ssl_options/0,
         start_link/4]).

%% Callbacks
-export([init/1,
	 handle_call/3,
	 handle_cast/2,
	 handle_info/2,
	 code_change/3,
	 terminate/2]).

-include_lib("riak_core_vnode.hrl").
-include_lib("riak_core_handoff.hrl").
-define(ACK_COUNT, 1000).
-record(state, {target, mod, partition, vnode, ssl_opts}).

%% -------------------------------------------------------------------
%% API
%% -------------------------------------------------------------------

get_handoff_ssl_options() ->
    case app_helper:get_env(riak_core, handoff_ssl_options, []) of
        [] ->
            [];
        Props ->
            try
                %% We'll check if the file(s) exist but won't check
                %% file contents' sanity.
                ZZ = [{_, {ok, _}} = {ToCheck, file:read_file(Path)} ||
                         ToCheck <- [certfile, keyfile, cacertfile, dhfile],
                         Path <- [proplists:get_value(ToCheck, Props)],
                         Path /= undefined],
                spawn(fun() -> self() ! ZZ end), % Avoid term...never used err
                %% Props are OK
                Props
            catch
                error:{badmatch, {FailProp, BadMat}} ->
                    lager:error("SSL handoff config error: property ~p: ~p.",
                                [FailProp, BadMat]),
                    [];
                X:Y ->
                    lager:error("Failure processing SSL handoff config "
                                "~p: ~p:~p",
                                [Props, X, Y]),
                    []
            end
    end.

start_link(Target, Mod, Partition, VNode) ->
    SSLOpts = get_handoff_ssl_options(),
    gen_server:start_link(?MODULE, [Target, Mod, Partition, VNode, SSLOpts], []).

%% -------------------------------------------------------------------
%% Callbacks
%% -------------------------------------------------------------------

init([Target, Mod, Partition, VNode, SSLOpts]) ->
    State = #state{target=Target,
		   mod=Mod,
		   partition=Partition,
		   vnode=VNode,
		   ssl_opts=SSLOpts},
    {ok, State, 0}.

handle_call(Req, _From, State) ->
    lager:error("Unexpected call ~p", Req),
    {noreply, State}.

handle_cast(Req, State) ->
    lager:error("Unexpected cast ~p", Req),
    {noreply, State}.

handle_info(timeout, State=#state{target=Target, mod=Mod, partition=Partition,
				  vnode=VNode, ssl_opts=SSLOpts}) ->
    start_fold(Target, Mod, Partition, VNode, SSLOpts),
    {stop, normal, State};
handle_info({Err=tcp_error, _Sock, Reason},
	    State=#state{target=Target, mod=Mod, partition=Partition,
			 vnode=VNode}) ->
    lager:error("Handoff of partition ~p ~p from ~p to ~p failed ~p:~p",
		[Mod, Partition, node(), Target, Err, Reason]),
    gen_fsm:send_event(VNode, {handoff_error, Err, Reason}),
    {stop, {Err, Reason}, State};
handle_info({tcp_closed, _Sock},
	    State=#state{target=Target, mod=Mod, partition=Partition,
			 vnode=VNode}) ->
    lager:error("Handoff of partition ~p ~p from ~p to ~p failed, "
		"the receiver unexpectedly closed the socket",
		[Mod, Partition, node(), Target]),
    gen_fsm:send_event(VNode, {handoff_error, tcp_closed, unexpected_close}),
    {stop, {tcp_closed, unexpected_close}, State};
handle_info(Req, State) ->
    lager:error("Unexpected info ~p", [Req]),
    {noreply, State}.

terminate(_Reason, _State) -> ignore.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% -------------------------------------------------------------------
%% Private
%% -------------------------------------------------------------------

get_handoff_port(Node) when is_atom(Node) ->
    case catch(gen_server2:call({riak_core_handoff_listener, Node}, handoff_port, infinity)) of
        {'EXIT', _}  ->
            %% Check old location from previous release
            gen_server2:call({riak_kv_handoff_listener, Node}, handoff_port, infinity);
        Other -> Other
    end.

start_fold(TargetNode, Module, Partition, ParentPid, SslOpts) ->
     try
         lager:info("Starting handoff of partition ~p ~p from ~p to ~p",
                               [Module, Partition, node(), TargetNode]),
         [_Name,Host] = string:tokens(atom_to_list(TargetNode), "@"),
         {ok, Port} = get_handoff_port(TargetNode),
         SockOpts = [binary, {packet, 4}, {header,1}, {active, false}],
         {Socket, TcpMod} =
             if SslOpts /= [] ->
                     {ok, Skt} = ssl:connect(Host, Port, SslOpts ++ SockOpts,
                                             15000),
                     {Skt, ssl};
                true ->
                     {ok, Skt} = gen_tcp:connect(Host, Port, SockOpts, 15000),
                     {Skt, gen_tcp}
             end,

         %% Piggyback the sync command from previous releases to send
         %% the vnode type across.  If talking to older nodes they'll
         %% just do a sync, newer nodes will decode the module name.
         %% After 0.12.0 the calls can be switched to use PT_MSG_SYNC
         %% and PT_MSG_CONFIGURE
         VMaster = list_to_atom(atom_to_list(Module) ++ "_master"),
         ModBin = atom_to_binary(Module, utf8),
         Msg = <<?PT_MSG_OLDSYNC:8,ModBin/binary>>,
         ok = TcpMod:send(Socket, Msg),
         {ok,[?PT_MSG_OLDSYNC|<<"sync">>]} = TcpMod:recv(Socket, 0),
         M = <<?PT_MSG_INIT:8,Partition:160/integer>>,
         ok = TcpMod:send(Socket, M),
         StartFoldTime = now(),
         {Socket,ParentPid,Module,TcpMod,_Ack,SentCount,ErrStatus} =
             riak_core_vnode_master:sync_command({Partition, node()},
                                                 ?FOLD_REQ{
                                                    foldfun=fun visit_item/3,
                                                    acc0={Socket,ParentPid,Module,TcpMod,0,0,ok}},
                                                 VMaster, infinity),
         %% One last sync to make sure the message has been received.
         %% post-0.14 vnodes switch to handoff to forwarding immediately
         %% so handoff_complete can only be sent once all of the data is
         %% written.  handle_handoff_data is a sync call, so once
         %% we receive the sync the remote side will be up to date.
         lager:debug("~p ~p Sending final sync", [Partition, Module]),
         ok = TcpMod:send(Socket, <<?PT_MSG_SYNC:8>>),
         {ok,[?PT_MSG_SYNC|<<"sync">>]} = TcpMod:recv(Socket, 0),
         lager:debug("~p ~p Final sync received", [Partition, Module]),

         EndFoldTime = now(),
         FoldTimeDiff = timer:now_diff(EndFoldTime, StartFoldTime) / 1000000,
         case ErrStatus of
             ok ->
                 lager:info("Handoff of partition ~p ~p from ~p to ~p "
                                       "completed: sent ~p objects in ~.2f "
                                       "seconds",
                                       [Module, Partition, node(), TargetNode,
                                        SentCount, FoldTimeDiff]),
                 gen_fsm:send_event(ParentPid, handoff_complete);
             {error, ErrReason} ->
                 lager:error("Handoff of partition ~p ~p from ~p to ~p "
                                        "FAILED after sending ~p objects "
                                        "in ~.2f seconds: ~p",
                                        [Module, Partition, node(), TargetNode,
                                         SentCount, FoldTimeDiff, ErrReason]),
                 gen_fsm:send_event(ParentPid, {handoff_error,
                                                fold_error, ErrReason})
         end
     catch
         Err:Reason ->
             lager:error("Handoff of partition ~p ~p from ~p to ~p failed ~p:~p",
                                    [Module, Partition, node(), TargetNode,
                                     Err, Reason]),
             gen_fsm:send_event(ParentPid, {handoff_error, Err, Reason})
     end.

%% When a tcp error occurs, the ErrStatus argument is set to {error, Reason}.
%% Since we can't abort the fold, this clause is just a no-op.
visit_item(_K, _V, {Socket, ParentPid, Module, TcpMod, Ack, Total,
                    {error, Reason}}) ->
    {Socket, ParentPid, Module, TcpMod, Ack, Total, {error, Reason}};
visit_item(K, V, {Socket, ParentPid, Module, TcpMod, ?ACK_COUNT, Total, _Err}) ->
    M = <<?PT_MSG_OLDSYNC:8,"sync">>,
    case TcpMod:send(Socket, M) of
        ok ->
            case TcpMod:recv(Socket, 0) of
                {ok,[?PT_MSG_OLDSYNC|<<"sync">>]} ->
                    visit_item(K, V, {Socket, ParentPid, Module, TcpMod, 0, Total, ok});
                {error, Reason} ->
                    {Socket, ParentPid, Module, TcpMod, 0, Total, {error, Reason}}
            end;
        {error, Reason} ->
            {Socket, ParentPid, Module, TcpMod, 0, Total, {error, Reason}}
    end;
visit_item(K, V, {Socket, ParentPid, Module, TcpMod, Ack, Total, _ErrStatus}) ->
    BinObj = Module:encode_handoff_item(K, V),
    M = <<?PT_MSG_OBJ:8,BinObj/binary>>,
    case TcpMod:send(Socket, M) of
        ok ->
            {Socket, ParentPid, Module, TcpMod, Ack+1, Total+1, ok};
        {error, Reason} ->
            {Socket, ParentPid, Module, TcpMod, Ack, Total, {error, Reason}}
    end.

%%% File        : broadcast_eqc.erl
%%% Author      : Ulf Norell
%%% Description : 
%%% Created     : 20 Aug 2013 by Ulf Norell
-module(broadcast_eqc).

-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").
-include_lib("eqc/include/eqc_temporal.hrl").

-record(state, {nodes = []}).

-define(LAZY_TIMER, 20).

initial_state() -> #state{}.

node_list() ->
  [a, b, c, d, e, f, g, h, i, j, k, l].

%% -- Generators -------------------------------------------------------------

key() -> elements([k1, k2, k3, k4, k5]).
val() -> elements([v1, v2, v3, v4, v5]).
msg() -> {key(), val()}.

gen_peers(Node, Nodes) ->
  case length(Nodes) of
    1 -> {[], []};
    2 -> {Nodes -- [Node], []};
    N ->
      Width = 2, % if N < 5 -> 1; true -> 2 end,
      Tree  = riak_core_util:build_tree(Width, Nodes, [cycles]),
      Eager = orddict:fetch(Node, Tree),
      Lazy  = [elements(Nodes -- [Node | Eager]) || N > 3],
      {Eager, Lazy}
  end.

%% -- Commands ---------------------------------------------------------------

%% -- init --
init_pre(S) -> S#state.nodes == [].

init_args(_S) ->
  [?LET(Nodes, ?LET(N, choose(2, length(node_list())),
                    shrink_list(lists:sublist(node_list(), N))),
        [ {Node, gen_peers(Node, Nodes)} || Node <- Nodes ])
  ].

init(Tree) ->
  Names = [ Name || {Name, _} <- Tree ],
  [ rpc:call(mk_node(Name), ?MODULE, start_server, [Name, Eager, Lazy, Names])
    || {Name, {Eager, Lazy}} <- Tree ],
  ok.

start_server(_Name, Eager, Lazy, Names) ->
  try
    N = fun(Xs) -> lists:map(fun mk_node/1, Xs) end,
    {ok, Pid} = riak_core_broadcast:start_link(N(Names), N(Eager), N(Lazy)),
    unlink(Pid),
    (catch metadata_manager_mock:stop()),
    timer:sleep(1),
    {ok, Mgr} = metadata_manager_mock:start_link(),
    unlink(Mgr),
    ok
  catch _:Err ->
    io:format("OOPS\n~p\n~p\n", [Err, erlang:get_stacktrace()])
  end.

init_next(S, _, [Names]) ->
  S#state{ nodes  = [ Name || {Name, _} <- Names ] }.

%% -- broadcast --
broadcast_pre(S) -> S#state.nodes /= [].
broadcast_pre(S, [Node, _Msg]) -> lists:member(Node, S#state.nodes).

broadcast_args(S) -> [elements(S#state.nodes), msg()].

broadcast(Node, Msg={Key, Val}) ->
  %% event_logger:event({broadcast, Node, Msg}),
  rpc:call(mk_node(Node), metadata_manager_mock, put, [Key, Val]),
  rpc:call(mk_node(Node), riak_core_broadcast, broadcast, [Msg, metadata_manager_mock]).
    %% Parameterize on manager

%% -- sleep --
sleep_pre(S) -> S#state.nodes /= [].
sleep_args(_) -> [choose(1, ?LAZY_TIMER)].
sleep(N) -> timer:sleep(N).

weight(_, sleep)     -> 1;
weight(_, broadcast) -> 4;
weight(_, init)      -> 1.

%% -- Property ---------------------------------------------------------------

prop_test() ->
  ?SETUP(fun() -> setup(), fun() -> ok end end,
  ?FORALL(Cmds, ?SIZED(N, resize(N div 2, commands(?MODULE))),
  ?LET(Shrinking, parameter(shrinking, false),
  ?ALWAYS(if Shrinking -> 5; true -> 1 end,
  begin
    timer:sleep(2),
    event_logger:reset(),
    HSR={_H, S, _Res} = run_commands(?MODULE, Cmds),
    %% timer:sleep(200),
    {Trace, Ok} = event_logger:get_events(100, 10000),
    event_logger:event(reset),
    {messages, Mailbox} = process_info(global:whereis_name(event_logger), messages),
    timer:sleep(10),
    Tree = get_tree(S#state.nodes),
    stop_servers(S),
    timer:sleep(5),
    Views = [ {Node, rpc:call(mk_node(Node), metadata_manager_mock, stop, [])}
              || Node <- S#state.nodes ],
    timer:sleep(10),
    MoreTrace = event_logger:get_events(),
    ?IMPLIES(length(MoreTrace) == 2,
    aggregate([ element(1, E) || {_, E} <- Trace, is_tuple(E) ],
    ?WHENFAIL(io:format("~p\n", [Trace]),
    ?WHENFAIL(io:format("Views =\n  ~p\n", [Views]),
    ?WHENFAIL(io:format("MoreTrace =\n  ~p\nTree =\n  ~p\nMailbox =\n  ~p\n", [MoreTrace, Tree, Mailbox]),
    pretty_commands(?MODULE, Cmds, HSR,
      conjunction(
      [ {consistent, prop_consistent(Views)}
      , {valid_views, [] == [ bad || {_, View} <- Views, not is_list(View) ]}
      , {termination, equals(Ok, ok)}
      %% , {tree, prop_tree(Tree)}
      %% , {extra_trace, equals(length(MoreTrace), 2)}
      ])))))))
  end)))).

prop_tree(Tree) ->
  Nodes = [ Node || {Node, _} <- Tree ],
  conjunction(
    [ {Node, equals(Nodes -- reachable(Node, Tree), [])}
      || Node <- Nodes ]).

reachable(Node, Tree) -> reachable([Node], Node, Tree, []).
reachable([], _Root, _Tree, Acc) -> lists:sort(Acc);
reachable([Node|Nodes], Root, Tree, Acc) ->
  case lists:member(Node, Acc) of
    true -> reachable(Nodes, Root, Tree, Acc);
    false -> 
      {_, Neighbours, _} = lists:keyfind(Root, 1, proplists:get_value(Node, Tree)),
      reachable(Nodes ++ Neighbours, Root, Tree, [Node|Acc])
  end.

prop_consistent([]) -> true;
prop_consistent(Views) ->
  Dicts = [ Dict || {_, Dict} <- Views ],
  1 == length(lists:usort(Dicts)).

setup() ->
  %% error_logger:tty(false),
  error_logger:tty(true),
  try event_logger:get_events() catch _:_ -> event_logger:start_link() end,
  start_nodes(),
  [ rpc:call(mk_node(Node), application, set_env,
      [riak_core, broadcast_lazy_timer, ?LAZY_TIMER])
    || Node <- node_list() ].

%% -- Helpers ----------------------------------------------------------------

host() ->
  hd(tl(string:tokens(atom_to_list(node()),"@"))).

mk_node(Name) ->
  list_to_atom(lists:concat([Name, "@", host()])).

node_name() ->
  node_name(node()).

node_name(Node) ->
  list_to_atom(hd(string:tokens(atom_to_list(Node),"@"))).

start_nodes() ->
  [ start_node(Node) || Node <- node_list() ].

stop_nodes() ->
  [ slave:stop(mk_node(Node)) || Node <- node_list() ].

start_node(Node) ->
  case lists:member(mk_node(Node), nodes()) of
    true  ->
      rpc:call(mk_node(Node), user_default, l, []);
    false ->
      {ok, _} = slave:start(host(), Node),
      rpc:call(mk_node(Node), ?MODULE, register_root, [node()]),
      ok
  end.

kill(Name) ->
  catch exit(whereis(Name), kill).

stop_servers(S) ->
  [ rpc:call(mk_node(P), ?MODULE, kill, [riak_core_broadcast])
    || P <- S#state.nodes ].

proplists_modify(Key, List, Fun) ->
  Val = proplists:get_value(Key, List),
  lists:keystore(Key, 1, List, {Key, Fun(Val)}).

get_tree(Nodes) ->
  [ {A, [ begin
            {Eager, Lazy} = riak_core_broadcast:debug_get_peers(mk_node(A), mk_node(B)),
            {B, lists:map(fun node_name/1, Eager), lists:map(fun node_name/1, Lazy)}
          end || B <- Nodes ]}
    || A <- Nodes ].

%% prop_send_after() ->
%%   ?FORALL(N, choose(10, 40),
%%   begin
%%     T0 = timestamp(),
%%     erlang:send_after(N, self(), done),
%%     T1 = receive done -> timestamp() end,
%%     ?WHENFAIL(io:format("T0 = ~p\nT1 = ~p\nD  = ~p\n", [T0, T1, T1 - T0]),
%%     abs(T1 - T0 - N) < 4)
%%   end).

%% timestamp() -> from_now(os:timestamp()).

%% from_now({A, B, C}) ->
%%   (C + 1000000 * (B + 1000000 * A)) div 1000.


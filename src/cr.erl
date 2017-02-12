-module(cr).
-description('Distributed Transaction Coordinator').
-copyright('Maxim Sokhatsky').
-include("cr.hrl").
-include_lib("db/include/transaction.hrl").
-include("rafter.hrl").
-compile(export_all).
-compile({no_auto_import,[node/0]}).

main(A) -> mad_repl:main(A,[]).

encode(Msg) -> term_to_binary(Msg).
decode(Bin) -> binary_to_term(Bin).

set_socket(Pid, Socket) when is_pid(Pid), is_port(Socket) -> gen_fsm:send_event(Pid, {socket_ready, Socket}).
send(Pid, Message) when is_pid(Pid)  -> gen_fsm:send_event(Pid, {out, Message}).

config()       -> {ok,Peers} = application:get_env(cr,peers),
                  N = lists:map(fun({N,_,_,_})->N end,Peers),
                  #config{state=stable,oldservers=N,newservers=N}.
local(Object)  -> {I,N}=lists:keyfind(cr:nodex(cr:node()),2,cr:chain(Object)),
                  {I,P,_,_}=lists:keyfind(I,1,supervisor:which_children(vnode_sup)), P.
secret()       -> application:get_env(cr,secret,<<"ThisIsClassified">>).
peers()        -> {ok,Peers}=application:get_env(cr,peers),Peers.
peers(N)       -> lists:zip(lists:seq(1,N),lists:seq(1,N)).
hash(Object)   -> hd(seq(Object)).
rep(Object)    -> roll(element(2,hash(Object))).
roll(N)        -> lists:seq(N,length(peers())) ++ lists:seq(1,N-1).
seq(Object)    -> lists:keydelete(0,1,cr_hash:succ(cr_hash:key_of(Object),ring())).
peer({I,N})    -> element(1,lists:nth(N,peers())).
nodex(Node)    -> string:str(cr:peers(),[lists:keyfind(Node,1,cr:peers())]).
node()         -> list_to_atom(lists:concat([os:getenv("NAME"),'@127.0.0.1'])).
vpid({I,Node}) -> {I,P,_,_}=lists:keyfind(I,1,supervisor:which_children({vnode_sup,Node})), P.
ring()         -> ring(4).
ring(C)        -> {Nodes,[{0,1}|Rest]} = cr_hash:fresh(length(peers())*C,1),
                  {Nodes,[{0,0}|lists:map(fun({{I,1},X})->{I,(X-1) div C+1} end,
                                lists:zip(Rest,lists:seq(1,length(Rest))))]}.

chain(Object) ->
    cr:info(?MODULE,"Object ~p~n",[Object]),
    {N,_} = cr:ring(),
    lists:map(fun(X) -> lists:nth((X-1)*4+1,cr:seq(Object)) end,
              cr:roll(element(2,cr:hash(Object)))).

tx(Record) when is_tuple(Record) ->
    gen_server:cast(local(Record),
        {client,{self(),os:timestamp()},
                chain(element(2,Record)),
                Record}).

stack(Error, Reason) ->
    Stacktrace = [case A of
         { Module,Function,Arity,Location} ->
             { Module,Function,Arity,proplists:get_value(line, Location) };
         Else -> Else end
    || A <- erlang:get_stacktrace()],
    [Error, Reason, Stacktrace].

error_page(Class,Error) ->
    io_lib:format("ERROR:  ~w:~w~n~n",[Class,Error]) ++
    "STACK: " ++
    [ io_lib:format("\t~w:~w/~w:~w\n",
        [ Module,Function,Arity,proplists:get_value(line, Location) ])
    ||  { Module,Function,Arity,Location} <- erlang:get_stacktrace() ].

test() -> test(10).
test(Num) ->
    O1 = lists:foldl(fun({_,_,_,A,_,_},Acc) -> A+Acc end,0,kvs:all(log)),
    T1 = length(kvs:all(transaction)),
    kvs:info(?MODULE,"Already in Database: ~p~n"
                     "New record will be applied: ~p~n",[O1,Num]),
    [cr:tx(#transaction{id=kvs:next_id(transaction,1)})||I<-lists:seq(1,Num)],
    O2 = lists:foldl(fun({_,_,_,A,_,_},Acc) -> A+Acc end,0,kvs:all(log)),
    {transactions,T2 = length(kvs:all(transaction))}.

log_size({I,N}) ->
    {ok,Log} = kvs:get(log,{I,N}),
    {Log#log.top,length(kvs:entries({ok,Log},operation,-1))}.

dump() ->
     {N,Nodes} = cr:ring(),
     io:format("~52w ~3w ~2w ~10w ~11w~n",[vnode,i,n,top,latency]),
   [ begin
     {A,B} = rpc(rpc:call(cr:peer({I,N}),cr,log_size,[{I,N}])),
     {Min,Max,Avg} = latency({I,N}),
     L = lists:concat([Min,'/',Max,'/',Avg]),
     io:format("~52w ~3w ~2w ~10w ~11s~n",[I,P,N,A,L])
     end || {{I,N},P} <- lists:zip(lists:keydelete(0,1,Nodes),lists:seq(1,length(Nodes)-1))],
     ok.

string(O) ->
    lists:concat(lists:flatten([lists:map(fun(undefined) -> ''; (X) -> [X,':'] end, tuple_to_list(O))])).

dump(N) when N < 13  -> {_,X}   = cr:ring(),
                        Nodes   = lists:keydelete(0,1,X),
                        {I,P}   = lists:nth(N,Nodes),
                        Pos     = string:str(Nodes,[{I,P}]),
                        {ok,C}  = rpc:call(cr:peer({I,P}),kvs,get,[log,{I,P}]),
                        dump_op(Pos,rpc(rpc:call(cr:peer({I,P}),kvs,entries,[C,operation,10])));

dump(N)              -> {_,X}   = cr:ring(),
                        Nodes   = lists:keydelete(0,1,X),
                        {ok,Oo} = kvs:get(operation,N),
                        {I,P}   = lists:keyfind(element(1,Oo#operation.feed_id),1,Nodes),
                        Pos     = string:str(Nodes,[{I,P}]),
                        dump_op(Pos,kvs:traversal(operation,Oo#operation.id,10,#iterator.prev)).

dump_op(Pos,List) ->
     io:format("~50s ~10w ~10w ~4w ~10w~n",[operation,id,prev,i,size]),
   [ io:format("~50s ~10w ~10w ~4w ~10w~n",[
        string(Tx),
        element(2,O),
        rpc(element(#iterator.prev,O)),
        rpc(Pos),
        size(term_to_binary(O))])
     || #operation{name=Name,body={Cmd,_,Chain,Tx}}=O <- List],
     ok.

latency({I,N}) -> gen_server:call(cr:vpid({I,cr:peer({I,N})}),{latency}).

rpc(undefined) -> [];
rpc({badrpc,_}) -> {error,error};
rpc(Value) -> Value.

clean() -> kvs:destroy(), kvs:join().

config(Key)     -> config(cr, Key, "").
config(App,Key) -> config(App,Key, "").
config(App, Key, Default) -> case application:get_env(App,Key) of
                                  undefined -> Default;
                                     {ok,V} -> V end.

log_modules() -> [cr,cr_log,cr_rafter,cr_heart,cr_vnode].
-define(ALLOWED, (config(cr,log_modules,cr))).

log(Module, String, Args, Fun) ->
    case lists:member(Module,?ALLOWED:log_modules()) of
         true -> error_logger:Fun("~p:"++String, [Module|Args]);
         false -> skip end.

info(Module, String,   Args) -> log(Module, String, Args, info_msg).
warning(Module,String, Args) -> log(Module, String, Args, warning_msg).
error(Module, String,  Args) -> log(Module, String, Args, error_msg).


sup()   -> [{T,Pid}||{T,Pid,_,_}<-supervisor:which_children(cr_sup)].
heart() -> [{_,P,_,_}]=supervisor:which_children(heart_sup), gen_server:call(P,{heart}).
local() -> [{I,P}||{I,P,_,_} <- supervisor:which_children(vnode_sup)].

% Integrity Functions

% consensus_log  checks that the length of RAFT log is the same on all nodes.
% node_log       checks that the sum of chains of all vnodes equals the the overal operations counts.
% operation_log  checks that on all nodes all operations logs are ok
% cluster_status checks that all logs on all nodes are ok

consensus_log() ->
      Entries = cr_log:get_last_index(cr:node()),
      case lists:all(fun({H,_,_,_}) ->
            rpc:call(H,cr_log,get_last_index,[H]) == Entries end,
            cr:peers()) of true -> {ok,Entries};
                          false -> {error,consensus_log} end.


node_log() ->
      Operations = length(kvs:all(operation)),
      case lists:sum([ begin
            length(kvs:entries(kvs:get(log,Id),operation,-1)) == Num, Num end
            || {log,Id,_,Num,_,_} <- kvs:all(log) ]) == Operations of
           true -> {ok,Operations};
          false -> {error,node_log} end.


operation_log() ->
      Operations = length(kvs:all(operation)),
      case lists:all(fun({H,_,_,_}) ->
            case rpc:call(H,cr,node_log,[]) of
                 {ok,Operations} -> true;
                               _ -> false end end,
             cr:peers()) of true -> {ok,Operations};
                           false -> {error,operation_log} end.


cluster_status() -> {ok,_} = consensus_log(),
                    {ok,_} = operation_log().

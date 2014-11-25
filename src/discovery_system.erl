-module(discovery_system).
-behaviour (gen_fsm).
-export([start_link/0]).
%-export([create_file/2, get_file/1, flush_data/0, flush_state/0, new_server/1]).
-export([init/1, code_change/4, terminate/3, handle_event/3, handle_info/3, handle_sync_event/4]).
-export ([alone/2]).

-define (RED_MSGS, 3).

%%% Client API
start_link() ->
	gen_server:start_link({local, discovery_system}, discovery_system, [], []).

%%% Server Functions
init([]) ->
	Msg = {hello, my_ip()},
	loop(?RED_MSGS, fun transport_system:broadcast/1, Msg),
	{ok, alone, []}.

code_change(_OldVsn, S, State, _Extra) ->
	{ok, alone, S, State}.

handle_event(_E, S, SS) -> {next_state, S, SS}.

handle_info(_I, S, SS) -> {next_state, S, SS}.

handle_sync_event(_E, _F, S, SS) -> {next_state, S, SS}.

% send terminate data to a logger later...
terminate(_Reason, _S, _State) -> ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%% Client Functions Handlers %%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

alone({hello_ack}, Friends_Count) ->
	

	{next_state, connected, Friends_Count}.

connected({hello, IP}, State) ->
	Msg = {hello_ack, my_ip()}
	loop(?RED_MSGS, fun transport_system:unreliable_unicast/3, [IP, Msg]),



loop(0, _, _) -> ok;
loop(N, F, Arg) ->
	apply(F, Arg),
	loop(N-1, F, Arg).]

my_ip() -> 
	{ok, [{addr, IP}]} = inet:ifget("wlan0", [addr]),
	IP.
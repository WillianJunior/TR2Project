-module(dfs_server).
-behaviour (gen_server).
-export([start_link/0, start_link/1]).
-export([create_file/2, get_file/1, flush_data/0, flush_state/0, new_server/1]).
-export([init/1, code_change/3, terminate/2, handle_cast/2
	, handle_call/3, handle_info/2]).

-define (TIMEOUT_MULTICAST_MS, 10000).
-define (DFS_SERVER_UDP_PORT, 8678).

%%%% Files Structures
% Data = {filename, consistent, locked, {file, versions}}
% versions = [{location, version}]


%%% Client API
start_link() ->
	%net_kernel:start([Server_Name, shortnames]),
	gen_server:start_link({local, dfs_server}, dfs_server, [], []).

start_link(_Group) ->
	%net_kernel:start([Server_Name, shortnames]),
	%net_kernel:connect_node(Group),
	%Server_List = lists:map(fun get_server_name/1, nodes()),
	gen_server:start_link({local, dfs_server}, dfs_server, [], []).
	%hail_all(). %% hailing but not getting the answers

%% Sync call
create_file(Filename, File) ->
	%Payload = term_to_binary({call, {new_local_file, Filename, File}}),
	%gen_udp:send(Socket, Server, ?DFS_SERVER_UDP_PORT, Payload).
	gen_server:call(dfs_server, {new_local_file, Filename, File}).

get_file(Filename) ->
	gen_server:call(dfs_server, {get_file, Filename}).

flush_data() ->
	gen_server:call(dfs_server, flush_data).

flush_state() ->
	gen_server:call(dfs_server, flush_state).

new_server(Server) ->
	gen_server:call(dfs_server, {new_server, Server}).

%% Async call
%ping_all() ->
%	Nodes = nodes(),
%	ping(Nodes).

%%% Server Functions
init([]) ->
	{ok, {[],[]}};

init(Server_List) ->
	{ok, {Server_List, []}}.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

% send terminate data to a logger later...
terminate(_Reason, _State) -> ok.

%% Client Functions Handlers
% add a new server manually
handle_call({new_server, Server}, _From, {Servers, Data}) ->
	New_Servers = [Server|Servers],
	{reply, ok, {New_Servers, Data}};

% New file sync call
handle_call({new_local_file, Filename, File}, _From, {Servers, Data}) ->
	New_Data = {Filename, true, 0, {File, [{get_self(), 1}]}},
	reliable_multicast({new_file, Filename}, Servers),
	{reply, ok, {Servers, lists:keymerge(1, Data, [New_Data])}};

% Get file list
handle_call(flush_data, _From, {Servers, Data}) ->
	{reply, Data, {Servers, Data}};

handle_call(flush_state, _From, State) ->
	{reply, State, State};

handle_call({get_file, Filename}, _From, {Servers, Data}) ->
	File_Found = lists:keyfind(Filename, 1, Data),
	%atom_to_list(File_Found),
	{New_Data, Return_File} = case File_Found of
		false ->
			{Data, doesnt_exist};
		{_Filename_Found, Consist, _Lock, {File, _Versions}} when Consist -> 
			{Data, File};
		{_Filename_Found, Consist, Lock, _File} when not Consist ->
			% get remote file field
			{Remote_File, Remote_Versions} = get_remote_file(Filename, Servers),
			% update the versions list locally
			New_Versions = lists:keymerge(1, Remote_Versions, [{get_self(), 1}]),
			New_D = lists:keyreplace(Filename, 1, Data, {Filename, true, Lock, {Remote_File, New_Versions}}),
			% multicast the new holder of file to current holders
			%Current_Holders = lists:map(fun fst/1, Remote_Versions),
				%%%% RACE CONDItION!!!!! if 2 new holders: the current holder will send obsolete 
				%% Versions and the new holders won't know about each other
				%% Solution: Broadcast instead...
				%% worse eficiency, but correct
			reliable_multicast({new_file_holder, Filename}, Servers),
			{New_D, Remote_File};
		_ -> {Data, false}
	end,
	{reply, Return_File, {Servers, New_Data}};

handle_call(_Reason, _From, State) ->
	{noreply, State}.

% currently not needed. send event to a logger later
handle_info(_Request, State) ->
	{noreply, State}.

%%% Server Functions Handlers
%% Add a new file descriptor from a remote server
handle_cast({{From_IP, From_Port}, {new_file, Filename}}, {Servers, Data}) ->
	New_Data = lists:keymerge(1, Data, [{Filename, false, 0, {}}]),
	{ok, Socket} = gen_udp:open(get_random_port(), [binary, {active, false}]),
	gen_udp:send(Socket, From_IP, From_Port, term_to_binary({ack, get_self()})),
	gen_udp:close(Socket),
	{noreply, {Servers, New_Data}};

%% Add a new file holder after a remote server read a file it did not posses
handle_cast({{From_IP, From_Port}, {new_file_holder, Filename}}, {Servers, Data}) ->
	{_Filename_Found, Consist, Lock, {File, Versions}} = lists:keyfind(Filename, 1, Data),
	if
		Consist ->
			New_Versions = lists:keymerge(1, Versions, [{From_IP, 1}]),
			New_Data = lists:keyreplace(Filename, 1, Data, {Filename, true, Lock, {File, New_Versions}});
		true ->
			New_Data = Data
	end,
	{ok, Socket} = gen_udp:open(get_random_port(), [binary, {active, false}]),
	gen_udp:send(Socket, From_IP, From_Port, term_to_binary({ack, get_self()})),
	gen_udp:close(Socket),
	{noreply, {Servers, New_Data}};

handle_cast({{From_IP, From_Port}, {file_query, Filename}}, {Servers, Data}) ->
	{_Filename_Found, Consist, Lock, File} = lists:keyfind(Filename, 1, Data),
	% need to check consist
	{Reply, New_Data} = if
		Consist ->
			%%%% RACE CONDITION!!! what if two workers query the same file: find and lock must be atomic
			New_D = lists:keyreplace(Filename, 1, Data, {Filename, true, Lock+1, File}),
			{{available, get_self()}, New_D};
		not Consist ->
			{unavailable, Data}
	end,
	{ok, Socket} = gen_udp:open(get_random_port(), [binary, {active, false}]),
	gen_udp:send(Socket, From_IP, From_Port, term_to_binary(Reply)),
	gen_udp:close(Socket),
	{noreply, {Servers, New_Data}};

handle_cast({{From_IP, From_Port}, {file_download, Filename}}, {Servers, Data}) ->
	{_Filename_Found, _Consist, Lock, File} = lists:keyfind(Filename, 1, Data),
	% don't need to check consist here, since it will be done at file_query
	%%%% RACE CONDITION!!! what if between file_query and file_download the file is deleted?
	%% Solution, use of locks
	%%%% RACE CONDITION!!! what if two workers finish the download at the same time: download and unlock must be atomic
	New_Data = lists:keyreplace(Filename, 1, Data, {Filename, true, Lock-1, File}),
	{ok, Socket} = gen_udp:open(get_random_port(), [binary, {active, false}]),
	gen_udp:send(Socket, From_IP, From_Port, term_to_binary(File)),
	gen_udp:close(Socket),
	{noreply, {Servers, New_Data}};

handle_cast({unreachable_dest, _Dest}, State) ->
	io:format("Server out~n"),
	{noreply, State}.

%handle_cast({hello, From}, {Servers, Data}) ->
%	io:format("hello from ~s~n", [atom_to_list(From)]),
%	Exists = lists:member(From, Servers),
%	if
%		not Exists ->
%			New_Servers = lists:merge([From], Servers);
%		true ->
%			New_Servers = Servers
%	end,
%	{noreply, {New_Servers, Data}};

%handle_cast(ping, State) ->
%	io:format("ping~n"),
%	{noreply, State}.


%%% Private Functions
%fst({First, _Second}) -> First.

get_self() -> {192,168,0,8}.

%hail_all() ->
%	Nodes = nodes(),
%	hail_group(Nodes).

%hail_group([N|Ns]) ->
%	Server = get_server_name(N),
%	Me = get_self(),
%	io:format("hailing ~s~n", [atom_to_list(Server)]),
%	gen_server:cast(Server, {hello, Me}),
%	hail_group(Ns);
%hail_group([]) -> ok.

%ping([N|Ns]) ->
%	Me = get_server_name(N),
%	io:format("pinging ~s~n", [atom_to_list(Me)]),
%	gen_server:cast(Me, ping),
%	ping(Ns);
%ping([]) -> ok.

%get_server_name(Full_Name) ->
%	S = string:substr(atom_to_list(Full_Name), 1, string:chr(atom_to_list(Full_Name),  $@)-1),
%	list_to_atom(S).

%% Perform a multicast of a message to a group
% If a message can't reach the destination (i.e. no ack) the server is signaled
% on the unresponsive server.
reliable_multicast(Message, Group) ->
	try gen_udp:open(get_random_port(), [binary, {active, false}]) of
		{ok, Socket} ->
			% multicast message
			multicast(Socket, Message, Group),
			% get a list of receivers that replied
			Replies = ack_multicast(Socket, Group),
			% update server list by sending unreachable_dest for receivers that did not reply
			Cast_Fn = fun(Dest) -> gen_server:cast(get_self(), {unreachable_dest, Dest}) end,
			lists:map(Cast_Fn, lists:subtract(Group, Replies)),
			% close the socket
			gen_udp:close(Socket)
	catch
		_Error ->
			reliable_multicast(Message, Group)
	end.

%% Multicast a nessage
multicast(Socket, Message, [Dest|Group]) ->
	%io:format("multicasting ~s to ~s~n", [atom_to_list(Message), atom_to_list(Dest)]),
	Payload = term_to_binary(Message),
	gen_udp:send(Socket, Dest, ?DFS_SERVER_UDP_PORT, Payload),
	multicast(Socket, Message, Group);
multicast(_Socket, _Message, []) -> ok.

%% Colect a list of destinations that replied the multicast
ack_multicast(Socket, [_Dest|Group]) -> 
	try {ok, {_Addr, _Port, Msg}} = gen_udp:recv(Socket, 0, ?TIMEOUT_MULTICAST_MS), binary_to_term(Msg) of
		{ack, Recvr} ->
			[Recvr|ack_multicast(Socket, Group)]
	catch
		_Error ->
			ack_multicast(Socket, Group)
	end;
ack_multicast(_Socket, []) -> [].

%% Perform a multicall of a message to a group
% If a message can't reach the destination (i.e. no ack) the server is signaled
% on the unresponsive server.
% Returns a list of responses.
reliable_multicall(Message, Group, Fun) ->
	Responses = try gen_udp:open(get_random_port(), [binary, {active, false}]) of
		{ok, Socket} ->
			% multicast message
			multicast(Socket, Message, Group),
			% collect the replies
			Reply_List = reply_multicast(Socket, Group, Fun),
			{Receivers, Replies} = lists:unzip(Reply_List),
			% update server list by sending unreachable_dest for receivers that did not reply
			Cast_Fn = fun(Dest) -> gen_server:cast(get_self(), {unreachable_dest, Dest}) end,
			lists:map(Cast_Fn, lists:subtract(Group, Receivers)),
			% close the socket
			gen_udp:close(Socket),
			Replies
	catch
		_Error ->
			reliable_multicall(Message, Group, Fun)
	end,
	Responses.

%reliable_multicall(Message, [Dest|Group], Fun) ->
%	io:format("multicalling to ~s~n", [atom_to_list(Dest)]),
%	Response = try gen_server:call(Dest, Message, ?TIMEOUT_MULTICAST_MS) of
%		Reply ->
%			Fun(Reply)
%	catch
%		_Error ->
%			gen_server:cast(get_self(), {unreachable_dest, Dest})
%	end,
%	[Response | reliable_multicall(Message, Group, Fun)];

%reliable_multicall(_Message, [], _Fun) -> [].

reply_multicast(Socket, [_Dest|Group], Fun) -> 
	try  {ok, {Addr, _Port, Msg}} = gen_udp:recv(Socket, 0, ?TIMEOUT_MULTICAST_MS), {Addr, binary_to_term(Msg)} of
		{Recvr, Reply} ->
			[{Recvr, Fun(Reply)}|reply_multicast(Socket, Group, Fun)]
	catch
		_Error ->
			reply_multicast(Socket, Group, Fun)
	end;
reply_multicast(_Socket, [], _Fun) -> [].

get_remote_file(Filename, Servers) ->
	Responses = reliable_multicall({file_query, Filename}, Servers, fun get_available/1),
	First_Server = hd(Responses),
	%gen_server:call(First_Server, {file_download, Filename}).
	% when it gets concurent the connection will be gone from here
	{ok, Socket} = gen_udp:open(get_random_port(), [binary, {active, false}]),
	gen_udp:send(Socket, First_Server, ?DFS_SERVER_UDP_PORT, term_to_binary({file_download, Filename})),
	{ok, {_Addr, _Port, Msg}} = gen_udp:recv(Socket, 0),
	gen_udp:close(Socket),
	binary_to_term(Msg).
	


get_available({available, Server}) -> Server;
get_available(unavailable) -> [].

%% Generate a random number between 1024 and 49151
get_random_port() -> random:uniform(48127) + 1024.

%get_third({_A, _B, C}) -> C.

format_list(L) -> %when list(L) ->
        io:format("["),
        fnl(L),
        io:format("]").

    fnl([H]) ->
        io:format("~p", [H]);
    fnl([H|T]) ->
        io:format("~p,", [H]),
        fnl(T);
    fnl([]) ->
        ok.
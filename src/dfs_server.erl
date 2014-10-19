-module(dfs_server).
-behaviour (gen_server).
-export([start_link/0, start_link/2]).
-export([create_file/2, get_file/1, flush_data/0, flush_state/0, new_server/1]).
-export([init/1, code_change/3, terminate/2, handle_cast/2
	, handle_call/3, handle_info/2]).

-define (TIMEOUT_MULTICAST_MS, 10000).
-define (DFS_SERVER_UDP_PORT, 8678).

%%%% Files' Structures
% Data = {Filename, Consistent, Lock, {File, Versions}}
% versions = [{Location, Version}]
%
% Servers = [Server]
% Server = IP
%
% State = {Max_Files, Min_Redn, Num_Local_Files}


%%% Client API
start_link() ->
	%net_kernel:start([Server_Name, shortnames]),
	gen_server:start_link({local, dfs_server}, dfs_server, {10, 2, 0}, []).

start_link(Max_Files, Min_Redn) ->
	%net_kernel:start([Server_Name, shortnames]),
	%net_kernel:connect_node(Group),
	%Server_List = lists:map(fun get_server_name/1, nodes()),
	gen_server:start_link({local, dfs_server}, dfs_server, {Max_Files, Min_Redn, 0}, []).
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

%%% Server Functions
init(State) ->
	{ok, {[], [], State}}.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

% send terminate data to a logger later...
terminate(_Reason, _State) -> ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%% Client Functions Handlers %%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% Add a new server manually
% Since the time to perform this operation is short, it won't need a worker
handle_call({new_server, Server}, _From, {Servers, Data, State}) ->
	New_Servers = [Server|Servers],
	{reply, ok, {New_Servers, Data, State}};

% New file sync call
handle_call({new_local_file, Filename, File}, _From, {Servers, Data, {Max_Files, Min_Redn, Num_Local_Files}}) ->
	% check if Max_Files <= Num_Local_Files
	if
		Num_Local_Files >= Max_Files ->
			% transfer one file before
			New_Data = transfer_file_out(Servers, Filename, Data),
			New_Num_Local_Files = Num_Local_Files;
		true ->
			New_Num_Local_Files = Num_Local_Files + 1,
			New_Data = Data
	end,
	New_File = new_local_file(Filename, File, Servers, Min_Redn),
	{reply, ok, {Servers, push_new_file(New_Data, New_File), {Max_Files, Min_Redn, New_Num_Local_Files}}};

% Flush the server state
handle_call(flush_state, _From, State) ->
	{reply, State, State};

% Get a file:
%	if the file is present locally, return imediately
%	if not, get form the first source and send an update of holders
handle_call({get_file, Filename}, _From, {Servers, Data, {Max_Files, Min_Redn, Num_Local_Files}}) ->
	{Return_File, New_Data} = get_file_serv(Filename, Data, Servers, Max_Files, Num_Local_Files),
	{reply, Return_File, {Servers, New_Data, {Max_Files, Min_Redn, Num_Local_Files}}};

handle_call(_Reason, _From, State) ->
	{noreply, State}.

% currently not needed. send event to a logger later
handle_info(_Request, State) ->
	{noreply, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%% Server Functions Handlers %%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Add a new file descriptor from a remote server
handle_cast({{From_IP, From_Port}, {new_file, Filename}}, {Servers, Data, State}) ->
	New_Data = new_file(From_IP, From_Port, Filename, Data),
	{noreply, {Servers, New_Data, State}};

%% Add a new file holder after a remote server read a file it did not posses
handle_cast({{From_IP, From_Port}, {new_file_holder, Filename}}, {Servers, Data, State}) ->
	New_Data = new_file_holder(From_IP, From_Port, Filename, Data),
	{noreply, {Servers, New_Data, State}};

handle_cast({{From_IP, From_Port}, {file_query, Filename}}, {Servers, Data, {Max_Files, Min_Redn, Num_Local_Files}}) ->
	New_Data = file_query(From_IP, From_Port, Filename, Data, Num_Local_Files, Max_Files),
	{noreply, {Servers, New_Data, {Max_Files, Min_Redn, Num_Local_Files}}};

handle_cast({{From_IP, From_Port}, {file_download, Filename}}, {Servers, Data, State}) ->
	New_Data = file_download(From_IP, From_Port, Filename, Data),
	{noreply, {Servers, New_Data, State}};

handle_cast({{From_IP, From_Port}, {file_unquery, Filename}}, {Servers, Data, State}) ->
	% send the reply
	{ok, Socket} = gen_udp:open(get_random_port(), [binary, {active, false}]),
	gen_udp:send(Socket, From_IP, From_Port, {ack, get_self()}),
	gen_udp:close(Socket),

	{_Filename2, Consist, Lock, File} = lists:keyfind(Filename, 1, Data),
	% need to guarantee lock decrement is atomic with read -------------------------------------------------------------------------------------
	New_Data = lists:keyreplace(Filename, 1, Data, {Filename, Consist, Lock-1, File}),
	{Servers, New_Data, State};

handle_cast({unreachable_dest, _Dest}, State) ->
	io:format("Server out~n"),
	{noreply, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%% Server Handlers' Implementations %%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% Create a new file and broadcast the action to the other servers
new_local_file(Filename, File, Servers, _Min_Redn) ->
	% need to get a lock to create an id
	New_Data = {Filename, true, 0, {File, [{get_self(), 1}]}},
	reliable_multicast({new_file, Filename}, Servers),
	% need to force Min_Redn-1 servers to download the file ---------------------------------------------------------------------------------------------------
	New_Data.

% Returns a wanted file and the updated data if the file wasn't present before
get_file_serv(Filename, Data, Servers, Max_Files, Num_Local_Files) ->
	File_Found = lists:keyfind(Filename, 1, Data),
	{New_Data, Return_File} = case File_Found of
		false ->
			{Data, doesnt_exist};
		{_Filename_Found, Consist, _Lock, {File, _Versions}} when Consist -> 
			{Data, File};
		{_Filename_Found, Consist, Lock, _File} when not Consist ->
			% check if another file can be downloaded
			if
				Num_Local_Files >= Max_Files ->
					% check if there is a file that isn't locked
					Trans_Filename_Temp = lists:keyfind(0, 3, Data),
					if
						not Trans_Filename_Temp ->
							{Trans_Filename, _C, _L, _D} = hd(Data);
						true ->
							Trans_Filename = Trans_Filename_Temp
					end,
					% transfer the file elsewhere
					New_D = transfer_file_out(Servers, Trans_Filename, Data);
				true ->
					New_D = Data
			end,
			% get remote file field
			{Remote_File, Remote_Versions} = get_remote_file(Filename, Servers),
			% update the versions list locally
			New_Versions = lists:keymerge(1, Remote_Versions, [{get_self(), 1}]),
			New_DD = lists:keyreplace(Filename, 1, New_D, {Filename, true, Lock, {Remote_File, New_Versions}}),
			% multicast the new holder of file to current holders
			% Current_Holders = lists:map(fun fst/1, Remote_Versions),
				%%%% RACE CONDItION!!!!! if 2 new holders: the current holder will send obsolete
				%% versions and the new holders won't know about each other
				%% Solution: Broadcast instead...
				%% worse eficiency, but correct
			reliable_multicast({new_file_holder, Filename}, Servers),
			{New_DD, Remote_File};
		_ -> {Data, false}
	end,
	{Return_File, New_Data}.

new_file(From_IP, From_Port, Filename, Data) ->
	New_Data = lists:keymerge(1, Data, [{Filename, false, 0, {}}]),
	{ok, Socket} = gen_udp:open(get_random_port(), [binary, {active, false}]),
	gen_udp:send(Socket, From_IP, From_Port, term_to_binary({ack, get_self()})),
	gen_udp:close(Socket),
	New_Data.

new_file_holder(From_IP, From_Port, Filename, Data) ->
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
	New_Data.

file_query(From_IP, From_Port, Filename, Data, Num_Local_Files, Max_Files) ->
	{_Filename_Found, Consist, Lock, File} = lists:keyfind(Filename, 1, Data),
	% need to check consist -------------------------------------------------------------------------------------------------------------------------------------------
	{Reply, New_Data} = if
		Consist ->
			%%%% RACE CONDITION!!! what if two workers query the same file: find and lock must be atomic ----------------------------------------------------------------
			%%%% WORSE PROBLEM: the lock never decrement if the server isn't chosen for the download --------------------------------------------------------------
			New_D = lists:keyreplace(Filename, 1, Data, {Filename, true, Lock+1, File}),
			{{available, get_self()}, New_D};
		not Consist and Num_Local_Files < Max_Files ->
			{{unavailable, get_self()}, Data};
		true ->
			{{full, get_self()}, Data}
	end,
	{ok, Socket} = gen_udp:open(get_random_port(), [binary, {active, false}]),
	gen_udp:send(Socket, From_IP, From_Port, term_to_binary(Reply)),
	gen_udp:close(Socket),
	New_Data.

file_download(From_IP, From_Port, Filename, Data) ->
	{_Filename_Found, _Consist, Lock, File} = lists:keyfind(Filename, 1, Data),
	% don't need to check consist here, since it will be done at file_query
	%%%% RACE CONDITION!!! what if between file_query and file_download the file is deleted?
	%% Solution, use of locks
	%%%% RACE CONDITION!!! what if two workers finish the download at the same time: download and unlock must be atomic ---------------------------------------------
	%% need to UPDATE this to tcp ----------------------------------------------------------------------------------------------------------------------------------
	{ok, Socket} = gen_udp:open(get_random_port(), [binary, {active, false}]),
	gen_udp:send(Socket, From_IP, From_Port, term_to_binary(File)),
	New_Data = lists:keyreplace(Filename, 1, Data, {Filename, true, Lock-1, File}),
	gen_udp:close(Socket),
	New_Data.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%% Private Functions %%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

get_self() -> 
	%{ok, [{addr, IP}]} = inet:ifget("wlan0", [addr]),
	{ok, [{addr, IP}]} = inet:ifget("eth0", [addr]),
	IP.

get_first_available_server(Servers, Filename) ->
	Responses = reliable_multicall({file_query, Filename}, Servers, fun get_unavailable/1),
	Selected_Server = hd(Responses),
	reliable_multicast({file_unquery, Filename}, lists:subtract(Responses, Selected_Server)),
	Selected_Server.

force_download(Filename, Server) ->
	reliable_multicast({file_download, Filename}, [Server]).

remove_locally(Filename, Data) ->
	{_Filename2, _Consist, _Lock, _File} = lists:keyfind(Filename, 1, Data),
	%% need to validate if lock = 0 and, if not, wait until it is ---------------------------------------------------------------------------------------------------
	% this can only be done after file server/database
	lists:keyreplace(Filename, 1, Data, {Filename, false, 0, []}).

push_new_file(Data, File) ->
	lists:keymerge(1, Data, [File]).

transfer_file_out(Servers, Filename, Data) ->
	Server = get_first_available_server(Servers, Filename),
	force_download(Filename, Server),
	remove_locally(Filename, Data).

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
			% updates server list by sending unreachable_dest for receivers that did not reply
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
	reliable_multicast({file_download, Filename}, [First_Server]),
	% UPDATE recv file to tcp -----------------------------------------------------------------------------------------------------------------------------------------
	% when it gets concurent the connection will be gone from here
	{ok, Socket} = gen_udp:open(get_random_port(), [binary, {active, false}]),
	{ok, {_Addr, _Port, Msg}} = gen_udp:recv(Socket, 0),
	gen_udp:close(Socket),
	binary_to_term(Msg).
	


get_available({available, Server}) -> Server;
get_available({_State, _Server}) -> [].

get_unavailable({unavailable, Server}) -> Server;
get_unavailable({_State, _Server}) -> [].

%% Generate a random number between 1024 and 49151
get_random_port() -> random:uniform(48127) + 1024.

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
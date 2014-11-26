-module(control_system).
-behaviour(gen_server).
-export([start_link/0]).
-export([init/1, code_change/3, terminate/2, handle_info/2, 
	handle_cast/2, handle_call/3]).

%%% Client API
start_link() ->
	gen_server:start_link({local, control_system}, control_system, [], []).

%%% Server Functions
init(_) ->
	{ok, {[], [{0, transport_system:my_ip(), lo}]}}.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

handle_info(_I, S) -> {noreply, S}.

handle_call(flush, _From, State) ->
	{reply, State, State};
handle_call(_R, _F, S) -> {noreply, S}.

% send terminate data to a logger later...
terminate(_Reason, _State) -> ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%% Client Functions Handlers %%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%%%%%%%%% New Server Subprotocol %%%%%%%%%%%%

handle_cast({new_server, Socket, IP}, {Files, Servers}) ->
	New_Servers = Servers ++ {0, IP, Socket},
	New_Servers_Sorted = lists:sort(New_Servers),
	{noreply, {Files, New_Servers_Sorted}};

%%%%%%%%%%%% New File Subprotocol %%%%%%%%%%%%%

handle_cast({new_file, Filename}, {Files, Servers}) ->
	% send new descriptors to all servers
	Desc_Msg = term_to_binary({new_descriptor, Filename}),
	Desc_Sockets = lists:map(fun ({_A,_B,C}) -> C end, Servers),
	lists:map(fun (Socket) -> gen_tcp:send(Socket, Desc_Msg) end, Desc_Sockets),

	% upload files
	% TODO: support 1 live server
	Upload_Sockets = [lists:nth(1, Servers), lists:nth(2, Servers)],
	Lo_List = lists:map(fun (Socket) -> upload_file(Socket, Filename) end, 
		Upload_Sockets),
	Got_Lo = lists:foldr(fun (A,B) -> A or B end, false, Lo_List),
	if
		not Got_Lo ->
			file:delete("./files/" ++ Filename);
		true -> ok
	end,
	{noreply, {Files, Servers}};

handle_cast({new_descriptor, Filename}, {Files, Servers}) ->
	New_Files = Files ++ {Filename, []},
	{noreply, {New_Files, Servers}};

handle_cast({upload_file, Filename, From}, {Files, Servers}) ->
	% add self location to the file descriptors' list
	{_, Locations} = lists:keyfind(Filename, 1, Files),
	New_Files = lists:keyreplace(Filename, 1, Files, {Filename, Locations ++ here}),

	% update file count
	{Count, My_IP, lo} = lists:keyfind(transport_system:my_ip(), 2, Servers),
	New_Servers = lists:keyreplace(My_IP, 2, Servers, {Count+1, My_IP, lo}),

	% download file
	{_Count, From, Socket} = lists:keyfind(From, 2, Servers),
	File = gen_tcp:recv(Socket, 0),
	file:write_file("./files/" ++ Filename, File),

	% send update to network
	Update_Msg = {update_file_ref, Filename, transport_system:my_ip()},
	Update_Sockets = lists:map(fun ({_A,_B,C}) -> C end, Servers),
	transport_system:multicast_tcp_list(Update_Sockets, Update_Msg),
	{noreply, {New_Servers, New_Files}};

handle_cast({update_file_ref, Filename, IP}, {Files, Servers}) ->
	% add self location to the file descriptors' list
	{_, Locations} = lists:keyfind(Filename, 1, Files),
	New_Files = lists:keyreplace(Filename, 1, Files, {Filename, Locations ++ IP}),

	% increment file counter

	{noreply, {New_Files, Servers}};

%%%%%%%%%%% Discard other messages %%%%%%%%%%%%

handle_cast(_Other, State) ->
	{noreply, State}.


upload_file(Socket, Filename) ->
	case Socket of
		lo ->
			true;
		_S ->
			gen_tcp:send(Socket, {upload_file, Filename, transport_system:my_ip()}),
			{ok, File} = file:read_file("./files/" ++ Filename),
			gen_tcp:send(Socket, File)
	end.
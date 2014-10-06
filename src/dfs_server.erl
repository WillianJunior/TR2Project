-module(dfs_server).
-behaviour (gen_server).
-export([start_link/1, start_link/2]).
-export([ping_all/0, hail_all/0, create_file/2, get_file/1, flush_data/0, flush_state/0]).
-export([init/1, code_change/3, terminate/2, handle_cast/2
	, handle_call/3, handle_info/2]).
-export([get_server_name/1]).

-define (TIMEOUT_MULTICAST_MS, 10000).

%%%% Files Structures
% Data = {filename, here, {file, consistent, versions}}
% versions = [{location, version}]


%%% Client API
start_link(Server_Name) ->
	net_kernel:start([Server_Name, shortnames]),
	gen_server:start_link({global, Server_Name}, dfs_server, [], []).

start_link(Server_Name, Group) ->
	net_kernel:start([Server_Name, shortnames]),
	net_kernel:connect_node(Group),
	Server_List = lists:map(fun get_server_name/1, nodes()),
	gen_server:start_link({global, Server_Name}, dfs_server, Server_List, []),
	hail_all(). %% hailing but not getting the answers

%% Sync call
create_file(Filename, File) ->
	gen_server:call({global, get_self()}, {new_local_file, Filename, File}).

get_file(Filename) ->
	gen_server:call({global, get_self()}, {get_file, Filename}).

flush_data() ->
	gen_server:call({global, get_self()}, flush_data).

flush_state() ->
	gen_server:call({global, get_self()}, flush_state).

%% Async call
ping_all() ->
	Nodes = nodes(),
	ping(Nodes).

%%% Server Functions
init([]) ->
	{ok, {[],[]}};

init(Server_List) ->
	{ok, {Server_List, []}}.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

% send terminate data to a logger later...
terminate(_Reason, _State) -> ok.

%% handlers
% New file sync call
handle_call({new_local_file, Filename, File}, _From, {Servers, Data}) ->
	New_Data = {Filename, true, {File, true, [{get_self(), 1}]}},
	reliable_multicast({new_file, Filename}, Servers),
	{reply, ok, {Servers, lists:keymerge(1, Data, [New_Data])}};

% Get file list
handle_call(flush_data, _From, {Servers, Data}) ->
	{reply, Data, {Servers, Data}};

handle_call(flush_state, _From, State) ->
	{reply, State, State};

handle_call({new_file, Filename}, _From, {Servers, Data}) ->
	New_Data = lists:keymerge(1, Data, [{Filename, false, {}}]),
	{reply, ok, {Servers, New_Data}};

handle_call({get_file, Filename}, _From, {Servers, Data}) ->
	File_Found = lists:keyfind(Filename, 1, Data),
	%atom_to_list(File_Found),
	{New_Data, Return_File} = case File_Found of
		false ->
			{Data, doesnt_exist};
		{_Filename_Found, Here, {File, _Consist, _Versions}} when Here -> 
			% need to check consist
			{Data, File};
		{_Filename_Found, Here, _File} when not Here ->
			% get remote file field
			{Remote_File, _Consist, Remote_Versions} = get_remote_file(Filename, Servers),
			% update the versions list locally
			New_Versions = lists:keymerge(1, Remote_Versions, [{get_self(), 1}]),
			New_D = lists:keyreplace(Filename, 1, Data, {Filename, true, {Remote_File, true, New_Versions}}),
			% multicast the new holder of file to current holders
			%Current_Holders = lists:map(fun fst/1, Remote_Versions),
				%%%% RACE CONDItION!!!!! if 2 new holders: the current holder will send obsolete 
				%% Versions and the new holders won't know about each other
				%% Solution: Broadcast instead...
				%% worse eficiency, but correct
			reliable_multicast({new_file_holder, Filename, get_self()}, Servers),
			{New_D, Remote_File};
		_ -> {Data, false}
	end,
	{reply, Return_File, {Servers, New_Data}};

handle_call({new_file_holder, Filename, New_Holder}, _From, {Servers, Data}) ->
	{_Filename_Found, Here, {File, Consist, Versions}} = lists:keyfind(Filename, 1, Data),
	if
		Here ->
			New_Versions = lists:keymerge(1, Versions, [{New_Holder, 1}]),
			New_Data = lists:keyreplace(Filename, 1, Data, {Filename, true, {File, Consist, New_Versions}});
		true ->
			New_Data = Data
	end,
	{reply, ok, {Servers, New_Data}};

handle_call({file_query, Filename}, _From, {Servers, Data}) ->
	{_Filename_Found, Here, {_File, _Consist, _Versions}} = lists:keyfind(Filename, 1, Data),
	% need to check consist
	Reply = if
		Here ->
			{available, get_self()};
		not Here ->
			unavailable
	end,
	{reply, Reply, {Servers, Data}};


handle_call({file_download, Filename}, _From, {Servers, Data}) ->
	{_Filename_Found, _Here, File} = lists:keyfind(Filename, 1, Data),
	% don't need to check consist here, since it will be done at file_query
	%%%% RACE CONDITION!!! what if between file_query and file_download the file is deleted?
	{reply, File, {Servers, Data}};

handle_call(_Reason, _From, State) ->
	{noreply, State}.

% currently not needed. send event to a logger later
handle_info(_Request, State) ->
	{noreply, State}.

% Async call
handle_cast({hello, From}, {Servers, Data}) ->
	io:format("hello from ~s~n", [atom_to_list(From)]),
	Exists = lists:member(From, Servers),
	if
		not Exists ->
			New_Servers = lists:merge([From], Servers);
		true ->
			New_Servers = Servers
	end,
	{noreply, {New_Servers, Data}};

handle_cast(ping, State) ->
	io:format("ping~n"),
	{noreply, State}.


%%% Private Functions
fst({First, _Second}) -> First.

get_self() -> get_server_name(node()).

hail_all() ->
	Nodes = nodes(),
	hail_group(Nodes).

hail_group([N|Ns]) ->
	Server = get_server_name(N),
	Me = get_self(),
	io:format("hailing ~s~n", [atom_to_list(Server)]),
	gen_server:cast({global, Server}, {hello, Me}),
	hail_group(Ns);
hail_group([]) -> ok.

ping([N|Ns]) ->
	Me = get_server_name(N),
	io:format("pinging ~s~n", [atom_to_list(Me)]),
	gen_server:cast({global, Me}, ping),
	ping(Ns);
ping([]) -> ok.

get_server_name(Full_Name) ->
	S = string:substr(atom_to_list(Full_Name), 1, string:chr(atom_to_list(Full_Name),  $@)-1),
	list_to_atom(S).

reliable_multicast(Message, [Dest|Group]) ->
	io:format("multicasting to ~s~n", [atom_to_list(Dest)]),
	try gen_server:call({global, Dest}, Message, ?TIMEOUT_MULTICAST_MS) of
		ok ->
			ok
	catch
		_Error ->
			gen_server:cast({global, get_self()}, {unreachable_dest, Dest})
	end,
	reliable_multicast(Message, Group);

reliable_multicast(_Message, []) -> ok.

reliable_multicall(Message, [Dest|Group], Fun) ->
	io:format("multicalling to ~s~n", [atom_to_list(Dest)]),
	Response = try gen_server:call({global, Dest}, Message, ?TIMEOUT_MULTICAST_MS) of
		Reply ->
			Fun(Reply)
	catch
		_Error ->
			gen_server:cast({global, get_self()}, {unreachable_dest, Dest})
	end,
	[Response | reliable_multicall(Message, Group, Fun)];

reliable_multicall(_Message, [], _Fun) -> [].

get_remote_file(Filename, Servers) ->
	Responses = reliable_multicall({file_query, Filename}, Servers, fun get_available/1),
	First_Server = hd(Responses),
	gen_server:call({global, First_Server}, {file_download, Filename}).


get_available({available, Server}) -> Server;
get_available(unavailable) -> [].

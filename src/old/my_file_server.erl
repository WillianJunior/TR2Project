-module(my_file_server).
-behaviour (gen_server).

-compile(export_all).

-export([start_link/0]).
-export([new_file/4, flush_state/0]).
-export([init/1, code_change/3, terminate/2, handle_cast/2
	, handle_call/3, handle_info/2]).

%%%% Files' Structures
% Data = {Name, ID, [Data]|File|Location}
% Name = String
% ID = dir|Num
% Location = [IP]
% IP = {String, String, String, String}
% Dir = [Name]

%%% Client API
start_link() ->
	gen_server:start_link({local, my_file_server}, my_file_server, [], []).

%% Sync calls
% returns the file 
new_file(Filename, ID, File, Path) ->
	gen_server:call(my_file_server, {new_file, Filename, ID, File, Path}).

flush_state() ->
	gen_server:call(my_file_server, flush_state).

%%% Server Functions
init(_Arg) ->
	{ok, [{root, dir, []}]}.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

% send terminate data to a logger later...
terminate(_Reason, _State) -> ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%% Client Functions Handlers %%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

handle_call({new_file, Filename, ID, File, Path}, _From, Data) ->
	Fn = fun(Dir) -> insert_new_file(Filename, ID, File, Dir) end,
	New_Data = apply_on_file(Data, list_init(Path), Fn, list_last(Path)),
	{reply, ok, New_Data};

% Flush the server state
handle_call(flush_state, _From, State) ->
	{reply, State, State}.

handle_cast(_Request, State) ->
	{noreply, State}.

% currently not needed. send event to a logger later
handle_info(_Request, State) ->
	{noreply, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%% Helper Functions %%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

apply_on_file(Data, [P|Ps], Fun, Filename) ->
	Dir_List = lists:map(fun return_dir/1, Data),
	Dir = lists:keyfind(P, 1, Dir_List),
	File = case Dir of
		{_Name, dir, File_list} ->
			apply_on_file(File_list, Ps, Fun, Filename);
		[] ->
			{dir_doesnt_exist, P};
		Error ->
			{error, Error}
	end,
	lists:keyreplace(P, 1, Data, File);
apply_on_file(Data, [], Fun, Filename) ->
	[Fun(lists:keyfind(Filename, 1, Data))].

insert_new_file(Filename, ID, File, {Dir_Name, dir, Data}) ->
	{Dir_Name, dir, [{Filename, ID, File}|Data]}.

return_dir({Name, dir, Data}) -> {Name, dir, Data};
return_dir(_) -> [].

return (A) -> A.

list_tail([]) -> [];
list_tail(L) -> tl(L).

list_init([_El]) -> [];
list_init(List) -> lists:reverse(list_tail(lists:reverse(List))).

list_last([]) -> [];
list_last(List) -> lists:last(List).

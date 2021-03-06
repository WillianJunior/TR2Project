-module(application_supervisor).
-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

-define (MAX_RESTART, 15).
-define (MAX_TIME, 15). % seconds
-define (SHUTDOWN_TIME, 5000). % milliseconds

start_link(Port) ->
	supervisor:start_link({local,?MODULE}, ?MODULE, Port).
 
init(Port) ->
	{ok, {{one_for_one, ?MAX_RESTART, ?MAX_TIME},
		[{transport_system,
			{transport_system, start_link, []},
			transient, 1000, worker, [transport_system]},
		{dfs_supervisor,
			{dfs_supervisor, start_link, []},
			transient, 1000, supervisor, [dfs_supervisor]},
		{web_server,
			{web_server, start_link, [Port]},
			transient, 1000, worker, [web_server]}
	]}}.
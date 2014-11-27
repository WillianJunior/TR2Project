-module(dfs_supervisor).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define (MAX_RESTART, 15).
-define (MAX_TIME, 15). % seconds
-define (SHUTDOWN_TIME, 5000). % milliseconds

start_link() ->
	supervisor:start_link({local,?MODULE}, ?MODULE, []).

init(_) ->
	{ok, {{rest_for_one, ?MAX_RESTART, ?MAX_TIME},
		[{control_system,
			{control_system, start_link, []},
			transient, 1000, worker, [control_system]},
		{discovery_system,
			{discovery_system, start_link, []},
			transient, 1000, worker, [discovery_system]}
	]}}.
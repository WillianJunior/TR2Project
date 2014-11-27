-module(dfs).
-behaviour(application).
-export([start/2, stop/1]).
 
start(normal, Args) ->
	application_supervisor:start_link(Args).
 
stop(_State) ->
	ok.
{application, dfs,
	[{vsn, "0.1.0"},
		{modules, [transport_system, control_system, discovery_system, 
			web_server, dfs_supervisor, application_supervisor]},
		{registered, [dfs]},
		{mod, {dfs, {first, 1234}}}
	]
}.
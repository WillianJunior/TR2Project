{application, dfs,
	[{vsn, "0.1.0"},
		{description, "Distributed File System"},
		{modules, [dfs, transport_system, control_system, discovery_system, 
			web_server, dfs_supervisor, application_supervisor]},
		{registered, [dfs]},
		{mod, {dfs, 1234}},
		{applications, [kernel, stdlib]}
	]
}.
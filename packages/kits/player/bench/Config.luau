--!strict
-- Additions to the unchanged all-kit reference workload (50 players, 100 items each).
return {
	modules = { "Codes", "Settings" },
	config = {
		Codes = {
			definitions = {
				{
					id = "example",
					code = "EXAMPLE",
					testOnly = true,
					maxUses = 10,
					rewards = { { kind = "currency", amount = 1 } },
				},
			},
		},
		Settings = {
			schema = {
				{
					id = "cameraDistance",
					type = "slider",
					min = 1,
					max = 5,
					step = 1,
					default = 3,
					category = "gameplay",
					labelKey = "game.cameraDistance",
					scope = "saved",
				},
			},
		},
	},
	strings = { ["game.cameraDistance"] = "Camera distance" },
}

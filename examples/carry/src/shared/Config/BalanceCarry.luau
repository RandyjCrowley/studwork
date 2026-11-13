--!strict
-- config.Carry for the fixture game (owner: the Carry builder): the carriables and delivery tag.
-- Merged over the module defaults (docs/framework/kits/carry.md "Config").
return {
	carriables = {
		DemoCrate = {
			massClass = "medium",
			carriers = { min = 1, max = 1 },
			gripPoints = { { 0, 0, 0 } },
		},
		-- a couch: two carriers, one at each end, 2.5 studs in front of each (holdOffset)
		DemoCouch = {
			massClass = "heavy",
			carriers = { min = 2, max = 2 },
			gripPoints = { { -3, 0, 0 }, { 3, 0, 0 } },
			speedPenalty = 0.1,
			fragility = 0.8,
		},
		-- the void-drop crate: a light object on the ledge
		DemoVoidCrate = {
			massClass = "light",
			carriers = { min = 1, max = 1 },
			gripPoints = { { 0, 0, 0 } },
		},
	},
	-- the demo opts in to hard-landing drops (off by default; carry.md "dropRules" lists its limits)
	dropRules = { hardLandingSpeed = 55 },
}

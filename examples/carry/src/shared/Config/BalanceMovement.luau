--!strict
-- config.Movement for the fixture game (owner: the Movement builder): the demo's volume tags and
-- responses. Merged over the module defaults (docs/framework/kits/carry.md "Movement > Config").
return {
	volumes = {
		Hazard = "hazard",
		NoEntry = "noEntry",
		MovingPlatform = "platform",
		Climbable = "climbable",
	},
	-- visible in the demo: a strike actually shows up (log is invisible by default)
	responses = { teleport = "strike", volumeSweep = "strike" },
}

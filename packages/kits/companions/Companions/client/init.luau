--!strict
local Config = require(script.Parent.shared.Config)
local State = require(script.State)
local Follow = require(script.Follow)
local Screen = require(script.Screen)
return {
	init = function(ctx: any)
		Config.validate(ctx.config, ctx.gameConfig)
		Follow.init(ctx)
		Screen.init(ctx)
	end,
	start = function(ctx: any)
		Follow.start(ctx)
		Screen.start(ctx)
	end,
	actions = { "equip", "unequip", "equipBest" },
	api = {
		setLowDetail = Follow.api.setLowDetail,
		lowDetail = Follow.api.lowDetail,
		debugStats = Follow.api.debugStats,
		registerLook = Follow.api.registerLook,
		applyLook = Follow.api.applyLook,
		open = Screen.open,
		read = State,
	},
}

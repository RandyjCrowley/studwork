--!nocheck
--[[
	CarryFakeMovement: a stand-in Movement server part for Carry's specs (harness `servers = { Movement = part }`).
	It implements only what Carry reads: lastValid, velocity and the Strike / RunDisqualified / VolumeCrossed
	signals. The real Movement is built elsewhere; Carry must work against its frozen API only.

	  local mv = CarryFakeMovement.new(fw)
	  StudWork.test.harness({ modules = { Movement, Carry }, servers = { Movement = mv.part } })
	  mv.trusted[player] = false         -- lastValid now returns (cf, false)
	  mv.fire("Strike", player, "teleport", { response = "strike" })

	lastValid is the last SAMPLE (every 0.1 s on the shared ticker, from the world's raw root), so it lags
	the raw root like the real thing; nil before the first sample.
]]

local SignalTable = require("packages/kits/carry/Movement/server/SignalTable.luau")

local CarryFakeMovement = {}

function CarryFakeMovement.new(fw)
	local mv = { trusted = {}, samples = {}, velocities = {}, calls = 0 }
	local signals = SignalTable.new()
	local part = {}
	part.api = {
		lastValid = function(player)
			mv.calls += 1
			local cf = mv.samples[player]
			if cf == nil then
				return nil, false
			end
			return cf, mv.trusted[player] ~= false
		end,
		active = function()
			return true
		end,
		velocity = function(player)
			return mv.velocities[player]
		end,
		startRun = function() end,
		endRun = function()
			return true, {}
		end,
		teleport = function() end,
		exempt = function() end,
		strikes = function()
			return {}
		end,
		registerVolume = function() end,
		registerPlatformSource = function() end,
		setSpeedCap = function() end,
		setResponse = function() end,
		useWorld = function() end,
		signals = signals,
	}
	function part.init(ctx)
		for _, name in { "Strike", "RunDisqualified", "VolumeCrossed" } do
			signals[name] = ctx.signals.new(name)
		end
		mv.signals = signals
	end
	function part.start(ctx)
		ctx.lifecycle.onTick(0.1, function()
			for _, player in fw.world.players() do
				local _, cf = fw.world.rootOf(player)
				if cf ~= nil then
					mv.samples[player] = cf
				end
			end
		end)
	end
	function mv.fire(name, ...)
		signals[name]:Fire(...)
	end
	mv.part = part
	return mv
end

return CarryFakeMovement

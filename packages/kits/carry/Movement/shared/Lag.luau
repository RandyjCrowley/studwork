--!strict
--[[
	Lag: the lag allowance (docs/framework/kits/carry.md, Movement "Worked numbers"). Pure.

	  allowance = clamp(ping x pingFactor + jitterMarginSeconds, minSeconds, maxSeconds)   (0.45 s at ping 0.30)
	  teleport lag = max(allowance, teleport.minLagSeconds)                                  (0.60 s at the defaults)

	The teleport lag (never the plain allowance) is the lag term of the teleport cap, the speed window,
	the descent bound, the rise cap and the respawn envelope.
]]

export type LagConfig = {
	pingFactor: number,
	jitterMarginSeconds: number,
	minSeconds: number,
	maxSeconds: number,
}

local Lag = {}

function Lag.allowance(ping: number, cfg: LagConfig): number
	local raw = ping * cfg.pingFactor + cfg.jitterMarginSeconds
	return math.max(cfg.minSeconds, math.min(cfg.maxSeconds, raw))
end

function Lag.teleportLag(allowance: number, minLagSeconds: number): number
	return math.max(allowance, minLagSeconds)
end

return Lag

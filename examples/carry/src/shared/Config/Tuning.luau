--!strict
--[[
	Game-own numbers that are not part of Types.GameConfig (tools/lint guardrail "numbers" flags
	literals outside src/shared/Config). Each module's builder keeps its demo numbers in its OWN file,
	so the two builders never edit the same lines: TuningCarry.luau (the Carry demo: object sizes,
	zone sizes, positions) and TuningMovement.luau (the Movement demo: volumes, platform speed, the
	scripted cheat).
]]

return {
	carry = require(script.Parent.TuningCarry),
	movement = require(script.Parent.TuningMovement),
}

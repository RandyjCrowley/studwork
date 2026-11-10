--!strict
--[[
	Framework internal: the side's installed runtime + starter that the StudWork facade reads.
	Written only through packages/framework/server/Boot.luau (decisions.md, core-v1.3.0 Phase 0
	step 4, decision 3): StudWork itself exposes no _attach/_installStarter escape hatch, so the
	Phase 2 "nothing is special" lint rule has nothing on the public table to allowlist.
]]

local RuntimeSlot = {
	runtime = nil :: any,
	starter = nil :: ((...any) -> any)?,
}

return RuntimeSlot

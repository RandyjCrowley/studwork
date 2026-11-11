--!strict
--[[
	Framework internal (decisions.md, v1.3.0, decision 3): installs the server
	runtime into the StudWork facade. Required only by the framework's own server/init.luau
	(and a future client runtime), never by StudWork, kits or game code.
]]

local Shared = require(script.Parent.Shared)
local requireShared = require :: any -- see Shared.luau
local RuntimeSlot = requireShared(Shared.RuntimeSlot)

local Boot = {}

function Boot.installStarter(fn: (...any) -> any)
	RuntimeSlot.starter = fn
end

function Boot.attach(rt: any)
	RuntimeSlot.runtime = rt
end

return Boot

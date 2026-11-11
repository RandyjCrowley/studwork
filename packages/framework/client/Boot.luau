--!strict
--[[
	Framework internal: installs the CLIENT runtime into the StudWork facade (the client twin of
	server/Boot.luau; decisions.md, v1.3.0, decision 3). Required only by the
	framework client's own init.luau / Runtime.luau, never by StudWork, kits or game code.
]]

local parent: any = script.Parent.Parent
local shared: any = parent and parent:FindFirstChild("shared")
if shared == nil then
	shared = game:GetService("ReplicatedStorage"):WaitForChild("Framework")
end
local RuntimeSlot = (require :: any)(shared:WaitForChild("RuntimeSlot"))

local Boot = {}

Boot.shared = shared

function Boot.installStarter(fn: (...any) -> any)
	RuntimeSlot.starter = fn
end

function Boot.attach(rt: any)
	RuntimeSlot.runtime = rt
end

function Boot.runtime(): any
	return RuntimeSlot.runtime
end

return Boot

--!strict
--[[
	Locates the framework's shared folder. In the Lune harness (and any layout where server/ and
	shared/ are siblings) it's script.Parent.Parent.shared; in a Rojo place it's
	ReplicatedStorage.Framework (server code lives in ServerScriptService, shared code doesn't).

	Server files require shared modules through `requireShared = require :: any` because luau-lsp
	can't resolve this dynamic path. The core Lune harness's fake `game` only maps
	ReplicatedStorage.Core (packages/core is off-limits in this step); when packages/core becomes
	kits/framework and the Rojo/harness mapping gains ReplicatedStorage.Framework, switch these
	to direct, typed requires.
]]

local parent: any = script.Parent.Parent
local shared: any = parent and parent:FindFirstChild("shared")
if shared == nil then
	shared = game:GetService("ReplicatedStorage"):WaitForChild("Framework")
end
return shared

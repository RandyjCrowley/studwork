--!strict
--[[
	UI theme derived from the shared palette. OWNED BY AGENT F (core/f-ui).
	Theme.get(overrides?) resolves palette keys to Color3 at runtime.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Palette = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("Palette"))

local Theme = {}

Theme.fonts = Palette.fonts
Theme.metrics = Palette.metrics

function Theme.color(key: string, overrides: { [string]: string }?): Color3
	return Palette.color(key, overrides)
end

return Theme

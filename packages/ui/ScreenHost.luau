--!strict
--[[
	ScreenHost: renders every open screen of a Screens registry (UI.screens by default), each with
	its props plus onClose (closes it). A prop `bind` (a Charm selector / function returning a
	table) is re-read on every state change and merged into the props, so a screen opened with
	UI.open("Mailbox", { bind = function() return { messages = ... } end }) stays live.

	ScreenHost.mount(registry) lazily creates the "CoreScreens" ScreenGui (DisplayOrder 10, above
	the HUD) the first time a screen opens; UI.open calls it.

	props: registry: Screens?
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local React = require(Packages:WaitForChild("React"))
local ReactCharm = require(Packages:WaitForChild("ReactCharm"))
local ReactRoblox = require(Packages:WaitForChild("ReactRoblox"))
local ScaledRoot = require(script.Parent.ScaledRoot)

local e = React.createElement

local ScreenHost = {}

local function none(): any
	return nil
end

local function ScreenSlot(props: { entry: any, registry: any })
	local entry = props.entry
	local bound = ReactCharm.useAtom(if type(entry.props.bind) == "function" then entry.props.bind else none)
	local p: { [string]: any } = table.clone(entry.props)
	if type(bound) == "table" then
		for k, v in bound do
			p[k] = v
		end
	end
	p.bind = nil
	local userClose = entry.props.onClose
	p.onClose = function()
		props.registry:close(entry.name)
		if type(userClose) == "function" then
			userClose()
		end
	end
	return e(entry.component, p)
end

function ScreenHost.Component(props: { registry: any })
	local registry = props.registry
	local version, setVersion = React.useState(0)
	React.useEffect(function()
		return registry:subscribe(function()
			setVersion(function(v: number): number
				return v + 1
			end)
		end)
	end, { registry })
	local _ = version
	local children: { [string]: any } = {}
	for i, entry in registry:openList() do
		children[entry.name] = e("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			ZIndex = i,
		}, { Screen = e(ScreenSlot, { entry = entry, registry = registry }) })
	end
	return e(ScaledRoot, nil, children)
end

local mounted: { [any]: boolean } = {}

function ScreenHost.mount(registry: any)
	if mounted[registry] then
		return
	end
	mounted[registry] = true
	local gui = Instance.new("ScreenGui")
	gui.Name = "CoreScreens"
	gui.ResetOnSpawn = false
	gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 10
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	ReactRoblox.createRoot(gui):render(e(ScreenHost.Component, { registry = registry }))
end

return ScreenHost

--!strict
--[[
	Claim and completion toasts. A UI.ToastHost (theme tokens, queued, never modal) in its own
	ScreenGui, created on the first toast (nothing is created at start), so the quest part draws
	nothing until something happens. The host's frame is transparent and only the toast pills take
	taps, so it never blocks input.

	  local toasts = Toasts.new()
	  toasts.push(text)       queues a toast (texts pushed before the host mounted are kept)
	  toasts.destroy()

	Loaded lazily by client/init.luau (it needs React and the UI kit).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local React = require(Packages:WaitForChild("React")) :: any
local ReactRoblox = require(Packages:WaitForChild("ReactRoblox")) :: any
local UI = require(ReplicatedStorage:WaitForChild("UI")) :: any

local e = React.createElement

local GUI_NAME = "QuestsToasts"
local DISPLAY_ORDER = 50

local Toasts = {}

function Toasts.new(): any
	local pending: { string } = {}
	local pushFn: ((text: string) -> ())? = nil
	local gui: ScreenGui? = nil
	local root: any = nil

	local function ensure()
		if gui ~= nil then
			return
		end
		local player = Players.LocalPlayer
		local playerGui = if player then player:FindFirstChildOfClass("PlayerGui") else nil
		if playerGui == nil then
			return
		end
		local g = Instance.new("ScreenGui")
		g.Name = GUI_NAME
		g.ResetOnSpawn = false
		g.DisplayOrder = DISPLAY_ORDER
		g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		g.Parent = playerGui
		gui = g
		root = ReactRoblox.createRoot(g)
		root:render(e(UI.ToastHost, {
			subscribe = function(push: (text: string) -> ()): () -> ()
				pushFn = push
				for _, text in pending do
					push(text)
				end
				table.clear(pending)
				return function()
					pushFn = nil
				end
			end,
		}))
	end

	local api = {}

	function api.push(text: string)
		ensure()
		if pushFn ~= nil then
			pushFn(text)
		else
			table.insert(pending, text)
		end
	end

	function api.destroy()
		if root ~= nil then
			root:unmount()
			root = nil
		end
		if gui ~= nil then
			gui:Destroy()
			gui = nil
		end
		pushFn = nil
		table.clear(pending)
	end

	return api
end

return Toasts

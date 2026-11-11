--[[
	Builds examples/legacy/legacy-example-a/legacy-example-a.rbxlx: a small Studio-only game (no
	Rojo, no StudWork) used as an adoption fixture (docs/framework/adopting.md, the v1.6.0 dogfood).
	Run from the repo root: lune run examples/legacy/_build/legacy-example-a/build
	The place is committed; rebuild it only when these sources change.
]]
local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local Instance = roblox.Instance

local SRC = "examples/legacy/_build/legacy-example-a/src/"
local OUT = "examples/legacy/legacy-example-a/legacy-example-a.rbxlx"

local function new(class: string, name: string, parent: any): any
	local i = Instance.new(class)
	i.Name = name
	i.Parent = parent
	return i
end

local function script(class: string, name: string, file: string, parent: any): any
	local s = new(class, name, parent)
	s.Source = fs.readFile(SRC .. file)
	return s
end

local game = Instance.new("DataModel")
local rs = game:GetService("ReplicatedStorage")
local sss = game:GetService("ServerScriptService")
local ws = game:GetService("Workspace")
local sg = game:GetService("StarterGui")
local sp = game:GetService("StarterPlayer")

local remotes = new("Folder", "Remotes", rs)
new("RemoteEvent", "BuyItem", remotes)
new("RemoteEvent", "ClaimDaily", remotes)
new("RemoteEvent", "ToggleMusic", remotes)
new("RemoteFunction", "GetShop", remotes)
script("ModuleScript", "ShopItems", "ShopItems.luau", rs)

script("Script", "DataManager", "DataManager.server.luau", sss)
script("Script", "ShopServer", "ShopServer.server.luau", sss)
script("Script", "Purchases", "Purchases.server.luau", sss)

local baseplate = new("Part", "Baseplate", ws)
baseplate.Anchored = true
baseplate.Size = roblox.Vector3.new(256, 4, 256)
baseplate.Position = roblox.Vector3.new(0, -2, 0)
local pad = new("Part", "CoinPad", ws)
pad.Anchored = true
pad.Size = roblox.Vector3.new(8, 1, 8)
pad.Position = roblox.Vector3.new(0, 0.5, 12)
pad.BrickColor = roblox.BrickColor.new("Bright yellow")
script("Script", "CoinPadScript", "CoinPadScript.server.luau", pad)
local spawnLocation = new("SpawnLocation", "SpawnLocation", ws)
spawnLocation.Anchored = true
spawnLocation.Position = roblox.Vector3.new(0, 0.5, 0)

local gui = new("ScreenGui", "ShopGui", sg)
gui.ResetOnSpawn = false
local frame = new("Frame", "Frame", gui)
frame.Size = roblox.UDim2.new(0, 260, 0, 320)
frame.Position = roblox.UDim2.new(0, 16, 0.5, -160)
local list = new("ScrollingFrame", "List", frame)
list.Size = roblox.UDim2.new(1, -16, 1, -96)
list.Position = roblox.UDim2.new(0, 8, 0, 8)
new("UIListLayout", "Layout", list)
local daily = new("TextButton", "Daily", frame)
daily.Size = roblox.UDim2.new(1, -16, 0, 36)
daily.Position = roblox.UDim2.new(0, 8, 1, -84)
daily.Text = "Daily reward"
local pack = new("TextButton", "CoinPack", frame)
pack.Size = roblox.UDim2.new(1, -16, 0, 36)
pack.Position = roblox.UDim2.new(0, 8, 1, -44)
pack.Text = "1000 coins (Robux)"
script("LocalScript", "ShopGuiClient", "ShopGuiClient.client.luau", gui)

local sps = sp:FindFirstChildOfClass("StarterPlayerScripts") or new("StarterPlayerScripts", "StarterPlayerScripts", sp)
script("LocalScript", "MusicClient", "MusicClient.client.luau", sps)

fs.writeFile(OUT, roblox.serializePlace(game, true))
print("wrote " .. OUT)

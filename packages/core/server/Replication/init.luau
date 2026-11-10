--!strict
--[[
	Server -> local player state replication. OWNED BY AGENT G (core/g-client).

	PHASE 0 STUB: sends the FULL ReplicatedState snapshot to a player on every DataChanged and
	every set(), deferred to once per frame per player. Agent G replaces this with Charm atoms
	on the server + charm-sync, sending patches (changes only) to the owning player only.

	Contract (keep): set(player, key, value) / setAll(key, value) for non-PlayerData keys of
	Types.ReplicatedState; StateInit request sends a full snapshot; payload goes through the
	Blink StateSync event; one player's data is never sent to another player.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))

local Replication = {}

local ctx: any = nil
local extra: { [Player]: { [string]: any }? } = {}
local shared: { [string]: any } = {}
local pending: { [Player]: boolean } = {}

local function snapshot(player: Player): Types.ReplicatedState
	local e: { [string]: any } = extra[player] or {}
	local data = ctx.services.Data.get(player)
	return {
		loaded = data ~= nil,
		data = data,
		ratePerSec = e.ratePerSec or 0,
		multiplier = e.multiplier or 1,
		paidRandomRestricted = if e.paidRandomRestricted == nil then true else e.paidRandomRestricted,
		activeEvents = shared.activeEvents or {},
		plotName = e.plotName,
	}
end

function Replication.init(context: any)
	ctx = context
end

function Replication.set(player: Player, key: string, value: any)
	local e: { [string]: any } = extra[player] or {}
	extra[player] = e
	if e[key] ~= value then
		e[key] = value
		pending[player] = true
	end
end

function Replication.setAll(key: string, value: any)
	shared[key] = value
	for _, player in Players:GetPlayers() do
		pending[player] = true
	end
end

function Replication.start()
	ctx.signals.DataChanged:Connect(function(player: Player)
		pending[player] = true
	end)
	ctx.net.handle("StateInit", function(player: Player)
		pending[player] = true
	end)
	Players.PlayerRemoving:Connect(function(player)
		extra[player] = nil
		pending[player] = nil
	end)
	RunService.Heartbeat:Connect(function()
		if next(pending) == nil then
			return
		end
		local batch = pending
		pending = {}
		for player in batch do
			if player.Parent == Players then
				ctx.net.events.StateSync.Fire(player, { full = snapshot(player) })
			end
		end
	end)
end

return Replication

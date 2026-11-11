--!strict
--[[
	Core.Client.state. OWNED BY AGENT G (core/g-client).

	State.atom is a Charm atom (Types.Atom<Types.ReplicatedState>) with the same identity for the
	whole session. The server (server/Replication) syncs it with charm-sync 0.4.1:
	  * the client registers State.atom under its own key tostring(LocalPlayer.UserId) with
	    CharmSync.client.addSignals, then fires StateInit;
	  * StateSync payloads ({ SyncPayload }) are applied with CharmSync.client.patch, which sets
	    the atom from "init" (full state) or merges "patch" diffs immutably (patch.apply clones
	    every changed table, so React/Charm selectors see new references only where data changed);
	  * loaded becomes true once the server has PlayerData for us (it ships loaded = data ~= nil).
	Client code should only READ the atom.

	core-v1.3.0 (step 4b-IIa): charm-sync now patches State.raw, the replicated state as the
	server sends it (StudWork.Client.state(), module-api.md §10: { loaded, framework, modules }).
	State.atom is a selector over it through State.setView. Since Phase 2 the client bootstrap no
	longer installs the compat FlatState view (Hud reads State.raw through Hud/Slices, onMailbox
	reads either shape), so State.atom is the raw state unless a caller installs a view.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Charm = require(Packages:WaitForChild("Charm"))
local CharmSync = require(Packages:WaitForChild("CharmSync")) :: any
local Types = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("Types"))

local PayloadCheck = require(script.PayloadCheck)

local State = {}

local initial: Types.ReplicatedState = {
	loaded = false,
	data = nil,
	ratePerSec = 0,
	multiplier = 1,
	paidRandomRestricted = true,
	activeEvents = {},
	plotName = nil,
}

-- What charm-sync patches: the server's replicated state, unchanged.
State.raw = (Charm.atom(initial) :: any) :: Types.Atom<any>

local view: (raw: any) -> any = function(raw: any): any
	return raw
end

-- The flat v1.2 view the v1.2 UI reads (identity until the bootstrap installs a view).
State.atom = (
	Charm.computed(function(): any
		return view(State.raw())
	end) :: any
) :: Types.Atom<Types.ReplicatedState>

-- An optional view over the raw state (none is installed since Phase 2).
function State.setView(fn: (raw: any) -> any)
	view = fn
end

local started = false

function State.start(ctx: any)
	if started then
		return
	end
	started = true
	local key = tostring(Players.LocalPlayer.UserId)
	CharmSync.client.addSignals({ [key] = State.raw })
	ctx.net.StateSync.On(function(payloads: any)
		local ok, reason = PayloadCheck.check(payloads, key)
		if not ok then
			warn(`[State] ignored StateSync payload: {reason}`)
			return
		end
		CharmSync.client.patch(payloads)
	end)
	ctx.net.StateInit.Fire()
end

return State

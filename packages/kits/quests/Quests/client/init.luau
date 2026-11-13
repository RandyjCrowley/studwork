--!strict
--[[
	Quests client part (docs/framework/kits/quests.md, "Client part and UI").

	The client never progresses a quest: the actions only claim, reroll, pin and acknowledge (they
	fire this module's own Blink events, ../net.blink -> ./Net.luau, bound by the client runtime as
	the part's `net`), and the server checks every one. It reads the replicated board
	(extra.board), live values (extra.prog), the disclosed roll odds (extra.questOdds) and its own
	config (titles, objectives, rewards).

	  StudWork.use(Quests).active() -> { QuestView }        from state + config, board order
	  StudWork.use(Quests).board() -> extra.board?          the raw board
	  StudWork.use(Quests).onCompleted(fn(questId)) -> () -> ()   a quest's status turned complete
	                                                        (not for the first state after joining)
	  StudWork.use(Quests).onClaimed(fn(questId)) -> () -> ()     a claim landed
	  StudWork.use(Quests).open(tab?)                       opens the "Quests" screen (the player's
	                                                        own action: nothing here opens it)
	  StudWork.use(Quests).read.<reader>(state)             pure state readers (client/State.luau)
	  StudWork.use(Quests).actions.claimQuest(questId) / rerollQuest(kind, slot) / pinQuest(questId, on)
	      / ackQuest(key)

	At start: the screen "Quests" (Board.luau; unless the game registered its own first), the HUD
	widgets "Quests.tracker" (right, 5) and "Quests.button" (right, 4) (unless the game removed
	them), and a toast for every completion and claim (Toasts.luau). The views load lazily, so
	requiring this part in a test or on a server never needs React; without the UI kit nothing
	is registered.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local State = require(script.State)

local SCREEN = "Quests"
local TRACKER_ID = "Quests.tracker"
local BUTTON_ID = "Quests.button"

local function studWork(): any
	return require(ReplicatedStorage:WaitForChild("Framework")) :: any
end

local function rawState(): any
	return studWork().Client.state()
end

local function ui(): any
	return require(ReplicatedStorage:WaitForChild("UI")) :: any
end

local function ownModule(): any
	return require(script.Parent:WaitForChild("module")) :: any
end

local function views(): any
	return {
		Board = require(script.Board),
		Tracker = require(script.Tracker),
		Button = require(script.Button),
	}
end

local function serverNow(): number
	local ok, t = pcall(function(): number
		return workspace:GetServerTimeNow()
	end)
	return if ok and type(t) == "number" then t else os.time()
end

local function openedFromGamepad(): boolean
	local ok, last = pcall(function(): string
		return game:GetService("UserInputService"):GetLastInputType().Name
	end)
	return ok and string.sub(last, 1, 7) == "Gamepad"
end

local Quests = {}

local clientCtx: any = nil -- { name, config, gameConfig } from the client runtime
local listeners: { completed: { [any]: boolean }, claimed: { [any]: boolean } } =
	{ completed = {}, claimed = {} }
local previous: any = nil
local toasts: any = nil
local unwatch: (() -> ())? = nil

local function cfg(): any
	return if clientCtx ~= nil and type(clientCtx.config) == "table" then clientCtx.config else {}
end

local function gameItems(): any
	local gc = if clientCtx ~= nil then clientCtx.gameConfig else nil
	return if type(gc) == "table" and type(gc.items) == "table" then gc.items else {}
end

local function primaryCurrency(): string
	local gc = if clientCtx ~= nil then clientCtx.gameConfig else nil
	local economy = if type(gc) == "table" and type(gc.config) == "table" then gc.config.Economy else nil
	return if type(economy) == "table" and type(economy.primaryCurrency) == "string"
		then economy.primaryCurrency
		else "Coins"
end

local function actions(): any
	return studWork().use(ownModule()).actions
end

local function open(tab: string?)
	assert(tab == nil or type(tab) == "string", "Quests.open(tab): tab must be a string or nil")
	ui().open(SCREEN, { tab = tab, gamepad = openedFromGamepad() })
end

-- Opens the UI kit's Odds screen with the disclosed luck-1 detail Quests replicated.
local function openOdds(tableId: string, odds: any)
	local UI = ui()
	local items = {}
	for key, def in gameItems() do
		if type(def) == "table" then
			local id = if type(def.id) == "string" then def.id else key -- the catalog is a list of defs
			table.insert(items, {
				id = id,
				name = if type(def.name) == "string" then def.name else id,
				rarity = if type(def.rarity) == "string" then def.rarity else "Common",
			})
		end
	end
	local detail = if type(odds) == "table" then odds[tableId] else nil
	UI.open("Odds", {
		title = UI.text("Quests.odds"),
		detail = detail,
		odds = if detail == nil then {} else nil,
		items = items,
	})
end

local function env(): any
	return {
		cfg = cfg(),
		items = gameItems(),
		primaryCurrency = primaryCurrency(),
		now = serverNow,
		open = open,
		claim = function(id: string)
			actions().claimQuest(id)
		end,
		reroll = function(kind: string, slot: number)
			actions().rerollQuest(kind, slot)
		end,
		pin = function(id: string, on: boolean)
			actions().pinQuest(id, on)
		end,
		openOdds = openOdds,
	}
end

local function fire(set: { [any]: boolean }, id: string)
	for fn in set do
		task.spawn(fn, id)
	end
end

-- A toast through the UI kit; without it (a test, a server) there is nothing to show and nothing fails.
local function toast(key: string, id: string)
	local hasUi, UI = pcall(ui)
	if not hasUi or type(UI) ~= "table" or UI.ToastHost == nil then
		return
	end
	local ok, err = pcall(function()
		if toasts == nil then
			toasts = require(script.Toasts).new()
		end
		toasts.push(UI.text(key, { title = UI.text(State.titleKey(cfg(), id)) }))
	end)
	if not ok then
		warn(`[Quests] toast failed: {err}`)
	end
end

-- Claims the board no longer lists: a chain or one-time quest that is claimed leaves the board (the
-- ledger holds it; the next step takes its place), so State.transitions never sees status "claimed"
-- for it. A quest that was complete and is gone from the snapshot, without a waiting entry of the
-- same id taking its place (a reset or an ended window moves it to waiting: that is not a claim),
-- was claimed.
local function vanishedClaims(prev: any, snap: any): { string }
	local out: { string } = {}
	if prev == nil then
		return out
	end
	local waitingIds: { [string]: boolean } = {}
	for _, now in snap do
		if now.waiting then
			waitingIds[now.id] = true
		end
	end
	local seen: { [string]: boolean } = {}
	for key, before in prev do
		if
			before.status == "complete"
			and not before.waiting
			and snap[key] == nil
			and not waitingIds[before.id]
		then
			if not seen[before.id] then
				seen[before.id] = true
				table.insert(out, before.id)
			end
		end
	end
	table.sort(out)
	return out
end
Quests.vanishedClaims = vanishedClaims

-- One watcher over the replicated state: the transitions between two board snapshots.
local function onState()
	local state = rawState()
	if not State.loaded(state) then
		previous = nil
		return
	end
	local snap = State.snapshot(State.views(state, cfg()))
	local completed, claimed = State.transitions(previous, snap)
	for _, id in vanishedClaims(previous, snap) do
		if table.find(claimed, id) == nil then
			table.insert(claimed, id)
		end
	end
	table.sort(claimed)
	previous = snap
	for _, id in completed do
		toast("Quests.toast.completed", id)
		fire(listeners.completed, id)
	end
	for _, id in claimed do
		toast("Quests.toast.claimed", id)
		fire(listeners.claimed, id)
	end
end

function Quests.init(context: any)
	clientCtx = context
end

function Quests.start(context: any)
	clientCtx = context or clientCtx
	previous = nil
	if unwatch ~= nil then
		unwatch()
		unwatch = nil
	end
	-- Charm is the replicated state's store; where it can't load (a Lune spec) `Quests.check` is the
	-- same watcher, called by hand
	local hasCharm, Charm = pcall(function(): any
		return require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Charm"))
	end)
	if hasCharm and type(Charm) == "table" then
		unwatch = Charm.subscribe(rawState, onState)
	end
	onState()

	-- the screen and widgets need the UI kit (and React): without it nothing is registered
	local ok, UI = pcall(ui)
	if not ok or type(UI) ~= "table" or UI.registerScreen == nil then
		return
	end
	if UI.screens:get(SCREEN) == nil then
		UI.registerScreen(SCREEN, function(props: any): any
			local merged = table.clone(props)
			merged.env = env()
			return views().Board.Screen(merged)
		end)
	end
	local _, removals = UI.widgets()
	if removals[TRACKER_ID] == nil then
		UI.registerWidget(TRACKER_ID, {
			slot = "right",
			order = 5,
			module = "Quests",
			component = function(props: any): any
				local merged = table.clone(props)
				merged.env = env()
				return views().Tracker(merged)
			end,
		})
	end
	if removals[BUTTON_ID] == nil then
		UI.registerWidget(BUTTON_ID, {
			slot = "right",
			order = 4,
			module = "Quests",
			component = function(props: any): any
				local merged = table.clone(props)
				merged.env = env()
				return views().Button(merged)
			end,
		})
	end
end

-- Compares the state with the last one seen and fires onCompleted / onClaimed and the toasts. The
-- subscription calls it on every state change; specs call it after changing a fake state.
Quests.check = onState

Quests.actions = { "claimQuest", "rerollQuest", "pinQuest", "ackQuest" }

Quests.api = {
	active = function(): { any }
		return State.views(rawState(), cfg())
	end,
	board = function(): any
		return State.board(rawState())
	end,
	onCompleted = function(fn: (questId: string) -> ()): () -> ()
		assert(type(fn) == "function", "Quests.onCompleted(fn): fn must be a function")
		listeners.completed[fn] = true
		return function()
			listeners.completed[fn] = nil
		end
	end,
	onClaimed = function(fn: (questId: string) -> ()): () -> ()
		assert(type(fn) == "function", "Quests.onClaimed(fn): fn must be a function")
		listeners.claimed[fn] = true
		return function()
			listeners.claimed[fn] = nil
		end
	end,
	open = open,
	read = State,
}

return Quests

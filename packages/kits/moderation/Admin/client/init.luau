--!strict
--[[
	Admin client part (docs/framework/kits/moderation.md "Client part and the panel").

	The panel's UI code is NOT here: the server clones it into a staff player's PlayerGui only
	(PlayerGui.StudWorkAdminPanel.Panel), so a non-staff client never receives it. This part reads
	extra.staff (set for staff only), hands the delivered panel a small bridge (this module's own
	Net events) and mounts it when it arrives; it unmounts it when the server takes it away.

	  StudWork.use(Admin).isStaff() -> boolean
	  StudWork.use(Admin).permissions() -> { string }   (frozen; {} for non-staff)
	  StudWork.use(Admin).role() -> string?
	  StudWork.use(Admin).panel()                       opens the delivered panel; no-op without one
	  StudWork.use(Admin).actions.run / fetch / panelOpen   this module's own Net events (net.blink)

	Server -> client: Rows / RunResult go to the open panel; Spectate(userId?) points this
	player's camera at that player (nil: back to their own character); Announce(payload) shows a
	notification to everyone ("k|<key>" a preset strings key, "t|<text>" text the server already
	filtered with TextFilter "public").
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NAME = "Admin"
local PANEL_NAME = "StudWorkAdminPanel"
local ANNOUNCE_KEY = "k|"
local ANNOUNCE_TEXT = "t|"
local EMPTY: { string } = table.freeze({})

local net: any = nil
local controller: any = nil
local mountedHolder: any = nil
local rowsListeners: { [any]: boolean } = {}
local resultListeners: { [any]: boolean } = {}
local staffListeners: { [any]: boolean } = {}

local function studWork(): any
	return require(ReplicatedStorage:WaitForChild("Framework")) :: any
end

local function staff(): any
	local state = studWork().Client.state()
	if type(state) ~= "table" or type(state.modules) ~= "table" then
		return nil
	end
	local slice = state.modules[NAME]
	local extra = if type(slice) == "table" then slice.extra else nil
	local value = if type(extra) == "table" then extra.staff else nil
	return if type(value) == "table" then value else nil
end

local function listen(eventName: string, fn: (...any) -> ())
	local event = if net ~= nil then net[eventName] else nil
	if event ~= nil and type(event.On) == "function" then
		event.On(fn)
	end
end

local function fireEvent(eventName: string, ...: any)
	local event = if net ~= nil then net[eventName] else nil
	if event ~= nil and type(event.Fire) == "function" then
		event.Fire(...)
	end
end

local function notify(set: { [any]: boolean }, ...: any)
	for fn in set do
		task.spawn(fn, ...)
	end
end

local function subscribe(set: { [any]: boolean }, fn: any): () -> ()
	set[fn] = true
	return function()
		set[fn] = nil
	end
end

local bridge = {
	staff = staff,
	onStaff = function(fn: () -> ()): () -> ()
		return subscribe(staffListeners, fn)
	end,
	onRows = function(fn: (string, number, string) -> ()): () -> ()
		return subscribe(rowsListeners, fn)
	end,
	onResult = function(fn: (boolean, string) -> ()): () -> ()
		return subscribe(resultListeners, fn)
	end,
	run = function(run: any)
		fireEvent("Run", run.actionId, run.targetUserId, run.preset, run.duration, run.text)
	end,
	fetch = function(tabId: string, page: number)
		fireEvent("Fetch", tabId, page)
	end,
	panelOpen = function()
		fireEvent("PanelOpen", 0)
	end,
	holder = nil :: any,
}

local function unmount()
	if controller ~= nil then
		pcall(controller.destroy)
	end
	controller = nil
	mountedHolder = nil
end

-- mount the panel the server delivered (a staff player only ever has one)
local function mount(holder: any)
	if holder == mountedHolder then
		return
	end
	unmount()
	local source = holder:WaitForChild("Panel", 10)
	if source == nil or not source:IsA("ModuleScript") then
		return
	end
	local ok, Panel = pcall(require, source)
	if not ok or type(Panel) ~= "table" or type(Panel.mount) ~= "function" then
		warn(`[Admin] the delivered panel didn't load: {tostring(Panel)}`)
		return
	end
	bridge.holder = holder
	mountedHolder = holder
	controller = Panel.mount(bridge)
	holder.AncestryChanged:Connect(function()
		if holder.Parent == nil and mountedHolder == holder then
			unmount()
		end
	end)
end

local function watchPanel()
	local player = game:GetService("Players").LocalPlayer
	if player == nil then
		return
	end
	local gui = player:WaitForChild("PlayerGui")
	local existing = gui:FindFirstChild(PANEL_NAME)
	if existing ~= nil then
		task.spawn(mount, existing)
	end
	gui.ChildAdded:Connect(function(child: Instance)
		if child.Name == PANEL_NAME then
			mount(child)
		end
	end)
end

local function humanoidOf(player: Player?): any
	local character = if player ~= nil then player.Character else nil
	return if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
end

local function spectate(userId: number?)
	local camera = game:GetService("Workspace").CurrentCamera
	if camera == nil then
		return
	end
	local target = if userId ~= nil then Players:GetPlayerByUserId(userId) else nil
	local subject = humanoidOf(target) or humanoidOf(Players.LocalPlayer)
	if subject ~= nil then
		camera.CameraSubject = subject
	end
end

local function announce(payload: string)
	local prefix, rest = string.sub(payload, 1, 2), string.sub(payload, 3)
	if rest == "" then
		return
	end
	local UI = require(ReplicatedStorage:WaitForChild("UI")) :: any
	local shown: string
	if prefix == ANNOUNCE_KEY then
		shown = UI.text(rest)
	elseif prefix == ANNOUNCE_TEXT then
		shown = rest -- filtered "public" on the server (GetNonChatStringForBroadcastAsync)
	else
		return
	end
	pcall(function()
		game:GetService("StarterGui"):SetCore("SendNotification", {
			Title = UI.text("Admin.announce.title"),
			Text = shown,
		})
	end)
end

local Admin = {}

function Admin.init(_context: any)
	local ok, loaded = pcall(function(): any
		return (require :: any)(script.Net)
	end)
	net = if ok then loaded else nil
end

function Admin.start(_context: any)
	listen("Rows", function(tabId: string, page: number, json: string)
		notify(rowsListeners, tabId, page, json)
	end)
	listen("RunResult", function(ok: boolean, key: string)
		notify(resultListeners, ok, key)
	end)
	listen("Spectate", spectate)
	listen("Announce", announce)
	-- the panel re-reads extra.staff when the replicated state changes
	local Charm = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Charm")) :: any
	Charm.subscribe(staff, function()
		notify(staffListeners)
	end)
	task.spawn(watchPanel)
end

-- `run = true`: fire this part's own Net event of the same (PascalCase) name (module-api §19.9)
Admin.actions = { run = true, fetch = true, panelOpen = true }

Admin.api = {
	isStaff = function(): boolean
		return staff() ~= nil
	end,
	permissions = function(): { string }
		local s = staff()
		return if s ~= nil and type(s.permissions) == "table"
			then table.freeze(table.clone(s.permissions))
			else EMPTY
	end,
	role = function(): string?
		local s = staff()
		return if s ~= nil and type(s.role) == "string" then s.role else nil
	end,
	panel = function()
		if staff() == nil or controller == nil then
			return
		end
		controller.open()
	end,
}

return Admin

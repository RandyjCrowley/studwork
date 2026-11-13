--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local SoundService = game:GetService("SoundService")
local Schema = require(script.Parent.shared.Schema)
local Model = require(script.Model)
local Preferences = require(script.Preferences)
local Registration = require(script.Registration)
local SendQueue = require(script.SendQueue)
local Settings: any = { actions = { "set" } }
local defs: { [string]: any } = {}
local callbacks: { [any]: boolean } = {}
local config: any = nil
local model: any = nil
local preferences: any = nil
local cleanup: { () -> () } = {}
local hooks: { [string]: any } = {}
local deferred: { [string]: any } = {}
local viewListeners: { [any]: boolean } = {}
local sendQueue: any = nil
local function framework(): any
	return require(ReplicatedStorage:WaitForChild("Framework")) :: any
end
local function ui(): any
	return require(ReplicatedStorage:WaitForChild("UI")) :: any
end
local function enabled(): boolean
	if config == nil or config.rate.rate <= 0 then
		return false
	end
	if config.flag == nil then
		return true
	end
	local ok, on = pcall(framework().flags.isOn, config.flag)
	return ok and on == true
end
local function changed(id: string, value: any)
	if preferences then
		preferences.apply(id, value)
	end
	local hook = hooks[id] or (if defs[id] then defs[id].apply else nil)
	if hook then
		pcall(hook, value)
	end
	for fn in callbacks do
		task.spawn(fn, id, value)
	end
end
local function sameDefinition(a: any, b: any): boolean
	for _, key in
		{ "id", "type", "default", "category", "labelKey", "descriptionKey", "scope", "min", "max", "step" }
	do
		if a[key] ~= b[key] then
			return false
		end
	end
	if a.type == "choice" then
		if #a.choices ~= #b.choices then
			return false
		end
		for i, choice in a.choices do
			if b.choices[i] ~= choice then
				return false
			end
		end
	end
	return true
end
Settings.api = {
	get = function(id: string): any
		return if model then model.get(id) else nil
	end,
	set = function(id: string, value: any): boolean
		return model ~= nil and model.edit(id, value)
	end,
	register = function(def: any): boolean
		if not Schema.validateDefinition(def) then
			return false
		end
		local existing = defs[def.id]
		if existing then
			if not sameDefinition(existing, def) then
				return false
			end
			if model then
				Registration.attach(hooks, def.id, def.apply, model)
			end
			return true
		end
		if config == nil then
			return false
		end
		if def.scope == "saved" then
			local pendingCount = 0
			for _ in deferred do
				pendingCount += 1
			end
			if pendingCount >= config.maxSettings then
				return false
			end
			deferred[def.id] = table.clone(def)
			return true
		end
		local count = 0
		for _ in defs do
			count += 1
		end
		if count >= config.maxSettings then
			return false
		end
		defs[def.id] = table.clone(def)
		if model then
			changed(def.id, model.get(def.id))
		end
		return true
	end,
	onChanged = function(fn: any): any
		assert(type(fn) == "function", "Settings.onChanged: function required")
		callbacks[fn] = true
		local connection = { Connected = true }
		function connection.Disconnect(self: any)
			self.Connected = false
			callbacks[fn] = nil
		end
		return connection
	end,
	open = function()
		if enabled() then
			ui().open("Settings")
		end
	end,
	reset = function()
		if model == nil then
			return
		end
		for id in defs do
			model.reset(id)
		end
	end,
}
function Settings.init(ctx: any)
	config = ctx.config
	defs = Schema.resolve(config)
	preferences = Preferences.new({
		player = Players.LocalPlayer,
		gui = GuiService,
		sounds = SoundService,
		audio = config.audio,
		createGroup = function()
			return Instance.new("SoundGroup")
		end,
		refreshDefault = function(id: string)
			if model then
				model.refreshDefault(id)
			end
		end,
	})
	model = Model.new(defs, {
		default = preferences.default,
		validate = Schema.validate,
		enabled = enabled,
		maxRequest = Schema.MAX_REQUEST,
		debounce = config.debounceSeconds,
		delay = task.delay,
		changed = changed,
		updated = function()
			for fn in viewListeners do
				task.spawn(fn)
			end
		end,
		cancelled = function()
			if sendQueue then
				sendQueue.reset()
			end
		end,
		send = function(id: string, value: any, request: number)
			sendQueue.send(id, value, request)
		end,
	})
	sendQueue = SendQueue.new({
		model = model,
		now = os.clock,
		delay = task.delay,
		enabled = enabled,
		interval = 1 / math.min(4, math.max(config.rate.rate, 0.01)),
		timeout = 10,
		default = function(id: string)
			return preferences.default(defs[id])
		end,
		fire = function(id: string, value: any, request: number)
			local kind, boolValue, numberValue, stringValue = Schema.encode(value)
			require(script.Net).Set.Fire(id, kind, boolValue, numberValue, stringValue, request)
		end,
	})
	for id in defs do
		changed(id, model.get(id))
	end
end
function Settings.start(_ctx: any)
	local Net = require(script.Net)
	table.insert(
		cleanup,
		Net.Ack.On(
			function(
				id: string,
				kind: string,
				boolValue: boolean,
				numberValue: number,
				stringValue: string,
				request: number,
				accepted: boolean,
				revision: number
			)
				local ok, value = Schema.decode(defs[id], kind, boolValue, numberValue, stringValue)
				if ok then
					model.ack(id, value, request, accepted, revision)
				end
			end
		)
	)
	local Charm = require(ReplicatedStorage.Packages.Charm) :: any
	local ref = require(script.Parent.module)
	local function snapshot(): any
		return framework().use(ref).state().extra or {}
	end
	local function receive(extra: any)
		Registration.receive({
			defs = defs,
			hooks = hooks,
			deferred = deferred,
			model = model,
			validate = Schema.validateDefinition,
			same = sameDefinition,
		}, extra)
	end
	receive(snapshot())
	table.insert(cleanup, Charm.subscribe(snapshot, receive))
	if config.flag then
		local connection = framework().flags.onChanged(config.flag, function(on: boolean)
			if not on then
				sendQueue.cancel()
				ui().close("Settings")
			end
		end)
		table.insert(cleanup, function()
			connection:Disconnect()
		end)
	end
	local UI = ui()
	if UI.screens:get("Settings") == nil then
		UI.registerScreen("Settings", function(props: any): any
			local viewProps = table.clone(props)
			viewProps.api = Settings.api
			viewProps.definitions = defs
			viewProps.subscribe = function(fn: any)
				viewListeners[fn] = true
				return function()
					viewListeners[fn] = nil
				end
			end
			viewProps.status = function()
				return model.status
			end
			return require(script.Views).Screen(viewProps)
		end)
	end
end
function Settings.destroy()
	for _, fn in cleanup do
		fn()
	end
	table.clear(cleanup)
	if model then
		model.destroy()
	end
	if preferences then
		preferences.destroy()
	end
	table.clear(callbacks)
	table.clear(viewListeners)
	table.clear(deferred)
end
return Settings

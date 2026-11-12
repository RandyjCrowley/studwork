--!strict
--[[
	StudWork CLIENT runtime: StudWork.start(Config) on the client (module-api.md §3, §9, §10).

	Boot (each step fails closed, like the server: every later StudWork.use errors with the boot
	message):
	  1. resolve       GameConfig.modules + the game's implicit module (§7, C4), same Resolve as
	                   the server (refs, hard deps listed, unique names/keys, topo order)
	  2. validate      the shared ConfigValidate (config.<Name>, items, theme); all errors at once
	  3. client parts  each module's client part, found BY NAME (ref.client): Runtime.defaultLoadClient
	  4. ui            the framework client UI (State sync, Input, Feedback, Hud) unless opts.ui == false
	  5. init(ctx), start(ctx) of every client part, in boot order

	StudWork.use(ref) on the client returns the module's frozen ClientAPI:
	  { actions = { <name> = fn(...) }, state = <Charm selector of state.modules[<Name>]>, ...part.api }
	  actions  declared by the client part: `actions = { name = <Blink client event> | "<EventName>"
	           | true }` (true / a string look the event up in the part's generated `net` module),
	           or a list of names. Calling one fires that Blink event (§9); the server routes it to
	           the module's handler (rate limit, drop-before-load, pcall). An unknown action errors
	           "<Module> has no client action '<name>'". A module that isn't enabled is an erroring
	           proxy, so ANY access (including .actions.x) errors "<Name> is not enabled in
	           GameConfig.modules".
	  state    state.modules[<Name>] ({ data, extra }) as a Charm selector (UI binds with useAtom).

	opts (tests inject them): loadClient(ref) -> part?, gameModule (ref), state (a Charm atom
	or any function returning the raw replicated state), ui (false = no UI; or fn(info) -> client
	table for StudWork.Client), computed (Charm.computed stand-in).
]]

local Boot = require(script.Parent.Boot)

local Shared: any = Boot.shared
local ConfigValidate = (require :: any)(Shared:WaitForChild("ConfigValidate"))
local DefineModule = (require :: any)(Shared:WaitForChild("defineModule"))
local Resolve = (require :: any)(Shared:WaitForChild("Resolve"))

local Runtime = {}

Runtime.VERSION = "1.6.2"

local function pascal(name: string): string
	return string.upper(string.sub(name, 1, 1)) .. string.sub(name, 2)
end

-- The live client part lookup (module-api.md §19.9, added in v1.3.1: R19, one folder per
-- module): the game module's ReplicatedStorage.GameModule.client, else
-- ReplicatedStorage.Modules[ref.client].client. A part without a `net` field gets that instance's
-- `Net` ModuleScript child (the module's generated Blink client module, from its net.blink) as
-- `net`, so `actions = { "name" }` fires the module's own event. nil when there is none.
local function bindNet(instance: any, part: any): any
	if type(part) ~= "table" or part.net ~= nil then
		return part
	end
	local net = instance:FindFirstChild("Net")
	if net == nil or not net:IsA("ModuleScript") then
		return part
	end
	local out = if table.isfrozen(part) then table.clone(part) else part
	out.net = (require :: any)(net)
	return out
end

-- `root` (tests): the ReplicatedStorage stand-in to look in.
function Runtime.defaultLoadClient(ref: any, isGame: boolean?, root: any?): any
	if ref.client == nil then
		return nil
	end
	local ReplicatedStorage = root or game:GetService("ReplicatedStorage")
	if isGame then
		local folder = ReplicatedStorage:FindFirstChild("GameModule")
		local part = folder and folder:FindFirstChild("client")
		if part and part:IsA("ModuleScript") then
			return bindNet(part, (require :: any)(part))
		end
	end
	local modules = ReplicatedStorage:FindFirstChild("Modules")
	local holder = modules and modules:FindFirstChild(ref.client)
	local part = holder and holder:FindFirstChild("client")
	if part and part:IsA("ModuleScript") then
		return bindNet(part, (require :: any)(part))
	end
	return nil
end

local function defaultGameModule(): any
	local ok, def = pcall(function(): any
		local folder = game:GetService("ReplicatedStorage"):FindFirstChild("GameModule")
		local m = folder and folder:FindFirstChild("module")
		return if m and m:IsA("ModuleScript") then (require :: any)(m) else nil
	end)
	return if ok then def else nil
end

local function frozenWithError(t: { [string]: any }, message: (key: string) -> string): any
	return table.freeze(setmetatable(t, {
		__index = function(_, key: any)
			error(message(tostring(key)), 2)
		end,
		__newindex = function(_, key: any)
			error(`client API is read-only (tried to set {tostring(key)})`, 2)
		end,
	}) :: any)
end

-- The module's client actions (§9).
function Runtime.buildActions(ref: any, part: any, assertUsable: () -> ()): any
	local out: { [string]: any } = {}
	local net = if type(part) == "table" then part.net else nil
	local declared = if type(part) == "table" then part.actions else nil
	if declared ~= nil and type(declared) ~= "table" then
		error(`{ref.name}: client part 'actions' must be a table`, 0)
	end
	for key, spec in declared or {} do
		local name: string, event: any
		if type(key) == "number" then
			name, event = spec, true
		else
			name, event = key, spec
		end
		if type(name) ~= "string" or not string.match(name, "^[%a_][%w_]*$") then
			error(`{ref.name}: client action names must be identifiers, got '{tostring(name)}'`, 0)
		end
		if event == true then
			event = if type(net) == "table" then (net[name] or net[pascal(name)]) else nil
		elseif type(event) == "string" then
			event = if type(net) == "table" then net[event] else nil
		end
		if type(event) ~= "table" or type(event.Fire) ~= "function" then
			error(
				`{ref.name}.client.actions.{name}: no Blink client event to fire (declare net or an event)`,
				0
			)
		end
		local ev = event
		out[name] = function(...: any)
			assertUsable()
			ev.Fire(...)
		end
	end
	return frozenWithError(out, function(key: string): string
		return `{ref.name} has no client action '{key}'`
	end)
end

function Runtime.start(gameConfig: any, serverConfig: any?, opts: any?): any
	local o = opts or {}
	if serverConfig ~= nil then
		error("[StudWork] ServerConfig is server-only: call StudWork.start(Config) on the client", 2)
	end
	local current = Boot.runtime()
	if current ~= nil and current.side == "client" then
		error("[StudWork] StudWork.start was already called on this client (call it once per side)", 2)
	end
	local enabled: { [any]: boolean } = {}
	local byName: { [string]: any } = {}
	local rt: any = {
		side = "client",
		state = "booting",
		phase = "resolve",
		bootError = nil,
		apis = {},
		order = {},
		configs = {},
		client = nil,
		gameModule = nil,
	}
	function rt.assertUsable()
		if rt.state == "failed" then
			error(rt.bootError, 3)
		end
	end
	function rt.isEnabled(ref: any): boolean
		return enabled[ref] == true
	end
	function rt.api(ref: any): any
		return rt.apis[ref]
	end
	function rt.byName(name: any): any
		return byName[name]
	end
	Boot.attach(rt)

	local parts: { [any]: any } = {}
	local function boot()
		-- 1. resolve (+ the game module)
		local config = table.clone(gameConfig)
		local gm = o.gameModule
		if gm == nil and o.loadClient == nil then
			gm = defaultGameModule()
		end
		if gm ~= nil then
			if not DefineModule.isModuleRef(gm) then
				error("the game module (GameModule.module) must return StudWork.defineModule(...)", 0)
			end
			rt.gameModule = gm
			local list = table.clone(if type(config.modules) == "table" then config.modules else {})
			if table.find(list, gm) == nil then
				table.insert(list, gm)
			end
			config.modules = list
		end
		local order, errors = Resolve.resolve(config.modules, Runtime.VERSION)
		if order == nil then
			error("invalid GameConfig.modules:\n  - " .. table.concat(errors, "\n  - "), 0)
		end
		rt.order = order
		rt.gameConfig = config
		for _, ref in order do
			enabled[ref] = true
			byName[ref.name] = ref
		end
		-- 2. validate
		rt.phase = "config"
		local result = ConfigValidate.validate(order, config)
		if #result.errors > 0 then
			error("invalid GameConfig:\n  - " .. table.concat(result.errors, "\n  - "), 0)
		end
		rt.configs = result.configs
		rt.theme = result.theme
		-- 3. client parts + APIs
		rt.phase = "client-parts"
		local stateAtom: any = o.state
		local computed: any = o.computed
		for _, ref in order do
			local part = if o.loadClient then o.loadClient(ref) else Runtime.defaultLoadClient(ref, ref == gm)
			if part ~= nil and type(part) ~= "table" then
				error(`{ref.name}: client part must return a table, got {type(part)}`, 0)
			end
			parts[ref] = part or {}
			local api: { [string]: any } = {}
			if type(part) == "table" and type(part.api) == "table" then
				for k, v in part.api do
					api[k] = v
				end
			end
			api.actions = Runtime.buildActions(ref, part, rt.assertUsable)
			local name = ref.name
			local function slice(): any
				local s = if stateAtom then stateAtom() else nil
				local m = if type(s) == "table" and type(s.modules) == "table" then s.modules[name] else nil
				return m or {}
			end
			api.state = if computed then computed(slice) else slice
			rt.apis[ref] = frozenWithError(api, function(key: string): string
				return `{name}: the client API has no member '{key}'`
			end)
		end
		-- 4. framework client UI
		rt.phase = "ui"
		if o.ui ~= false and type(o.ui) == "function" then
			rt.client = o.ui({
				gameConfig = config,
				configs = rt.configs,
				order = order,
				gameModule = gm,
			})
		end
		-- 5. client parts' init / start
		rt.phase = "init"
		for _, ref in order do
			local part = parts[ref]
			if type(part.init) == "function" then
				part.init({ name = ref.name, config = rt.configs[ref.name], gameConfig = config })
			end
		end
		rt.phase = "start"
		for _, ref in order do
			local part = parts[ref]
			if type(part.start) == "function" then
				part.start({ name = ref.name, config = rt.configs[ref.name], gameConfig = config })
			end
		end
		rt.phase = "running"
		rt.state = "running"
	end

	local ok, err = pcall(boot :: any)
	if not ok then
		rt.state = "failed"
		rt.phase = "failed"
		rt.bootError = "[StudWork] client boot failed; StudWork refuses every call until rejoin:\n"
			.. tostring(err)
		warn(rt.bootError)
		error(rt.bootError, 0)
	end
	return rt
end

return Runtime

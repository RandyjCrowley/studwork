--!strict
--[[
	StudWork: the public facade (module-api.md §4), shared by both sides.

	  StudWork.defineModule(spec) -> ModuleRef        validate + freeze a definition (§2)
	  StudWork.use(ref) -> API                         the module's frozen API on this side
	  StudWork.start(GameConfig, ServerConfig?)        boot (delegates to the side's runtime,
	                                                   installed by requiring server/ or client/)
	  StudWork.<Name>                                  untyped sugar for every ENABLED module
	  StudWork.Client                                  client only: state() (§10, the replicated
	                                                   { loaded, framework, modules }) plus the
	                                                   framework client UI (Hud, Feedback, Input)
	  StudWork.hook()                                  a helper list for offering extensions (§8)
	  StudWork.env / StudWork.flags / StudWork.text    (v1.7.0, §23) which environment this is; feature
	                                                   flags (both sides); a string by key (client).
	                                                   Facade members of the framework, not modules:
	                                                   no ModuleRef, StudWork.use doesn't accept them
	  StudWork.test                                    the public test harness (§15; Lune only:
	                                                   harness / boot / memoryStore / player /
	                                                   sim.*, packages/framework/test/Public.luau)

	StudWork.start finds the side's runtime by itself on Roblox (ServerScriptService.Framework on
	the server, ReplicatedStorage.FrameworkClient on the client), so a game's scripts are one line:
	StudWork.start(Config, ServerConfig) / StudWork.start(Config).

	C1: `use` accepts ONLY a ModuleRef. Data, Compliance, Net, Replication, Shop and Policy are
	framework internals with no ModuleRef and no facade; they are reachable only through the
	scoped ctx a module receives. StudWork.Data and friends error with that explanation.

	There is no item registration anywhere (CHANGELOG v1.3.0, Breaking): any register-/add-
	style key on this facade errors with ItemFields.NO_LATE_ITEMS_ERROR.
]]

local DefineModule = require(script.defineModule)
local ItemFields = require(script.ItemFields)
local Resolve = require(script.Resolve)

local StudWork = {}

StudWork.VERSION = "1.8.0"

export type ModuleRef<API = any, TxAPI = any, ClientAPI = any> = any

local INTERNALS =
	{ Data = true, Compliance = true, Net = true, Replication = true, Shop = true, Policy = true }

-- The side's runtime lives in RuntimeSlot, written only by server/Boot.luau (decision 3, v1.3.0
-- step 4). It provides state: "booting" | "running" | "failed", bootError, phase,
-- isEnabled(ref), api(ref), byName(name).
local RuntimeSlot = require(script.RuntimeSlot)

StudWork.defineModule = DefineModule.defineModule
StudWork.isModuleRef = DefineModule.isModuleRef
-- Declared for the type checker only: the key is never set, so __index serves it (client only).
StudWork.Client = (nil :: any) :: any

-- §15 StudWork.test: the Lune test harness (packages/framework/test/Public.luau), served by the
-- test kit as ServerScriptService.FrameworkTest and never part of a game build. Plain forwarders
-- (not a metamethod) so the harness loads on first use, outside any metamethod.
local function testKit(): any
	local ok, holder = pcall(function(): any
		return game:GetService("ServerScriptService"):FindFirstChild("FrameworkTest")
	end)
	if not ok or holder == nil then
		error("[StudWork] StudWork.test is the Lune test harness (tools/test); it is not in a game build", 3)
	end
	return (require :: any)(holder:WaitForChild("Public"))
end
local function forward(path: { string }): (...any) -> ...any
	return function(...: any): ...any
		local node = testKit()
		for _, key in path do
			node = node[key]
		end
		return node(...)
	end
end
local SIM_FUNCTIONS = {
	"world",
	"server",
	"gameServer",
	"bootGame",
	"saved",
	"section",
	"lockHolder",
	"writerViolations",
	"sameValue",
	"receipt",
	"buyItem",
	"key",
}
local sim: { [string]: any } = {}
for _, name in SIM_FUNCTIONS do
	sim[name] = forward({ "sim", name })
end
StudWork.test = table.freeze({
	harness = forward({ "harness" }),
	boot = forward({ "boot" }),
	memoryStore = forward({ "memoryStore" }),
	legacyStore = forward({ "legacyStore" }), -- (added in v1.6.0)
	player = forward({ "player" }),
	-- (added in v1.7.0, §23.10) in-memory stand-ins for the engine services and Open Cloud
	fakes = table.freeze({
		badgeService = forward({ "fakes", "badgeService" }),
		textService = forward({ "fakes", "textService" }),
		userService = forward({ "fakes", "userService" }),
		configService = forward({ "fakes", "configService" }),
		openCloud = forward({ "fakes", "openCloud" }),
		translator = forward({ "fakes", "translator" }),
		experienceNotificationService = forward({ "fakes", "experienceNotificationService" }),
	}),
	sim = table.freeze(sim),
}) :: any

-- On Roblox, requiring the side's runtime installs its starter (server/Boot.luau, client/Boot.luau).
local function installSideRuntime()
	local ok, RunService = pcall(function(): any
		return game:GetService("RunService")
	end)
	if not ok or RunService == nil then
		return -- Lune: tests install the runtime themselves
	end
	local holder: any = nil
	if RunService:IsServer() then
		holder = game:GetService("ServerScriptService"):FindFirstChild("Framework")
	else
		holder = game:GetService("ReplicatedStorage"):FindFirstChild("FrameworkClient")
	end
	if holder ~= nil and holder:IsA("ModuleScript") then
		(require :: any)(holder)
	end
end

function StudWork.start(...: any): any
	-- A second start must never replace (or poison) the runtime that is already running: v1.2
	-- row 15 ("a second Core.start errors"). Found in a v1.3.0 Studio run, where a
	-- second StudWork.start with a bad config swapped the live runtime for a failed one.
	if RuntimeSlot.runtime ~= nil then
		error(
			`[StudWork] StudWork.start called twice: the framework is already {if RuntimeSlot.runtime.state
					== "failed"
				then "failed (boot error above)"
				else "started"}; call it once per side`,
			2
		)
	end
	if RuntimeSlot.starter == nil then
		installSideRuntime()
	end
	local starter = RuntimeSlot.starter
	if starter == nil then
		error(
			"[StudWork] StudWork.start: no runtime installed; require the framework's server (or client) part first",
			2
		)
	end
	return (starter :: any)(...)
end

local function notEnabledProxy(name: string): any
	local msg = Resolve.notEnabledMessage(name)
	return table.freeze(setmetatable(
		{},
		table.freeze({
			__index = function()
				error(msg, 2)
			end,
			__newindex = function()
				error(msg, 2)
			end,
		})
	) :: any)
end
StudWork._notEnabledProxy = notEnabledProxy

local function assertStarted(what: string)
	if RuntimeSlot.runtime == nil then
		error(`[StudWork] {what} called before StudWork.start`, 3)
	end
	if RuntimeSlot.runtime.state == "failed" then
		error(RuntimeSlot.runtime.bootError, 3)
	end
	if RuntimeSlot.runtime.phase ~= "start" and RuntimeSlot.runtime.phase ~= "running" then
		error(
			`[StudWork] {what} called before StudWork.start (boot phase '{tostring(RuntimeSlot.runtime.phase)}')`,
			3
		)
	end
end

-- (v1.7.0, §23.1, §23.2, §23.9) facade members that forward to the side's runtime. Not modules:
-- `use` doesn't accept them, they have no ModuleRef.
local function runtimeMember(path: string, member: string): any
	assertStarted(path)
	local value = (RuntimeSlot.runtime :: any)[member]
	if value == nil then
		error(`[StudWork] {path} is not available on this side`, 3)
	end
	return value
end

StudWork.env = table.freeze({
	name = function(): string
		return runtimeMember("StudWork.env.name", "env").name()
	end,
	placeId = function(): number
		return runtimeMember("StudWork.env.placeId", "env").placeId()
	end,
	universeId = function(): number
		return runtimeMember("StudWork.env.universeId", "env").universeId()
	end,
})

StudWork.flags = table.freeze({
	isOn = function(name: string): boolean
		return runtimeMember("StudWork.flags.isOn", "flags").isOn(name)
	end,
	onChanged = function(name: string, fn: (on: boolean) -> ()): any
		return runtimeMember("StudWork.flags.onChanged", "flags").onChanged(name, fn)
	end,
	all = function(): { [string]: boolean }
		return runtimeMember("StudWork.flags.all", "flags").all()
	end,
	source = function(name: string): string
		return runtimeMember("StudWork.flags.source", "flags").source(name)
	end,
})

-- Client: the string for a key in the local player's language. The server side has ctx.text.
function StudWork.text(key: string, args: { [any]: any }?): string
	return runtimeMember("StudWork.text", "text")(key, args)
end

function StudWork.use<A>(ref: ModuleRef<A>): A
	if not DefineModule.isModuleRef(ref) then
		if type(ref) == "string" and INTERNALS[ref] then
			error(
				`[StudWork] StudWork.use("{ref}"): {ref} is a framework internal, not a module; use the scoped ctx.{string.lower(
					ref
				)} inside your module`,
				2
			)
		end
		error(
			`[StudWork] StudWork.use expects a ModuleRef (the value returned by StudWork.defineModule), got {typeof(
				ref
			)} {tostring(ref)}`,
			2
		)
	end
	assertStarted("StudWork.use")
	if RuntimeSlot.runtime.isEnabled(ref) then
		return RuntimeSlot.runtime.api(ref)
	end
	return notEnabledProxy((ref :: any).name)
end

-- A tiny hook list for modules offering extensions (§8):
--   local removed = StudWork.hook()
--   extensions = { onItemRemoved = removed.register }  ...  removed.fire(tx, player, instance)
function StudWork.hook(): any
	local fns: { (...any) -> () } = {}
	return table.freeze({
		register = function(fn: (...any) -> ())
			assert(type(fn) == "function", "hook expects a function")
			table.insert(fns, fn)
		end,
		fire = function(...: any)
			for _, fn in fns do
				fn(...)
			end
		end,
		count = function(): number
			return #fns
		end,
	})
end

setmetatable(
	StudWork,
	table.freeze({
		__index = function(_, key: any)
			if key == "Client" then
				local rt = RuntimeSlot.runtime
				if rt == nil or rt.client == nil then
					error(
						"[StudWork] StudWork.Client is client-only and exists after StudWork.start(Config) on the client",
						2
					)
				end
				return rt.client
			end
			if type(key) == "string" and INTERNALS[key] then
				error(
					`[StudWork] StudWork.{key}: {key} is a framework internal with no public facade; use ctx.{string.lower(
						key
					)} inside your module`,
					2
				)
			end
			if RuntimeSlot.runtime ~= nil and RuntimeSlot.runtime.state == "failed" then
				error(RuntimeSlot.runtime.bootError, 2)
			end
			if
				RuntimeSlot.runtime ~= nil
				and (RuntimeSlot.runtime.phase == "start" or RuntimeSlot.runtime.phase == "running")
			then
				local ref = RuntimeSlot.runtime.byName(key)
				if ref then
					return RuntimeSlot.runtime.api(ref)
				end
			end
			if type(key) == "string" then
				local k = string.lower(key)
				if string.find(k, "register", 1, true) or string.find(k, "item", 1, true) then
					error(ItemFields.NO_LATE_ITEMS_ERROR, 2)
				end
			end
			error(
				`[StudWork] StudWork.{tostring(key)}: no such member, and no enabled module named {tostring(
					key
				)}`,
				2
			)
		end,
		__newindex = function(_, key: any)
			error(`[StudWork] StudWork is read-only (tried to set {tostring(key)})`, 2)
		end,
	})
)

return table.freeze(StudWork)

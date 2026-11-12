--!strict
--[[
	`ctx.services.get(name)` (module-api.md §23.6): engine services for modules, replaceable in tests.

	  Services.ALLOWED   { [name] = true }       what a module may ask for
	  Services.REFUSED   { [name] = surface }    refused, naming the framework surface to use instead
	  Services.new(opts) -> { forModule(moduleName) -> ServicesAPI, internal(name) -> service }
	    opts = { get = (name) -> service      the engine lookup (live: GetService)
	             fakes = { [name] = fake }?   harness / sim `services = {...}` (win over `get`)
	             isTest = boolean? }          no fake given: a stub whose every method errors

	Live: game:GetService(name). In the harness and the sim: the given fake, or a stub whose every
	method errors `no test fake for <Name>: pass harness({ services = { <Name> = ... } })`.
	`internal(name)` is the framework's own route (e.g. the experience config service for the flag
	override): not name-checked, still replaceable by a fake.
]]

local Services = {}

Services.ALLOWED = table.freeze({
	BadgeService = true,
	TextService = true,
	UserService = true,
	LocalizationService = true,
	Players = true,
})

Services.REFUSED = table.freeze({
	DataStoreService = "ctx.data",
	MemoryStoreService = "ctx.data.sortedMap",
	MarketplaceService = "ctx.shop",
	HttpService = "ctx.openCloud",
	MessagingService = "ctx.data.messages",
	ConfigService = "ctx.flags",
	PolicyService = "ctx.policy",
})

local function noFakeStub(name: string): any
	return setmetatable({}, {
		__index = function(_, method: any)
			return function()
				error(
					"no test fake for "
						.. name
						.. ": pass harness({ services = { "
						.. name
						.. " = ... } }) (called "
						.. tostring(method)
						.. ")",
					2
				)
			end
		end,
	})
end

local function allowedList(): string
	local names = {}
	for name in Services.ALLOWED do
		table.insert(names, name)
	end
	table.sort(names)
	return table.concat(names, ", ")
end

function Services.new(opts: any): any
	local fakes: { [string]: any } = opts.fakes or {}
	local engineGet: (string) -> any = opts.get
	local isTest: boolean = opts.isTest == true
	local self: any = {}

	function self.internal(name: string): any
		if fakes[name] ~= nil then
			return fakes[name]
		end
		if isTest then
			return noFakeStub(name)
		end
		return engineGet(name)
	end

	function self.forModule(moduleName: string): any
		return table.freeze({
			get = function(name: string): any
				if type(name) ~= "string" then
					error(`{moduleName}: ctx.services.get(name): name must be a string`, 2)
				end
				local surface = Services.REFUSED[name]
				if surface ~= nil then
					error(`{moduleName}: ctx.services.get("{name}") is refused: use {surface} instead`, 2)
				end
				if not Services.ALLOWED[name] then
					error(
						`{moduleName}: ctx.services.get("{name}"): not an allowed service (allowed: {allowedList()})`,
						2
					)
				end
				return self.internal(name)
			end,
		})
	end

	return self
end

return Services

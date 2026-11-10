--!strict
--[[
	Minimal per-module stubs for the framework services whose real implementation is Phase 1+ /
	later framework work (module-api.md §7, §9, §10, §14). Each keeps the ctx SHAPE from §5 so
	modules can be written against it now; what works today is listed per service.

	  net        fire/fireAll record into rt.netLog (no Blink codegen yet); actions are routed by
	             rt.action (loaded check + pcall; no rate limit yet)
	  replicate  set/setAll/sent keep per-module "extra" state in memory (no Charm/CharmSync yet)
	  compliance registerRandomSource validates and stores; roll/spendForRoll/tagPaid ERROR
	             (not implemented) so nothing can produce an undisclosed paid outcome meanwhile
	  policy     every call ERRORS (not implemented)
	  analytics  funnel/economy/custom record into rt.analyticsLog
	  events     isActive -> false; schedule/trigger ERROR (not implemented)
	  shop       onProduct/onPassOwned record handlers (rt.products); ownsPass ERRORS; no
	             ProcessReceipt ownership yet (H4 lands with the real Shop)
]]

local Stubs = {}

local function notImplemented(what: string): (...any) -> any
	return function(): any
		error(`{what} is not implemented yet in the core-v1.3.0 runtime (Phase 1 / later framework step)`, 2)
	end
end
Stubs.notImplemented = notImplemented

function Stubs.build(rt: any, name: string): { [string]: any }
	local extra: { [any]: { [string]: any } } = {}
	local sentKeys: { [any]: { [string]: boolean } } = {}
	rt.replicated[name] = { perPlayer = extra, all = {} }

	local net = table.freeze({
		fire = function(player: any, event: string, ...: any)
			table.insert(rt.netLog, { module = name, player = player, event = event, args = table.pack(...) })
		end,
		fireAll = function(event: string, ...: any)
			table.insert(rt.netLog, { module = name, event = event, args = table.pack(...) })
		end,
	})

	local replicate = table.freeze({
		set = function(player: any, key: string, value: any)
			extra[player] = extra[player] or {}
			extra[player][key] = value
			sentKeys[player] = sentKeys[player] or {}
			sentKeys[player][key] = true
		end,
		setAll = function(key: string, value: any)
			rt.replicated[name].all[key] = value
		end,
		sent = function(player: any, key: string): boolean
			return sentKeys[player] ~= nil and sentKeys[player][key] == true
				or rt.replicated[name].all[key] ~= nil
		end,
	})

	local compliance = table.freeze({
		registerRandomSource = function(id: string, source: any)
			assert(type(id) == "string" and id ~= "", "registerRandomSource: id must be a string")
			assert(type(source) == "table", "registerRandomSource: source must be a table")
			assert(type(source.odds) == "function", "registerRandomSource: source.odds must be a function")
			assert(
				type(source.sample) == "function",
				"registerRandomSource: source.sample must be a function"
			)
			assert(
				type(source.luckDisclosed) == "boolean",
				"registerRandomSource: luckDisclosed must be a boolean"
			)
			assert(rt.randomSources[id] == nil, `random source '{id}' already registered`)
			rt.randomSources[id] = { owner = name, source = source }
		end,
		roll = notImplemented("ctx.compliance.roll"),
		spendForRoll = notImplemented("ctx.compliance.spendForRoll"),
		tagPaid = notImplemented("ctx.compliance.tagPaid"),
	})

	local policy = table.freeze({
		paidRandomRestricted = notImplemented("ctx.policy.paidRandomRestricted"),
		isKnown = notImplemented("ctx.policy.isKnown"),
	})

	local function record(kind: string)
		return function(...: any)
			table.insert(rt.analyticsLog, { module = name, kind = kind, args = table.pack(...) })
		end
	end
	local analytics =
		table.freeze({ funnel = record("funnel"), economy = record("economy"), custom = record("custom") })

	local events = table.freeze({
		isActive = function(_id: string): boolean
			return false
		end,
		schedule = notImplemented("ctx.events.schedule"),
		trigger = notImplemented("ctx.events.trigger"),
	})

	local shop = table.freeze({
		onProduct = function(product: string, handler: (tx: any) -> ())
			assert(type(product) == "string", "onProduct: product must be a name string")
			assert(type(handler) == "function", "onProduct: handler must be a function")
			assert(rt.products[product] == nil, `product '{product}' already has a handler`)
			rt.products[product] = { owner = name, handler = handler }
		end,
		onPassOwned = function(pass: string, handler: (player: any) -> ())
			table.insert(rt.passHandlers, { owner = name, pass = pass, handler = handler })
		end,
		ownsPass = notImplemented("ctx.shop.ownsPass"),
	})

	return {
		net = net,
		replicate = replicate,
		compliance = compliance,
		policy = policy,
		analytics = analytics,
		events = events,
		shop = shop,
	}
end

return Stubs

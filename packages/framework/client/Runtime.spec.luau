-- StudWork CLIENT runtime (client/Runtime.luau): StudWork.start(Config) on the client, module
-- client actions (§9), state slices (§10), the game module, fail-closed boot.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local FrameworkClient = ReplicatedStorage:WaitForChild("FrameworkClient")
local Runtime = require(FrameworkClient:WaitForChild("Runtime"))
local Boot = require(FrameworkClient:WaitForChild("Boot"))
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))

local function fakeEvent(log: { any }, name: string): any
	return {
		Fire = function(...: any)
			table.insert(log, { name = name, args = table.pack(...) })
		end,
	}
end

local Economy = StudWork.defineModule({
	name = "EconomyT",
	version = "1.0.0",
	framework = "^1.3.0",
	client = "EconomyT",
})
local Upgrades = StudWork.defineModule({
	name = "UpgradesT",
	version = "1.0.0",
	framework = "^1.3.0",
	dependsOn = { Economy },
	client = "UpgradesT",
})
local Off = StudWork.defineModule({ name = "OffT", version = "1.0.0", framework = "^1.3.0", client = "OffT" })

local function start(opts: any): (any, { any })
	Boot.attach(nil)
	local log = {}
	-- v1.3.1 R19: the module's own Blink event (Upgrades/net.blink `Upgrade`), `upgrade = true` looks it up
	local net = { Upgrade = fakeEvent(log, "Upgrade") }
	local parts = opts.parts or {
		UpgradesT = { net = net, actions = { upgrade = true } },
	}
	local rt = Runtime.start(opts.config or { gameId = "t", modules = { Economy, Upgrades } }, nil, {
		loadClient = function(ref: any)
			return parts[ref.name]
		end,
		gameModule = opts.gameModule,
		state = opts.state,
		ui = opts.ui,
	})
	return rt, log
end

describe("StudWork client runtime", function()
	it("boots the listed modules and fires a module's client action as its Blink event", function()
		local _, log = start({})
		StudWork.use(Upgrades).actions.upgrade("IncomeBoost")
		expect(#log).toBe(1)
		expect(log[1].name).toBe("Upgrade")
		expect(log[1].args[1]).toBe("IncomeBoost")
	end)

	it("errors clearly for an unknown action and for a module that isn't enabled", function()
		start({})
		local ok, err = pcall(function()
			StudWork.use(Upgrades).actions.nope()
		end)
		expect(ok).toBe(false)
		expect(string.find(tostring(err), "UpgradesT has no client action 'nope'", 1, true) ~= nil).toBe(true)
		ok, err = pcall(function()
			StudWork.use(Off).actions.anything()
		end)
		expect(ok).toBe(false)
		expect(string.find(tostring(err), "OffT is not enabled in GameConfig.modules", 1, true) ~= nil).toBe(
			true
		)
	end)

	it("serves state.modules[<Name>] as the module's state slice", function()
		local raw = {
			loaded = true,
			framework = {},
			modules = { EconomyT = { data = { currency = { Coins = 7 } } } },
		}
		start({
			state = function()
				return raw
			end,
		})
		expect(StudWork.use(Economy).state().data.currency.Coins).toBe(7)
		expect((next(StudWork.use(Upgrades).state()))).toBeNil()
	end)

	it("adds the game module (never listed) and exposes StudWork.Client from the UI step", function()
		local GameMod = StudWork.defineModule({ name = "GameT", version = "1.0.0", framework = "^1.3.0" })
		local seen: any = nil
		local rt = start({
			gameModule = GameMod,
			ui = function(info: any)
				seen = info
				return { marker = true }
			end,
		})
		expect(rt.isEnabled(GameMod)).toBe(true)
		expect(rt.order[#rt.order]).toBe(GameMod)
		expect(seen.gameModule).toBe(GameMod)
		expect(StudWork.Client.marker).toBe(true)
	end)

	it("fails closed: a bad config makes every later StudWork.use error with the boot message", function()
		local ok = pcall(start, { config = { gameId = "t", modules = { Upgrades } } }) -- missing dependency
		expect(ok).toBe(false)
		local okUse, err = pcall(function()
			return StudWork.use(Upgrades)
		end)
		expect(okUse).toBe(false)
		expect(string.find(tostring(err), "client boot failed", 1, true) ~= nil).toBe(true)
	end)

	it("refuses a ServerConfig on the client and a second start", function()
		Boot.attach(nil)
		local ok, err = pcall(
			Runtime.start,
			{ gameId = "t", modules = {} },
			{},
			{ loadClient = function() end }
		)
		expect(ok).toBe(false)
		expect(string.find(tostring(err), "server-only", 1, true) ~= nil).toBe(true)
		start({ config = { gameId = "t", modules = {} } })
		ok, err = pcall(Runtime.start, { gameId = "t", modules = {} }, nil, { loadClient = function() end })
		expect(ok).toBe(false)
		expect(string.find(tostring(err), "already called", 1, true) ~= nil).toBe(true)
		Boot.attach(nil)
	end)

	it("a module's theme(config) reaches the client theme: 4 custom Rarity tiers in config only", function()
		local Modules = ReplicatedStorage:WaitForChild("Modules")
		local Items = require(Modules:WaitForChild("Items"):WaitForChild("module"))
		local Rarity = require(Modules:WaitForChild("Rarity"):WaitForChild("module"))
		local tiers = {
			{ id = "Low", color = "#111111" },
			{ id = "Mid" },
			{ id = "High", soundKey = "r_high" },
			{ id = "Top", glow = "#FFFFFF", glowStrength = 1 },
		}
		local rt = start({
			config = {
				gameId = "t",
				modules = { Items, Rarity },
				items = {
					{ id = "dust", name = "Dust", rarity = "Low" },
					{ id = "crown", name = "Crown", rarity = "Top" },
				},
				config = { Rarity = { tiers = tiers } }, -- no GameConfig.theme
			},
			parts = {},
		})
		local got = rt.theme.rarity.tiers
		expect(#got).toBe(4)
		expect(got[1].id).toBe("Low")
		expect(got[1].color).toBe("#111111")
		expect(got[2].id).toBe("Mid")
		expect(got[3].soundKey).toBe("r_high")
		expect(got[4].id).toBe("Top")
		expect(got[4].glow).toBe("#FFFFFF")
	end)
end)

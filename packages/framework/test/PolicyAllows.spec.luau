--!nocheck
--[[
	v1.7.0 ctx.policy.allows(player, field) / restricted(player, field) (module-api.md §23.8): the
	permission and the restriction PolicyService fields, each fail closed its own way; an unknown
	field errors, fail closed until the join lookup succeeded, from that same lookup (no
	extra request), and ctx.policy.isKnown tells the cases apart.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Policy = require(script.Parent.Parent.server.Policy)

local function boot(opts)
	local captured = {}
	local o = {
		modules = { StudWork.defineModule({ name = "Probe", version = "1.0.0", framework = "^1.7.0" }) },
		servers = {
			Probe = {
				init = function(ctx)
					captured.ctx = ctx
				end,
			},
		},
	}
	for k, v in opts or {} do
		o[k] = v
	end
	local h, err = StudWork.test.boot(o)
	assert(h, err)
	return h, captured.ctx
end

describe("ctx.policy.allows", function()
	it("answers each boolean field from the player's policy", function()
		local h, ctx = boot({
			policy = {
				[1] = {
					IsContentSharingAllowed = true,
					AreAdsAllowed = true,
					IsPaidItemTradingAllowed = false,
				},
				[2] = { IsContentSharingAllowed = false, IsSubjectToChinaPolicies = true },
			},
		})
		local a = h:addPlayer({ userId = 1 })
		local b = h:addPlayer({ userId = 2 })
		expect(ctx.policy.allows(a, "IsContentSharingAllowed")).toBe(true)
		expect(ctx.policy.allows(a, "AreAdsAllowed")).toBe(true)
		expect(ctx.policy.allows(a, "IsPaidItemTradingAllowed")).toBe(false)
		expect(ctx.policy.allows(b, "IsContentSharingAllowed")).toBe(false)
		expect(ctx.policy.restricted(b, "IsSubjectToChinaPolicies")).toBe(true) -- a restriction: its own call
		-- a field the answer doesn't carry is false (fail closed)
		expect(ctx.policy.allows(b, "IsEligibleToPurchaseSubscription")).toBe(false)
		expect(ctx.policy.isKnown(a)).toBe(true)
	end)

	it("an unknown or non-boolean field errors, naming it", function()
		local h, ctx = boot({ policy = { [1] = { IsContentSharingAllowed = true } } })
		local a = h:addPlayer({ userId = 1 })
		local ok, err = pcall(ctx.policy.allows, a, "IsContentSharingAlowed")
		expect(ok).toBe(false)
		expect(tostring(err)).toContain("unknown policy field 'IsContentSharingAlowed'")
		expect(pcall(ctx.policy.allows, a, "AllowedExternalLinkReferences")).toBe(false) -- a list, not a boolean
		expect(pcall(ctx.policy.allows, a, nil)).toBe(false)
	end)

	it("fails closed while the lookup fails, and isKnown says why", function()
		local h, ctx = boot({ policy = { [1] = "fail" } })
		local a = h:addPlayer({ userId = 1 })
		expect(ctx.policy.isKnown(a)).toBe(false)
		expect(ctx.policy.allows(a, "IsContentSharingAllowed")).toBe(false)
		expect(ctx.policy.allows(a, "AreAdsAllowed")).toBe(false)
	end)

	it("is false for a player who isn't in the game or has left", function()
		local h, ctx = boot({ policy = { [1] = { IsContentSharingAllowed = true } } })
		expect(ctx.policy.allows({ UserId = 99 }, "IsContentSharingAllowed")).toBe(false)
		local a = h:addPlayer({ userId = 1 })
		expect(ctx.policy.allows(a, "IsContentSharingAllowed")).toBe(true)
		h:removePlayer(a)
		expect(ctx.policy.allows(a, "IsContentSharingAllowed")).toBe(false)
	end)

	it("the Studio console override changes paidRandomRestricted only, never allows", function()
		local h, ctx = boot({ isStudio = true, policy = { [1] = { IsContentSharingAllowed = false } } })
		local a = h:addPlayer({ userId = 1 })
		h:console("policy restrict false 1")
		expect(ctx.policy.paidRandomRestricted(a)).toBe(false)
		expect(ctx.policy.allows(a, "IsContentSharingAllowed")).toBe(false)
	end)
end)

describe("ctx.policy.restricted (M3: a restriction never reads as allowed while unknown)", function()
	it("answers restriction fields, true until the lookup succeeded", function()
		local h, ctx = boot({
			policy = {
				[1] = { IsSubjectToChinaPolicies = false, ArePaidRandomItemsRestricted = false },
				[2] = { IsSubjectToChinaPolicies = true },
				[3] = "fail",
			},
		})
		local a = h:addPlayer({ userId = 1 })
		local b = h:addPlayer({ userId = 2 })
		local c = h:addPlayer({ userId = 3 })
		expect(ctx.policy.restricted(a, "IsSubjectToChinaPolicies")).toBe(false)
		expect(ctx.policy.restricted(a, "ArePaidRandomItemsRestricted")).toBe(false)
		expect(ctx.policy.restricted(b, "IsSubjectToChinaPolicies")).toBe(true)
		-- unknown: restricted (fail closed), for a failing lookup and for someone not in the game
		expect(ctx.policy.restricted(c, "IsSubjectToChinaPolicies")).toBe(true)
		expect(ctx.policy.restricted(c, "ArePaidRandomItemsRestricted")).toBe(true)
		expect(ctx.policy.restricted({ UserId = 99 }, "IsSubjectToChinaPolicies")).toBe(true)
	end)

	it("each call refuses the other kind of field, naming the right one", function()
		local h, ctx = boot({ policy = { [1] = { IsSubjectToChinaPolicies = false } } })
		local a = h:addPlayer({ userId = 1 })
		local ok, err = pcall(ctx.policy.allows, a, "IsSubjectToChinaPolicies")
		expect(ok).toBe(false)
		expect(tostring(err)).toContain("use ctx.policy.restricted")
		ok, err = pcall(ctx.policy.allows, a, "ArePaidRandomItemsRestricted")
		expect(ok).toBe(false)
		ok, err = pcall(ctx.policy.restricted, a, "IsContentSharingAllowed")
		expect(ok).toBe(false)
		expect(tostring(err)).toContain("use ctx.policy.allows")
		expect(pcall(ctx.policy.restricted, a, "NoSuchField")).toBe(false)
	end)

	it("follows the Studio override for ArePaidRandomItemsRestricted, like paidRandomRestricted", function()
		local h, ctx = boot({ isStudio = true, policy = { [1] = { ArePaidRandomItemsRestricted = true } } })
		local a = h:addPlayer({ userId = 1 })
		expect(ctx.policy.restricted(a, "ArePaidRandomItemsRestricted")).toBe(true)
		h:console("policy restrict false 1")
		expect(ctx.policy.restricted(a, "ArePaidRandomItemsRestricted")).toBe(false)
		expect(ctx.policy.paidRandomRestricted(a)).toBe(false)
	end)
end)

describe("Policy.allows (unit)", function()
	it("reads the join lookup: no extra request however often it's asked", function()
		local lookups = 0
		local present = {}
		local p = Policy.new({
			lookup = function(_player)
				lookups += 1
				return { ArePaidRandomItemsRestricted = false, IsContentSharingAllowed = true }
			end,
			isPlayer = function(player)
				return present[player] == true
			end,
			wait = function() end,
			delay = function() end,
			publish = function() end,
			log = function() end,
		})
		local player = { UserId = 1 }
		present[player] = true
		expect(p.allows(player, "IsContentSharingAllowed")).toBe(false) -- before the lookup
		p.track(player)
		for _ = 1, 10 do
			expect(p.allows(player, "IsContentSharingAllowed")).toBe(true)
		end
		expect(lookups).toBe(1)
	end)

	it("BOOLEAN_FIELDS lists PolicyService's boolean fields", function()
		for _, name in
			{
				"AreAdsAllowed",
				"ArePaidRandomItemsRestricted",
				"IsContentSharingAllowed",
				"IsEligibleToPurchaseSubscription",
				"IsPaidItemTradingAllowed",
				"IsSubjectToChinaPolicies",
			}
		do
			expect(Policy.BOOLEAN_FIELDS[name]).toBe(true)
		end
	end)
end)

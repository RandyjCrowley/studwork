--!nocheck
-- tools/ is outside the harness index (packages, games, templates), so load by file path.
local PublishGate = require("tools/lune/PublishGate.luau")

local HEAD = "aaaaaaa1111111111111111111111111111111111"
local OLD = "bbbbbbb2222222222222222222222222222222222"

local function deploy(overrides: any?): any
	local d = {
		name = "g",
		test = { universeId = 111, placeId = 222 },
		live = { universeId = 333, placeId = 444 },
	}
	for k, v in overrides or {} do
		d[k] = v
	end
	return d
end

local function input(overrides: any?): any
	local i = {
		target = "test",
		dryRun = false,
		deploy = deploy(),
		head = HEAD,
		dirty = {},
		keyPresent = true,
		testEquivalent = false,
	}
	for k, v in overrides or {} do
		i[k] = v
	end
	return i
end

local function hasMessage(list: { string }, needle: string): boolean
	for _, m in list do
		if string.find(m, needle, 1, true) then
			return true
		end
	end
	return false
end

describe("PublishGate.isPlaceholderId", function()
	it("treats 0, negatives, fractions, strings and nil as placeholders", function()
		for _, v in { 0, -5, 1.5, "123", "PLACEHOLDER", nil, 0 / 0, math.huge } do
			expect(PublishGate.isPlaceholderId(v)).toBe(true)
		end
		expect(PublishGate.isPlaceholderId(1234567890)).toBe(false)
	end)
end)

describe("PublishGate.decide", function()
	it("allows a clean real test publish with real ids and a key", function()
		local d = PublishGate.decide(input())
		expect(d.ok).toBe(true)
		expect(#d.errors).toBe(0)
		expect(d.record).toBe("published")
	end)

	it("placeholder ids -> refuse a real publish", function()
		local d = PublishGate.decide(input({ deploy = deploy({ test = { universeId = 0, placeId = 0 } }) }))
		expect(d.ok).toBe(false)
		expect(hasMessage(d.errors, "test.universeId/placeId is a placeholder")).toBe(true)
	end)

	it("placeholder ids -> only a warning in a dry run", function()
		local d = PublishGate.decide(
			input({ dryRun = true, deploy = deploy({ test = { universeId = 0, placeId = 5 } }) })
		)
		expect(d.ok).toBe(true)
		expect(hasMessage(d.warnings, "test.universeId is a placeholder")).toBe(true)
		expect(d.record).toBe("dryRun")
	end)

	it("missing target section counts as placeholder ids", function()
		local d = PublishGate.decide(input({ deploy = { name = "g" } }))
		expect(d.ok).toBe(false)
	end)

	it("dirty tree -> refuse a real publish", function()
		local d = PublishGate.decide(input({ dirty = { "games/g/src/x.luau", "packages/framework/y.luau" } }))
		expect(d.ok).toBe(false)
		expect(hasMessage(d.errors, "games/g/src/x.luau")).toBe(true)
	end)

	it("dirty tree is fine for a dry run", function()
		local d = PublishGate.decide(input({ dryRun = true, dirty = { "games/g/src/x.luau" } }))
		expect(d.ok).toBe(true)
	end)

	it("missing key -> refuse real, warn in dry run", function()
		expect(PublishGate.decide(input({ keyPresent = false })).ok).toBe(false)
		local d = PublishGate.decide(input({ keyPresent = false, dryRun = true }))
		expect(d.ok).toBe(true)
		expect(hasMessage(d.warnings, "ROBLOX_OPEN_CLOUD_API_KEY")).toBe(true)
	end)

	it("live without test -> refuse", function()
		local d = PublishGate.decide(input({ target = "live" }))
		expect(d.ok).toBe(false)
		expect(hasMessage(d.errors, "nothing was published to test yet")).toBe(true)
	end)

	it("test commit != HEAD -> refuse live", function()
		local dep = deploy()
		dep.test.published = { commit = OLD, at = "t" }
		local d = PublishGate.decide(input({ target = "live", deploy = dep }))
		expect(d.ok).toBe(false)
		expect(hasMessage(d.errors, "test has bbbbbbb, HEAD is aaaaaaa")).toBe(true)
	end)

	it("test commit == HEAD -> allow live", function()
		local dep = deploy()
		dep.test.published = { commit = HEAD, at = "t" }
		expect(PublishGate.decide(input({ target = "live", deploy = dep })).ok).toBe(true)
	end)

	it("test commit differing only by stamp files (testEquivalent) -> allow live", function()
		local dep = deploy()
		dep.test.published = { commit = OLD, at = "t" }
		expect(PublishGate.decide(input({ target = "live", deploy = dep, testEquivalent = true })).ok).toBe(
			true
		)
	end)

	it("a test dry run never unlocks a real live publish", function()
		local dep = deploy()
		dep.test.dryRun = { commit = HEAD, at = "t" }
		local d = PublishGate.decide(input({ target = "live", deploy = dep }))
		expect(d.ok).toBe(false)
		expect(hasMessage(d.errors, "does not count")).toBe(true)
	end)

	it("live dry run accepts a test dry run of HEAD (with a warning)", function()
		local dep = deploy()
		dep.test.dryRun = { commit = HEAD, at = "t" }
		local d = PublishGate.decide(input({ target = "live", dryRun = true, deploy = dep }))
		expect(d.ok).toBe(true)
		expect(hasMessage(d.warnings, "DRY RUN")).toBe(true)
	end)

	it("live dry run without any test record of HEAD -> refuse", function()
		local dep = deploy()
		dep.test.dryRun = { commit = OLD, at = "t" }
		local d = PublishGate.decide(input({ target = "live", dryRun = true, deploy = dep }))
		expect(d.ok).toBe(false)
	end)

	it("collects every error at once", function()
		local d = PublishGate.decide(input({
			target = "live",
			deploy = deploy({ live = { universeId = 0, placeId = 0 } }),
			dirty = { "packages/x" },
			keyPresent = false,
		}))
		expect(#d.errors).toBe(4)
	end)

	it("rejects an unknown target", function()
		expect(PublishGate.decide(input({ target = "prod" })).ok).toBe(false)
	end)
end)

describe("PublishGate.syncStatus", function()
	it("reports placeholder ids and never published", function()
		local d = deploy({ test = { universeId = 0, placeId = 0 } })
		expect(PublishGate.syncStatus(d, "test", HEAD)).toBe("placeholder ids, never published")
	end)

	it("reports in sync with the version number", function()
		local d = deploy()
		d.live.published = { commit = HEAD, at = "t", versionNumber = 7 }
		expect(PublishGate.syncStatus(d, "live", HEAD)).toBe("333/444, in sync (v7)")
	end)

	it("reports behind HEAD and dry-run-only states", function()
		local d = deploy()
		d.test.published = { commit = OLD, at = "t" }
		d.live.dryRun = { commit = HEAD, at = "t" }
		expect(PublishGate.syncStatus(d, "test", HEAD)).toBe("111/222, behind HEAD (has bbbbbbb)")
		expect(PublishGate.syncStatus(d, "live", HEAD)).toBe("333/444, dry run of HEAD only")
	end)
end)

describe("PublishGate output never contains the key", function()
	local SECRET = "RBX-SECRET-abc123+/="

	it("requestPreview has the header redacted and builds the exact URL", function()
		local text = PublishGate.requestPreview(deploy(), "test", "build/g-test.rbxl", 42)
		expect(string.find(text, SECRET, 1, true)).toBeNil()
		expect(string.find(text, "x-api-key: <redacted>", 1, true) ~= nil).toBe(true)
		expect(
			string.find(
				text,
				"POST https://apis.roblox.com/universes/v1/111/places/222/versions?versionType=Published",
				1,
				true
			) ~= nil
		).toBe(true)
	end)

	it("placeholder ids show up as <PLACEHOLDER:...> in the URL", function()
		local url = PublishGate.url(deploy({ test = { universeId = 0, placeId = 0 } }), "test")
		expect(url).toBe(
			"https://apis.roblox.com/universes/v1/<PLACEHOLDER:0>/places/<PLACEHOLDER:0>/versions?versionType=Published"
		)
	end)

	it("no decision message contains the key (it is never an input)", function()
		local d = PublishGate.decide(input({ target = "live", keyPresent = false, dirty = { "x" } }))
		for _, m in d.errors do
			expect(string.find(m, SECRET, 1, true)).toBeNil()
		end
	end)

	it("redact removes every occurrence, including pattern characters", function()
		local out = PublishGate.redact("a " .. SECRET .. " b " .. SECRET, SECRET)
		expect(out).toBe("a <redacted> b <redacted>")
		expect(PublishGate.redact("nothing", "")).toBe("nothing")
	end)
end)

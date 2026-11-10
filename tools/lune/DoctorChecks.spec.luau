--!nocheck
-- tools/ is outside the harness index (packages, games, templates), so load by file path.
local Doctor = require("tools/lune/DoctorChecks.luau")

describe("DoctorChecks.parseRokit", function()
	it("reads the [tools] pins and ignores comments/other sections", function()
		local tools = Doctor.parseRokit([[
# comment = "x/y@9.9.9"
[other]
nope = "a/b@1.0.0"
[tools]
rojo = "rojo-rbx/rojo@7.7.1"
StyLua = "JohnnyMorganz/StyLua@2.6.0" # trailing
luau-lsp = "JohnnyMorganz/luau-lsp@1.70.1"
]])
		expect(tools).toEqual({
			{ name = "rojo", version = "7.7.1" },
			{ name = "StyLua", version = "2.6.0" },
			{ name = "luau-lsp", version = "1.70.1" },
		})
	end)
end)

describe("DoctorChecks.versionMatches", function()
	it("matches the version as a whole token in real --version outputs", function()
		expect(Doctor.versionMatches("Rojo 7.7.1", "7.7.1")).toBe(true)
		expect(Doctor.versionMatches("1.70.1", "1.70.1")).toBe(true)
		expect(Doctor.versionMatches("Blink 0.18.9", "0.18.9")).toBe(true)
	end)

	it("rejects other versions that merely contain the string", function()
		expect(Doctor.versionMatches("Rojo 7.7.10", "7.7.1")).toBe(false)
		expect(Doctor.versionMatches("Rojo 17.7.1", "7.7.1")).toBe(false)
		expect(Doctor.versionMatches("Rojo 7.6.0", "7.7.1")).toBe(false)
	end)
end)

describe("DoctorChecks.parseWally", function()
	it("maps aliases to realm and the _Index folder name", function()
		local deps = Doctor.parseWally([[
[package]
name = "randyjcrowley/studwork-deps"
[dependencies]
Charm = "littensy/charm@=0.11.1"
ReactRoblox = "jsdotlua/react-roblox@=17.2.1"
[server-dependencies]
ProfileStore = "lm-loleris/profilestore@=1.0.3"
[place]
shared-packages = "game.ReplicatedStorage.Packages"
]])
		expect(deps).toEqual({
			{ alias = "Charm", realm = "shared", index = "littensy_charm@0.11.1" },
			{ alias = "ReactRoblox", realm = "shared", index = "jsdotlua_react-roblox@17.2.1" },
			{ alias = "ProfileStore", realm = "server", index = "lm-loleris_profilestore@1.0.3" },
		})
	end)
end)

describe("DoctorChecks.envKeys", function()
	local EXAMPLE = "# comment\nROBLOX_OPEN_CLOUD_API_KEY=\nOTHER_KEY=\n"

	it("reports present/missing and never returns a value", function()
		local rows = Doctor.envKeys(EXAMPLE, 'ROBLOX_OPEN_CLOUD_API_KEY="s3cr3t-value"\nOTHER_KEY=\n')
		expect(rows).toEqual({
			{ key = "OTHER_KEY", present = false },
			{ key = "ROBLOX_OPEN_CLOUD_API_KEY", present = true },
		})
		for _, r in rows do
			for _, v in r do
				expect(v ~= "s3cr3t-value").toBe(true)
			end
		end
	end)

	it("treats a missing .env, empty quotes and export lines correctly", function()
		local none = Doctor.envKeys(EXAMPLE, nil)
		expect(none[1].present).toBe(false)
		expect(none[2].present).toBe(false)
		local rows = Doctor.envKeys(EXAMPLE, "export ROBLOX_OPEN_CLOUD_API_KEY=abc\nOTHER_KEY=''\n")
		expect(rows[1].present).toBe(false)
		expect(rows[2].present).toBe(true)
	end)
end)

describe("DoctorChecks.format", function()
	it("counts failures, shows fix hints for warn/fail only", function()
		local text, failures = Doctor.format({
			{ level = "ok", item = "a", detail = "fine", fix = "never shown" },
			{ level = "warn", item = "b", detail = "meh", fix = "do b" },
			{ level = "fail", item = "c", detail = "bad", fix = "do c" },
		})
		expect(failures).toBe(1)
		expect(string.find(text, "never shown", 1, true)).toBeNil()
		expect(string.find(text, "fix: do b", 1, true) ~= nil).toBe(true)
		expect(string.find(text, "[FAIL] c", 1, true) ~= nil).toBe(true)
	end)
end)

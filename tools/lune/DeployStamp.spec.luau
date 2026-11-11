--!nocheck
-- tools/lune/DeployStamp (StudWork v1.5.0): the deploy.json stamp and the GAMES.md cell, incl. a
-- single-game project (deploy.json at the root, no GAMES.md).
local DeployStamp = require("tools/lune/DeployStamp.luau")

local INFO = { version = "1.5.0", commit = "abc1234", sha = string.rep("a", 40), tag = "v1.5.0" }
local NOW = "2026-11-11T00:00:00Z"

describe("DeployStamp", function()
	it("finds deploy.json: games/<g>/deploy.json, or the root's for a single-game project", function()
		expect(DeployStamp.deployPath("games/demo")).toBe("games/demo/deploy.json")
		expect(DeployStamp.deployPath(".")).toBe("deploy.json")
		expect(DeployStamp.deployPath("")).toBe("deploy.json")
	end)

	it("stamps the core and a dry run", function()
		local deploy = { name = "demo", test = { universeId = 0, placeId = 0 } }
		DeployStamp.stamp(deploy, INFO, "publish --test --dry-run", NOW, {
			target = "test",
			commit = "head",
			dryRun = true,
		})
		expect(deploy.coreVersion).toBe("1.5.0")
		expect(deploy.coreCommit).toBe("abc1234")
		expect(deploy.coreSha).toBe(string.rep("a", 40))
		expect(deploy.coreTag).toBe("v1.5.0")
		expect(deploy.coreStamp).toEqual({ how = "publish --test --dry-run", at = NOW })
		expect(deploy.test.dryRun).toEqual({ commit = "head", at = NOW })
		expect(deploy.test.published).toBeNil()
		expect(deploy.live).toBeNil()
	end)

	it("stamps a real publish (and creates a missing target section)", function()
		local deploy = { name = "demo" }
		DeployStamp.stamp(
			deploy,
			INFO,
			"publish --live",
			NOW,
			{ target = "live", commit = "c", version = "7" }
		)
		expect(deploy.live.published).toEqual({ commit = "c", at = NOW, versionNumber = 7 })
		expect(deploy.live.universeId).toBe(0)
	end)

	it("updates the game's GAMES.md Core cell, and writes nothing without a GAMES.md", function()
		local games = table.concat({
			"| Game | Status | Port | Core | Doc |",
			"|---|---|---|---|---|",
			"| demo | scaffolded | 34873 | — | — |",
			"| other | scaffolded | 34874 | — | — |",
		}, "\n")
		local out = DeployStamp.gamesMd(games, "demo", "1.5.0 (abc1234)")
		expect(string.find(out, "| demo | scaffolded | 34873 | 1.5.0 (abc1234) | — |", 1, true)).never.toBeNil()
		expect(string.find(out, "| other | scaffolded | 34874 | — | — |", 1, true)).never.toBeNil()
		-- a single-game project has no GAMES.md: nothing to write (deploy.json is the record)
		expect(DeployStamp.gamesMd(nil, "demo", "1.5.0 (abc1234)")).toBeNil()
	end)
end)

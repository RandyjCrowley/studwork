--!nocheck
-- (StudWork v1.5.0) the guardrails' single-game project cases: the studwork/ pin (not a checkout,
-- not at a tag, local changes) and the staged check (a studwork bump with any other file is
-- refused; the bump alone and the project's first commit pass). They are planted in
-- `guardrails --self-test` (guardrails.luau is a CLI script, so this spec runs it): every case
-- must be present and caught.
local luneRequire = (getmetatable(getfenv(1)) :: any).__index.require
local fs = luneRequire("@lune/fs")
local process = luneRequire("@lune/process")

describe("guardrails: single-game project", function()
	it("plants every single-game case in --self-test", function()
		local source = fs.readFile("tools/lune/guardrails.luau")
		for _, case in
			{
				"single-game: studwork bump + a game file in one commit",
				"single-game: studwork bump + a root file in one commit",
				"single-game: an edit inside studwork/ + a module file",
				"single-game: game branch moves studwork",
				"single-game: studwork bump alone",
				"single-game: the first commit adds the pin with the scaffold",
				"single-game pin: not a tag",
				"single-game pin: local change",
				"single-game pin: not initialised",
			}
		do
			expect(string.find(source, '"' .. case .. '"', 1, true)).never.toBeNil()
		end
	end)

	it("--self-test passes (each planted violation is caught)", function()
		local result = process.exec("lune", { "run", "tools/lune/guardrails", "--self-test" })
		expect(result.stdout .. result.stderr).toContain("every check catches its planted violation")
		expect(result.ok).toBe(true)
	end)
end)

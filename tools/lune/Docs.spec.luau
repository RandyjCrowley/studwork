--!nocheck
-- Docs that must match the code (core-v1.3.0 Phase 2 P2-F, final review 9).
local fs = (getmetatable(getfenv(1)) :: any).__index.require("@lune/fs")
local Theme = require("packages/framework/shared/Theme.luau")

describe("docs/framework/getting-started.md", function()
	it("has no stale 'Known gap' note (the game's Config spec loads module refs now)", function()
		local doc = fs.readFile("docs/framework/getting-started.md")
		expect(string.find(doc, "Known gap", 1, true)).toBeNil()
	end)
end)

describe("docs/framework/theme.md token table matches the framework defaults (final review 6)", function()
	it("names only real tokens, with the default values", function()
		local doc = fs.readFile("docs/framework/theme.md")
		local d = Theme.DEFAULT
		for _, group in { "colors", "fonts", "metrics" } do
			local row = string.match(doc, "\n| `" .. group .. "` |([^|\n]*)|") -- the Keys column
			expect(row).never.toBeNil()
			for key in string.gmatch(row, "`([%w_%.]+)`") do
				local root, sub = string.match(key, "^([%w_]+)%.?([%w_]*)$")
				local v = d[group][root]
				if sub ~= "" then
					v = type(v) == "table" and v[sub] or nil
				end
				if v == nil then
					error(`theme.md lists {group}.{key}, which is not a framework token`)
				end
			end
		end
		for key, hex in d.colors do
			expect(string.find(doc, "`" .. key .. "` `" .. hex .. "`", 1, true) ~= nil).toBe(true)
		end
	end)
end)

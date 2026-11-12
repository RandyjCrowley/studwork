--!nocheck
-- (StudWork v1.7.0) the `textfilter` guardrail (tools/lune/GuardTextFilter.luau,
-- docs/framework/kits/textfilter.md "The textfilter lint check"): the planted cases, the reading
-- rules (comments, strings, interpolation, scope), and which files a game scan reads.
local G = require("tools/lune/GuardTextFilter.luau")

local SERVER = { path = "games/x/modules/m/server/init.luau", isServer = true }

local function scan(src)
	return G.scanSource(src, SERVER)
end

-- an action handler `rename(player, name: string)` around `body`
local function handler(body, params)
	return table.concat({
		"local TextFilter = require(Modules.TextFilter.module)",
		"return function(ctx, part)",
		"\treturn {",
		"\t\tactions = {",
		"\t\t\trename = { limit = { rate = 1, burst = 2 }, handler = function(player, "
			.. (params or "name: string")
			.. ")",
		body,
		"\t\t\tend },",
		"\t\t},",
		"\t}",
		"end",
	}, "\n")
end

-- an in-memory fs: { [path] = source }
local function memfs(files)
	local dirs = {}
	for path in files do
		local parts = string.split(path, "/")
		local acc = nil
		for i = 1, #parts - 1 do
			local parent = acc or "."
			acc = if acc then acc .. "/" .. parts[i] else parts[i]
			dirs[parent] = dirs[parent] or {}
			dirs[parent][parts[i]] = true
			dirs[acc] = dirs[acc] or {}
		end
		local parent = acc or "."
		dirs[parent] = dirs[parent] or {}
		dirs[parent][parts[#parts]] = true
	end
	return {
		isDir = function(p)
			return dirs[p] ~= nil
		end,
		readDir = function(p)
			local out = {}
			for e in dirs[p] or {} do
				table.insert(out, e)
			end
			return out
		end,
		readFile = function(p)
			return assert(files[p], p)
		end,
	}
end

describe("textfilter: planted cases (guardrails --self-test)", function()
	it("every planted violation is caught and every clean flow passes", function()
		expect(G.selfTest()).toEqual({})
		expect(#G.PLANTED_FAIL >= 10).toBe(true)
		expect(#G.PLANTED_PASS >= 3).toBe(true)
	end)

	it("each FAIL plant gives a finding in the documented shape", function()
		for _, case in G.PLANTED_FAIL do
			local got = scan(case[2])
			expect(#got >= 1).toBe(true)
			for _, f in got do
				expect(string.match(f, "^games/x/modules/m/server/init%.luau:%d+: %[textfilter%] ")).never.toBe(
					nil
				)
				expect(f).toContain("(docs/framework/kits/textfilter.md)")
			end
		end
	end)

	it("the message names the identifier and the sink", function()
		local got = scan(handler('\t\t\t\tctx.replicate.setAll("sign", name)'))
		expect(got).toEqual({
			"games/x/modules/m/server/init.luau:6: [textfilter] player text 'name' reaches ctx.replicate.setAll without TextFilter (docs/framework/kits/textfilter.md)",
		})
		local rec = scan(handler(table.concat({
			'\t\t\t\tlocal ok, stored = TextFilter.store(player, name, "public")',
			'\t\t\t\tctx.replicate.setAll("sign", stored)',
		}, "\n")))
		expect(rec).toEqual({
			"games/x/modules/m/server/init.luau:7: [textfilter] filter record 'stored' reaches ctx.replicate.setAll whole: pass TextFilter.shown(...) or .public (docs/framework/kits/textfilter.md)",
		})
	end)
end)

describe("textfilter: reading rules", function()
	it("comments and string contents are not code", function()
		expect(scan(handler('\t\t\t\t-- ctx.replicate.setAll("sign", name)'))).toEqual({})
		expect(scan(handler('\t\t\t\t--[[ ctx.replicate.setAll("sign", name) ]]'))).toEqual({})
		expect(scan(handler('\t\t\t\tctx.replicate.setAll("sign", "name")'))).toEqual({})
		expect(scan(handler("\t\t\t\tctx.replicate.setAll([[sign]], [[name]])"))).toEqual({})
	end)

	it("a header comment that documents a sink is not a finding", function()
		local src =
			"--[[\n\tactions = { x = function(player, name) ctx.replicate.setAll('a', name) end }\n]]\nreturn {}"
		expect(scan(src)).toEqual({})
	end)

	it("interpolated strings keep their expressions", function()
		expect(#scan(handler("\t\t\t\tctx.net.fireAll(Ev, `Pet: {name}!`)"))).toBe(1)
		expect(scan(handler("\t\t\t\tctx.net.fireAll(Ev, `Pet: {#name}`)"))).never.toEqual({})
		expect(scan(handler("\t\t\t\tctx.net.fireAll(Ev, `no player text {1 + 2}`)"))).toEqual({})
	end)

	it("only the handler's own params, after the player, count; other functions aren't sources", function()
		expect(scan(handler("\t\t\t\tpart.Name = player.Name"))).toEqual({})
		local helper = table.concat({
			"local function show(ctx, name)",
			'\tctx.replicate.setAll("sign", name)',
			"end",
			"return show",
		}, "\n")
		expect(scan(helper)).toEqual({})
	end)

	it("non-string annotations are not sources; string? and unions with string are", function()
		expect(scan(handler('\t\t\t\tctx.replicate.setAll("n", n)', "n: number"))).toEqual({})
		expect(#scan(handler('\t\t\t\tctx.replicate.setAll("n", n)', "n: string?"))).toBe(1)
		expect(#scan(handler('\t\t\t\tctx.replicate.setAll("n", n)', "n: string | number"))).toBe(1)
		expect(#scan(handler('\t\t\t\tctx.replicate.setAll("n", n)', "n"))).toBe(1)
	end)

	it("taint follows plain assignment, .., string.sub/format/lower/upper and their methods", function()
		for _, rhs in
			{ "name", '"a" .. name', "string.sub(name, 1, 3)", "string.format('%s', name)", "name:lower()" }
		do
			local got = scan(handler(table.concat({
				"\t\t\t\tlocal shown = " .. rhs,
				'\t\t\t\tctx.replicate.setAll("sign", shown)',
			}, "\n")))
			expect(#got).toBe(1)
		end
		-- not text-preserving: a length, a lookup
		for _, rhs in { "#name", "table.find(list, name)", "names[name]" } do
			local got = scan(handler(table.concat({
				"\t\t\t\tlocal v = " .. rhs,
				'\t\t\t\tctx.replicate.setAll("v", v)',
			}, "\n")))
			expect(got).toEqual({})
		end
	end)

	it("a TextFilter call clears a name from the next line on, through ctx.deps or an alias", function()
		local viaDeps = scan(handler(table.concat({
			'\t\t\t\tlocal t = ctx.deps[TextFilter].textFor(player, player, name, "private")',
			"\t\t\t\tctx.net.fire(player, Ev, t)",
		}, "\n")))
		expect(viaDeps).toEqual({})
		local sameLine = scan(
			handler(
				'\t\t\t\tctx.net.fire(player, Ev, ctx.deps[TextFilter].textFor(player, player, name, "private"))'
			)
		)
		expect(sameLine).toEqual({})
		local notTf = scan(handler(table.concat({
			"\t\t\t\tlocal t = Other.textFor(player, name)",
			"\t\t\t\tctx.net.fire(player, Ev, name)",
		}, "\n")))
		expect(#notTf).toBe(1)
	end)

	it("fields of a record are fine; the record itself is not", function()
		local src = handler(table.concat({
			"\t\t\t\tlocal tf = ctx.deps[TextFilter]",
			'\t\t\t\tlocal ok, r = tf.filter(player, name, "public")',
			'\t\t\t\tctx.replicate.setAll("a", r.public)',
			'\t\t\t\tctx.replicate.setAll("b", r.forViewer(player))',
			'\t\t\t\tctx.replicate.setAll("c", r)',
		}, "\n"))
		local got = scan(src)
		expect(#got).toBe(1)
		expect(got[1]).toContain("filter record 'r' reaches ctx.replicate.setAll whole")
	end)

	it("a guard comment on the sink's line skips it, only for textfilter", function()
		expect(scan(handler('\t\t\t\tctx.replicate.setAll("c", name) -- guard: allow textfilter'))).toEqual({})
		expect(#scan(handler('\t\t\t\tctx.replicate.setAll("c", name) -- guard: allow numbers'))).toBe(1)
	end)

	it("a sink spanning lines is reported at its first line", function()
		local got = scan(handler(table.concat({
			"\t\t\t\tctx.replicate.setAll(",
			'\t\t\t\t\t"sign",',
			"\t\t\t\t\tname",
			"\t\t\t\t)",
		}, "\n")))
		expect(#got).toBe(1)
		expect(got[1]).toContain("init.luau:6:")
	end)

	it("client code is not scanned", function()
		expect(
			G.scanSource(
				handler('ctx.replicate.setAll("s", name)'),
				{ path = "x/client/a.luau", isServer = false }
			)
		).toEqual({})
	end)
end)

describe("textfilter: files", function()
	local bad = handler('\t\t\t\tctx.replicate.setAll("sign", name)')
	it("scanGame reads server code only: not client code, not specs", function()
		local fs = memfs({
			["games/g/modules/m/server/init.luau"] = bad,
			["games/g/modules/m/client/init.luau"] = bad,
			["games/g/modules/m/server/init.spec.luau"] = bad,
			["games/g/src/server/Main.server.luau"] = bad,
			["games/g/src/shared/Util.luau"] = bad,
		})
		local got = G.scanGame(fs, "games/g")
		expect(#got).toBe(2)
		expect(got[1]).toContain("games/g/modules/m/server/init.luau:6:")
		expect(got[2]).toContain("games/g/src/server/Main.server.luau:6:")
	end)

	it("scanGame on a project root skips the framework submodule and dependency folders", function()
		local fs = memfs({
			["modules/m/server/init.luau"] = bad,
			["studwork/packages/kits/k/K/server/init.luau"] = bad,
			["Packages/x/server/init.luau"] = bad,
		})
		local got = G.scanGame(fs, ".")
		expect(#got).toBe(1)
		expect(got[1]).toContain("modules/m/server/init.luau:6:")
	end)

	it("scanAll reads kit and example-module server code", function()
		local fs = memfs({
			["packages/kits/social/Thing/server/init.luau"] = bad,
			["packages/kits/social/Thing/client/init.luau"] = bad,
			["examples/modules/demo/server/init.luau"] = bad,
			["packages/framework/server/Net.luau"] = bad,
		})
		local got = G.scanAll(fs)
		expect(#got).toBe(2)
	end)
end)

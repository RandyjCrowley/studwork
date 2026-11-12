--!nocheck
--[[
	v1.7.0 ctx.openCloud (module-api.md §23.7): deny by default. A path outside the allow-list,
	another module's secret, a wrong method and a hard-refused family are each refused with no
	request reaching the fake; a missing secret degrades cleanly (log once, no error); the
	per-minute budget; non-2xx and transport errors returned, never logged with their text.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local OpenCloud = require(script.Parent.Parent.server.OpenCloud)
local fakes = StudWork.test.fakes

local RULES = {
	Notify = { modules = { "Sender" }, methods = { "POST" }, paths = { "users/*/notifications" } },
	Broad = {
		modules = { "Sender" },
		methods = { "GET", "POST", "PATCH", "DELETE" },
		paths = { "*", "*/*", "*/*/*", "*/*/*/*", "*/*/*/*/*" },
	},
	Theirs = { modules = { "Other" }, methods = { "POST" }, paths = { "users/*/notifications" } },
}

local function boot(opts)
	local captured = {}
	local o = {
		modules = {
			StudWork.defineModule({ name = "Sender", version = "1.0.0", framework = "^1.7.0" }),
			StudWork.defineModule({ name = "Other", version = "1.0.0", framework = "^1.7.0" }),
		},
		servers = {
			Sender = {
				init = function(ctx)
					captured.ctx = ctx
				end,
			},
			Other = {
				init = function(ctx)
					captured.other = ctx
				end,
			},
		},
	}
	for k, v in opts or {} do
		o[k] = v
	end
	local h, err = StudWork.test.boot(o)
	assert(h, err)
	return h, captured.ctx, captured.other
end

local function standard(extra)
	local oc = fakes.openCloud()
	local o = {
		openCloud = oc,
		secrets = { Notify = true, Broad = true, Theirs = true },
		serverConfig = { openCloud = { secrets = RULES } },
	}
	for k, v in extra or {} do
		o[k] = v
	end
	local h, ctx, other = boot(o)
	return h, ctx, oc, other
end

local function warnings(h, text)
	local n = 0
	for _, w in h:warnings() do
		if string.find(w, text, 1, true) then
			n += 1
		end
	end
	return n
end

local function send(ctx, method, path, secret)
	return ctx.openCloud.request({
		secret = secret or "Notify",
		method = method,
		path = path,
		body = { x = 1 },
	})
end

describe("ctx.openCloud: the allow-list", function()
	it("sends an allowed request through the transport with the secret's name", function()
		local _, ctx, oc = standard()
		local ok, status, body = send(ctx, "POST", "users/42/notifications")
		expect(ok).toBe(true)
		expect(status).toBe(200)
		expect(type(body)).toBe("table")
		expect(#oc.requests).toBe(1)
		expect(oc.requests[1].secret).toBe("Notify")
		expect(oc.requests[1].method).toBe("POST")
		expect(oc.requests[1].path).toBe("users/42/notifications")
		expect(oc.requests[1].body.x).toBe(1)
	end)

	it("refuses a path outside the allow-list, with no request", function()
		local h, ctx, oc = standard()
		local ok, status, why = send(ctx, "POST", "users/42/notifications/extra")
		expect(ok).toBe(false)
		expect(status).toBeNil()
		expect(why).toBe("not_allowed")
		expect(select(3, send(ctx, "POST", "users/notifications"))).toBe("not_allowed")
		expect(select(3, send(ctx, "POST", "groups/42/notifications"))).toBe("not_allowed")
		expect(#oc.requests).toBe(0)
		expect(warnings(h, "Sender: secret 'Notify' refused: no pattern in its paths matches")).toBe(1)
	end)

	it("refuses another module's secret, with no request", function()
		local h, ctx, oc, other = standard()
		expect(select(3, send(ctx, "POST", "users/1/notifications", "Theirs"))).toBe("not_allowed")
		expect(ctx.openCloud.available("Theirs")).toBe(false)
		expect(#oc.requests).toBe(0)
		expect(warnings(h, `Sender: secret 'Theirs' refused: the entry doesn't list modules`)).toBe(1)
		-- the owner can
		expect((send(other, "POST", "users/1/notifications", "Theirs"))).toBe(true)
		expect(other.openCloud.available("Notify")).toBe(false)
	end)

	it("refuses a wrong method, with no request", function()
		local h, ctx, oc = standard()
		expect(select(3, send(ctx, "GET", "users/1/notifications"))).toBe("not_allowed")
		expect(select(3, send(ctx, "DELETE", "users/1/notifications"))).toBe("not_allowed")
		expect(#oc.requests).toBe(0)
		expect(warnings(h, "method GET isn't in its methods")).toBe(1)
	end)

	it("refuses a secret with no entry at all", function()
		local _, ctx, oc = standard()
		expect(select(3, send(ctx, "POST", "users/1/notifications", "Unknown"))).toBe("not_allowed")
		expect(#oc.requests).toBe(0)
	end)

	it("no ServerConfig.openCloud: everything is refused", function()
		local oc = fakes.openCloud({ secrets = { Notify = true } })
		local _, ctx = boot({ openCloud = oc })
		expect(ctx.openCloud.available("Notify")).toBe(false)
		expect(select(3, send(ctx, "POST", "users/1/notifications"))).toBe("not_allowed")
		expect(#oc.requests).toBe(0)
	end)

	it("logs one warning per (module, secret), however many refusals", function()
		local h, ctx = standard()
		for _ = 1, 5 do
			send(ctx, "POST", "nope/1")
			send(ctx, "GET", "users/1/notifications")
		end
		expect(warnings(h, "Sender: secret 'Notify' refused")).toBe(1)
	end)
end)

describe("ctx.openCloud: hard-refused families", function()
	local FAMILIES = {
		{ "universes/1/data-stores/scores/entries/k", "ctx.data" },
		{ "universes/1/data-stores/scores/entries:list", "ctx.data" },
		{ "universes/1/ordered-data-stores/board/scopes/global/entries", "ctx.data.ordered" },
		{ "universes/1/memory-store/sorted-maps/m/items", "ctx.data.sortedMap" },
		{ "universes/1/memory-store:flush", "ctx.data.sortedMap" },
		{ "universes/1/memory-store/queues/q/items:read", "ctx.data.sortedMap" },
		{ "universes/1/configs", "ctx.flags" },
		{ "universes/1/configs/staged", "ctx.flags" },
		{ "universes/1/places/2/luau-execution-session-tasks", "Luau execution" },
		{ "universes/1/Data-Stores/x", "ctx.data" },
	}

	it("refuses each family even with a broad allow-list, with no request", function()
		local h, ctx, oc = standard()
		for _, case in FAMILIES do
			local ok, status, why = send(ctx, "POST", case[1], "Broad")
			expect(ok).toBe(false)
			expect(status).toBeNil()
			expect(why).toBe("forbidden")
			expect(OpenCloud.refusedSurface(case[1])).toContain(case[2])
		end
		expect(#oc.requests).toBe(0)
		expect(warnings(h, "is in a refused family; use")).toBe(1)
		-- the broad key still reaches everything else
		expect((send(ctx, "GET", "universes/1/places/2", "Broad"))).toBe(true)
		expect(#oc.requests).toBe(1)
	end)

	it("a refused family wins over the allow-list order (forbidden, not not_allowed)", function()
		local _, ctx = standard()
		expect(select(3, send(ctx, "POST", "universes/1/data-stores/x", "Unknown"))).toBe("forbidden")
	end)
end)

describe("ctx.openCloud: paths", function()
	it("`*` matches exactly one segment; there is no `**`", function()
		expect(OpenCloud.matches("users/*/notifications", "users/1/notifications")).toBe(true)
		expect(OpenCloud.matches("users/*/notifications", "users/1/2/notifications")).toBe(false)
		expect(OpenCloud.matches("users/*", "users")).toBe(false)
		expect(OpenCloud.matches("users/**", "users/1/notifications")).toBe(false)
		expect(OpenCloud.matches("users/**", "users/**")).toBe(true) -- only literally
	end)

	it("a query string is allowed; the pattern matches the path part", function()
		local _, ctx, oc = standard()
		expect((send(ctx, "POST", "users/1/notifications?view=FULL"))).toBe(true)
		expect(oc.requests[1].path).toBe("users/1/notifications?view=FULL")
	end)

	it("a path that isn't plain and relative is a programming error, with no request", function()
		local _, ctx, oc = standard()
		local bad = {
			{ "users/1/../../universes/1/data-stores", "'..'" },
			{ "https://example.com/users/1/notifications", "no scheme" },
			{ "/users/1/notifications", "no leading '/'" },
			{ "users//1/notifications", "empty segments" },
			{ "users/1/notifications/", "empty segments" },
			{ "users/%2e%2e/notifications", "percent-encoded" },
			{ "users/./notifications", "'.' segments" },
			{ "users/1 /notifications", "spaces" },
			{ "users/1/notifications#x", "'#'" },
			{ "", "non-empty" },
		}
		for _, case in bad do
			local ok, err = pcall(send, ctx, "POST", case[1])
			expect(ok).toBe(false)
			expect(tostring(err)).toContain(case[2])
		end
		expect(#oc.requests).toBe(0)
	end)

	it("bad arguments are programming errors", function()
		local _, ctx = standard()
		expect(pcall(ctx.openCloud.request, nil)).toBe(false)
		expect(pcall(ctx.openCloud.request, { method = "POST", path = "users/1/notifications" })).toBe(false)
		local _, err = pcall(
			ctx.openCloud.request,
			{ secret = "Notify", method = "PUT", path = "users/1/notifications" }
		)
		expect(tostring(err)).toContain("method must be GET, POST, PATCH or DELETE")
		local _, err2 = pcall(ctx.openCloud.request, {
			secret = "Notify",
			method = "POST",
			path = "users/1/notifications",
			body = "text",
		})
		expect(tostring(err2)).toContain("body must be a table")
	end)
end)

describe("ctx.openCloud: the secret", function()
	it("no key: available is false, request returns no_secret, logs once, never errors or sends", function()
		local oc = fakes.openCloud()
		local h, ctx = boot({ openCloud = oc, serverConfig = { openCloud = { secrets = RULES } } })
		expect(ctx.openCloud.available("Notify")).toBe(false)
		for _ = 1, 3 do
			local ok, status, why = send(ctx, "POST", "users/1/notifications")
			expect(ok).toBe(false)
			expect(status).toBeNil()
			expect(why).toBe("no_secret")
		end
		expect(#oc.requests).toBe(0)
		expect(warnings(h, "secret 'Notify' is not available")).toBe(1)
	end)

	it("no transport at all (the default harness): no_secret, no error", function()
		local _, ctx = boot({ serverConfig = { openCloud = { secrets = RULES } } })
		expect(ctx.openCloud.available("Notify")).toBe(false)
		expect(select(3, send(ctx, "POST", "users/1/notifications"))).toBe("no_secret")
	end)

	it("a transport whose secret check raises counts as no secret", function()
		local transport = {
			hasSecret = function()
				error("GetSecret failed: Can't find secret with given key")
			end,
			request = function()
				error("must not be called")
			end,
		}
		local logs = {}
		local api = OpenCloud.new({
			config = { secrets = RULES },
			transport = transport,
			log = function(m)
				table.insert(logs, m)
			end,
		}).forModule("Sender")
		expect(api.available("Notify")).toBe(false)
		expect(select(3, api.request({ secret = "Notify", method = "POST", path = "users/1/notifications" }))).toBe(
			"no_secret"
		)
		for _, m in logs do
			expect(string.find(m, "Can't find secret", 1, true)).toBeNil()
		end
	end)

	it("available asks the secrets store once per secret (cached, doesn't yield again)", function()
		local _, ctx, oc = standard()
		local before = #oc.secretChecks
		for _ = 1, 4 do
			expect(ctx.openCloud.available("Notify")).toBe(true)
			send(ctx, "POST", "users/1/notifications")
		end
		local asked = 0
		for i = before + 1, #oc.secretChecks do
			if oc.secretChecks[i] == "Notify" then
				asked += 1
			end
		end
		expect(asked <= 1).toBe(true)
		expect(#oc.requests).toBe(4)
	end)
end)

describe("ctx.openCloud: budget and answers", function()
	it("at most perMinute requests a minute, then budget; the next minute resets it", function()
		local oc = fakes.openCloud()
		local h, ctx = boot({
			openCloud = oc,
			secrets = { Notify = true },
			serverConfig = { openCloud = { perMinute = 2, secrets = { Notify = RULES.Notify } } },
		})
		expect((send(ctx, "POST", "users/1/notifications"))).toBe(true)
		expect((send(ctx, "POST", "users/2/notifications"))).toBe(true)
		local ok, status, why = send(ctx, "POST", "users/3/notifications")
		expect(ok).toBe(false)
		expect(status).toBeNil()
		expect(why).toBe("budget")
		expect(#oc.requests).toBe(2)
		h:tick(60)
		expect((send(ctx, "POST", "users/3/notifications"))).toBe(true)
		expect(#oc.requests).toBe(3)
	end)

	it("the budget is per server, shared by its modules", function()
		local oc = fakes.openCloud()
		local _, ctx, other = boot({
			openCloud = oc,
			secrets = { Notify = true, Theirs = true },
			serverConfig = { openCloud = { perMinute = 1, secrets = RULES } },
		})
		expect((send(ctx, "POST", "users/1/notifications"))).toBe(true)
		expect(select(3, send(other, "POST", "users/1/notifications", "Theirs"))).toBe("budget")
	end)

	it("a 429 or 5xx is returned to the caller with its status", function()
		local _, ctx, oc = standard()
		oc.failNext(1, 429)
		local ok, status = send(ctx, "POST", "users/1/notifications")
		expect(ok).toBe(false)
		expect(status).toBe(429)
		oc.respondNext(503, { message = "down" })
		local ok2, status2, body2 = send(ctx, "POST", "users/1/notifications")
		expect(ok2).toBe(false)
		expect(status2).toBe(503)
		expect(body2.message).toBe("down")
		oc.respondNext(400, {})
		expect(select(2, send(ctx, "POST", "users/1/notifications"))).toBe(400)
	end)

	it("a transport error is failed, logged without its text or the bodies", function()
		local h, ctx, oc = standard()
		oc.raiseNext(1)
		local ok, status, why = send(ctx, "POST", "users/1/notifications")
		expect(ok).toBe(false)
		expect(status).toBeNil()
		expect(why).toBe("failed")
		for _, w in h:warnings() do
			expect(string.find(w, "injected", 1, true)).toBeNil()
			expect(string.find(w, "x = 1", 1, true)).toBeNil()
		end
		expect(warnings(h, "a request with secret 'Notify' failed")).toBe(1)
	end)
end)

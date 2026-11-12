--!nocheck
--[[
	v1.7.0 foundation: the in-memory fakes (StudWork.test.fakes, module-api.md §23.10) do what their
	headers say: record calls, take failNext, and behave like the engine service for the calls the
	v1.7.0 modules make. Behaviour of the modules on top of them is the builders' to spec.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local fakes = StudWork.test.fakes
local Fakes = require(script.Parent.Fakes)

describe("badgeService", function()
	it("awards once, reports owned, checks batches, reads info, records calls, takes failNext", function()
		local f =
			fakes.badgeService({ owned = { [1] = { 10 } }, disabled = { 12 }, names = { [11] = "Eleven" } })
		expect(f:AwardBadgeAsync(1, 10)).toBe(false) -- already owned
		expect(f:AwardBadgeAsync(1, 11)).toBe(true)
		expect(f:AwardBadgeAsync(1, 11)).toBe(false)
		expect(f:CheckUserBadgesAsync(1, { 10, 11, 12 })).toEqual({ 10, 11 })
		expect(f:GetBadgeInfoAsync(11).Name).toBe("Eleven")
		expect(f:GetBadgeInfoAsync(12).IsEnabled).toBe(false)
		expect(#f.awarded()).toBe(1)
		f.failNext(1)
		expect(pcall(f.AwardBadgeAsync, f, 2, 11)).toBe(false)
		expect(f:AwardBadgeAsync(2, 11)).toBe(true)
		expect(f.calls[1].method).toBe("AwardBadgeAsync")
	end)
end)

describe("textService", function()
	it("filters through the result methods, case-insensitively, and records calls", function()
		local f = fakes.textService({ replace = { badword = "#######" }, hiddenFrom = { 9 } })
		local r = f:FilterStringAsync("a BadWord here", 1, "PublicChat")
		expect(r:GetNonChatStringForBroadcastAsync()).toBe("a ####### here")
		expect(r:GetNonChatStringForUserAsync(2)).toBe("a ####### here")
		expect(pcall(r.GetNonChatStringForUserAsync, r, 9)).toBe(false)
		expect(f.calls[1].method).toBe("FilterStringAsync")
	end)

	it("fails the next n submissions and refuses offline authors", function()
		local f = fakes.textService({ failNext = 1, offline = { 5 } })
		expect(pcall(f.FilterStringAsync, f, "x", 1)).toBe(false)
		expect(pcall(f.FilterStringAsync, f, "x", 5)).toBe(false)
		expect(f:FilterStringAsync("x", 1):GetNonChatStringForBroadcastAsync()).toBe("x")
	end)
end)

describe("userService", function()
	it("answers display names, leaves out missing users, takes failNext", function()
		local f = fakes.userService({
			users = { [1] = { Username = "ada", DisplayName = "Ada" } },
			missing = { 3 },
		})
		local infos = f:GetUserInfosByUserIdsAsync({ 1, 2, 3 })
		expect(#infos).toBe(2)
		expect(infos[1].DisplayName).toBe("Ada")
		expect(infos[2].Username).toBe("user2")
		f.failNext(1)
		expect(pcall(f.GetUserInfosByUserIdsAsync, f, { 1 })).toBe(false)
		expect(f.lookups()).toBe(2)
	end)
end)

describe("configService", function()
	it("shows new values only after publish and Refresh, fires UpdateAvailable, takes failNext", function()
		local f = fakes.configService({ values = { flag_a = true } })
		local snapshot = f:GetConfigAsync()
		expect(snapshot:GetValue("flag_a")).toBe(true)
		local fired = 0
		snapshot.UpdateAvailable:Connect(function()
			fired += 1
		end)
		f.set("flag_a", false)
		expect(snapshot:GetValue("flag_a")).toBe(true) -- staged, not published
		f.publish()
		expect(fired).toBe(1)
		expect(snapshot.Outdated).toBe(true)
		snapshot:Refresh()
		expect(snapshot:GetValue("flag_a")).toBe(false)
		expect(snapshot.Outdated).toBe(false)
		f.failNext(1)
		expect(pcall(f.GetConfigAsync, f)).toBe(false)
	end)
end)

describe("openCloud", function()
	it("records requests (the secret's name), scripts responses and failures", function()
		local f = fakes.openCloud({ secrets = { Key = true } })
		expect(f.hasSecret("Key")).toBe(true)
		expect(f.hasSecret("Nope")).toBe(false)
		local ok, status, body = f.request({ secret = "Key", method = "POST", path = "p", body = { a = 1 } })
		expect(ok).toBe(true)
		expect(status).toBe(200)
		expect(body).toEqual({})
		f.respondNext(429)
		local ok2, status2 = f.request({ secret = "Key", method = "POST", path = "p" })
		expect(ok2).toBe(false)
		expect(status2).toBe(429)
		f.failNext(1, 503)
		expect(select(2, f.request({ secret = "Key", method = "POST", path = "p" }))).toBe(503)
		f.raiseNext(1)
		expect(pcall(f.request, { secret = "Key", method = "POST", path = "p" })).toBe(false)
		f.respond(201, { id = "x" })
		expect(select(3, f.request({ secret = "Key", method = "POST", path = "p" })).id).toBe("x")
		expect(#f.requests).toBe(5)
		expect(f.requests[1].secret).toBe("Key")
		expect(f.requests[1].body).toEqual({ a = 1 })
	end)
end)

describe("translator", function()
	it("formats entries, raises on a missing one, fires the locale change", function()
		local f = fakes.translator({
			locale = "es",
			entries = { ["ui.close"] = "Cerrar", ["a.b"] = "Hola {name}" },
		})
		expect(f.LocaleId).toBe("es")
		expect(f:FormatByKey("ui.close")).toBe("Cerrar")
		expect(f:FormatByKey("a.b", { name = "Ana" })).toBe("Hola Ana")
		expect(pcall(f.FormatByKey, f, "missing.key")).toBe(false)
		local changes = 0
		f:GetPropertyChangedSignal("LocaleId"):Connect(function()
			changes += 1
		end)
		f.setLocale("pt")
		expect(f.LocaleId).toBe("pt")
		expect(changes).toBe(1)
		expect(pcall(f.FormatByKey, f, "ui.close")).toBe(false) -- no pt table
		f.setEntries("pt", { ["ui.close"] = "Fechar" })
		expect(f:FormatByKey("ui.close")).toBe("Fechar")
	end)
end)

describe("experienceNotificationService", function()
	it("answers CanPromptOptInAsync, counts prompts, fires the closed event, takes failNext", function()
		local f = fakes.experienceNotificationService({ canPrompt = true })
		expect(f:CanPromptOptInAsync()).toBe(true)
		f:PromptOptIn()
		expect(f.prompts()).toBe(1)
		local closed = 0
		f.OptInPromptClosed:Connect(function()
			closed += 1
		end)
		f.close()
		expect(closed).toBe(1)
		f.setCanPrompt(false)
		expect(f:CanPromptOptInAsync()).toBe(false)
		f.failNext(1)
		expect(pcall(f.CanPromptOptInAsync, f)).toBe(false)
	end)
end)

describe("memory stores registry", function()
	it("shares an ordered store and a sorted map by name, on its clock", function()
		local now = 1000
		local r = Fakes.memoryStores({
			clock = function()
				return now
			end,
		})
		expect(r.ordered("SW/M/a") == r.ordered("SW/M/a")).toBe(true)
		r.ordered("SW/M/a").set("k", 4)
		expect(r.ordered("SW/M/a").top(5, "asc")[1].value).toBe(4)
		local map = r.sortedMap("SW/M/s")
		map.set("k", { v = 1 }, 30, 5)
		expect(#map.entries()).toBe(1)
		expect(r.memoryUsed() > 0).toBe(true)
		now += 31
		expect(#map.entries()).toBe(0)
		expect(r.sortedMapNames()).toEqual({ "SW/M/s" })
		expect(r.orderedNames()).toEqual({ "SW/M/a" })
	end)

	it("applies the structure limit as a minute window", function()
		local now = 0
		local r = Fakes.memoryStores({
			clock = function()
				return now
			end,
			sortedMap = { structureLimit = 2, partitionLimit = 10 },
		})
		local map = r.sortedMap("SW/M/s")
		map.set("a", 1, 60)
		map.set("b", 1, 60)
		local ok, err = pcall(map.set, "c", 1, 60)
		expect(ok).toBe(false)
		expect(err).toBe("DataStructureRequestsOverLimit")
		now += 61
		expect(pcall(map.set, "c", 1, 60)).toBe(true)
	end)
end)

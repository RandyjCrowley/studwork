--!nocheck
--[[
	TextFilter (v1.7.0, docs/framework/kits/textfilter.md): one path for player text, by audience.
	Every filter call goes to StudWork.test.fakes.textService through ctx.services; the fake's
	output is a pure function of its input ("badword" -> "#######"), so specs can assert it.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))

local Modules = ReplicatedStorage:WaitForChild("Modules")
local TextFilter = require(Modules:WaitForChild("TextFilter"):WaitForChild("module"))

local fakes = StudWork.test.fakes
local DAY = 86400
local OK = { IsContentSharingAllowed = true }

local function boot(opts)
	opts = opts or {}
	local fake = opts.fake or fakes.textService({ replace = { badword = true } })
	local policy = opts.policy or { [1] = OK, [2] = OK, [3] = OK, [4] = OK }
	local h = StudWork.test.harness({
		modules = { TextFilter },
		config = { TextFilter = opts.config or {} },
		services = { TextService = fake },
		policy = policy,
		store = opts.store,
	})
	return h, fake
end

-- players 1..n; friendships as pairs { {1, 2} }
local function join(h, n, pairs)
	local friends = {}
	for _, pair in pairs or {} do
		friends[pair[1] .. ":" .. pair[2]] = true
		friends[pair[2] .. ":" .. pair[1]] = true
	end
	local out = {}
	for i = 1, n do
		local p = h:addPlayer({ userId = i })
		p.friendChecks = 0
		function p.IsFriendsWithAsync(self, other)
			self.friendChecks += 1
			return friends[self.UserId .. ":" .. other] == true
		end
		out[i] = p
	end
	return table.unpack(out)
end

local function count(fake, method)
	local n = 0
	for _, c in fake.calls do
		if c.method == method then
			n += 1
		end
	end
	return n
end

local function containsDeep(v, needle, seen)
	seen = seen or {}
	if type(v) == "string" then
		return string.find(v, needle, 1, true) ~= nil
	end
	if type(v) ~= "table" or seen[v] then
		return false
	end
	seen[v] = true
	for k, x in v do
		if containsDeep(k, needle, seen) or containsDeep(x, needle, seen) then
			return true
		end
	end
	return false
end

describe("TextFilter: contexts", function()
	it("public: one broadcast string for everyone in the server", function()
		local h, fake = boot()
		local a, b = join(h, 2)
		local tf = h:use(TextFilter)
		local ok, r = tf.filter(a, "my badword pet", "public")
		expect(ok).toBe(true)
		expect(r.public).toBe("my ####### pet")
		expect(r.context).toBe("public")
		expect(r.author).toBe(1)
		expect(r.forViewer(b)).toBe("my ####### pet")
		expect(count(fake, "FilterStringAsync")).toBe(1)
		expect(count(fake, "GetNonChatStringForBroadcastAsync")).toBe(1)
	end)

	it("friends: the author and the author's friends; a stranger gets nil", function()
		local h, fake = boot()
		local a, friend, stranger = join(h, 3, { { 1, 2 } })
		local tf = h:use(TextFilter)
		local ok, r = tf.filter(a, "hi badword", "friends")
		expect(ok).toBe(true)
		expect(r.public).toBe(nil)
		expect(r.forViewer(a)).toBe("hi #######")
		expect(r.forViewer(friend)).toBe("hi #######")
		expect(r.forViewer(stranger)).toBe(nil)
		-- per viewer once, then cached; friendship cached per pair
		r.forViewer(friend)
		expect(count(fake, "GetNonChatStringForUserAsync")).toBe(2)
		expect(a.friendChecks).toBe(2)
		r.forViewer(stranger)
		expect(a.friendChecks).toBe(2)
	end)

	it("private: only the author", function()
		local h = boot()
		local a, b = join(h, 2, { { 1, 2 } })
		local ok, r = h:use(TextFilter).filter(a, "secret", "private")
		expect(ok).toBe(true)
		expect(r.public).toBe(nil)
		expect(r.forViewer(a)).toBe("secret")
		expect(r.forViewer(b)).toBe(nil)
	end)

	it("a viewer who left, or one Roblox can't filter for, gets nil", function()
		local h = boot({ fake = fakes.textService({ hiddenFrom = { 3 } }) })
		local a, b, c = join(h, 3, { { 1, 2 }, { 1, 3 } })
		local ok, r = h:use(TextFilter).filter(a, "hello", "friends")
		expect(ok).toBe(true)
		h:removePlayer(b)
		expect(r.forViewer(b)).toBe(nil)
		expect(r.forViewer(c)).toBe(nil)
	end)

	it("an unknown context is an error (a bug in the caller)", function()
		local h = boot()
		local a = join(h, 1)
		expect(pcall(h:use(TextFilter).filter, a, "x", "everyone")).toBe(false)
	end)
end)

describe("TextFilter: submissions and the re-display cache", function()
	it("two submissions of the same text are two filter calls; re-display is cached", function()
		local h, fake = boot()
		local a, b = join(h, 2)
		local tf = h:use(TextFilter)
		tf.filter(a, "same", "public")
		tf.filter(a, "same", "public")
		expect(count(fake, "FilterStringAsync")).toBe(2)
		expect(tf.textFor(b, a, "same", "public")).toBe("same")
		expect(tf.textFor(b, a, "same", "public")).toBe("same")
		expect(tf.textFor(a, a, "same", "public")).toBe("same")
		expect(count(fake, "FilterStringAsync")).toBe(2) -- re-display used the submission's result
		h:tick(600) -- cache.seconds
		expect(tf.textFor(b, a, "same", "public")).toBe("same")
		expect(count(fake, "FilterStringAsync")).toBe(3)
	end)

	it("textFor applies the context rules for the viewer", function()
		local h = boot()
		local a, friend, stranger = join(h, 3, { { 1, 2 } })
		local tf = h:use(TextFilter)
		expect(tf.textFor(friend, a, "hey", "friends")).toBe("hey")
		expect(tf.textFor(stranger, a, "hey", "friends")).toBe(nil)
		expect(tf.textFor(friend, a, "hey", "private")).toBe(nil)
		expect(tf.textFor(a, a, "hey", "private")).toBe("hey")
	end)

	it("the cache keeps at most cache.maxEntries (least recently used dropped)", function()
		local h, fake = boot({ config = { cache = { maxEntries = 2, seconds = 600 } } })
		local a = join(h, 1)
		local tf = h:use(TextFilter)
		tf.textFor(a, a, "one", "public")
		tf.textFor(a, a, "two", "public")
		tf.textFor(a, a, "one", "public") -- one is now the most recent
		tf.textFor(a, a, "three", "public") -- drops two
		expect(count(fake, "FilterStringAsync")).toBe(3)
		tf.textFor(a, a, "one", "public")
		expect(count(fake, "FilterStringAsync")).toBe(3)
		tf.textFor(a, a, "two", "public")
		expect(count(fake, "FilterStringAsync")).toBe(4)
	end)

	it("maxLength, trimming and control characters", function()
		local h, fake = boot({ config = { maxLength = 5 } })
		local a = join(h, 1)
		local tf = h:use(TextFilter)
		expect(select(2, tf.filter(a, "toolong", "public"))).toBe("too_long")
		expect(select(2, tf.filter(a, "   ", "public"))).toBe("empty")
		expect(select(2, tf.filter(a, "\n\t\0", "public"))).toBe("empty")
		expect(select(2, tf.filter(a, 42, "public"))).toBe("empty")
		local ok, r = tf.filter(a, "  a \n  b  ", "public")
		expect(ok).toBe(true)
		expect(r.public).toBe("a b")
		expect(fake.calls[1].text).toBe("a b") -- what Roblox was given
		expect(count(fake, "FilterStringAsync")).toBe(1) -- refused input never reaches Roblox
	end)

	it("trim = false keeps the spacing (control characters are still stripped)", function()
		local h = boot({ config = { trim = false } })
		local a = join(h, 1)
		local ok, r = h:use(TextFilter).filter(a, " a\tb ", "public")
		expect(ok).toBe(true)
		expect(r.public).toBe(" ab ")
	end)

	it("perPlayerPerMinute limits one author's filter calls", function()
		local h, fake = boot({ config = { perPlayerPerMinute = 2 } })
		local a, b = join(h, 2)
		local tf = h:use(TextFilter)
		expect(tf.filter(a, "1", "public")).toBe(true)
		expect(tf.filter(a, "2", "public")).toBe(true)
		expect(select(2, tf.filter(a, "3", "public"))).toBe("rate_limited")
		expect(tf.filter(b, "4", "public")).toBe(true) -- per author
		h:tick(60)
		expect(tf.filter(a, "5", "public")).toBe(true)
		expect(count(fake, "FilterStringAsync")).toBe(4)
	end)

	it("a textFor cache miss counts against perPlayerPerMinute; a cache hit is free", function()
		local h, fake = boot({ config = { perPlayerPerMinute = 2 } })
		local a, b = join(h, 2)
		local tf = h:use(TextFilter)
		expect(tf.textFor(b, a, "never submitted 1", "public")).never.toBe(nil)
		expect(tf.textFor(b, a, "never submitted 2", "public")).never.toBe(nil)
		expect(tf.textFor(b, a, "never submitted 3", "public")).toBe(nil) -- over: nil, no filter call
		expect(count(fake, "FilterStringAsync")).toBe(2)
		expect(tf.textFor(b, a, "never submitted 1", "public")).never.toBe(nil) -- cached: free
		expect(count(fake, "FilterStringAsync")).toBe(2)
		h:tick(60)
		expect(tf.textFor(b, a, "never submitted 3", "public")).never.toBe(nil)
	end)

	it("viewers' textFor misses never spend the author's submission rate (N2)", function()
		local h, fake = boot({ config = { perPlayerPerMinute = 2 } })
		local a, b = join(h, 2)
		local tf = h:use(TextFilter)
		tf.textFor(b, a, "shown 1", "public")
		tf.textFor(b, a, "shown 2", "public")
		expect(tf.textFor(b, a, "shown 3", "public")).toBe(nil) -- re-display is still bounded
		expect(tf.filter(a, "mine 1", "public")).toBe(true) -- the author's own submissions are not
		expect(tf.filter(a, "mine 2", "public")).toBe(true)
		expect(select(2, tf.filter(a, "mine 3", "public"))).toBe("rate_limited")
		expect(count(fake, "FilterStringAsync")).toBe(4)
	end)

	it("content sharing off or unknown refuses public and friends; private still works", function()
		local h, fake = boot({ policy = { [1] = { IsContentSharingAllowed = false }, [2] = "fail" } })
		local a, b, c = join(h, 3)
		local tf = h:use(TextFilter)
		expect(select(2, tf.filter(a, "x", "public"))).toBe("policy")
		expect(select(2, tf.filter(a, "x", "friends"))).toBe("policy")
		expect(tf.filter(a, "x", "private")).toBe(true)
		expect(select(2, tf.filter(b, "x", "public"))).toBe("policy") -- lookup failed: fail closed
		expect(select(2, tf.filter(c, "x", "public"))).toBe("policy") -- no answer: fail closed
		expect(tf.textFor(a, a, "x", "public")).toBe(nil)
		expect(count(fake, "FilterStringAsync")).toBe(1)
	end)

	it("respectContentSharing = false skips the policy check", function()
		local h = boot({ config = { respectContentSharing = false }, policy = {} })
		local a = join(h, 1)
		expect(h:use(TextFilter).filter(a, "x", "public")).toBe(true)
	end)

	it("an author who isn't in this server is refused", function()
		local h = boot()
		local a = join(h, 1)
		h:removePlayer(a)
		local tf = h:use(TextFilter)
		expect(select(2, tf.filter(a, "x", "public"))).toBe("author_offline")
		expect(select(2, tf.store(a, "x", "public"))).toBe("author_offline")
		expect(tf.textFor(a, a, "x", "public")).toBe(nil)
		expect(select(2, tf.filter(StudWork.test.player(99), "x", "public"))).toBe("author_offline")
	end)

	it("filter_failed never returns the original, and nothing logs player text", function()
		local h = boot({ fake = fakes.textService({ failNext = 1 }) })
		local a = join(h, 1)
		local tf = h:use(TextFilter)
		local ok, reason = tf.filter(a, "zebra-secret", "public")
		expect(ok).toBe(false)
		expect(reason).toBe("filter_failed")
		local h2 = boot({ fake = fakes.textService({ offline = { 1 } }) })
		local a2 = join(h2, 1)
		local ok2, r2 = h2:use(TextFilter).store(a2, "zebra-secret", "public")
		expect(ok2).toBe(false)
		expect(r2).toBe("filter_failed")
		for _, l in h.logs do
			expect(string.find(l.msg, "zebra", 1, true)).toBe(nil)
		end
		for _, l in h2.logs do
			expect(string.find(l.msg, "zebra", 1, true)).toBe(nil)
		end
		expect(containsDeep(h2:saved(a2) or {}, "zebra")).toBe(false)
	end)
end)

describe("TextFilter: stored text", function()
	it("a Stored record holds no original text; the original stays in the module's own section", function()
		local h = boot()
		local a, b = join(h, 2)
		local tf = h:use(TextFilter)
		local ok, s = tf.store(a, "zebra badword", "public")
		expect(ok).toBe(true)
		expect(s.id).toBe(1)
		expect(s.author).toBe(1)
		expect(s.context).toBe("public")
		expect(s.shown).toBe("zebra #######")
		expect(containsDeep(s, "badword")).toBe(false)
		expect(table.isfrozen(s)).toBe(true)
		expect(tf.shown(s, b)).toBe("zebra #######")
		expect(tf.shown(s)).toBe("zebra #######")
		h:removePlayer(a)
		local saved = h:saved(a).textfilter
		expect(saved.nextId).toBe(2)
		expect(saved.originals["1"].t).toBe("zebra badword")
		expect(saved.originals["1"].c).toBe("public")
	end)

	it("the original never replicates (not in the author's or anyone's state)", function()
		local h = boot()
		local a, b = join(h, 2)
		h:use(TextFilter).store(a, "zebra badword", "public")
		expect(containsDeep(h:state(a), "badword")).toBe(false)
		expect(containsDeep(h:state(b), "badword")).toBe(false)
		expect(containsDeep(h:state(a), "zebra")).toBe(false)
	end)

	it("store/shown round trip across a rejoin; away, a public record shows its saved string", function()
		local store = StudWork.test.memoryStore()
		local h, fake = boot({ store = store })
		local a, b = join(h, 2)
		local tf = h:use(TextFilter)
		local _, s = tf.store(a, "my badword", "public")
		h:removePlayer(a)
		local before = count(fake, "FilterStringAsync")
		expect(tf.shown(s, b)).toBe("my #######") -- author away: the stored broadcast string
		expect(count(fake, "FilterStringAsync")).toBe(before)
		h:tick(3600)
		h:addPlayer({ userId = 1 }) -- back in this server
		expect(tf.shown(s, b)).toBe("my #######") -- re-filtered from the original
		expect(count(fake, "FilterStringAsync")).toBe(before + 1)
	end)

	it("shownMaxDays defaults to 7: an away author's public string is shown for a week, no longer", function()
		expect(TextFilter.config.defaults.shownMaxDays).toBe(7)
		local h = boot()
		local a, b = join(h, 2)
		local tf = h:use(TextFilter)
		local _, s = tf.store(a, "hello", "public")
		h:removePlayer(a)
		h.clock += 6 * 86400
		expect(tf.shown(s, b)).never.toBe(nil)
		h.clock += 2 * 86400
		expect(tf.shown(s, b)).toBe(nil)
	end)

	it("shownMaxDays: away longer than that, a public record shows nil", function()
		local h = boot({ config = { shownMaxDays = 2 } })
		local a, b = join(h, 2)
		local tf = h:use(TextFilter)
		local _, s = tf.store(a, "sign", "public")
		h:removePlayer(a)
		h:tick(DAY)
		expect(tf.shown(s, b)).toBe("sign")
		h:tick(DAY + 1)
		expect(tf.shown(s, b)).toBe(nil)
	end)

	it("friends and private records show nil while the author is away", function()
		local h = boot()
		local a, b = join(h, 2, { { 1, 2 } })
		local tf = h:use(TextFilter)
		local _, f = tf.store(a, "for friends", "friends")
		local _, p = tf.store(a, "for me", "private")
		expect(f.shown).toBe(nil)
		expect(tf.shown(f, b)).toBe("for friends")
		expect(tf.shown(p, a)).toBe("for me")
		expect(tf.shown(p, b)).toBe(nil)
		expect(tf.shown(f)).toBe(nil) -- no viewer: only public text has an everyone string
		h:removePlayer(a)
		expect(tf.shown(f, b)).toBe(nil)
	end)

	it("originals.max drops the oldest; its record then behaves as if the author were away", function()
		local h = boot({ config = { originals = { max = 2 }, shownMaxDays = 1 } })
		local a = join(h, 1)
		local tf = h:use(TextFilter)
		local _, s1 = tf.store(a, "one", "public")
		tf.store(a, "two", "public")
		local _, s3 = tf.store(a, "three", "public")
		expect(tf.shown(s1, a)).toBe("one") -- dropped: the saved broadcast string, within shownMaxDays
		expect(tf.shown(s3, a)).toBe("three")
		h:tick(DAY + 1)
		expect(tf.shown(s1, a)).toBe(nil)
		expect(tf.shown(s3, a)).toBe("three") -- still re-filtered from its original
		h:removePlayer(a)
		local section = h:saved(a).textfilter
		expect(section.originals["1"]).toBe(nil)
		expect(section.originals["2"].t).toBe("two")
		expect(section.originals["3"].t).toBe("three")
	end)

	it("release drops the original (only the author's own records)", function()
		local h = boot({ config = { shownMaxDays = 0 } })
		local a, b = join(h, 2)
		local tf = h:use(TextFilter)
		local _, s = tf.store(a, "sign", "public")
		tf.release(b, s) -- not b's record: ignored
		expect(tf.shown(s, b)).toBe("sign")
		tf.release(a, s)
		h:tick(1)
		expect(tf.shown(s, b)).toBe(nil)
		h:removePlayer(a)
		expect(h:saved(a).textfilter.originals["1"]).toBe(nil)
	end)

	it(
		"viewers re-showing stored text never block the author's submissions or blank the text (N2)",
		function()
			local h = boot({ config = { perPlayerPerMinute = 30 } })
			local a, b = join(h, 2, { { 1, 2 } })
			local tf = h:use(TextFilter)
			local records = {}
			for i = 1, 30 do
				local context = if i % 3 == 0 then "public" elseif i % 3 == 1 then "friends" else "private"
				local ok, s = tf.store(a, `item {i}`, context)
				expect(ok).toBe(true)
				records[i] = s
			end
			h:tick(600) -- cache.seconds: every re-display is a miss now
			for i, s in records do
				local viewer = if s.context == "private" then a else b
				expect(tf.shown(s, viewer)).toBe(`item {i}`)
			end
			expect(tf.filter(a, "a new name", "public")).toBe(true)
		end
	)

	it(
		"shown re-filters a stored record at most once per cache.seconds, even past cache.maxEntries",
		function()
			local h, fake = boot({ config = { cache = { maxEntries = 1, seconds = 600 } } })
			local a, b = join(h, 2)
			local tf = h:use(TextFilter)
			local records = {}
			for i = 1, 5 do
				records[i] = select(2, tf.store(a, `sign {i}`, "public"))
			end
			h:tick(600)
			local before = count(fake, "FilterStringAsync")
			for _ = 1, 3 do
				for _, s in records do
					tf.shown(s, b)
				end
			end
			expect(count(fake, "FilterStringAsync")).toBe(before + 5)
			h:tick(600)
			tf.shown(records[1], b)
			expect(count(fake, "FilterStringAsync")).toBe(before + 6)
		end
	)

	it("shown refuses anything that isn't a Stored record", function()
		local h = boot()
		local a = join(h, 1)
		local tf = h:use(TextFilter)
		expect(tf.shown(nil)).toBe(nil)
		expect(tf.shown("text", a)).toBe(nil)
		expect(tf.shown({ id = 1, author = 1, context = "everyone" }, a)).toBe(nil)
	end)
end)

describe("TextFilter: pure cleaning", function()
	it("TextFilter.clean", function()
		local Server = require("packages/kits/social/TextFilter/server/init.luau")
		expect(Server.clean("  a  b  ", 40, true)).toBe("a b")
		expect(Server.clean("a\0b", 40, true)).toBe("ab")
		expect(select(2, Server.clean("", 40, true))).toBe("empty")
		expect(select(2, Server.clean("abcdef", 5, true))).toBe("too_long")
		expect(Server.clean("héllo", 5, true)).toBe("héllo") -- characters, not bytes
	end)
end)

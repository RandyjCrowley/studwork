--!strict
--[[
	tools/lune/PublishGate: the pure decision logic of tools/publish (zero requires, so the Lune
	test harness loads it directly; specs in PublishGate.spec.luau).

	decide(input) -> Decision
	  input = {
	    target       "test" | "live"
	    dryRun       boolean
	    deploy       decoded games/<name>/deploy.json
	    head         full commit hash of HEAD
	    dirty        { string } build-relevant paths with uncommitted changes (game folder, core,
	                 deps), deploy.json excluded (publishing itself writes it)
	    keyPresent   boolean: ROBLOX_OPEN_CLOUD_API_KEY is set (the value never reaches this module)
	    testEquivalent boolean?: the recorded test commit and HEAD have identical build inputs
	                 (games/<name> minus deploy.json, packages/, deps/), e.g. only the stamp files
	                 or tools/docs changed since; computed by the caller with `git diff --quiet`
	  }
	Decision = { ok, errors, warnings, record = "published" | "dryRun" }

	Rules (all errors are collected, not just the first):
	  1. ids: deploy[target].universeId/placeId must be positive integers. 0, negative, non-integer
	     or string values are placeholders. Real publish: error. Dry run: warning (the request is
	     printed with the placeholder so the rest of the pipeline can still be exercised).
	  2. real publish: no dirty build-relevant paths.
	  3. real publish: the API key must be present.
	  4. --live: the SAME commit must have gone to test first:
	       real live    needs deploy.test.published.commit == head (or testEquivalent)
	       live dry run accepts deploy.test.published OR deploy.test.dryRun with commit == head
	     A test dry run never unlocks a real live publish.

	Records written after a run (tools/lune/deploy-stamp):
	  deploy[target].published = { commit, at, versionNumber }   real publish (HTTP 200)
	  deploy[target].dryRun    = { commit, at }                  dry run
]]

local PublishGate = {}

export type Record = { commit: string?, at: string?, versionNumber: number? }

export type Input = {
	target: string,
	dryRun: boolean,
	deploy: any,
	head: string,
	dirty: { string },
	keyPresent: boolean,
	testEquivalent: boolean?,
}

export type Decision = {
	ok: boolean,
	errors: { string },
	warnings: { string },
	record: string,
}

-- True when an id is not a real Roblox id (0 / missing / negative / non-integer / string).
function PublishGate.isPlaceholderId(value: any): boolean
	if type(value) ~= "number" then
		return true
	end
	return value ~= value or value <= 0 or math.floor(value) ~= value or value == math.huge
end

local function section(deploy: any, target: string): any
	if type(deploy) ~= "table" then
		return nil
	end
	local s = deploy[target]
	if type(s) ~= "table" then
		return nil
	end
	return s
end

local function recordCommit(deploy: any, target: string, kind: string): string?
	local s = section(deploy, target)
	if s == nil then
		return nil
	end
	local r = s[kind]
	if type(r) ~= "table" or type(r.commit) ~= "string" then
		return nil
	end
	return r.commit
end
PublishGate.recordCommit = recordCommit

local function short(hash: string?): string
	if hash == nil then
		return "none"
	end
	return string.sub(hash, 1, 7)
end

function PublishGate.decide(input: Input): Decision
	local errors: { string } = {}
	local warnings: { string } = {}
	local target = input.target
	if target ~= "test" and target ~= "live" then
		return { ok = false, errors = { "target must be test or live" }, warnings = {}, record = "dryRun" }
	end
	local real = not input.dryRun

	-- 1. ids
	local s = section(input.deploy, target)
	local placeholders: { string } = {}
	for _, key in { "universeId", "placeId" } do
		if s == nil or PublishGate.isPlaceholderId(s[key]) then
			table.insert(placeholders, key)
		end
	end
	if #placeholders > 0 then
		local msg = string.format(
			"deploy.json %s.%s is a placeholder (0 or not a positive integer): create the %s "
				.. "experience and paste its ids (docs/publishing.md)",
			target,
			table.concat(placeholders, "/"),
			target
		)
		table.insert(if real then errors else warnings, msg)
	end

	-- 2. clean tree
	if real and #input.dirty > 0 then
		local shown = {}
		for i, p in input.dirty do
			if i > 5 then
				table.insert(shown, string.format("... (%d more)", #input.dirty - 5))
				break
			end
			table.insert(shown, p)
		end
		table.insert(
			errors,
			"uncommitted changes in game/core paths (commit them first; a publish must match a commit): "
				.. table.concat(shown, ", ")
		)
	end

	-- 3. key
	if not input.keyPresent then
		local msg = "ROBLOX_OPEN_CLOUD_API_KEY is not set (env var or .env, see docs/publishing.md)"
		table.insert(if real then errors else warnings, msg)
	end

	-- 4. test before live
	if target == "live" then
		local published = recordCommit(input.deploy, "test", "published")
		local dry = recordCommit(input.deploy, "test", "dryRun")
		local publishedOk = published ~= nil and (published == input.head or input.testEquivalent == true)
		if real then
			if not publishedOk then
				local why = if published == nil
					then "nothing was published to test yet"
					else string.format("test has %s, HEAD is %s", short(published), short(input.head))
				if published == nil and dry == input.head then
					why ..= " (a test --dry-run does not count for a real live publish)"
				end
				table.insert(
					errors,
					"--live needs this exact commit published to --test first: "
						.. why
						.. ". Run tools/publish <game> --test, playtest, then --live."
				)
			end
		else
			if not publishedOk and dry ~= input.head then
				table.insert(
					errors,
					string.format(
						"--live --dry-run needs this commit on test first (a real --test or a --test "
							.. "--dry-run of HEAD): test published %s, test dry run %s, HEAD %s",
						short(published),
						short(dry),
						short(input.head)
					)
				)
			elseif not publishedOk then
				table.insert(
					warnings,
					"test only has a DRY RUN of this commit: a real --live will still be refused "
						.. "until a real --test publish of it"
				)
			end
		end
	end

	return {
		ok = #errors == 0,
		errors = errors,
		warnings = warnings,
		record = if real then "published" else "dryRun",
	}
end

-- One-cell summary for tools/core-status: ids placeholder? and is <target> in sync with HEAD?
function PublishGate.syncStatus(deploy: any, target: string, head: string): string
	local s = section(deploy, target)
	local ids = if s == nil
			or PublishGate.isPlaceholderId(s.universeId)
			or PublishGate.isPlaceholderId(s.placeId)
		then "placeholder ids"
		else string.format("%d/%d", s.universeId, s.placeId)
	local published = recordCommit(deploy, target, "published")
	local dry = recordCommit(deploy, target, "dryRun")
	local sync
	if published == head then
		local v = s and s.published and s.published.versionNumber
		sync = if type(v) == "number" and v > 0 then string.format("in sync (v%d)", v) else "in sync"
	elseif published ~= nil then
		sync = "behind HEAD (has " .. short(published) .. ")"
	elseif dry == head then
		sync = "dry run of HEAD only"
	elseif dry ~= nil then
		sync = "never published (dry run " .. short(dry) .. ")"
	else
		sync = "never published"
	end
	return ids .. ", " .. sync
end

-- Replaces every occurrence of `secret` in `text` (plain, not a pattern).
function PublishGate.redact(text: string, secret: string?): string
	if secret == nil or secret == "" then
		return text
	end
	local out = {}
	local i = 1
	while true do
		local s, e = string.find(text, secret, i, true)
		if s == nil then
			table.insert(out, string.sub(text, i))
			break
		end
		table.insert(out, string.sub(text, i, s - 1))
		table.insert(out, "<redacted>")
		i = (e :: number) + 1
	end
	return table.concat(out)
end

PublishGate.ENDPOINT = "https://apis.roblox.com/universes/v1/%s/places/%s/versions?versionType=Published"

local function idText(value: any): string
	if PublishGate.isPlaceholderId(value) then
		return "<PLACEHOLDER:" .. tostring(value) .. ">"
	end
	return string.format("%d", value)
end

function PublishGate.url(deploy: any, target: string): string
	local s = section(deploy, target) or {}
	return string.format(PublishGate.ENDPOINT, idText(s.universeId), idText(s.placeId))
end

-- The exact request a real publish sends, for --dry-run output. The key is never an input, so it
-- can't leak through here; the header always reads <redacted>.
function PublishGate.requestPreview(deploy: any, target: string, file: string, bytes: number): string
	return table.concat({
		"POST " .. PublishGate.url(deploy, target),
		"x-api-key: <redacted> (from ROBLOX_OPEN_CLOUD_API_KEY, sent via a 0600 temp header file)",
		"Content-Type: application/octet-stream",
		string.format("body: %s (%d bytes)", file, bytes),
	}, "\n")
end

return PublishGate

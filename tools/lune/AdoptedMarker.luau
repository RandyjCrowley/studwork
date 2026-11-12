--!nocheck
--[[
	tools/lune/AdoptedMarker (StudWork v1.6.1, docs/framework/adopting.md §5, guardrails.md): the
	adopted marker is sticky. studwork.json's "adopted": true is anchored in git like the legacy
	baseline: if ANY commit reachable from HEAD had a studwork.json that says adopted, the project
	counts as adopted for tools/lint and tools/publish, whatever the working copy says now.

	Why any commit (not only the first one that added studwork.json): a project can be adopted
	after its studwork.json was first committed, and studwork.json can be deleted and re-added; the
	history from HEAD only grows, so once a commit said adopted, no later commit can take it back.
	Rewriting history is the only way to drop it, and `tools/lint --anchor-remote` compares the
	marker with the remote default branch's history for that. History is read loosely (any key
	casing, true / "true" / 1): a marker that was ever spelled like "adopted" counts. The working
	copy is read strictly (`"adopted": true` only), so `"adopted": "true"`, `"adopted": false` or
	`"Adopted": true` now = the flag was removed.

	Removing the flag (or studwork-legacy.json, or both) fails lint until `tools/adopt --verify .`
	passes ("graduating"); after that the flag may go.

	Zero requires; git is passed in as gitIn(args) -> (ok, stdout|stderr), serde as a module.
	  AdoptedMarker.strict(decoded) -> boolean        the working copy says "adopted": true
	  AdoptedMarker.loose(decoded) -> boolean         any "adopted"-like key that is true/"true"/1
	  AdoptedMarker.fromVersions(serde, versions) -> (adopted, commit?)
	      versions = { { commit, text? } } oldest first (text nil = studwork.json deleted there)
	  AdoptedMarker.history(serde, gitIn, rev?) -> { status = "ok", adopted, commit? }
	      | { status = "shallow" } | { status = "no-commit" } | { status = "unavailable", detail }
	  AdoptedMarker.evaluate(input) -> (failures, notes)
	      input = { currentAdopted, history, runVerify = fn() -> (ok, output) }
]]

local AdoptedMarker = {}

AdoptedMarker.FILE = "studwork.json"

function AdoptedMarker.strict(decoded: any): boolean
	return type(decoded) == "table" and decoded.adopted == true
end

function AdoptedMarker.loose(decoded: any): boolean
	if type(decoded) ~= "table" then
		return false
	end
	for k, v in decoded do
		if type(k) == "string" and string.lower(k) == "adopted" then
			if v == true or v == 1 or (type(v) == "string" and string.lower(v) == "true") then
				return true
			end
		end
	end
	return false
end

function AdoptedMarker.fromVersions(serde: any, versions: { any }): (boolean, string?)
	for _, v in versions do
		if type(v.text) == "string" then
			local ok, decoded = pcall(serde.decode, "json", v.text)
			if ok and AdoptedMarker.loose(decoded) then
				return true, v.commit
			end
		end
	end
	return false, nil
end

function AdoptedMarker.history(serde: any, gitIn: (args: { string }) -> (boolean, string), rev: string?): any
	local okRepo, inside = gitIn({ "rev-parse", "--is-inside-work-tree" })
	if not okRepo or not string.find(inside, "true", 1, true) then
		return { status = "unavailable", detail = "not a git repository" }
	end
	local okS, shallow = gitIn({ "rev-parse", "--is-shallow-repository" })
	if not okS then
		return { status = "unavailable", detail = "git rev-parse --is-shallow-repository failed" }
	end
	if string.find(shallow, "true", 1, true) then
		return { status = "shallow" }
	end
	local at = rev or "HEAD"
	if not gitIn({ "rev-parse", "--verify", "-q", at .. "^{commit}" }) then
		return { status = "no-commit" }
	end
	-- --full-history: a side branch that added and removed the flag before a merge still counts
	local okL, log =
		gitIn({ "log", "--full-history", "--reverse", "--format=%H", at, "--", AdoptedMarker.FILE })
	if not okL then
		return { status = "unavailable", detail = "git log failed" }
	end
	local versions = {}
	for h in string.gmatch(log, "%x+") do
		local okShow, text = gitIn({ "show", h .. ":" .. AdoptedMarker.FILE })
		table.insert(versions, { commit = h, text = if okShow then text else nil })
	end
	local adopted, commit = AdoptedMarker.fromVersions(serde, versions)
	return { status = "ok", adopted = adopted, commit = commit }
end

function AdoptedMarker.evaluate(input: any): ({ string }, { string })
	local failures, notes = {}, {}
	if input.currentAdopted then
		return failures, notes
	end
	local h = input.history or { status = "unavailable" }
	if h.status == "shallow" then
		table.insert(
			notes,
			"guardrails: shallow clone: the adopted marker's history isn't checked (fetch the full history, as CI does)"
		)
		return failures, notes
	elseif h.status ~= "ok" or not h.adopted then
		return failures, notes
	end
	local ok, output = input.runVerify()
	local commit = string.sub(tostring(h.commit), 1, 12)
	if ok then
		table.insert(
			notes,
			`guardrails: studwork.json no longer says "adopted": true (it did in {commit}); tools/adopt --verify . passes, so the project has graduated`
		)
		return failures, notes
	end
	table.insert(
		failures,
		`studwork.json: [legacy] the project was adopted ({commit} has "adopted": true) and studwork.json no longer says "adopted": true; it still counts as adopted until tools/adopt --verify . passes. Restore "adopted": true (and studwork-legacy.json), or finish the migration (docs/framework/adopting.md §5)`
	)
	for line in string.gmatch(output or "", "[^\n]+") do
		table.insert(failures, "studwork.json: [legacy]   verify: " .. line)
	end
	return failures, notes
end

return AdoptedMarker

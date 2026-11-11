--!nocheck
-- The public repo carries nothing private (v1.6.0): no name from the local, git-ignored
-- .private-names (one per line, # comments; or STUDWORK_PRIVATE_NAMES, comma-separated) and no
-- home-folder path, in any file git tracks or would add (tracked + untracked, not ignored).
-- Without .private-names and STUDWORK_PRIVATE_NAMES the name part is skipped (CI), the path part
-- always runs.
local lune = (getmetatable(getfenv(1)) :: any).__index.require
local fs = lune("@lune/fs")
local process = lune("@lune/process")

local function names(): { string }
	local out = {}
	local function add(text: string, sep: string)
		for _, raw in string.split(text, sep) do
			local name = string.gsub(string.gsub(raw, "#.*$", ""), "^%s*(.-)%s*$", "%1")
			if name ~= "" then
				table.insert(out, string.lower(name))
			end
		end
	end
	if process.env.STUDWORK_PRIVATE_NAMES then
		add(process.env.STUDWORK_PRIVATE_NAMES, ",")
	end
	if fs.isFile(".private-names") then
		add(fs.readFile(".private-names"), "\n")
	end
	return out
end

local function files(): { string }
	local res = process.exec("git", { "ls-files", "-z", "--cached", "--others", "--exclude-standard" })
	if not res.ok then
		return {}
	end
	local out = {}
	for _, p in string.split(res.stdout, "\0") do
		if p ~= "" and p ~= ".private-names" and fs.isFile(p) then
			table.insert(out, p)
		end
	end
	return out
end

-- Home-folder paths a committed file must never contain. The two spec/doc lines that NAME the
-- generic patterns (to check for them) are allowed by exact text.
local PATH_PATTERNS = { "/Users/([%w%._%-]+)/", "/home/([%w%._%-]+)/" }
-- placeholder user names in examples and specs ("/home/me/x") are not anyone's home
local PLACEHOLDERS = { me = true, user = true, you = true, name = true, example = true }
local ALLOWED_LINES = {
	["docs/decisions.md"] = "generic machine paths (`/Users/`, `/home/`, `.local`)",
	["tools/lune/NewProject.spec.luau"] = '{ "/Users/", "/home/", ".local" }',
}

describe("privacy: the tracked tree", function()
	it("names no private name and no home-folder path", function()
		local private = names()
		local hits = {}
		for _, path in files() do
			local ok, text = pcall(fs.readFile, path)
			if not ok or string.find(text, "\0", 1, true) then
				continue -- binary
			end
			local lower = string.lower(text)
			for _, n in private do
				if string.find(lower, n, 1, true) then
					table.insert(hits, `{path}: a name from .private-names`)
				end
			end
			for lineNo, line in string.split(text, "\n") do
				for _, pat in PATH_PATTERNS do
					local who = string.match(line, pat)
					if who and not PLACEHOLDERS[who] then
						local allowed = ALLOWED_LINES[path]
						if not (allowed and string.find(line, allowed, 1, true)) then
							table.insert(hits, `{path}:{lineNo}: a home-folder path`)
						end
					end
				end
			end
		end
		if #hits > 0 then
			error("private text in the tree:\n  " .. table.concat(hits, "\n  "))
		end
	end)
end)

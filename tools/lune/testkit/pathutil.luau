--!nocheck
--[[
	Pure path helpers for the test harness and its specs (no I/O).

	Lune's `process.cwd` ends in "/" and $TMPDIR may be unset (CI), so a naive `cwd .. "/.cache"`
	yields "//" and a prefix strip against `pwd` output leaves an absolute-looking "/.cache/...".
	Always join and compare through these.
]]

local PathUtil = {}

-- Collapses repeated "/", drops "." segments, resolves ".." and any trailing "/".
-- Absolute paths stay absolute ("/" for the root); a relative path that collapses to nothing is ".".
function PathUtil.normalize(path: string): string
	local abs = string.sub(path, 1, 1) == "/"
	local parts: { string } = {}
	for seg in string.gmatch(path, "[^/]+") do
		if seg == "." then
			continue
		elseif seg == ".." then
			if #parts > 0 and parts[#parts] ~= ".." then
				table.remove(parts)
			elseif not abs then
				table.insert(parts, "..")
			end
		else
			table.insert(parts, seg)
		end
	end
	local out = table.concat(parts, "/")
	if abs then
		return "/" .. out
	end
	return if out == "" then "." else out
end

-- Joins segments with exactly one "/" between them, normalised. A later absolute segment is
-- appended like any other (this is string joining, not shell cd).
function PathUtil.join(...: string): string
	return PathUtil.normalize(table.concat({ ... }, "/"))
end

-- `path` relative to `base` (either may have a trailing "/", doubled slashes or "." segments);
-- nil when `path` is not strictly inside `base`.
function PathUtil.relativeTo(path: string, base: string): string?
	local p, b = PathUtil.normalize(path), PathUtil.normalize(base)
	if b == "/" then
		return if p ~= "/" and string.sub(p, 1, 1) == "/" then string.sub(p, 2) else nil
	end
	if string.sub(p, 1, #b + 1) == b .. "/" then
		return string.sub(p, #b + 2)
	end
	return nil
end

return PathUtil

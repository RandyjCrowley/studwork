--!strict
--[[
	Window: the speed check's sliding window as a fixed-capacity ring (no per-sample allocation).
	Each entry is one sample's horizontal segment: its start time, its length, its horizontal vector and
	whether it was measured relative to a platform or seat (then only the NET relative displacement counts)
	with the frame's speed (also set for the samples just after leaving a platform). `measure` = the path length of the non-platform entries + the length of the summed
	platform-relative vectors (carry.md, Movement "Checks", `speed`).
]]

export type Window = {
	cap: number,
	head: number, -- index of the oldest entry
	count: number,
	t0: { number },
	len: { number },
	vx: { number },
	vz: { number },
	plat: { boolean },
	ps: { number },
	pathSum: number,
	netX: number,
	netZ: number,
	platCount: number,
	speedCount: number, -- entries with a frame speed above zero
}

local Window = {}

function Window.new(capacity: number): Window
	local cap = math.max(8, math.floor(capacity))
	return {
		cap = cap,
		head = 1,
		count = 0,
		t0 = table.create(cap, 0),
		len = table.create(cap, 0),
		vx = table.create(cap, 0),
		vz = table.create(cap, 0),
		plat = table.create(cap, false),
		ps = table.create(cap, 0),
		pathSum = 0,
		netX = 0,
		netZ = 0,
		platCount = 0,
		speedCount = 0,
	}
end

function Window.clear(w: Window)
	w.head, w.count = 1, 0
	w.pathSum, w.netX, w.netZ, w.platCount, w.speedCount = 0, 0, 0, 0, 0
end

local function dropOldest(w: Window)
	local i = w.head
	if w.plat[i] then
		w.netX -= w.vx[i]
		w.netZ -= w.vz[i]
		w.platCount -= 1
	else
		w.pathSum -= w.len[i]
	end
	if w.ps[i] > 0 then
		w.speedCount -= 1
	end
	w.head = if i == w.cap then 1 else i + 1
	w.count -= 1
	if w.count == 0 then
		w.pathSum, w.netX, w.netZ, w.platCount, w.speedCount = 0, 0, 0, 0, 0 -- shed float drift
	end
end

function Window.push(
	w: Window,
	t0: number,
	len: number,
	vx: number,
	vz: number,
	onPlatform: boolean,
	platformSpeed: number
)
	if w.count == w.cap then
		dropOldest(w)
	end
	local i = w.head + w.count
	if i > w.cap then
		i -= w.cap
	end
	w.t0[i], w.len[i], w.vx[i], w.vz[i], w.plat[i], w.ps[i] = t0, len, vx, vz, onPlatform, platformSpeed
	w.count += 1
	if platformSpeed > 0 then
		w.speedCount += 1
	end
	if onPlatform then
		w.netX += vx
		w.netZ += vz
		w.platCount += 1
	else
		w.pathSum += len
	end
end

-- drop every entry that started before `minT0`
function Window.prune(w: Window, minT0: number)
	while w.count > 0 and w.t0[w.head] < minT0 do
		dropOldest(w)
	end
end

-- start time of the oldest entry (nil when empty)
function Window.oldestStart(w: Window): number?
	if w.count == 0 then
		return nil
	end
	return w.t0[w.head]
end

function Window.measure(w: Window): number
	return w.pathSum + math.sqrt(w.netX * w.netX + w.netZ * w.netZ)
end

-- the fastest frame (platform, or a platform just left) any entry was measured against
function Window.maxFrameSpeed(w: Window): number
	if w.speedCount == 0 then
		return 0
	end
	local best = 0
	local i = w.head
	for _ = 1, w.count do
		if w.ps[i] > best then
			best = w.ps[i]
		end
		i = if i == w.cap then 1 else i + 1
	end
	return best
end

return Window

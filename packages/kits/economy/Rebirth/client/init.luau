--!strict
--[[
	Rebirth client part (module-api.md §9; core-v1.3.1 R19: one folder per module, found by the client
	runtime as ReplicatedStorage.Modules.Rebirth.client). Client action:
	  StudWork.use(Rebirth).actions.rebirth(...)
	fires this module's own Blink event `Rebirth` (./net.blink -> generated ./Net.luau, bound by the
	runtime as the part's `net`).
]]

return {
	actions = {
		rebirth = true, -- the event `Rebirth` in ./Net.luau (generated from ../net.blink)
	},
}

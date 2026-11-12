--!strict
--[[
	Notifications client part (docs/framework/kits/notifications.md, "Client part").

	FOUNDATION SKELETON: declares the module's client actions (net.blink OptInShown, SetUtcOffset);
	the prompt itself (PromptOptIn -> Roblox's check and prompt through a small seam,
	`StudWork.use(Notifications).canPrompt()`) is the notifications builder's (B6).
]]

return {
	actions = { "optInShown", "setUtcOffset" },
	api = {},
}

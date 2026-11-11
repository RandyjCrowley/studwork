--!strict
-- Sandbox balance: every number the sandbox loop uses, as each kit module's config
-- (GameConfig.config.<Name>). The keys inside each module are the v1.2 `balance` keys.
-- Each module's config is merged over its defaults and checked against its schema at boot
-- (unknown keys are warnings). Commented lines show the other keys with their default values:
-- uncomment one to change it (docs/framework/override-levels.md level 2, kit pages for meanings).
local Balance = {}

return Balance

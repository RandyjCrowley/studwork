# The migrate prompt

Copy the block below into your coding agent (Claude Code, Codex, Cursor or any other).

1. Replace `<studwork>` with the path to your StudWork checkout and `<game>` with the path to your
   game (a Rojo repo, or a folder with your `.rbxl` / `.rbxlx` place file).
2. Make a copy or a git branch of your game first. The agent works on a branch, but a backup costs nothing.
3. When the agent finishes, read its report and do the cutover checklist yourself. The agent never
   publishes and never touches your live data.

```text
Here's StudWork at <studwork>. Here's my game at <game>. Migrate it to StudWork following
<studwork>/docs/agents/adopt-existing-game.md, step by step, from step 0 to step 11.

Rules:
- Work on a new git branch in my game's repo. Never push, merge or tag.
- Never publish to Roblox, never call Open Cloud, never read or write my live DataStores.
- Never write the old save store, and never edit the studwork/ submodule.
- Stop and ask me before installing anything outside the game folder, using sudo, or anything
  that costs money.
- Decide everything else yourself using the playbook's rules, and write down each decision.
- You're done when `tools/adopt --verify`, `tools/lint`, `tools/typecheck`, `tools/test`,
  `tools/test-migration` and `tools/build` all pass in my game. Then give me the report and the
  cutover checklist from step 11. Don't do the cutover.
```

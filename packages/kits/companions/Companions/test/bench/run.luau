--!nocheck
-- Run from the repository root: lune run packages/kits/companions/Companions/test/bench/run
local Harness = require("../../../../../../tools/lune/testkit/harness")
local passed, failed, failures =
	Harness.runSpec("packages/kits/companions/Companions/test/bench/Performance.spec.luau")
for _, failure in failures do
	print(failure)
end
print(string.format("%d passed, %d failed", passed, failed))
assert(failed == 0, "performance check failed")

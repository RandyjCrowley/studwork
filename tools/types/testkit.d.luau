-- Type declarations for the globals injected into *.spec.luau by packages/core/tests/harness.luau.
-- Loaded by tools/typecheck through `luau-lsp analyze --defs`.

type Matchers = {
	toBe: (expected: any) -> (),
	toEqual: (expected: any) -> (),
	toBeNear: (expected: number, epsilon: number?) -> (),
	toBeTruthy: () -> (),
	toBeFalsy: () -> (),
	toBeNil: () -> (),
	toBeGreaterThan: (n: number) -> (),
	toBeGreaterThanOrEqual: (n: number) -> (),
	toBeLessThan: (n: number) -> (),
	toBeLessThanOrEqual: (n: number) -> (),
	toContain: (item: any) -> (),
	toThrow: (substring: string?) -> (),
	never: Matchers,
}

declare function describe(name: string, fn: () -> ()): ()
declare function it(name: string, fn: () -> ()): ()
declare function expect(actual: any): Matchers
declare function beforeEach(fn: () -> ()): ()
declare function afterEach(fn: () -> ()): ()
declare Stubs: any

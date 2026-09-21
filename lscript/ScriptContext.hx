package lscript;

/**
 * The Haxe object behind the `script` table a Lua script sees: it holds what an unknown global falls
 * back to.
 *
 * `script.parent` is a plain field of this object, and a Lua read or write of `script.parent` is
 * reflected onto it by the metatable the library attaches to every value it hands to Lua.
 *
 * A class is used instead of an anonymous structure on purpose: Haxe/cpp anonymous structures have a
 * fixed shape, so assigning `parent` to one that was created without that field raises "Invalid
 * field" instead of storing the value.
 *
 * `script.import` is *not* read from here: `import` is a Haxe keyword and cannot be a field name. It is
 * put into the `script` table itself as a regular Lua field (see `LScript.createScriptTable`), which
 * also means reading it never goes through the metatable at all.
 */
class ScriptContext
{
	/** What the unknown-global fallback reads from and writes to. */
	public var parent:Dynamic;

	/** The same function `script.import` resolves to, for Haxe callers. */
	public var importFunction:Dynamic;

	public function new(importFunction:Dynamic)
	{
		this.importFunction = importFunction;
		parent = null;
	}
}

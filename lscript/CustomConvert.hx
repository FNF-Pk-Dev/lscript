package lscript;

import lscript.ClassWorkarounds;
import lscript.LScript;

import llua.Lua;
import llua.LuaL;
import llua.State;
import llua.Macro.*;

import cpp.RawPointer;

/**
 * Conversion between Haxe values and Luau values.
 *
 * Values pushed to Lua are *handles*, not copies: a Haxe object becomes a table carrying
 * `__special_id` (the key under which the object lives in the owning script's `specialVars`) and
 * `__parent_id`, with `MetatableFunctions` answering every field read and write on it. That is what
 * keeps `game.health = 5` or `sprite:playAnim('idle')` working on live Haxe objects, and it is also
 * why `fromLua` gives the very same object back when Lua hands a table to Haxe again.
 *
 * ## Type constants
 *
 * Nothing here compares `Lua.type()` against the `Lua.LUA_T*` constants. Those constants are Haxe-side
 * copies of the `lua_Type` enumeration of the Luau *headers*, and the prebuilt VM this library links
 * against (`linc_luajit`'s `libLuau.VM`) numbers its types differently - measured on that VM:
 *
 * ```
 * 0 nil  1 boolean  2 userdata  3 number  4 integer  5 vector  6 string  7 table  8 function  9 userdata  10 thread
 * ```
 *
 * so `Lua.type()` of a *string* is 6, which equals `Lua.LUA_TTABLE` and made the old conversions read
 * strings as tables (and tables as functions) - the "script-set values come back as garbage" bug.
 * `Lua.typename()` is answered by the same VM that answers `Lua.type()`, so the two always agree;
 * every type test below goes through `typeName()`.
 */
@:allow(lscript.LScript)
@:allow(lscript.MetatableFunctions)
@:allow(lscript.ClassWorkarounds)
class CustomConvert
{
	/**
	 * How deep table conversion may recurse. A Lua table that contains itself (`t.self = t`) would
	 * otherwise convert forever and take the process down with a stack overflow.
	 */
	public static inline final MAX_DEPTH:Int = 48;

	/**
	 * How many table entries one conversion may produce across all its levels. A table whose
	 * sub-tables are shared instead of nested (`t = {a = t, b = t}` around an empty table, repeated)
	 * expands into 2^depth *distinct* Haxe objects even though it contains no cycle, which is enough to
	 * exhaust memory on a script that is otherwise perfectly valid.
	 */
	public static inline final MAX_NODES:Int = 100000;

	/** Current recursion depth of the table conversions. */
	static var depth:Int = 0;

	/** Tables converted by the current top level conversion, against `MAX_NODES`. */
	static var convertedNodes:Int = 0;

	/** Stack positions of the tables currently being converted, to detect tables that contain themselves. */
	static var conversionPath:Array<Int> = [];

	// ---------------------------------------------------------------------------------------------
	// Type helpers
	// ---------------------------------------------------------------------------------------------

	/**
	 * Name of the type of the value at `index`, as the VM itself names it.
	 * `index` must be a valid stack index - see `absoluteIndex`.
	 */
	public static inline function typeName(state:State, index:Int):String
		return Lua.typename(state, Lua.type(state, index));

	/** True when the value at `index` is of the VM type `name` (`"table"`, `"function"`, ...). */
	public static inline function isType(state:State, index:Int, name:String):Bool
		return typeName(state, index) == name;

	/** Numbers and integers are two VM types; both are numbers to Haxe. */
	public static inline function isNumberAt(state:State, index:Int):Bool
	{
		final name:String = typeName(state, index);
		return name == "number" || name == "integer";
	}

	/**
	 * Turns a possibly negative stack index into an absolute one.
	 *
	 * Relative indices have to be used with care: the conversions in here push and pop values while
	 * they walk a table, so a `-1` captured before the walk may point somewhere else afterwards -
	 * which is why the old `toHaxeObj()` used to walk the wrong table.
	 */
	public static inline function absoluteIndex(state:State, index:Int, ?top:Int):Int
	{
		if (index >= 0) return index;
		final height:Int = (top != null) ? top : Lua.gettop(state);
		return height + index + 1;
	}

	/**
	 * Grows the VM stack so that `count` more values can be pushed at the current nesting level.
	 *
	 * The VM only guarantees stack space it reserved itself: the API macros check pushes against
	 * `L->ci->top`, and a push beyond it trips an assertion instead of growing anything (in a build
	 * without `NDEBUG` that means `abort()`, i.e. the process disappears). Haxe runs on whatever frame
	 * the VM last entered, so the library asks for room itself - one call per nesting level, which is
	 * enough because each level reserves for its own children before recursing.
	 */
	public static inline function reserve(state:State, count:Int):Void
	{
		if (state != null) Lua.checkstack(state, count);
	}

	// ---------------------------------------------------------------------------------------------
	// Lua -> Haxe
	// ---------------------------------------------------------------------------------------------

	/**
	 * Converts the Lua value at `stackPos` to a Haxe value.
	 *
	 * @param stackPos      Position of the value (negative positions are relative to the stack top).
	 * @param specialIndex  When set, receives the `__special_id` of a value that was handed to Lua by
	 *                      this library (the id under which the Haxe object lives in `specialVars`).
	 * @param parentIndex   When set, receives the `__parent_id` of such a value, or -1.
	 * @param includeIndexes Whether to fill `specialIndex` / `parentIndex`.
	 */
	public static function fromLua(stackPos:Int, ?specialIndex:RawPointer<Int>, ?parentIndex:RawPointer<Int>, ?includeIndexes:Bool = false):Dynamic
	{
		final script:LScript = LScript.currentLua;
		if (script == null || script.luaState == null) return null;

		// A conversion that starts here is the outermost one, so the node budget starts over - nested
		// calls all see a depth above zero.
		if (depth == 0) convertedNodes = 0;

		final state:State = script.luaState;
		final top:Int = Lua.gettop(state);
		if (top < 1) return null;

		final index:Int = absoluteIndex(state, stackPos, top);
		if (index < 1 || index > top) return null;

		var value:Dynamic = null;
		try
		{
			value = switch (typeName(state, index))
			{
				case "nil": null;
				case "boolean": Lua.toboolean(state, index);
				case "number", "integer": Lua.tonumber(state, index);
				case "string": Lua.tostring(state, index);
				case "table": toHaxeObj(index);
				case "function": script.wrapLuaFunction(index);
				default: null; // userdata, thread, vector, buffer: nothing sensible to hand to Haxe
			}

			// A table this library pushed to Lua stands for a Haxe object: give the object itself back
			// instead of the copy of its fields that `toHaxeObj()` just built.
			if (value != null && isType(state, index, "table") && Reflect.hasField(value, "__special_id"))
			{
				final specialValue:Dynamic = Reflect.field(value, "__special_id");
				if (Std.isOfType(specialValue, Int) || Std.isOfType(specialValue, Float))
				{
					final id:Int = Std.int(cast specialValue);
					final parentValue:Dynamic = Reflect.field(value, "__parent_id");
					if (includeIndexes && specialIndex != null) specialIndex[0] = id;
					if (includeIndexes && parentIndex != null)
						parentIndex[0] = (Std.isOfType(parentValue, Int) || Std.isOfType(parentValue, Float)) ? Std.int(cast parentValue) : -1;
					if (script.specialVars.exists(id)) return script.specialVars.get(id);
					return null;
				}
			}
		}
		catch (e:Dynamic)
		{
			// Conversions must never throw into the VM: they run for every field read a script makes.
			return null;
		}
		return value;
	}

	/**
	 * Converts the Lua table at `i` to a Haxe value: an `Array` for a table with a 1-based run of
	 * integer keys, a `DynamicAccess` (anonymous object) for anything else, `{}` for an empty table.
	 *
	 * A table that contains itself - directly or through another table - converts to `null` at the
	 * point where it closes the loop. Without that check the walk is not just endless, it is
	 * exponential: every reference to an already-visited table used to be converted again, so a table
	 * with three self-references produces a tree with 3^`MAX_DEPTH` nodes and takes the process down
	 * with it.
	 */
	public static function toHaxeObj(i:Int):Any
	{
		final script:LScript = LScript.currentLua;
		if (script == null || script.luaState == null) return null;

		final state:State = script.luaState;
		final top:Int = Lua.gettop(state);
		final index:Int = absoluteIndex(state, i, top);
		if (index < 1 || index > top) return null;
		if (!isType(state, index, "table")) return null;
		if (depth >= MAX_DEPTH) return null;
		if (convertedNodes >= MAX_NODES) return null;
		convertedNodes++;

		// Every table on the way down here is still on the stack, so a cycle is a table equal to one
		// of its ancestors.
		try
		{
			for (ancestor in conversionPath)
			{
				if (Lua.rawequal(state, index, ancestor) != 0) return null;
			}
		}
		catch (e:Dynamic)
		{
			return null;
		}

		// This level holds a key and a value per walk, and recurses for nested tables.
		reserve(state, 8);
		depth++;
		conversionPath.push(index);

		var result:Any = null;
		try
		{
			result = buildHaxeObj(state, index);
		}
		catch (e:Dynamic)
		{
			result = null;
		}

		conversionPath.pop();
		finallyDepth();
		return result;
	}

	static function buildHaxeObj(state:State, index:Int):Any
	{
		var count:Int = 0;
		var array:Bool = true;

		loopTable(state, index, {
			count++;
			if (array)
			{
				if (!isNumberAt(state, -2)) array = false;
				else
				{
					final key:Float = Lua.tonumber(state, -2);
					if (key < 1 || Std.int(key) != key) array = false;
				}
			}
		});

		if (count == 0) return {};

		if (array)
		{
			final values:Array<Dynamic> = [];
			loopTable(state, index, {
				final position:Int = Std.int(Lua.tonumber(state, -2)) - 1;
				if (position >= 0) values[position] = fromLua(-1);
			});
			return values;
		}

		final values:haxe.DynamicAccess<Any> = {};
		loopTable(state, index, {
			if (isType(state, -2, "string")) values.set(Lua.tostring(state, -2), fromLua(-1));
			else if (isNumberAt(state, -2)) values.set(Std.string(Lua.tonumber(state, -2)), fromLua(-1));
		});
		return values;
	}

	/** Decrements `depth`; separate so every exit path of `toHaxeObj` shares it. */
	static inline function finallyDepth():Void
	{
		if (depth > 0) depth--;
	}

	// ---------------------------------------------------------------------------------------------
	// Haxe -> Lua
	// ---------------------------------------------------------------------------------------------

	/**
	 * Converts `val` into a Lua value and pushes it. Always pushes exactly one value, `nil` when the
	 * value cannot be represented or the conversion fails - a conversion call must never leave the
	 * stack unbalanced, because it usually runs from inside a Lua callback.
	 */
	public static function toLua(val:Any, ?parentIndex:Int = -1):Void
	{
		pushValue(val, parentIndex);
	}

	/**
	 * Same as `toLua()`, but reports whether a value was pushed at all.
	 * @return `true` when a state was available and exactly one value was pushed.
	 */
	@:noCompletion
	public static function pushValue(val:Any, ?parentIndex:Int = -1):Bool
	{
		final script:LScript = LScript.currentLua;
		if (script == null || script.luaState == null) return false;

		final state:State = script.luaState;
		final top:Int = Lua.gettop(state);
		try
		{
			pushAny(state, val, parentIndex);
			if (Lua.gettop(state) != top + 1)
			{
				Lua.settop(state, top);
				Lua.pushnil(state);
			}
			return true;
		}
		catch (e:Dynamic)
		{
			Lua.settop(state, top);
			Lua.pushnil(state);
			return true;
		}
	}

	static function pushAny(state:State, val:Any, parentIndex:Int):Void
	{
		switch (Type.typeof(val))
		{
			case TNull:
				Lua.pushnil(state);
			case TBool:
				Lua.pushboolean(state, cast val);
			case TInt:
				Lua.pushinteger(state, cast val);
			case TFloat:
				Lua.pushnumber(state, cast val);
			case TClass(String):
				final text:String = cast val;
				if (text == null) Lua.pushnil(state) else Lua.pushstring(state, text);
			case TClass(Array):
				pushArray(state, cast val, parentIndex);
			default:
				if (isMap(val)) pushMap(state, cast val)
				else addToMetatable(val, parentIndex);
		}
	}

	/** A Haxe array becomes a real Lua array (1-based copy) so `#`, `ipairs()` and indexing behave. */
	static function pushArray(state:State, values:Array<Dynamic>, parentIndex:Int):Void
	{
		if (depth >= MAX_DEPTH || values == null)
		{
			Lua.newtable(state);
			return;
		}

		reserve(state, 8);
		depth++;
		try
		{
			Lua.createtable(state, values.length, 0);
			for (i in 0...values.length)
			{
				Lua.pushinteger(state, i + 1);
				pushAny(state, values[i], parentIndex);
				Lua.settable(state, -3);
			}
		}
		finallyDepth();
	}

	/** A Haxe map becomes a real Lua table keyed by strings. */
	static function pushMap(state:State, values:Dynamic):Void
	{
		if (depth >= MAX_DEPTH || values == null)
		{
			Lua.newtable(state);
			return;
		}

		reserve(state, 8);
		depth++;
		try
		{
			var map:haxe.Constraints.IMap<Dynamic, Dynamic> = cast values;
			Lua.createtable(state, 0, 0);
			for (key => value in map)
			{
				Lua.pushstring(state, Std.string(key));
				pushAny(state, value, -1);
				Lua.settable(state, -3);
			}
		}
		finallyDepth();
	}

	static inline function isMap(val:Dynamic):Bool
	{
		try
		{
			return (val is haxe.Constraints.IMap);
		}
		catch (e:Dynamic)
		{
			return false;
		}
	}

	/**
	 * Pushes a Haxe object (or value) to Lua as a handle: a table carrying the id of `val` in the
	 * current script's `specialVars` plus the id of the Haxe object it was read from, both of which
	 * `MetatableFunctions` uses to reflect reads and writes back onto the Haxe side.
	 *
	 * @param parentIndex Id of the value this one is a member of, or -1.
	 * @return The absolute stack index of the pushed table, or -1 when there is no current script.
	 */
	public static function addToMetatable(val:Dynamic, parentIndex:Int):Int
	{
		final script:LScript = LScript.currentLua;
		if (script == null || script.luaState == null) return -1;

		final state:State = script.luaState;
		reserve(state, 8);

		final location:Int = script.nextSpecialVarId();
		script.specialVars.set(location, val);

		Lua.newtable(state);
		final tableIndex:Int = Lua.gettop(state);

		Lua.pushstring(state, "__parent_id");
		Lua.pushinteger(state, parentIndex);
		Lua.settable(state, tableIndex);

		Lua.pushstring(state, "__special_id");
		Lua.pushinteger(state, location);
		Lua.settable(state, tableIndex);

		script.attachScriptMetatable(tableIndex);
		return tableIndex;
	}
}

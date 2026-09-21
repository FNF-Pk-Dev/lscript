package lscript;

import lscript.CustomConvert;
import lscript.LScript;

import llua.Lua;
import llua.State;

import cpp.Callable;

/**
 * The functions the VM calls for the metatable this library gives to the values it hands to Lua.
 *
 * ## Contract
 *
 * Every entry point here can be reached *outside* a protected call - the VM answers a plain
 * `lua_getglobal()` with `__index` too - and an error raised from a C function at that point is a
 * Luau panic, i.e. the host process dies with no crash log. So, unconditionally:
 *
 * 1. The result is a value (`nil`, `0`, ...) - never a raised error. `LuaL.error` and friends are not
 *    used anywhere, and each entry point catches everything and answers its "not found" value.
 * 2. The owning script is resolved from the id in the closure's upvalue, not from the global
 *    `LScript.currentLua`: a callback running while another script is current, or after its own
 *    script was closed, used to dereference a stale or null script.
 * 3. The Haxe side is only ever touched through reflection helpers that swallow their own errors
 *    (`index()`, `writeTo()`), so a Haxe exception cannot escape into the VM.
 *
 * The four states a callback can find itself in are handled the same way: no owner -> `nil`/no-op,
 * owner but no Haxe object behind the table -> `nil`/no-op, object without the field -> `nil`, field
 * found -> the value (or, on a write, the field is set).
 */
class MetatableFunctions
{
	/** `__index` of the table standing for a Haxe value. */
	public static final callIndex:Callable<StatePointer->Int> = Callable.fromStaticFunction(_callIndex);
	/** `__newindex` of the table standing for a Haxe value. */
	public static final callNewIndex:Callable<StatePointer->Int> = Callable.fromStaticFunction(_callNewIndex);
	/** `__call` of the table standing for a Haxe value. */
	public static final callMetatableCall:Callable<StatePointer->Int> = Callable.fromStaticFunction(_callMetatableCall);
	/** `__len` of the table standing for a Haxe value. */
	public static final callLen:Callable<StatePointer->Int> = Callable.fromStaticFunction(_callLen);
	/** `__gc` of the table standing for a Haxe value. */
	public static final callGarbageCollect:Callable<StatePointer->Int> = Callable.fromStaticFunction(_callGarbageCollect);
	/** `__index` of a table standing for a Haxe enum. */
	public static final callEnumIndex:Callable<StatePointer->Int> = Callable.fromStaticFunction(_callEnumIndex);

	/** `__index` of the globals table: unknown globals are read from `script.parent`. */
	public static final callParentIndex:Callable<StatePointer->Int> = Callable.fromStaticFunction(_callParentIndex);
	/** `__newindex` of the globals table: unknown globals are written to `script.parent`. */
	public static final callParentNewIndex:Callable<StatePointer->Int> = Callable.fromStaticFunction(_callParentNewIndex);
	/** `__index` of the `global` table. */
	public static final callGlobalIndex:Callable<StatePointer->Int> = Callable.fromStaticFunction(_callGlobalIndex);
	/** `__newindex` of the `global` table. */
	public static final callGlobalNewIndex:Callable<StatePointer->Int> = Callable.fromStaticFunction(_callGlobalNewIndex);

	// ---------------------------------------------------------------------------------------------
	// Closure entry points
	// ---------------------------------------------------------------------------------------------

	static function _callIndex(state:StatePointer):Int
	{
		final l:State = cast state;
		final args:Int = Lua.gettop(l);
		try
		{
			final script:LScript = ownerOf(state);
			if (script == null) return pushNilResult(l, args);

			return script.enter(() ->
			{
				final object:Dynamic = specialVarOf(l, script, 1);
				final value:Dynamic = index(object, propertyAt(l, 2));
				return pushResult(l, value, args, specialIdOf(l, 1));
			});
		}
		catch (e:Dynamic)
		{
			return pushNilResult(l, args);
		}
	}

	static function _callNewIndex(state:StatePointer):Int
	{
		final l:State = cast state;
		final args:Int = Lua.gettop(l);
		if (args < 3) return 0;

		try
		{
			final script:LScript = ownerOf(state);
			if (script == null) return 0;

			return script.enter(() ->
			{
				final object:Dynamic = specialVarOf(l, script, 1);
				final property:Dynamic = propertyAt(l, 2);
				final value:Dynamic = CustomConvert.fromLua(3);

				if (!writeTo(object, property, value))
				{
					// The Haxe object cannot take the field - a value the script only ever held as a
					// handle, an array slot outside the array, a field its class does not declare.
					// Keep the value on the table itself so reading it back works.
					Lua.pushvalue(l, 2);
					Lua.pushvalue(l, 3);
					Lua.rawset(l, 1);
				}
				return 0;
			});
		}
		catch (e:Dynamic)
		{
			return 0;
		}
	}

	static function _callMetatableCall(state:StatePointer):Int
	{
		final l:State = cast state;
		final args:Int = Lua.gettop(l);
		try
		{
			final script:LScript = ownerOf(state);
			if (script == null || args < 1) return 0;

			return script.enter(() ->
			{
				final target:Dynamic = specialVarOf(l, script, 1);
				if (target == null || !Reflect.isFunction(target)) return 0;

				final params:Array<Dynamic> = [];
				for (i in 2...args + 1) params.push(CustomConvert.fromLua(i));

				// `obj:method(a)` is `obj.method(obj, a)`: Lua puts the object in as the first argument
				// itself. When that argument is the very object the function was read from, drop it and
				// call the Haxe function with the remaining arguments and that object as `this`.
				final owner:Dynamic = specialParentOf(l, script, 1);
				if (owner != null && params.length > 0 && params[0] == owner) params.shift();

				final result:Dynamic = script.callHaxeFunction(target, owner, params);
				if (result == null) return 0;

				Lua.settop(l, args);
				CustomConvert.pushValue(result, -1);
				if (Lua.gettop(l) <= args)
				{
					Lua.settop(l, args);
					return 0;
				}
				return 1;
			});
		}
		catch (e:Dynamic)
		{
			Lua.settop(l, args);
			return 0;
		}
	}

	static function _callLen(state:StatePointer):Int
	{
		final l:State = cast state;
		final args:Int = Lua.gettop(l);
		try
		{
			final script:LScript = ownerOf(state);
			if (script == null) return pushLength(l, args, 0);

			return script.enter(() ->
			{
				final object:Dynamic = specialVarOf(l, script, 1);
				return pushLength(l, args, lengthOf(object));
			});
		}
		catch (e:Dynamic)
		{
			return pushLength(l, args, 0);
		}
	}

	/**
	 * `__gc` of the metatable given to values handed to Lua.
	 *
	 * The old version pushed the collected id back into `avalibableIndexes` of
	 * `LScript.currentLua` - which is null when the VM finalizes objects while a script is being torn
	 * down. Nothing here touches anything the VM owns beyond reading the id, so it cannot fail; on the
	 * Luau VM this library links against, tables are not finalized at all, so in practice it never runs.
	 */
	static function _callGarbageCollect(state:StatePointer):Int
	{
		try
		{
			final l:State = cast state;
			final script:LScript = ownerOf(state);
			if (script != null)
			{
				final args:Int = Lua.gettop(l);
				if (args >= 1) script.releaseSpecialVar(specialIdOf(l, 1));
			}
		}
		catch (e:Dynamic) {}
		return 0;
	}

	static function _callEnumIndex(state:StatePointer):Int
	{
		final l:State = cast state;
		final args:Int = Lua.gettop(l);
		try
		{
			final script:LScript = ownerOf(state);
			if (script == null) return pushNilResult(l, args);

			return script.enter(() ->
			{
				final enumObject:Dynamic = specialVarOf(l, script, 1);
				final name:String = keyNameAt(l, 2);
				if (enumObject == null || name == null) return pushNilResult(l, args);

				final params:Array<Dynamic> = [];
				for (i in 3...args + 1) params.push(CustomConvert.fromLua(i));

				final value:EnumValue = enumIndex(cast enumObject, name, params);
				return pushResult(l, value, args, specialIdOf(l, 1));
			});
		}
		catch (e:Dynamic)
		{
			return pushNilResult(l, args);
		}
	}

	static function _callParentIndex(state:StatePointer):Int
	{
		final l:State = cast state;
		final args:Int = Lua.gettop(l);
		try
		{
			final script:LScript = ownerOf(state);
			if (script == null) return pushNilResult(l, args);

			return script.enter(() ->
			{
				final parent:Dynamic = script.parentOrNull();
				final property:Dynamic = propertyAt(l, 2);
				final value:Dynamic = (parent != null && property != null) ? index(parent, property) : null;
				return pushResult(l, value, args, 0);
			});
		}
		catch (e:Dynamic)
		{
			return pushNilResult(l, args);
		}
	}

	static function _callParentNewIndex(state:StatePointer):Int
	{
		final l:State = cast state;
		final args:Int = Lua.gettop(l);
		if (args < 3) return 0;

		try
		{
			final script:LScript = ownerOf(state);
			if (script == null) return 0;

			return script.enter(() ->
			{
				final parent:Dynamic = script.parentOrNull();
				final property:Dynamic = propertyAt(l, 2);
				final value:Dynamic = CustomConvert.fromLua(3);

				// The parent takes the write when it has that field - which is what `script.parent`
				// exists for. When it cannot (no parent, or a class without that field), the write
				// becomes a real global: the old code let the reflection fail, and `Reflect` throwing
				// from a C callback that ran unprotected is a panic.
				if (!writeTo(parent, property, value))
				{
					final name:String = (property != null) ? Std.string(property) : null;
					if (name != null) script.setGlobalFromStack(name, 3);
				}
				return 0;
			});
		}
		catch (e:Dynamic)
		{
			return 0;
		}
	}

	static function _callGlobalIndex(state:StatePointer):Int
	{
		final l:State = cast state;
		final args:Int = Lua.gettop(l);
		try
		{
			final script:LScript = ownerOf(state);
			if (script == null) return pushNilResult(l, args);

			return script.enter(() ->
			{
				final key:String = keyNameAt(l, 2);
				final value:Dynamic = (key != null && LScript.GlobalVars.exists(key)) ? LScript.GlobalVars.get(key) : null;
				return pushResult(l, value, args, -1);
			});
		}
		catch (e:Dynamic)
		{
			return pushNilResult(l, args);
		}
	}

	static function _callGlobalNewIndex(state:StatePointer):Int
	{
		final l:State = cast state;
		final args:Int = Lua.gettop(l);
		if (args < 3) return 0;

		try
		{
			final script:LScript = ownerOf(state);
			if (script == null) return 0;

			return script.enter(() ->
			{
				final key:String = keyNameAt(l, 2);
				if (key != null)
				{
					try LScript.GlobalVars.set(key, CustomConvert.fromLua(3)) catch (e:Dynamic) {}
				}
				return 0;
			});
		}
		catch (e:Dynamic)
		{
			return 0;
		}
	}

	/** `__index` of the `global` table, as a plain function. */
	public static function globalIndex(state:StatePointer):Int
		return _callGlobalIndex(state);

	/** `__newindex` of the `global` table, as a plain function. */
	public static function globalNewIndex(state:StatePointer):Int
		return _callGlobalNewIndex(state);

	// ---------------------------------------------------------------------------------------------
	// Haxe side reflection
	// ---------------------------------------------------------------------------------------------

	/**
	 * Reads `property` from `object`: an array element for a number, a field/getter for anything else.
	 * Never throws, returns `null` when there is nothing to read.
	 */
	public static function index(object:Dynamic, property:Any, ?uselessValue:Any):Dynamic
	{
		if (object == null || property == null) return null;

		try
		{
			if (Std.isOfType(property, Float) || Std.isOfType(property, Int))
			{
				final position:Int = Std.int(cast(property, Float));
				if (object is Array)
				{
					final values:Array<Dynamic> = cast object;
					// Lua arrays are 1-based, Haxe arrays are 0-based.
					final offset:Int = position - 1;
					return (offset >= 0 && offset < values.length) ? values[offset] : null;
				}
				return fieldOf(object, Std.string(position));
			}

			return fieldOf(object, Std.string(property));
		}
		catch (e:Dynamic)
		{
			return null;
		}
	}

	/**
	 * Writes `property` on `object`: an array element (or an append) for a number, a field for
	 * anything else. Kept for compatibility, it always returns `null` like it used to; use `writeTo()`
	 * when the outcome matters.
	 */
	public static function newIndex(object:Dynamic, property:Any, value:Dynamic):Dynamic
	{
		writeTo(object, property, value);
		return null;
	}

	/** @return `true` when the Haxe object took the write (see `newIndex`). */
	public static function writeTo(object:Dynamic, property:Any, value:Dynamic):Bool
	{
		if (object == null || property == null) return false;

		try
		{
			if (Std.isOfType(property, Float) || Std.isOfType(property, Int))
			{
				final offset:Int = Std.int(cast(property, Float)) - 1;
				if (object is Array)
				{
					final values:Array<Dynamic> = cast object;
					if (offset == values.length)
					{
						values.push(value);
						return true;
					}
					if (offset >= 0 && offset < values.length)
					{
						values[offset] = value;
						return true;
					}
					return false;
				}

				final name:String = Std.string(offset + 1);
				if (!hasFieldOf(object, name)) return false;
				Reflect.setProperty(object, name, value);
				return true;
			}

			final name:String = Std.string(property);
			if (!hasFieldOf(object, name)) return false;
			Reflect.setProperty(object, name, value);
			return true;
		}
		catch (e:Dynamic)
		{
			return false;
		}
	}

	/** Calls a Haxe function that Lua reached through a value it was given. */
	public static function metatableCall(func:Dynamic, object:Dynamic, ?params:Array<Any>):Dynamic
	{
		if (func == null || !Reflect.isFunction(func)) return null;

		try
		{
			return Reflect.callMethod(object, func, (params != null && params.length > 0) ? params : []);
		}
		catch (e:Dynamic)
		{
			return null;
		}
	}

	/** Frees a special var id. Kept for compatibility; `LScript.releaseSpecialVar()` does the work. */
	public static function garbageCollect(index:Int):Void
	{
		final script:LScript = LScript.currentLua;
		if (script != null) script.releaseSpecialVar(index);
	}

	/** Creates a Haxe enum value out of a constructor name and its parameters. */
	public static function enumIndex(object:Enum<Dynamic>, value:String, ?params:Array<Any>):EnumValue
	{
		if (object == null || value == null) return null;

		try
		{
			return object.createByName(value, (params != null && params.length > 0) ? params : []);
		}
		catch (e:Dynamic)
		{
			return null;
		}
	}

	/** Reads a field or property, preferring accessors and falling back to the raw field. */
	static function fieldOf(object:Dynamic, name:String):Dynamic
	{
		if (name == null) return null;

		var value:Dynamic = null;
		try value = Reflect.getProperty(object, name) catch (e:Dynamic) value = null;
		if (value != null) return value;
		try value = Reflect.field(object, name) catch (e:Dynamic) value = null;
		return value;
	}

	static function hasFieldOf(object:Dynamic, name:String):Bool
	{
		try
		{
			if (Reflect.hasField(object, name)) return true;
		}
		catch (e:Dynamic) {}

		// Fields that exist only as a getter/setter pair are not reported by `Reflect.hasField` on
		// every target: accept anything `Reflect.field` knows about as well.
		try
		{
			return Reflect.field(object, name) != null;
		}
		catch (e:Dynamic)
		{
			return false;
		}
	}

	/** Length of a value handed to Lua, for `#value`. */
	static function lengthOf(object:Dynamic):Int
	{
		try
		{
			if (object == null) return 0;
			if (object is Array) return (cast object : Array<Dynamic>).length;

			final value:Dynamic = fieldOf(object, "length");
			if (Std.isOfType(value, Int)) return cast value;
			if (Std.isOfType(value, Float)) return Std.int(cast value);
			return 0;
		}
		catch (e:Dynamic)
		{
			return 0;
		}
	}

	// ---------------------------------------------------------------------------------------------
	// Stack helpers
	// ---------------------------------------------------------------------------------------------

	/**
	 * The script that owns the closure the VM entered, resolved from the id in its first upvalue.
	 * @return `null` when the closure has no id, the script is gone, or resolution failed - callers
	 *         answer with their "not found" value in that case.
	 */
	static function ownerOf(state:StatePointer):LScript
	{
		try
		{
			final l:State = cast state;
			final id:Int = Lua.tointeger(l, Lua.upvalueindex(1));
			final script:LScript = LScript.liveScripts.get(id);
			if (script == null || script.closed || script.luaState == null) return null;
			return script;
		}
		catch (e:Dynamic)
		{
			return null;
		}
	}

	/** The Haxe object behind the table at `index`, using its `__special_id`. */
	static function specialVarOf(l:State, script:LScript, index:Int):Dynamic
	{
		if (!CustomConvert.isType(l, index, "table")) return null;

		Lua.pushstring(l, "__special_id");
		Lua.rawget(l, index);
		var object:Dynamic = null;
		if (CustomConvert.isNumberAt(l, -1))
		{
			final id:Int = Lua.tointeger(l, -1);
			if (script.specialVars.exists(id)) object = script.specialVars.get(id);
		}
		Lua.pop(l, 1);
		return object;
	}

	/** `__special_id` of the table at `index`, or -1. */
	static function specialIdOf(l:State, index:Int):Int
	{
		if (!CustomConvert.isType(l, index, "table")) return -1;

		Lua.pushstring(l, "__special_id");
		Lua.rawget(l, index);
		var id:Int = -1;
		if (CustomConvert.isNumberAt(l, -1)) id = Lua.tointeger(l, -1);
		Lua.pop(l, 1);
		return id;
	}

	/** The Haxe object the table at `index` was read from (`__parent_id`), if it is still known. */
	static function specialParentOf(l:State, script:LScript, index:Int):Dynamic
	{
		if (!CustomConvert.isType(l, index, "table")) return null;

		Lua.pushstring(l, "__parent_id");
		Lua.rawget(l, index);
		var object:Dynamic = null;
		if (CustomConvert.isNumberAt(l, -1))
		{
			final id:Int = Lua.tointeger(l, -1);
			if (id >= 0 && script.specialVars.exists(id)) object = script.specialVars.get(id);
		}
		Lua.pop(l, 1);
		return object;
	}

	/** The key at `index` as a Haxe value: a `String`, or a `Float` for Lua numbers. */
	static function propertyAt(l:State, index:Int):Dynamic
	{
		final name:String = CustomConvert.typeName(l, index);
		if (name == "string") return Lua.tostring(l, index);
		if (name == "number" || name == "integer") return Lua.tonumber(l, index);
		return null;
	}

	/** The key at `index` as a name, for the tables that are keyed by names only. */
	static function keyNameAt(l:State, index:Int):String
	{
		final name:String = CustomConvert.typeName(l, index);
		if (name == "string") return Lua.tostring(l, index);
		if (name == "number" || name == "integer") return Std.string(Lua.tonumber(l, index));
		return null;
	}

	/** Pushes `value` as the single result of the current callback. */
	static function pushResult(l:State, value:Dynamic, args:Int, parentId:Int):Int
	{
		Lua.settop(l, args);
		if (value == null)
		{
			Lua.pushnil(l);
			return 1;
		}

		CustomConvert.pushValue(value, parentId);
		if (Lua.gettop(l) <= args) Lua.pushnil(l);
		return 1;
	}

	/** Pushes `nil` as the single result of the current callback. */
	static function pushNilResult(l:State, args:Int):Int
	{
		Lua.settop(l, args);
		Lua.pushnil(l);
		return 1;
	}

	/** Pushes the length `#value` should report. */
	static function pushLength(l:State, args:Int, length:Int):Int
	{
		Lua.settop(l, args);
		Lua.pushinteger(l, length);
		return 1;
	}
}

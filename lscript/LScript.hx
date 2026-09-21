package lscript;

import lscript.ClassWorkarounds;
import lscript.CustomConvert;
import lscript.MetatableFunctions;
import lscript.ScriptContext;

import llua.Lua;
import llua.LuaL;
import llua.LuaOpen;
import llua.State;

import cpp.Callable;

/**
 * A Lua (Luau) script: one VM state per script, a body that defines callbacks, and a two way bridge
 * between Haxe values and Lua.
 *
 * Base code written by YoshiCrafter29 (https://github.com/YoshiCrafter29)
 * Fixed and tweaked by Srt (https://github.com/SrtHero278)
 *
 * ## What a script sees
 *
 * - `script.parent` - the Haxe object unknown globals are read from and written to.
 * - `script.import("my.package.MyClass")` - the same import as the `import` global in unsafe mode.
 * - `global.x` - variables shared between every script (see `GlobalVars`).
 * - Any Haxe object handed over with `setVar()`: field reads and writes, and calls through
 *   `object.method(...)`, are reflected onto the live Haxe object.
 *
 * ## Why this file looks defensive
 *
 * Every callback the VM runs on the library's behalf (the metatable functions in
 * `MetatableFunctions`) may be entered *outside* a protected call: the VM invokes `__index` for a
 * plain `lua_getglobal()` too, and an error raised there is a VM panic, which in Luau means the host
 * process aborts with no crash log. On top of that, this VM's type numbering does not match the
 * `Lua.LUA_T*` constants (see `CustomConvert.typeName`), so a type test done the obvious way used to
 * take the wrong conversion branch. The rules followed below:
 *
 * 1. Nothing the VM can reach throws: the metatable functions catch everything and answer `nil`.
 * 2. Nothing the VM can reach calls into a script that may already be gone: the closures carry the
 *    id of the script that owns them and resolve it through `liveScripts` on every call.
 * 3. Haxe never reads or writes a global through the metatable: `rawGetGlobal()` / `setVar()` go
 *    through the globals table held in the VM registry, so no Lua code runs for a global access.
 * 4. Every dispatch (`callFunc`) and the script body itself run inside `Lua.pcall`, so a runtime
 *    error ends up on the `functionError` / `parseError` handler instead of the process.
 */
@:allow(lscript.MetatableFunctions)
@:allow(lscript.CustomConvert)
@:allow(lscript.ClassWorkarounds)
@:allow(lscript.LuauScript)
class LScript
{
	/** The script whose Lua code is running right now; set around every entry into the VM. */
	public static var currentLua:LScript = null;

	/** Variables of the `global` table, shared by every script of the process. */
	public static var GlobalVars:Map<String, Dynamic> = new Map<String, Dynamic>();

	/**
	 * Every script that is still alive, keyed by the id baked into its Lua closures.
	 *
	 * The closures cannot hold the Haxe script object themselves (a VM upvalue can only hold a Lua
	 * value, and a raw pointer would dangle as soon as the GC moved the object), so they carry the id
	 * and look the script up here. `stop()` / `release()` remove the entry; while a script is in here
	 * it, and everything it exposed to Lua through `specialVars`, stays alive.
	 */
	static var liveScripts:Map<Int, LScript> = new Map<Int, LScript>();
	static var nextScriptId:Int = 1;

	// Keys the library uses inside the VM registry (a private table every state owns). The base is
	// arbitrary but non-zero so that the registry entries of this library cannot be confused with a
	// `1`, `2`, ... key another binding might use.
	static inline final REG_BASE:Int = 19539;
	static inline final REG_SCRIPT_META:Int = REG_BASE + 1;
	static inline final REG_ENUM_META:Int = REG_BASE + 2;
	static inline final REG_GLOBALS:Int = REG_BASE + 3;
	static inline final REG_FUNC_REFS:Int = REG_BASE + 4;

	static var callbacksInitialised:Bool = false;

	public var luaState:State;
	public var tracePrefix:String = "testScript: ";

	/** The Haxe object unknown globals of this script fall back to. See `script.parent`. */
	public var parent(get, set):Dynamic;

	/** The object behind the `script` table (fields: `import`, `parent`). */
	public var script(get, null):Dynamic;

	/** True when the script runs in full trust mode: every Luau library is opened, `import` works. */
	public var unsafe(default, null):Bool;

	/** Set once the script was stopped/released; every method becomes a no-op afterwards. */
	public var closed(default, null):Bool = false;

	/** Id of this script inside `liveScripts`. */
	public var id(default, null):Int;

	/**
	 * The map containing the special vars so lua can utilize them by getting the location used in the
	 * `__special_id` field.
	 */
	public var specialVars:Map<Int, Dynamic> = [-1 => null];

	/** Ids of special vars whose Lua handle was collected and which can be handed out again. */
	public var avalibableIndexes:Array<Int> = [];
	public var nextIndex:Int = 1;

	/** Owns the `script` table's fields. Also kept in `specialVars[0]`. */
	var context:ScriptContext;

	/** The script body, preprocessed. */
	var toParse:String;

	/** Whether the parent-fallback metatable was already installed on the globals table. */
	var globalFallbackInstalled:Bool = false;

	/** Key of the next Lua function stored for Haxe (see `wrapLuaFunction`). */
	var nextFunctionRef:Int = 1;

	public function new(code:String, ?unsafe:Bool = false)
	{
		this.unsafe = unsafe;
		id = nextScriptId++;
		liveScripts.set(id, this);

		if (!callbacksInitialised)
		{
			callbacksInitialised = true;
			// linc_luajit's callback layer stores a function pointer that is null until this runs, and
			// calls it when a script invokes a callback registered through `Lua_helper.add_callback`.
			Lua.init_callbacks();
		}

		luaState = LuaL.newstate();
		if (unsafe) LuaL.openlibs(luaState)
		else
		{
			LuaOpen.base(luaState);
			LuaOpen.math(luaState);
			LuaOpen.string(luaState);
			LuaOpen.table(luaState);
		}

		// The `luaopen_*` functions leave the library tables they return on the stack; their contents
		// are already registered in the globals, so drop them and start from a known stack height.
		Lua.settop(luaState, 0);

		context = new ScriptContext(unsafe ? ClassWorkarounds.importClass : ClassWorkarounds.importClassSafe);
		specialVars = [-1 => null, 0 => context];

		enterVoid(() ->
		{
			createMetatables();
			createScriptTable();
			createGlobalTable();
			pushGlobalsTable();
			Lua.settop(luaState, 0);
		});

		toParse = preprocessCode(code);
	}

	// ---------------------------------------------------------------------------------------------
	// VM setup
	// ---------------------------------------------------------------------------------------------

	/**
	 * Creates the metatable that is given to every value this library hands to Lua. Its callbacks are
	 * closures carrying this script's id, so a callback can always tell which script it belongs to.
	 */
	function createMetatables():Void
	{
		Lua.newtable(luaState);
		final metaIndex:Int = Lua.gettop(luaState);
		setCallback(metaIndex, "__index", MetatableFunctions.callIndex);
		setCallback(metaIndex, "__newindex", MetatableFunctions.callNewIndex);
		setCallback(metaIndex, "__call", MetatableFunctions.callMetatableCall);
		setCallback(metaIndex, "__len", MetatableFunctions.callLen);
		setCallback(metaIndex, "__gc", MetatableFunctions.callGarbageCollect);
		storeInRegistry(REG_SCRIPT_META, metaIndex);

		// Kept as a global for compatibility with scripts that referenced it directly.
		Lua.pushvalue(luaState, metaIndex);
		Lua.setglobal(luaState, "__scriptMetatable");
		Lua.settop(luaState, 0);

		Lua.newtable(luaState);
		final enumMetaIndex:Int = Lua.gettop(luaState);
		setCallback(enumMetaIndex, "__index", MetatableFunctions.callEnumIndex);
		storeInRegistry(REG_ENUM_META, enumMetaIndex);
		Lua.settop(luaState, 0);
	}

	/**
	 * The `script` table: a handle for `specialVars[0]` (the `context` object) that also carries the
	 * import function.
	 */
	function createScriptTable():Void
	{
		Lua.newtable(luaState);
		final tableIndex:Int = Lua.gettop(luaState);

		Lua.pushstring(luaState, "__special_id");
		Lua.pushinteger(luaState, 0);
		Lua.settable(luaState, tableIndex);

		// `import` cannot be a Haxe field (it is a keyword), so it lives in the table itself - which
		// also makes reading `script.import` a plain table lookup that never involves the metatable.
		Lua.pushstring(luaState, "import");
		CustomConvert.pushValue(context.importFunction, 0);
		Lua.settable(luaState, tableIndex);

		attachScriptMetatable(tableIndex);

		Lua.pushvalue(luaState, tableIndex);
		Lua.setglobal(luaState, "script");
		Lua.settop(luaState, 0);
	}

	/** The `global` table: a view of `GlobalVars` shared by every script. */
	function createGlobalTable():Void
	{
		Lua.newtable(luaState);
		final tableIndex:Int = Lua.gettop(luaState);

		Lua.newtable(luaState);
		final metaIndex:Int = Lua.gettop(luaState);
		setCallback(metaIndex, "__index", MetatableFunctions.callGlobalIndex);
		setCallback(metaIndex, "__newindex", MetatableFunctions.callGlobalNewIndex);
		Lua.setmetatable(luaState, tableIndex);

		Lua.pushvalue(luaState, tableIndex);
		Lua.setglobal(luaState, "global");
		Lua.settop(luaState, 0);
	}

	/** Puts `fn` into `tableIndex` under `name` as a closure with this script's id as its upvalue. */
	function setCallback(tableIndex:Int, name:String, fn:Callable<StatePointer->Int>):Void
	{
		Lua.pushstring(luaState, name);
		Lua.pushinteger(luaState, id);
		Lua.pushcclosure(luaState, fn, 1);
		Lua.settable(luaState, tableIndex);
	}

	/** Gives the table at `tableIndex` the metatable that reflects reads/writes onto the Haxe side. */
	function attachScriptMetatable(tableIndex:Int):Void
	{
		Lua.rawgeti(luaState, Lua.LUA_REGISTRYINDEX, REG_SCRIPT_META);
		Lua.setmetatable(luaState, tableIndex);
	}

	/** Gives the table at `tableIndex` the metatable that turns field reads into enum values. */
	function attachEnumMetatable(tableIndex:Int):Void
	{
		Lua.rawgeti(luaState, Lua.LUA_REGISTRYINDEX, REG_ENUM_META);
		Lua.setmetatable(luaState, tableIndex);
	}

	function storeInRegistry(key:Int, valueIndex:Int):Void
	{
		Lua.pushvalue(luaState, valueIndex);
		Lua.rawseti(luaState, Lua.LUA_REGISTRYINDEX, key);
	}

	/**
	 * Pushes the table holding this state's globals, remembered in the registry the first time it was
	 * resolved (before any metatable existed on it), so that later accesses cannot run Lua code.
	 */
	function pushGlobalsTable():Bool
	{
		if (luaState == null) return false;

		Lua.rawgeti(luaState, Lua.LUA_REGISTRYINDEX, REG_GLOBALS);
		if (CustomConvert.isType(luaState, -1, "table")) return true;
		Lua.pop(luaState, 1);

		Lua.getglobal(luaState, "_G");
		if (CustomConvert.isType(luaState, -1, "table"))
		{
			storeInRegistry(REG_GLOBALS, -1);
			return true;
		}
		Lua.pop(luaState, 1);
		return false;
	}

	// ---------------------------------------------------------------------------------------------
	// Running the script
	// ---------------------------------------------------------------------------------------------

	/** Loads and runs the script body, then installs the parent fallback for unknown globals. */
	public function execute():Void
	{
		if (closed || luaState == null || toParse == null) return;

		enterVoid(() ->
		{
			final base:Int = mark();
			try
			{
				restore(base);
				CustomConvert.reserve(luaState, 8);

				if (LuaL.luau_loadsource(luaState, "script", toParse) != Lua.LUA_OK)
				{
					reportParseError(errorText());
					restore(base);
					return;
				}

				if (Lua.pcall(luaState, 0, 0, 0) != Lua.LUA_OK)
				{
					reportParseError(errorText());
					restore(base);
					return;
				}

				restore(base);
				installGlobalFallback();
			}
			catch (e:Dynamic)
			{
				reportParseError(Std.string(e));
				restore(base);
			}
		});
	}

	/**
	 * Teaches the VM what to do with a global the script never defined: hand the access to
	 * `script.parent`.
	 *
	 * The old implementation appended
	 * `setmetatable(_G, { __index = function(...) __scriptMetatable.__index(script.parent, ...) end })`
	 * to the script source. That made the feature depend on the script's own globals (`script`,
	 * `__scriptMetatable`) surviving the body, ran a Lua closure - which can raise - from a C API
	 * global read, and broke any script ending in a top level `return` (Lua rejects statements after
	 * it). Installing the metatable from Haxe keeps the same behaviour at the same point in the
	 * script's life, with callbacks that cannot raise.
	 */
	function installGlobalFallback():Void
	{
		if (globalFallbackInstalled || closed || luaState == null) return;

		final base:Int = mark();
		restore(base);
		if (!pushGlobalsTable())
		{
			restore(base);
			return;
		}

		final globalsIndex:Int = Lua.gettop(luaState);

		Lua.newtable(luaState);
		final metaIndex:Int = Lua.gettop(luaState);
		setCallback(metaIndex, "__index", MetatableFunctions.callParentIndex);
		setCallback(metaIndex, "__newindex", MetatableFunctions.callParentNewIndex);
		Lua.setmetatable(luaState, globalsIndex);

		globalFallbackInstalled = true;
		restore(base);
	}

	/** Rewrites the `global <name> = ...` / `global <name>(...)` sugar scripts may use. */
	private function preprocessCode(code:String):String
	{
		if (code == null) return "";

		var processedCode:String = code;

		processedCode = ~/\bglobal\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*=/g.map(processedCode, function(e)
		{
			final varName:String = e.matched(1);
			return varName + " =";
		});

		processedCode = ~/\bglobal\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*\(/g.map(processedCode, function(e)
		{
			final varName:String = e.matched(1);
			return varName + " (";
		});

		return processedCode;
	}

	// ---------------------------------------------------------------------------------------------
	// Haxe -> script
	// ---------------------------------------------------------------------------------------------

	/** Reads a global. Never through the metatable, so no Lua code runs for this. */
	public function getVar(name:String):Dynamic
	{
		if (closed || luaState == null || name == null) return null;

		return enter(() ->
		{
			final base:Int = mark();
			try
			{
				restore(base);
				CustomConvert.reserve(luaState, 8);
				rawGetGlobal(name);
				final value:Dynamic = CustomConvert.fromLua(Lua.gettop(luaState));
				restore(base);
				if (value != null) return value;

				// Not a global: the script may have written the name through the parent fallback, in
				// which case the parent object holds it.
				final target:Dynamic = parentOrNull();
				if (target != null) return MetatableFunctions.index(target, name);
				return null;
			}
			catch (e:Dynamic)
			{
				restore(base);
				return null;
			}
		});
	}

	/** Sets a global. Writes into the globals table directly, so the fallback metatable is not used. */
	public function setVar(name:String, newValue:Dynamic):Void
	{
		if (closed || luaState == null || name == null) return;

		enterVoid(() ->
		{
			final base:Int = mark();
			try
			{
				restore(base);
				CustomConvert.reserve(luaState, 8);
				if (!CustomConvert.pushValue(newValue))
				{
					Lua.pushnil(luaState);
				}
				setGlobalFromStack(name, Lua.gettop(luaState));
			}
			catch (e:Dynamic)
			{
				reportFunctionError(name, Std.string(e));
			}
			restore(base);
		});
	}

	/** Sets the global `name` to the value on top of the stack. */
	function setGlobalFromStack(name:String, valueIndex:Int):Void
	{
		if (pushGlobalsTable())
		{
			final globalsIndex:Int = Lua.gettop(luaState);
			Lua.pushstring(luaState, name);
			Lua.pushvalue(luaState, valueIndex);
			Lua.rawset(luaState, globalsIndex);
			Lua.remove(luaState, globalsIndex);
			return;
		}

		Lua.pushvalue(luaState, valueIndex);
		Lua.setglobal(luaState, name);
	}

	/**
	 * Pushes the global `name`, i.e. the value of the globals table read without metatables. The
	 * pushed value is `nil` when the script never defined it.
	 */
	function rawGetGlobal(name:String):Void
	{
		if (pushGlobalsTable())
		{
			final globalsIndex:Int = Lua.gettop(luaState);
			Lua.pushstring(luaState, name);
			Lua.rawget(luaState, globalsIndex);
			Lua.remove(luaState, globalsIndex);
			return;
		}

		Lua.getglobal(luaState, name);
	}

	/**
	 * Sets a class as a global, under the name of the class itself.
	 */
	public function setClass(value:Class<Dynamic>):Void
	{
		if (value == null) return;
		final className:String = Type.getClassName(value);
		if (className == null) return;
		setVar(className.split(".").pop(), value);
	}

	// ---------------------------------------------------------------------------------------------
	// Calling into the script
	// ---------------------------------------------------------------------------------------------

	/**
	 * Calls the script's callback `name` with `params`.
	 *
	 * The function is looked up with `rawget`: a callback the script did not define is simply not
	 * there, and asking the VM for it must not run the fallback metatable (which is what used to abort
	 * the process). The call itself runs inside `Lua.pcall`, so a runtime error inside the callback
	 * lands on `functionError()` instead of ending the process.
	 *
	 * @return The callback's first return value, or `null` when it is missing, not a function, failed.
	 */
	public function callFunc(name:String, ?params:Array<Dynamic>):Dynamic
	{
		if (closed || luaState == null || name == null) return null;

		return enter(() ->
		{
			final base:Int = mark();
			try
			{
				restore(base);
				rawGetGlobal(name);

				if (!CustomConvert.isType(luaState, -1, "function"))
				{
					restore(base);
					return null;
				}

				var nparams:Int = 0;
				if (params != null && params.length > 0)
				{
					CustomConvert.reserve(luaState, params.length + 8);
					for (value in params)
					{
						CustomConvert.toLua(value);
						nparams++;
					}
				}

				if (Lua.pcall(luaState, nparams, 1, 0) != Lua.LUA_OK)
				{
					final error:String = errorText();
					reportFunctionError(name, error);
					restore(base);
					return null;
				}

				final result:Dynamic = CustomConvert.fromLua(Lua.gettop(luaState));
				restore(base);
				return result;
			}
			catch (e:Dynamic)
			{
				reportFunctionError(name, Std.string(e));
				restore(base);
				return null;
			}
		});
	}

	/** Alias of `callFunc()`. */
	public function call(name:String, ?args:Array<Dynamic>):Dynamic
		return callFunc(name, args);

	// ---------------------------------------------------------------------------------------------
	// Lua functions handed to Haxe
	// ---------------------------------------------------------------------------------------------

	/**
	 * Hands the Lua function at `index` to Haxe as a callable.
	 *
	 * The function is kept in a table held by the VM registry (never in the globals, where a script
	 * could see or overwrite it) and the returned closure calls it through `Lua.pcall`. The old code
	 * stored the *registry table* instead of the function - `Lua.pushvalue(state, -1)` after the table
	 * had been pushed - so every Lua function Haxe received was a table and every call of it failed.
	 */
	function wrapLuaFunction(index:Int):Dynamic
	{
		final absolute:Int = CustomConvert.absoluteIndex(luaState, index);
		final key:Int = nextFunctionRef++;
		CustomConvert.reserve(luaState, 8);

		pushFunctionRefs();
		Lua.pushinteger(luaState, key);
		Lua.pushvalue(luaState, absolute);
		Lua.rawset(luaState, -3);
		Lua.pop(luaState, 1);

		return Reflect.makeVarArgs((params:Array<Dynamic>) -> callStoredLuaFunction(key, params));
	}

	/** Pushes the table holding the Lua functions Haxe received; creates it on first use. */
	function pushFunctionRefs():Void
	{
		Lua.rawgeti(luaState, Lua.LUA_REGISTRYINDEX, REG_FUNC_REFS);
		if (CustomConvert.isType(luaState, -1, "table")) return;

		Lua.pop(luaState, 1);
		Lua.newtable(luaState);
		Lua.pushvalue(luaState, -1);
		Lua.rawseti(luaState, Lua.LUA_REGISTRYINDEX, REG_FUNC_REFS);
	}

	function callStoredLuaFunction(key:Int, params:Array<Dynamic>):Dynamic
	{
		if (closed || luaState == null) return null;

		return enter(() ->
		{
			final base:Int = mark();
			try
			{
				restore(base);
				pushFunctionRefs();
				Lua.pushinteger(luaState, key);
				Lua.rawget(luaState, -2);
				Lua.remove(luaState, -2);

				if (!CustomConvert.isType(luaState, -1, "function"))
				{
					restore(base);
					return null;
				}

				var nparams:Int = 0;
				if (params != null && params.length > 0)
				{
					CustomConvert.reserve(luaState, params.length + 8);
					for (value in params)
					{
						CustomConvert.toLua(value);
						nparams++;
					}
				}

				if (Lua.pcall(luaState, nparams, 1, 0) != Lua.LUA_OK)
				{
					final error:String = errorText();
					reportFunctionError("(lua function)", error);
					restore(base);
					return null;
				}

				final result:Dynamic = CustomConvert.fromLua(Lua.gettop(luaState));
				restore(base);
				return result;
			}
			catch (e:Dynamic)
			{
				restore(base);
				return null;
			}
		});
	}

	// ---------------------------------------------------------------------------------------------
	// Entry points used by MetatableFunctions
	// ---------------------------------------------------------------------------------------------

	/** Calls a Haxe function that Lua reached through a value it was given. */
	function callHaxeFunction(fn:Dynamic, owner:Dynamic, params:Array<Dynamic>):Dynamic
	{
		return enter(() ->
		{
			try
			{
				return Reflect.callMethod(owner, fn, params != null ? params : []);
			}
			catch (e:Dynamic)
			{
				reportFunctionError("(haxe call)", Std.string(e));
				return null;
			}
		});
	}

	/** `Type.createInstance()` for the class behind a value Lua treated as a class. */
	function instantiate(classValue:Class<Dynamic>, params:Array<Dynamic>):Dynamic
	{
		return enter(() ->
		{
			try
			{
				return Type.createInstance(classValue, params != null ? params : []);
			}
			catch (e:Dynamic)
			{
				reportFunctionError("new", Std.string(e));
				return null;
			}
		});
	}

	/** Creates a Haxe enum value from a name and constructor parameters. */
	function createEnumValue(enumObject:Dynamic, name:String, params:Array<Dynamic>):Dynamic
	{
		if (enumObject == null || name == null) return null;

		return enter(() ->
		{
			try
			{
				final enumType:Enum<Dynamic> = cast enumObject;
				return enumType.createByName(name, params != null ? params : []);
			}
			catch (e:Dynamic)
			{
				return null;
			}
		});
	}

	/** The `parent` of the `script` table, or `null` before one was set. */
	inline function parentOrNull():Dynamic
	{
		final current:ScriptContext = context;
		return (current != null) ? current.parent : null;
	}

	/** Stack height to come back to: see `restore()`. */
	function mark():Int
		return (luaState != null) ? Lua.gettop(luaState) : 0;

	/**
	 * Drops everything pushed above `mark`.
	 *
	 * The old code dropped *everything* (`lua_settop(state, 0)`) around every entry point. That is only
	 * equivalent while nothing below is in use - but Haxe can be called from inside a Lua frame (a
	 * callback a script invoked, which then calls into the library again), and clearing the stack to 0
	 * there wipes the frame the VM is about to return into.
	 */
	function restore(mark:Int):Void
	{
		if (luaState != null) Lua.settop(luaState, mark);
	}

	/** Runs `fn` with `currentLua` pointing at this script, restoring it afterwards. */
	function enter<T>(fn:Void->T):T
	{
		final last:LScript = currentLua;
		currentLua = this;
		try
		{
			final result:T = fn();
			currentLua = last;
			return result;
		}
		catch (e:Dynamic)
		{
			currentLua = last;
			throw e;
		}
	}

	/** `enter()` for calls that return nothing. */
	function enterVoid(fn:Void->Void):Void
	{
		final last:LScript = currentLua;
		currentLua = this;
		try
		{
			fn();
		}
		catch (e:Dynamic)
		{
			currentLua = last;
			throw e;
		}
		currentLua = last;
	}

	// ---------------------------------------------------------------------------------------------
	// Special vars
	// ---------------------------------------------------------------------------------------------

	/** Hands out the id of the next special var, reusing ids whose Lua handle was collected. */
	function nextSpecialVarId():Int
	{
		if (avalibableIndexes.length > 0) return avalibableIndexes.shift();

		final location:Int = nextIndex;
		nextIndex++;
		return location;
	}

	/** Frees a special var id (used by the `__gc` callback on builds that finalize tables). */
	function releaseSpecialVar(index:Int):Void
	{
		if (index <= 0 || !specialVars.exists(index)) return;

		specialVars.remove(index);
		if (!avalibableIndexes.contains(index)) avalibableIndexes.push(index);
	}

	// ---------------------------------------------------------------------------------------------
	// Messages
	// ---------------------------------------------------------------------------------------------

	/** Called when the script body could not be parsed or died while running. */
	public dynamic function parseError(err:String):Void
	{
		trace('${tracePrefix}Lua code was unable to be parsed.\n$err');
	}

	/** Called when a callback the script defines died, or a Lua side call failed. */
	public dynamic function functionError(func:String, err:String):Void
	{
		Sys.println('${tracePrefix}Function("$func") Error: $err');
	}

	/** Called for messages about the script. */
	public dynamic function print(line:Int, s:String):Void
	{
		Sys.println('${tracePrefix}:$line: $s');
	}

	/** Reports through the handlers without letting a throwing handler escape into the VM. */
	function reportParseError(err:String):Void
	{
		try parseError(err) catch (e:Dynamic) trace('${tracePrefix}Lua code was unable to be parsed.\n$err');
	}

	function reportFunctionError(func:String, err:String):Void
	{
		try functionError(func, err) catch (e:Dynamic) Sys.println('${tracePrefix}Function("$func") Error: $err');
	}

	/** Reports a plain message about the script (see `ClassWorkarounds.importClassSafe`). */
	function reportPrint(message:String):Void
	{
		try print(0, message) catch (e:Dynamic) Sys.println('${tracePrefix}:${message}');
	}

	/** Text of the error object on top of the stack; never throws, whatever the error object is. */
	function errorText():String
	{
		try
		{
			if (luaState == null || Lua.gettop(luaState) < 1) return "unknown error";

			return switch (CustomConvert.typeName(luaState, -1))
			{
				// Only a string is safe to read: linc's `tostring` helper builds a Haxe String from the
				// C pointer, and `lua_tostring` returns null for anything that is not a string.
				case "string":
					final text:String = Lua.tostring(luaState, -1);
					(text != null) ? text : "unknown error";
				case "number", "integer":
					Std.string(Lua.tonumber(luaState, -1));
				case "boolean":
					Std.string(Lua.toboolean(luaState, -1));
				default:
					'error object of type ${CustomConvert.typeName(luaState, -1)}';
			}
		}
		catch (e:Dynamic)
		{
			return "unknown error";
		}
	}

	// ---------------------------------------------------------------------------------------------
	// Lifecycle
	// ---------------------------------------------------------------------------------------------

	/**
	 * Closes the script: drops it from `liveScripts` (so its Lua closures stop resolving it and answer
	 * `nil`) and picks it, and every Haxe value it exposed, up for garbage collection.
	 *
	 * Use this instead of closing the state yourself: a state closed with `Lua.close(luaState)`
	 * directly cannot be noticed from here, and its entry in `liveScripts` (plus everything the script
	 * exposed to Lua) would stay alive for the rest of the process.
	 */
	public function stop():Void
	{
		if (closed) return;

		release();
		if (luaState != null) Lua.close(luaState);
		luaState = null;
	}

	/** Same as `stop()`, for callers that prefer that name. */
	public function close():Void
	{
		stop();
	}

	/**
	 * Marks the script closed without closing its Lua state: for callers that own the state and close
	 * it themselves (e.g. `Lua.close(myScript.luaState)`), which is the only way to release the
	 * library's entry for it.
	 */
	public function release():Void
	{
		if (closed) return;

		closed = true;
		liveScripts.remove(id);
		if (currentLua == this) currentLua = null;

		specialVars = [-1 => null];
		context = null;
		toParse = null;
	}

	// ---------------------------------------------------------------------------------------------
	// Properties and compatibility API
	// ---------------------------------------------------------------------------------------------

	inline function get_script():Dynamic
		return specialVars.get(0);

	inline function get_parent():Dynamic
		return parentOrNull();

	inline function set_parent(newParent:Dynamic):Dynamic
	{
		final current:ScriptContext = context;
		if (current != null) current.parent = newParent;
		return newParent;
	}

	/** `__index` of the `global` table. Kept for compatibility; the callback lives in `MetatableFunctions`. */
	public static function globalIndex(state:StatePointer):Int
		return MetatableFunctions.globalIndex(state);

	/** `__newindex` of the `global` table. Kept for compatibility. */
	public static function globalNewIndex(state:StatePointer):Int
		return MetatableFunctions.globalNewIndex(state);

	/**
	 * How many scripts are still registered with the library.
	 *
	 * A script is registered while it lives and unregistered by `stop()`/`close()`/`release()`; a host
	 * that closes a state behind the library's back is the only way for this to stay high.
	 */
	@:noCompletion
	public static function activeScriptCount():Int
	{
		var total:Int = 0;
		for (_ in liveScripts.keys()) total++;
		return total;
	}
}

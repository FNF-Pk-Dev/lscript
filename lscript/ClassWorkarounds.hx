package lscript;

import lscript.CustomConvert;
import lscript.LScript;

import llua.Lua;
import llua.State;

import cpp.Callable;

/**
 * Exposes Haxe classes and enums to a script.
 *
 * A class handed to Lua is a table with `MetatableFunctions` answering its reads, plus a `new` field,
 * so `MyClass:new(1, 2)` (i.e. `MyClass.new(MyClass, 1, 2)`) constructs an instance. An enum becomes a
 * table whose reads turn field names into enum values.
 *
 * Nothing in here calls `LuaL.error()`: these functions run from Lua, and an error raised from them
 * while the VM is not in a protected call is a panic. A failure (unknown path, constructor that
 * throws) is reported through the script's message channel and answers `nil` instead.
 */
class ClassWorkarounds
{
	/** The `new` callback put into the table of a class, i.e. what `MyClass:new(...)` calls. */
	public static final workaroundCallable:Callable<StatePointer->Int> = Callable.fromStaticFunction(instanceWorkAround);

	static function instanceWorkAround(state:StatePointer):Int
	{
		final l:State = cast state;
		final args:Int = Lua.gettop(l);
		try
		{
			final script:LScript = LScript.currentLua;
			if (script == null || args < 1) return 0;

			final classValue:Dynamic = CustomConvert.fromLua(1);
			if (classValue == null) return 0;

			final params:Array<Dynamic> = [];
			for (i in 2...args + 1) params.push(CustomConvert.fromLua(i));

			final created:Dynamic = script.instantiate(cast classValue, params);
			if (created == null) return 0;

			Lua.settop(l, args);
			CustomConvert.pushValue(created, -1);
			if (Lua.gettop(l) <= args)
			{
				Lua.settop(l, args);
				return 0;
			}
			return 1;
		}
		catch (e:Dynamic)
		{
			Lua.settop(l, args);
			return 0;
		}
	}

	/**
	 * Adds a class or enum as a global of the running script.
	 *
	 * @param path    The path of the class, e.g. `flixel.FlxSprite`.
	 * @param varName The name to set it to; the class' own name when omitted.
	 */
	public static function importClass(path:String, ?varName:String):Void
	{
		final script:LScript = LScript.currentLua;
		if (script == null || script.luaState == null || path == null) return;

		final state:State = script.luaState;
		final importedClass:Class<Dynamic> = Type.resolveClass(path);
		final importedEnum:Enum<Dynamic> = Type.resolveEnum(path);
		final trimmedName:String = (varName != null) ? varName : path.substr(path.lastIndexOf(".") + 1, path.length);

		// Relative to the height the state had when Lua called this: clearing the stack to 0 would wipe
		// the frame the VM is going to return into.
		final base:Int = script.mark();
		try
		{
			script.restore(base);

			if (importedClass != null)
			{
				final tableIndex:Int = CustomConvert.addToMetatable(importedClass, -1);
				if (tableIndex < 0) return;

				Lua.pushstring(state, "new");
				Lua.pushcfunction(state, workaroundCallable);
				Lua.rawset(state, tableIndex);
				script.setGlobalFromStack(trimmedName, tableIndex);
			}
			else if (importedEnum != null)
			{
				final tableIndex:Int = CustomConvert.addToMetatable(importedEnum, -1);
				if (tableIndex < 0) return;

				script.attachEnumMetatable(tableIndex);
				script.setGlobalFromStack(trimmedName, tableIndex);
			}
			else
			{
				script.reportPrint('Lua Import Error: Unable to find class from path "$path".');
			}
		}
		catch (e:Dynamic)
		{
			script.reportPrint('Lua Import Error: Unable to import "$path": ' + Std.string(e));
		}
		script.restore(base);
	}

	/**
	 * The `import` a script gets when it is created with `unsafe = false`: it refuses the import and
	 * reports it.
	 *
	 * This used to reach into the host game (`PlayState.instance.addTextToDebug`), which tied the
	 * library to one engine; the message now goes to the script's own message channel (`print`), so a
	 * host can route it wherever it wants.
	 */
	public static function importClassSafe(path:String, ?varName:String):Void
	{
		final message:String = 'Could not import class "$path" because this script is marked as safe.';
		final script:LScript = LScript.currentLua;
		if (script != null) script.reportPrint(message)
		else Sys.println(message);
	}
}

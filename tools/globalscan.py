"""List real global reads/writes in Lua files from luac bytecode listings.

Catches a call to a local function that is declared later in the file (Lua
resolves the name as a global, which is nil at run time), typos, and leaked
globals. Usage: python globalscan.py <luac.exe> <file.lua>...
"""
import re
import subprocess
import sys

KNOWN = set("""
_G _ENV _VERSION assert collectgarbage error getmetatable ipairs load next pairs pcall print rawequal rawget
rawlen rawset require select setmetatable tonumber tostring type xpcall dofile loadfile
string table math os io package debug utf8 coroutine
RegisterHook UnregisterHook FindAllOf FindFirstOf StaticFindObject StaticConstructObject LoadAsset FindObject FindObjects
NotifyOnNewObject ExecuteInGameThread ExecuteWithDelay ExecuteAsync LoopAsync LoopInGameThreadWithDelay
LoopInGameThreadAfterFrames ExecuteInGameThreadWithDelay ExecuteInGameThreadAfterFrames EngineTickAvailable
RegisterKeyBind IsKeyBindRegistered Key ModifierKey RegisterConsoleCommandHandler RegisterConsoleCommandGlobalHandler
RegisterLoadMapPreHook RegisterLoadMapPostHook RegisterInitGameStatePreHook RegisterInitGameStatePostHook
RegisterBeginPlayPreHook RegisterBeginPlayPostHook RegisterProcessConsoleExecPreHook RegisterProcessConsoleExecPostHook
RegisterCallFunctionByNameWithArgumentsPreHook RegisterCustomEvent UnregisterCustomEvent RegisterCustomProperty
FName FText FString UEHelpers CreateInvalidObject GetKismetSystemLibrary GetKismetMathLibrary IterateGameDirectories
DumpAllObjects GenerateSDK GenerateLuaTypes GenerateUHTCompatibleHeaders DumpStaticMeshes DumpAllActors
GetCurrentGameWorld ModRef EFindName PropertyTypes EObjectFlags EInternalObjectFlags print_r DumpUSMAP
""".split())

pat = re.compile(r'\b(GETTABUP|SETTABUP)\b.*?_ENV "([^"]+)"')


def scan(luac, path):
    out = subprocess.run([luac, "-l", "-l", "-p", path], capture_output=True, text=True, errors="replace")
    res = {}
    cur_line = None
    for line in out.stdout.splitlines():
        m = pat.search(line)
        if not m:
            continue
        op, name = m.groups()
        lm = re.search(r'\[(\d+)\]', line)
        ln = int(lm.group(1)) if lm else 0
        if op == "SETTABUP" or name not in KNOWN:
            res.setdefault((op, name), []).append(ln)
    return res


def main():
    luac, files = sys.argv[1], sys.argv[2:]
    bad = 0
    for f in files:
        for (op, name), lines in sorted(scan(luac, f).items()):
            kind = "WRITE" if op == "SETTABUP" else "read "
            print(f"{f}: global {kind} '{name}' at lines {sorted(set(lines))[:8]}")
            bad += 1
    print(f"{bad} suspicious global(s)")


if __name__ == "__main__":
    main()

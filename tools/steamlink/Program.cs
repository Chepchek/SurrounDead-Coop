// SDCoopSteamLink - Steam joining for SDCoop (SurrounDead co-op mod).
//
// The game keeps using plain UDP (IpNetDriver). This helper carries that UDP
// over Steam's peer-to-peer network (ISteamNetworkingSockets, Steam relays),
// so friends join through Steam with no IP, VPN or port forwarding:
//   host:   game :7777 <-> 127.0.0.1 socket per friend <-> Steam P2P <-> friend
//   client: game -> 127.0.0.1:<tunnel port> <-> Steam P2P <-> host
// It also publishes "Join Game" (rich presence), lists friends who host, and
// passes Steam's "Join Game" / invite clicks to the mod. Only Steam friends
// (and players the host invited) may connect.
//
// Started by the mod (sdc_steamlink.lua) once per game start, through
// cmd.exe: `SDCoopSteamLink.exe --launch ...` re-starts itself without the
// handles cmd.exe inherited from the game and returns at once. Exits when the
// game exits. Modes for checking: --selftest (UDP relay, IPC, no Steam) and
// --steamcheck (Steam init, SteamID, relay network, friends count, a local
// Steam socket pair).
//
// Build: tools\steamlink\build.ps1 (csc.exe of .NET Framework 4, C# 5).
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;

[assembly: AssemblyTitle("SDCoop Steam link")]
[assembly: AssemblyDescription("Carries SDCoop's game traffic over Steam peer-to-peer networking")]
[assembly: AssemblyProduct("SDCoop")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

namespace SDCoopSteamLink
{
    class Args
    {
        readonly Dictionary<string, string> values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        public readonly string[] Raw;

        public Args(string[] args)
        {
            Raw = args;
            for (int i = 0; i < args.Length; i++)
            {
                string a = args[i];
                if (!a.StartsWith("--", StringComparison.Ordinal)) continue;
                if (i + 1 < args.Length && !args[i + 1].StartsWith("--", StringComparison.Ordinal))
                {
                    values[a] = args[i + 1];
                    i++;
                }
                else
                {
                    values[a] = "";
                }
            }
        }

        public bool Has(string key) { return values.ContainsKey(key); }

        public string Get(string key, string def)
        {
            string v;
            return values.TryGetValue(key, out v) && v != "" ? v : def;
        }

        public int GetInt(string key, int def)
        {
            int v;
            return int.TryParse(Get(key, ""), NumberStyles.Integer, CultureInfo.InvariantCulture, out v) ? v : def;
        }
    }

    static class Program
    {
        static int Main(string[] argv)
        {
            Args args = new Args(argv);
            try
            {
                if (args.Has("--launch")) return Launch(argv);
                if (args.Has("--selftest") || args.Has("--steamcheck"))
                {
                    Win.AttachConsole(-1);   // a /target:winexe has no console of its own
                    Log.Echo = true;
                    int rc = args.Has("--selftest") ? Checks.SelfTest(args) : Checks.SteamCheck(args);
                    try { Console.Out.Flush(); } catch (Exception) { }
                    return rc;
                }
                return new App(args).Run();
            }
            catch (Exception e)
            {
                // never a crash dialog over the game
                Log.Warn("fatal: {0}", e);
                Log.Close();
                return 3;
            }
        }

        static string Quote(string a)
        {
            a = (a ?? "").Replace("\"", "");
            return (a.Length == 0 || a.IndexOfAny(new char[] { ' ', '\t' }) >= 0) ? "\"" + a + "\"" : a;
        }

        // Started by cmd.exe, which handed down every inheritable handle of the
        // game (sockets, files). Start the real helper without inheriting any,
        // tell it the game's process id when the parent chain shows it, and exit
        // right away so cmd.exe (and the game's os.execute) returns.
        static int Launch(string[] argv)
        {
            string exe = Assembly.GetExecutingAssembly().Location;
            int game = GameWatch.GameFromParents();
            StringBuilder cmd = new StringBuilder(Quote(exe));
            bool hasPid = false;
            foreach (string a in argv)
            {
                if (string.Equals(a, "--launch", StringComparison.OrdinalIgnoreCase)) continue;
                if (string.Equals(a, "--game-pid", StringComparison.OrdinalIgnoreCase)) hasPid = true;
                cmd.Append(' ').Append(Quote(a));
            }
            if (game > 0 && !hasPid) cmd.Append(" --game-pid ").Append(game.ToString(CultureInfo.InvariantCulture));
            STARTUPINFOW si = new STARTUPINFOW();
            si.cb = Marshal.SizeOf(typeof(STARTUPINFOW));
            PROCESS_INFORMATION pi;
            const uint CREATE_NEW_PROCESS_GROUP = 0x00000200;
            bool ok = Win.CreateProcessW(null, cmd, IntPtr.Zero, IntPtr.Zero, false, CREATE_NEW_PROCESS_GROUP,
                IntPtr.Zero, Path.GetDirectoryName(exe), ref si, out pi);
            if (!ok) return 1;
            Win.CloseHandle(pi.hThread);
            Win.CloseHandle(pi.hProcess);
            return 0;
        }
    }
}

// SDCoopSteamLink: which game process this helper belongs to, and whether it
// still runs. UE4SS Lua cannot read its own process id, so the helper finds
// the game itself: the parent chain at start (game -> cmd.exe -> helper), or
// else the newest SurrounDead-Win64-Shipping.exe whose image is the game next
// to this helper. The process list (Toolhelp) needs no access rights.
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace SDCoopSteamLink
{
    static class GameWatch
    {
        public const string GameExe = "SurrounDead-Win64-Shipping.exe";

        public struct Entry
        {
            public int Pid, Parent;
            public string Exe;
        }

        // ...\SurrounDead\Binaries\Win64 above `dir`, or null.
        public static string FindWin64(string dir)
        {
            try
            {
                DirectoryInfo d = new DirectoryInfo(dir);
                for (int i = 0; d != null && i < 10; i++, d = d.Parent)
                {
                    if (File.Exists(Path.Combine(d.FullName, GameExe))) return d.FullName;
                }
            }
            catch (Exception) { }
            return null;
        }

        public static Dictionary<int, Entry> Snapshot()
        {
            Dictionary<int, Entry> all = new Dictionary<int, Entry>();
            IntPtr snap = Win.CreateToolhelp32Snapshot(Win.TH32CS_SNAPPROCESS, 0);
            if (snap == Win.INVALID_HANDLE_VALUE || snap == IntPtr.Zero) return all;
            try
            {
                PROCESSENTRY32W e = new PROCESSENTRY32W();
                e.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32W));
                if (!Win.Process32FirstW(snap, ref e)) return all;
                do
                {
                    Entry x = new Entry();
                    x.Pid = (int)e.th32ProcessID;
                    x.Parent = (int)e.th32ParentProcessID;
                    x.Exe = e.szExeFile ?? "";
                    all[x.Pid] = x;
                    e.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32W));
                } while (Win.Process32NextW(snap, ref e));
            }
            finally
            {
                Win.CloseHandle(snap);
            }
            return all;
        }

        static bool IsGame(Entry e)
        {
            return string.Equals(e.Exe, GameExe, StringComparison.OrdinalIgnoreCase);
        }

        // The game among this process's ancestors (helper <- cmd.exe <- game), or 0.
        public static int GameFromParents()
        {
            Dictionary<int, Entry> all = Snapshot();
            int pid = Win.GetCurrentProcessId();
            for (int depth = 0; depth < 4; depth++)
            {
                Entry me;
                if (!all.TryGetValue(pid, out me)) return 0;
                Entry parent;
                if (!all.TryGetValue(me.Parent, out parent)) return 0;
                if (IsGame(parent)) return parent.Pid;
                pid = parent.Pid;
            }
            return 0;
        }

        public static string ImagePath(int pid)
        {
            IntPtr h = Win.OpenProcess(Win.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
            if (h == IntPtr.Zero) return null;
            try
            {
                StringBuilder sb = new StringBuilder(1024);
                int size = sb.Capacity;
                return Win.QueryFullProcessImageNameW(h, 0, sb, ref size) ? sb.ToString() : null;
            }
            finally
            {
                Win.CloseHandle(h);
            }
        }

        static long CreationTime(int pid)
        {
            IntPtr h = Win.OpenProcess(Win.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
            if (h == IntPtr.Zero) return 0;
            try
            {
                long c, e, k, u;
                return Win.GetProcessTimes(h, out c, out e, out k, out u) ? c : 0;
            }
            finally
            {
                Win.CloseHandle(h);
            }
        }

        // The newest running game whose image is `expectedExe` (any game when null).
        public static int FindGame(string expectedExe)
        {
            int best = 0;
            long bestTime = -1;
            foreach (Entry e in Snapshot().Values)
            {
                if (!IsGame(e)) continue;
                if (expectedExe != null)
                {
                    string img = ImagePath(e.Pid);
                    if (img != null && !string.Equals(Path.GetFullPath(img), Path.GetFullPath(expectedExe), StringComparison.OrdinalIgnoreCase)) continue;
                }
                long t = CreationTime(e.Pid);
                if (t > bestTime)
                {
                    bestTime = t;
                    best = e.Pid;
                }
            }
            return best;
        }

        public static bool IsAlive(int pid)
        {
            Entry e;
            return Snapshot().TryGetValue(pid, out e) && IsGame(e);
        }

        // Stable name for the one-helper-per-game mutex (FNV-1a of the path).
        public static string MutexName(string key)
        {
            uint h = 2166136261;
            foreach (char c in (key ?? "").ToLowerInvariant())
            {
                h ^= c;
                h *= 16777619;
            }
            return @"Local\SDCoopSteamLink_" + h.ToString("x8");
        }
    }
}

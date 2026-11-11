// SDCoopSteamLink: --selftest and --steamcheck.
//
// --selftest: no Steam. Two "game clients" talk to a "game server" (UDP
//   echo) through two client tunnels, an in-memory link and a host relay -
//   the same Relay code the helper runs; plus the file channel (Ipc).
// --steamcheck: Steam init with the game's steam_api64.dll, own SteamID,
//   relay network / authentication, friends counts (no names), a local Steam
//   socket pair (send / receive, poll group, struct offsets, callbacks) and
//   a P2P listen socket. Prints counts and IDs only, writes no files.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace SDCoopSteamLink
{
    static class Checks
    {
        static int checks, fails;

        static void Check(bool ok, string what)
        {
            checks++;
            if (!ok) fails++;
            Console.WriteLine((ok ? "  ok   " : "  FAIL ") + what);
        }

        static int Summary(string name)
        {
            Console.WriteLine(fails == 0
                ? string.Format("{0}: {1} checks, ALL OK", name, checks)
                : string.Format("{0}: {1} checks, {2} FAILED", name, checks, fails));
            return fails == 0 ? 0 : 1;
        }

        static Socket Udp()
        {
            Socket s = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
            s.Bind(new IPEndPoint(IPAddress.Loopback, 0));
            s.Blocking = false;
            return s;
        }

        static int Port(Socket s) { return ((IPEndPoint)s.LocalEndPoint).Port; }

        static byte[] Payload(byte client, int seq, int size)
        {
            byte[] b = new byte[size];
            for (int i = 0; i < size; i++) b[i] = (byte)(i * 7 + seq * 13 + client);
            b[0] = client;
            if (size > 1) b[1] = (byte)seq;
            return b;
        }

        // ------------------------------------------------------------------
        public static int SelfTest(Args args)
        {
            Console.WriteLine("SDCoopSteamLink " + App.Version + " selftest (no Steam)");
            Stopwatch sw = Stopwatch.StartNew();
            Func<long> now = delegate { return sw.ElapsedMilliseconds; };

            // --- relay: 2 clients -> tunnels -> memory link -> host relay -> game server
            MemoryLink hostL = new MemoryLink(), c1L = new MemoryLink(), c2L = new MemoryLink();
            hostL.Routes[1] = c1L;
            hostL.Routes[2] = c2L;
            c1L.Routes[1] = hostL;
            c2L.Routes[2] = hostL;
            Relay host = new Relay(hostL, now), r1 = new Relay(c1L, now), r2 = new Relay(c2L, now);
            Socket server = Udp(), g1 = Udp(), g2 = Udp();
            Peer h1 = host.AddHostPeer(1, 76561198000000010UL, Port(server));
            Peer h2 = host.AddHostPeer(2, 76561198000000020UL, Port(server));
            Peer t1 = r1.AddTunnel(1, 76561198000000090UL), t2 = r2.AddTunnel(2, 76561198000000090UL);
            Check(t1.LocalPort > 0 && t2.LocalPort > 0 && t1.LocalPort != t2.LocalPort, "tunnels got their own local ports");

            // a datagram from the link before the game spoke: dropped, no crash
            hostL.Send(1, new byte[] { 9, 9, 9 }, 3);
            r1.PumpLink();
            Check(t1.Dropped == 1 && t1.ToGamePkts == 0, "tunnel drops link data until the game's endpoint is known");

            int[] sizes = { 1, 16, 200, 512, 1024, 1200, 1400, 4000, 9000 };
            long sent1 = 0, sent2 = 0;
            for (int i = 0; i < sizes.Length; i++)
            {
                byte[] a = Payload(1, i, sizes[i]), b = Payload(2, i, sizes[i]);
                g1.SendTo(a, new IPEndPoint(IPAddress.Loopback, t1.LocalPort));
                g2.SendTo(b, new IPEndPoint(IPAddress.Loopback, t2.LocalPort));
                sent1 += a.Length;
                sent2 += b.Length;
            }
            HashSet<int> serverFrom = new HashSet<int>();
            Dictionary<int, int> got = new Dictionary<int, int>();
            int bad = 0, received = 0;
            byte[] buf = new byte[65536];
            while (sw.ElapsedMilliseconds < 4000 && received < sizes.Length * 2)
            {
                r1.PollGame(500);
                r2.PollGame(500);
                host.PumpLink();
                // game server: echo with the top bit of byte 0 set
                for (int k = 0; k < 64; k++)
                {
                    EndPoint from = new IPEndPoint(IPAddress.Any, 0);
                    int n;
                    try { n = server.ReceiveFrom(buf, ref from); } catch (SocketException) { break; }
                    serverFrom.Add(((IPEndPoint)from).Port);
                    buf[0] |= 0x80;
                    server.SendTo(buf, 0, n, SocketFlags.None, from);
                }
                host.PollGame(500);
                r1.PumpLink();
                r2.PumpLink();
                foreach (Socket g in new Socket[] { g1, g2 })
                {
                    for (int k = 0; k < 64; k++)
                    {
                        EndPoint from = new IPEndPoint(IPAddress.Any, 0);
                        int n;
                        try { n = g.ReceiveFrom(buf, ref from); } catch (SocketException) { break; }
                        received++;
                        byte client = (byte)(buf[0] & 0x7f);
                        int seq = n > 1 ? buf[1] : 0;
                        byte[] want = Payload(client, seq, n);
                        want[0] |= 0x80;
                        bool same = (g == g1 ? client == 1 : client == 2) && n == sizes[n > 1 ? seq : 0];
                        for (int j = 0; same && j < n; j++) if (buf[j] != want[j]) same = false;
                        if (!same) bad++;
                        int key = client * 1000 + seq;
                        int c;
                        got[key] = got.TryGetValue(key, out c) ? c + 1 : 1;
                    }
                }
            }
            Check(received == sizes.Length * 2, "every datagram came back through tunnel + link + host relay (" + received + "/" + sizes.Length * 2 + ")");
            Check(bad == 0, "payloads intact, each client got only its own replies");
            Check(got.Count == sizes.Length * 2, "no duplicates, nothing missing");
            Check(serverFrom.Count == 2 && serverFrom.Contains(h1.LocalPort) && serverFrom.Contains(h2.LocalPort),
                "the game server saw two different 127.0.0.1 clients (one per remote player)");
            Check(t1.Game != null && t1.Game.Port == Port(g1), "tunnel learned the game's endpoint");
            Check(t1.FromGameBytes == sent1 && t2.FromGameBytes == sent2, "tunnel byte counters (game -> link)");
            Check(h1.ToGameBytes == sent1 && h2.ToGameBytes == sent2, "host relay byte counters (link -> game)");
            Check(h1.FromGameBytes == sent1 && t1.ToGameBytes == sent1, "replies counted on both ends");

            host.Remove(1);
            Check(host.Count == 1 && host.Get(1) == null, "removing a peer closes only its socket");
            host.Clear();
            r1.Clear();
            r2.Clear();
            Check(host.Count == 0 && r1.Count == 0, "clear closes every socket");
            server.Close();
            g1.Close();
            g2.Close();

            // --- file channel
            string dir = Path.Combine(Path.GetTempPath(), "SDCoopSteamLink_selftest_" + Win.GetCurrentProcessId());
            Directory.CreateDirectory(dir);
            try
            {
                Ipc ipc = new Ipc(dir, "1700000000");
                // what the Lua side does: write .tmp, rename to a new name
                WriteCmd(dir, "cmd_1700000000_000002.txt", "join 76561198000000050 1700000000-1\n");
                WriteCmd(dir, "cmd_1700000000_000001.txt", "host 1 7777\n");
                WriteCmd(dir, "cmd_1600000000_000001.txt", "host 0\n");
                File.WriteAllText(Path.Combine(dir, "cmd_1700000000_000003.tmp"), "half written");
                List<string> cmds = ipc.TakeCommands();
                Check(cmds.Count == 2 && cmds[0] == "host 1 7777" && cmds[1].StartsWith("join 76561198000000050"),
                    "commands of this session in order; .tmp and other sessions ignored");
                Check(!File.Exists(Path.Combine(dir, "cmd_1700000000_000001.txt")), "taken commands are deleted");
                Check(File.Exists(Path.Combine(dir, "cmd_1600000000_000001.txt")), "another session's fresh command is left alone");
                Check(ipc.TakeCommands().Count == 0, "nothing twice");
                Check(ipc.Write("status.txt", "a=1\n") && ipc.Write("status.txt", "a=2\n")
                    && File.ReadAllText(Path.Combine(dir, "status.txt")) == "a=2\n", "status file replaced atomically");
                bool blocked;
                using (FileStream held = new FileStream(Path.Combine(dir, "status.txt"), FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                {
                    blocked = !ipc.Write("status.txt", "a=3\n");
                }
                Check(blocked && ipc.Write("status.txt", "a=4\n"), "replace fails while the mod reads, works right after");
                Check(Ipc.SessionOf("cmd_123_000001.txt") == "123" && Ipc.SessionOf("status.txt") == null, "command file names");
                Check(Ipc.Field("a\tb\nc") == "a b c", "names cannot break friends.txt lines");
                Dictionary<string, string> kv = Ipc.Pairs(Ipc.Split("config friends_only=0 allow=1,2 version=0.7.0"), 1);
                Check(kv["friends_only"] == "0" && kv["allow"] == "1,2" && kv["version"] == "0.7.0", "config pairs");
            }
            finally
            {
                try { Directory.Delete(dir, true); } catch (Exception) { }
            }

            // --- misc
            Check(GameWatch.MutexName(@"C:\A\b.exe") == GameWatch.MutexName(@"c:\a\B.EXE")
                && GameWatch.MutexName(@"C:\A\b.exe") != GameWatch.MutexName(@"D:\A\b.exe"), "one mutex per game install");
            Check(GameWatch.FindWin64(Path.GetTempPath()) == null, "no game folder above %TEMP%");
            Check(GameWatch.Snapshot().ContainsKey(Win.GetCurrentProcessId()), "process list sees this process");
            return Summary("selftest");
        }

        static void WriteCmd(string dir, string name, string text)
        {
            string tmp = Path.Combine(dir, name + ".tmp");
            File.WriteAllText(tmp, text);
            File.Move(tmp, Path.Combine(dir, name));
        }

        // ------------------------------------------------------------------
        public static int SteamCheck(Args args)
        {
            Console.WriteLine("SDCoopSteamLink " + App.Version + " steamcheck");
            string exeDir = AppDomain.CurrentDomain.BaseDirectory;
            string dll = SteamSession.FindDll(exeDir, args.Get("--steam-dll", null), args.Get("--game-root", null));
            Check(dll != null, "steam_api64.dll of the game found" + (dll != null ? " (" + new DirectoryInfo(Path.GetDirectoryName(dll)).Parent.Name + ")" : ""));
            if (dll == null) return Summary("steamcheck");
            SteamSession s = new SteamSession();
            uint appId = (uint)args.GetInt("--app-id", 1645820);
            Check(s.LoadDll(dll, appId), "steam_api64.dll loaded");
            bool init = s.Init(appId, exeDir);
            Check(init, "SteamAPI_Init" + (init ? "" : ": " + s.Error));
            if (!init) return Summary("steamcheck");
            try
            {
                Console.WriteLine("  own SteamID: " + s.Me + ", app id " + s.AppId + ", logged on " + s.LoggedOn());
                Check(s.Me > 76561197960265728UL && s.AppId == 1645820, "SteamID and app id");

                // callbacks seen while waiting (connection status changes recorded)
                List<int[]> statusCbs = new List<int[]>();
                int callbacks = 0;
                Action<int, IntPtr, int> handler = delegate(int id, IntPtr p, int size)
                {
                    callbacks++;
                    if (id == Steam.CbConnStatusChanged && size >= Steam.CbInfoOffset + Steam.InfoState + 4)
                        statusCbs.Add(new int[] { Marshal.ReadInt32(p, 0), Marshal.ReadInt32(p, Steam.CbInfoOffset + Steam.InfoState), size,
                            size >= Steam.CbOldState + 4 ? Marshal.ReadInt32(p, Steam.CbOldState) : -1 });
                };

                // relay network + authentication
                Stopwatch sw = Stopwatch.StartNew();
                int relay = 0, auth = 0, lastR = int.MinValue, lastA = int.MinValue;
                while (sw.ElapsedMilliseconds < 25000)
                {
                    s.RunCallbacks(handler);
                    relay = s.RelayStatus();
                    auth = s.AuthStatus();
                    if (relay != lastR || auth != lastA)
                    {
                        Console.WriteLine(string.Format("  {0,5} ms: relay network {1}, authentication {2}", sw.ElapsedMilliseconds, relay, auth));
                        lastR = relay;
                        lastA = auth;
                    }
                    if (relay == Steam.AvailabilityCurrent && auth == Steam.AvailabilityCurrent) break;
                    Thread.Sleep(50);
                }
                Check(relay == Steam.AvailabilityCurrent, "Steam relay network ready (100 = current)");
                Check(auth == Steam.AvailabilityCurrent, "networking certificate ready (100 = current)");

                // friends: counts only
                int n = Steam.SteamAPI_ISteamFriends_GetFriendCount(s.Friends, Steam.FriendFlagImmediate);
                int inGame = 0, hosting = 0;
                byte[] gi = new byte[32];
                for (int i = 0; i < n; i++)
                {
                    ulong id = Steam.SteamAPI_ISteamFriends_GetFriendByIndex(s.Friends, i, Steam.FriendFlagImmediate);
                    Array.Clear(gi, 0, gi.Length);
                    if (!Steam.SteamAPI_ISteamFriends_GetFriendGamePlayed(s.Friends, id, gi)) continue;
                    if ((BitConverter.ToUInt64(gi, 0) & 0xFFFFFF) != s.AppId) continue;
                    inGame++;
                    if (s.FriendPresence(id, "sdcoop") != "") hosting++;
                }
                Console.WriteLine("  friends: " + n + ", in SurrounDead now: " + inGame + ", hosting SDCoop: " + hosting);
                Check(n >= 0, "friends list readable");

                // local socket pair through the loopback network stack
                uint c1, c2;
                bool pair = Steam.SteamAPI_ISteamNetworkingSockets_CreateSocketPair(s.Sockets, out c1, out c2, true, IntPtr.Zero, IntPtr.Zero);
                Check(pair && c1 != 0 && c2 != 0, "CreateSocketPair (loopback)");
                if (pair)
                {
                    sw.Restart();
                    int ping, st1 = 0, st2 = 0;
                    while (sw.ElapsedMilliseconds < 5000)
                    {
                        s.RunCallbacks(handler);
                        st1 = s.ConnState(c1, out ping);
                        st2 = s.ConnState(c2, out ping);
                        if (st1 == Steam.StateConnected && st2 == Steam.StateConnected) break;
                        Thread.Sleep(20);
                    }
                    Check(st1 == Steam.StateConnected && st2 == Steam.StateConnected, "socket pair connected (real-time status)");
                    byte[] info = new byte[Steam.InfoSize];
                    bool gotInfo = Steam.SteamAPI_ISteamNetworkingSockets_GetConnectionInfo(s.Sockets, c1, info);
                    string desc = Steam.Utf8(info, Steam.InfoDescription, 128);
                    bool printable = desc.Length > 0;
                    foreach (char ch in desc) if (ch < 32 || ch > 126) printable = false;
                    Check(gotInfo && BitConverter.ToInt32(info, Steam.InfoState) == Steam.StateConnected,
                        "SteamNetConnectionInfo_t.m_eState at offset 176");
                    Check(printable, "SteamNetConnectionInfo_t.m_szConnectionDescription at offset 312 ('" + desc + "')");
                    Check(BitConverter.ToInt32(info, Steam.InfoEndReason) == 0, "m_eEndReason at 180 is 0 while connected");

                    // messages both ways, on the connection
                    int okMsgs = 0;
                    for (int i = 0; i < 3; i++)
                    {
                        byte[] a = Payload(1, i, 100 + i * 500), b = Payload(2, i, 1300 + i);
                        int ra = Steam.SteamAPI_ISteamNetworkingSockets_SendMessageToConnection(s.Sockets, c1, a, (uint)a.Length, Steam.SendUnreliableNoNagle, IntPtr.Zero);
                        int rb = Steam.SteamAPI_ISteamNetworkingSockets_SendMessageToConnection(s.Sockets, c2, b, (uint)b.Length, Steam.SendUnreliableNoNagle, IntPtr.Zero);
                        if (ra == Steam.ResultOK && rb == Steam.ResultOK) okMsgs++;
                    }
                    Check(okMsgs == 3, "SendMessageToConnection (unreliable, no Nagle)");
                    int on2 = ReceiveCount(s, c2, 3, false), on1 = ReceiveCount(s, c1, 3, false);
                    Check(on2 == 3 && on1 == 3, "messages received both ways with intact payloads (" + on2 + ", " + on1 + ")");

                    // the poll group path the helper uses
                    Steam.SteamAPI_ISteamNetworkingSockets_SetConnectionPollGroup(s.Sockets, c2, s.PollGroup);
                    byte[] m = Payload(1, 7, 1024);
                    Steam.SteamAPI_ISteamNetworkingSockets_SendMessageToConnection(s.Sockets, c1, m, (uint)m.Length, Steam.SendUnreliableNoNagle, IntPtr.Zero);
                    SteamLink link = new SteamLink(s);
                    int viaGroup = 0;
                    uint groupConn = 0;
                    sw.Restart();
                    while (viaGroup == 0 && sw.ElapsedMilliseconds < 3000)
                    {
                        link.Pump(delegate(uint conn, byte[] data, int len)
                        {
                            viaGroup++;
                            groupConn = conn;
                            if (len != 1024 || data[0] != 1 || data[1] != 7) viaGroup = -100;
                        });
                        Thread.Sleep(10);
                    }
                    Check(viaGroup == 1 && groupConn == c2, "ReceiveMessagesOnPollGroup: message with its connection handle");

                    Steam.SteamAPI_ISteamNetworkingSockets_CloseConnection(s.Sockets, c1, 0, Steam.Z("check done"), false);
                    Steam.SteamAPI_ISteamNetworkingSockets_CloseConnection(s.Sockets, c2, 0, Steam.Z("check done"), false);
                    s.RunCallbacks(handler);
                    int matched = 0;
                    foreach (int[] cb in statusCbs)
                    {
                        // a socket pair starts connected, so its only callbacks are our own closes:
                        // state None (0) with the old state Connected; any real transition counts too
                        if (((uint)cb[0] == c1 || (uint)cb[0] == c2) && cb[2] == 712
                            && cb[1] >= Steam.StateNone && cb[1] <= Steam.StateProblemLocally
                            && cb[3] >= Steam.StateNone && cb[3] <= Steam.StateProblemLocally && cb[1] != cb[3]) matched++;
                    }
                    Console.WriteLine("  callbacks: " + callbacks + ", connection status callbacks: " + statusCbs.Count
                        + (statusCbs.Count > 0 ? " (size " + statusCbs[0][2] + ")" : ""));
                    foreach (int[] cb in statusCbs)
                        Console.WriteLine(string.Format("    status callback: {0}, state {1} -> {2}",
                            (uint)cb[0] == c1 ? "pair end 1" : (uint)cb[0] == c2 ? "pair end 2" : "unknown handle", cb[3], cb[1]));
                    Check(statusCbs.Count == 0 || matched == statusCbs.Count,
                        "connection status callbacks: handle at 0, state at 8+176, old state at 704 (" + matched + "/" + statusCbs.Count + ")");
                }

                uint ls = Steam.SteamAPI_ISteamNetworkingSockets_CreateListenSocketP2P(s.Sockets, 0, 0, IntPtr.Zero);
                Check(ls != 0, "CreateListenSocketP2P (virtual port 0)");
                if (ls != 0) Steam.SteamAPI_ISteamNetworkingSockets_CloseListenSocket(s.Sockets, ls);
            }
            finally
            {
                s.Shutdown();
            }
            return Summary("steamcheck");
        }

        static int ReceiveCount(SteamSession s, uint conn, int want, bool usePoll)
        {
            IntPtr[] msgs = new IntPtr[16];
            int got = 0;
            Stopwatch sw = Stopwatch.StartNew();
            while (got < want && sw.ElapsedMilliseconds < 3000)
            {
                int n = Steam.SteamAPI_ISteamNetworkingSockets_ReceiveMessagesOnConnection(s.Sockets, conn, msgs, msgs.Length);
                for (int i = 0; i < n; i++)
                {
                    IntPtr data = Marshal.ReadIntPtr(msgs[i], 0);
                    int size = Marshal.ReadInt32(msgs[i], 8);
                    uint c = (uint)Marshal.ReadInt32(msgs[i], 12);
                    byte[] b = new byte[size];
                    Marshal.Copy(data, b, 0, size);
                    byte[] w = Payload(b[0], b[1], size);
                    bool same = c == conn;
                    for (int j = 0; same && j < size; j++) if (b[j] != w[j]) same = false;
                    if (same) got++;
                    Steam.SteamAPI_SteamNetworkingMessage_t_Release(msgs[i]);
                }
                if (n <= 0) Thread.Sleep(10);
            }
            return got;
        }
    }
}

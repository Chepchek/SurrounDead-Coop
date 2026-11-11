// SDCoopSteamLink: the helper's main loop - hosting, joining, friends,
// status for the mod, lifetime.
//
// Commands from the mod (Ipc.cs):
//   host 1 <game port> | host 0      publish / stop hosting (listen socket, rich presence)
//   join <SteamID64> <request id>    build a tunnel to that host
//   leave                            close the tunnel
//   config friends_only=<0|1> allow=<id,id,...> version=<mod version>
//   invite <SteamID64>               Steam invite + allow that player
//   friends                          refresh the friends list now
//   quit
// status.txt (rewritten every second and on every change) and friends.txt
// carry everything back; see WriteStatus.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace SDCoopSteamLink
{
    class App
    {
        public const string Version = "1.0";
        const uint DefaultAppId = 1645820;
        const int VirtualPort = 0;
        const int MaxPeers = 8;
        const string ConnectPrefix = "+sdcoop_join ";
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

        readonly Args args;
        readonly Stopwatch clock = Stopwatch.StartNew();
        long Now() { return clock.ElapsedMilliseconds; }

        string exeDir, session, modVersion;
        Ipc ipc;
        readonly SteamSession steam = new SteamSession();
        SteamLink link;
        Relay relay;
        uint appId = DefaultAppId;
        int gamePid, gamePort = 7777;
        bool friendsOnly = true;
        readonly HashSet<ulong> allow = new HashSet<ulong>();

        // hosting
        bool hostWanted, listenWarned, presenceOn;
        uint listen;
        long presenceAt;
        int presenceSize = -1;

        // client tunnel
        string joinReq = "", joinState = "idle", joinReason = "";
        ulong joinHost;
        uint joinConn;
        int joinPort, joinCode;
        long joinAt;
        bool joinPending;   // waiting for Steam to come up

        // "Join Game" / invite clicks in Steam
        int inviteSeq;
        ulong inviteHost;

        // friends
        int friendsSeq, friendsTotal, friendsInGame, friendsHosting;
        string friendsText = "";
        bool friendsDirty = true, friendsWritePending;
        long friendsAt = -100000;
        readonly Dictionary<ulong, long> presenceAsked = new Dictionary<ulong, long>();

        // status / lifetime
        int statusSeq, initAttempts, lastRelay = int.MinValue, lastAuth = int.MinValue;
        bool statusDirty = true, quit, timerHigh;
        long statusAt = -100000, steamRetryAt;
        string quitReason = "";

        public App(Args a)
        {
            args = a;
        }

        static bool IsSteamId(ulong id)
        {
            // individual accounts, public universe: 0x0110000100000000 + account id
            return id > 76561197960265728UL && id < 76561202255233023UL;
        }

        static string S(ulong v) { return v.ToString(Inv); }
        static string S(long v) { return v.ToString(Inv); }
        static string S(int v) { return v.ToString(Inv); }

        public int Run()
        {
            exeDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\', '/');
            string ipcDir = args.Get("--ipc", exeDir);
            session = args.Get("--session", "");
            modVersion = args.Get("--mod-version", "?");
            gamePort = args.GetInt("--game-port", 7777);
            friendsOnly = args.Get("--friends-only", "1") != "0";
            ParseAllow(args.Get("--allow", ""));
            appId = (uint)args.GetInt("--app-id", (int)DefaultAppId);
            Log.Open(Path.Combine(ipcDir, "helper_log.txt"));
            Log.Info("SDCoopSteamLink {0} started (pid {1}), session {2}, mod {3}, game port {4}, friends only {5}",
                Version, Win.GetCurrentProcessId(), session, modVersion, gamePort, friendsOnly);

            string win64 = GameWatch.FindWin64(exeDir);
            string gameExe = win64 != null ? Path.Combine(win64, GameWatch.GameExe) : null;
            if (!FindGame(gameExe)) return 2;

            bool created;
            Mutex mutex = new Mutex(true, GameWatch.MutexName(gameExe ?? exeDir), out created);
            if (!created)
            {
                Log.Info("another helper already runs for this game install; exiting");
                Log.Close();
                return 0;
            }
            try
            {
                ipc = new Ipc(ipcDir, session);
                ipc.Delete("status.txt");
                ipc.Delete("friends.txt");
                link = new SteamLink(steam);
                relay = new Relay(link, Now);
                string dll = SteamSession.FindDll(exeDir, args.Get("--steam-dll", null), args.Get("--game-root", null));
                if (steam.LoadDll(dll, appId)) TryInitSteam();
                else Log.Warn("Steam: {0}", steam.Error);
                Loop();
            }
            catch (Exception e)
            {
                Log.Warn("helper error: {0}", e);
                quitReason = "error";
            }
            finally
            {
                Shutdown();
                try { mutex.ReleaseMutex(); } catch (Exception) { }
            }
            return 0;
        }

        bool FindGame(string gameExe)
        {
            if (args.Has("--no-game"))
            {
                // development: the full helper without a game, for two minutes
                gamePid = 0;
                Log.Info("--no-game: running without a game process for 2 minutes");
                return true;
            }
            gamePid = args.GetInt("--game-pid", 0);
            if (gamePid > 0 && !GameWatch.IsAlive(gamePid))
            {
                Log.Warn("game process {0} from the command line is not running", gamePid);
                gamePid = 0;
            }
            string how = "command line";
            if (gamePid == 0)
            {
                gamePid = GameWatch.GameFromParents();
                how = "parent chain";
            }
            for (int i = 0; gamePid == 0 && i < 30; i++)
            {
                gamePid = GameWatch.FindGame(gameExe);
                how = "process list";
                if (gamePid == 0) Thread.Sleep(1000);
            }
            if (gamePid == 0)
            {
                Log.Warn("no running {0} found{1}; exiting", GameWatch.GameExe, gameExe != null ? " for this install" : "");
                Log.Close();
                return false;
            }
            Log.Info("watching game process {0} (found by {1})", gamePid, how);
            return true;
        }

        void ParseAllow(string list)
        {
            allow.Clear();
            foreach (string p in (list ?? "").Split(new char[] { ',', ';', ' ' }, StringSplitOptions.RemoveEmptyEntries))
            {
                ulong id;
                if (ulong.TryParse(p, NumberStyles.Integer, Inv, out id) && IsSteamId(id)) allow.Add(id);
            }
        }

        void TryInitSteam()
        {
            initAttempts++;
            if (steam.Init(appId, exeDir))
            {
                if (steam.AppId != 0) appId = steam.AppId;
                Log.Info("Steam ok: own SteamID {0}, app {1}, logged on {2}; relay network access requested",
                    S(steam.Me), appId, steam.LoggedOn());
                statusDirty = true;
                ApplyHosting();
                if (joinPending)
                {
                    joinPending = false;
                    StartJoin(joinHost, joinReq);
                }
                return;
            }
            steamRetryAt = Now() + 20000;
            Log.Warn("Steam: {0} (attempt {1}{2})", steam.Error, initAttempts, initAttempts < 30 ? ", retrying in 20 s" : ", giving up");
            if (joinPending)
            {
                joinPending = false;
                FailJoin("no_steam", 0);
            }
            statusDirty = true;
        }

        void SetTimer(bool high)
        {
            if (high == timerHigh) return;
            timerHigh = high;
            try
            {
                if (high) Win.timeBeginPeriod(1);
                else Win.timeEndPeriod(1);
            }
            catch (Exception) { }
        }

        void Loop()
        {
            long nextCb = 0, nextIpc = 0, nextSec = 0;
            while (!quit)
            {
                bool active = relay.Count > 0;
                // 1 ms waits need the 1 ms timer while datagrams flow
                SetTimer(active);
                if (active) relay.PollGame(1000);
                else Thread.Sleep(steam.Ok ? 10 : 50);
                if (steam.Ok) relay.PumpLink();
                long t = Now();
                if (t >= nextCb)
                {
                    nextCb = t + (active ? 5 : 25);
                    steam.RunCallbacks(OnCallback);
                }
                if (t >= nextIpc)
                {
                    nextIpc = t + 200;
                    foreach (string line in ipc.TakeCommands()) Command(line);
                }
                if (t >= nextSec)
                {
                    nextSec = t + 1000;
                    EverySecond(t);
                }
                if (friendsWritePending) WriteFriends();
                if ((statusDirty && t - statusAt >= 100) || t - statusAt >= 1000) WriteStatus(t);
            }
        }

        void EverySecond(long t)
        {
            if (gamePid > 0 && !GameWatch.IsAlive(gamePid))
            {
                quit = true;
                quitReason = "the game closed";
                return;
            }
            if (gamePid == 0 && t > 120000)
            {
                quit = true;
                quitReason = "--no-game test run over";
                return;
            }
            if (!steam.Ok && steam.State == "init_failed" && initAttempts < 30 && t >= steamRetryAt) TryInitSteam();
            if (!steam.Ok) return;
            int relayNow = steam.RelayStatus(), authNow = steam.AuthStatus();
            if (relayNow != lastRelay || authNow != lastAuth)
            {
                Log.Info("Steam network: relay {0}, authentication {1}", Availability(relayNow), Availability(authNow));
                lastRelay = relayNow;
                lastAuth = authNow;
                statusDirty = true;
            }
            ApplyHosting();
            if (joinState == "connecting" && joinConn != 0 && t - joinAt > 30000)
            {
                Log.Info("join {0}: no Steam connection to {1} after 30 s", joinReq, S(joinHost));
                steam.Close(joinConn, Steam.EndTimeout, "timeout");
                relay.Remove(joinConn);
                joinConn = 0;
                FailJoin("timeout", 0);
            }
            List<Peer> gone = new List<Peer>();
            foreach (Peer p in relay.All)
            {
                int ping;
                int st = steam.ConnState(p.Conn, out ping);
                p.Ping = ping;
                if (st == Steam.StateClosedByPeer || st == Steam.StateProblemLocally || st == Steam.StateNone)
                {
                    gone.Add(p);
                    continue;
                }
                bool idle = t - p.LastFromGame > 120000 && t - p.LastFromLink > 120000;
                if (idle && p.LinkUp)
                {
                    Log.Info("{0} {1}: no traffic for 2 minutes, closing", p.IsTunnel ? "tunnel to" : "peer", S(p.SteamId));
                    steam.Close(p.Conn, Steam.EndIdle, "idle");
                    gone.Add(p);
                    continue;
                }
                if (t - p.LastStats >= 60000)
                {
                    p.LastStats = t;
                    LogStats(p, "stats");
                }
            }
            foreach (Peer p in gone)
            {
                if (p.Conn == joinConn) OnTunnelClosed(Steam.StateClosedByPeer);
                else ClosePeer(p, "closed");
            }
            if (presenceOn && (t - presenceAt > 60000 || presenceSize != HostPeers() + 1)) SetPresence(true);
            if ((friendsDirty && t - friendsAt > 1500) || t - friendsAt > 5000) RefreshFriends(t);
        }

        static string Availability(int v)
        {
            switch (v)
            {
                case 100: return "current";
                case 3: return "attempting";
                case 2: return "waiting";
                case 1: return "never tried";
                case -10: return "retrying";
                case -100: return "previously";
                case -101: return "failed";
                case -102: return "cannot try";
                default: return "unknown (" + v + ")";
            }
        }

        void LogStats(Peer p, string what)
        {
            Log.Info("{0} {1} {2}: to game {3} pkts / {4} B, from game {5} pkts / {6} B, dropped {7}, ping {8} ms",
                p.IsTunnel ? "tunnel to" : "peer", S(p.SteamId), what, p.ToGamePkts, p.ToGameBytes, p.FromGamePkts,
                p.FromGameBytes, p.Dropped, p.Ping);
        }

        int HostPeers()
        {
            int n = 0;
            foreach (Peer p in relay.All) if (!p.IsTunnel) n++;
            return n;
        }

        // ------------------------------------------------------------------
        // Steam callbacks
        // ------------------------------------------------------------------

        void OnCallback(int id, IntPtr p, int size)
        {
            if (id == Steam.CbConnStatusChanged && size >= Steam.CbInfoOffset + Steam.InfoState + 4)
            {
                uint conn = (uint)Marshal.ReadInt32(p, 0);
                int state = Marshal.ReadInt32(p, Steam.CbInfoOffset + Steam.InfoState);
                // the live state (GetConnectionRealTimeStatus: m_eState at offset 0)
                // wins when there is one: it does not depend on the callback layout
                int ping;
                int live = steam.ConnState(conn, out ping);
                if (live >= Steam.StateConnecting && live <= Steam.StateProblemLocally) state = live;
                OnConnection(conn, state);
            }
            else if (id == Steam.CbRichPresenceJoin && size >= 8)
            {
                ulong friend = (ulong)Marshal.ReadInt64(p, 0);
                string connect = Steam.Utf8(new IntPtr(p.ToInt64() + 8), 256);
                ulong host = ParseConnect(connect);
                if (host == 0)
                {
                    Log.Info("Steam join request from friend {0} with a connect string of another mod; ignored", S(friend));
                    return;
                }
                inviteSeq++;
                inviteHost = host;
                statusDirty = true;
                Log.Info("Steam Join Game / invite accepted: host {0} (via friend {1}), request {2}", S(host), S(friend), inviteSeq);
            }
            else if (id == Steam.CbFriendRichPresence || id == Steam.CbPersonaState)
            {
                friendsDirty = true;
            }
            else if (id == Steam.CbRelayStatus)
            {
                statusDirty = true;
            }
        }

        static ulong ParseConnect(string s)
        {
            s = (s ?? "").Trim();
            int i = s.IndexOf(ConnectPrefix.Trim(), StringComparison.Ordinal);
            if (i < 0) return 0;
            string rest = s.Substring(i + ConnectPrefix.Trim().Length).Trim();
            int end = 0;
            while (end < rest.Length && char.IsDigit(rest[end])) end++;
            ulong id;
            return end > 0 && ulong.TryParse(rest.Substring(0, end), NumberStyles.Integer, Inv, out id) && IsSteamId(id) ? id : 0;
        }

        void OnConnection(uint conn, int state)
        {
            if (conn == 0) return;
            if (conn == joinConn)
            {
                if (state == Steam.StateConnected) OnTunnelUp();
                else if (state == Steam.StateClosedByPeer || state == Steam.StateProblemLocally) OnTunnelClosed(state);
                return;
            }
            Peer p = relay.Get(conn);
            if (p != null && !p.IsTunnel)
            {
                if (state == Steam.StateConnected && !p.LinkUp)
                {
                    p.LinkUp = true;
                    statusDirty = true;
                    Log.Info("peer {0} connected: relaying 127.0.0.1:{1} <-> game port {2}", S(p.SteamId), p.LocalPort, gamePort);
                }
                else if (state == Steam.StateClosedByPeer || state == Steam.StateProblemLocally)
                {
                    ClosePeer(p, state == Steam.StateClosedByPeer ? "closed by the player" : "connection problem");
                }
                return;
            }
            if (state == Steam.StateConnecting) OnIncoming(conn);
            else if (state == Steam.StateClosedByPeer || state == Steam.StateProblemLocally) steam.Close(conn, 0, "");
        }

        bool Allowed(ulong sid, out string why)
        {
            why = "friend";
            if (steam.IsFriend(sid)) return true;
            why = "invited";
            if (allow.Contains(sid)) return true;
            why = "anyone allowed";
            if (!friendsOnly) return true;
            why = "not a friend";
            return false;
        }

        void OnIncoming(uint conn)
        {
            int er;
            string ed;
            ulong sid = steam.Remote(conn, out er, out ed);
            string why = null;
            int code = 0;
            string kind;
            if (listen == 0)
            {
                why = "not hosting";
                code = Steam.EndNotHosting;
            }
            else if (!IsSteamId(sid))
            {
                why = "no Steam identity";
                code = Steam.EndNotFriend;
            }
            else if (!Allowed(sid, out kind))
            {
                why = kind;
                code = Steam.EndNotFriend;
            }
            else if (HostPeers() >= MaxPeers)
            {
                why = "server full";
                code = Steam.EndFull;
            }
            else
            {
                int r = Steam.SteamAPI_ISteamNetworkingSockets_AcceptConnection(steam.Sockets, conn);
                if (r != Steam.ResultOK)
                {
                    Log.Warn("incoming {0}: accept failed (result {1})", S(sid), r);
                    steam.Close(conn, 0, "accept failed");
                    return;
                }
                Steam.SteamAPI_ISteamNetworkingSockets_SetConnectionPollGroup(steam.Sockets, conn, steam.PollGroup);
                Peer p = relay.AddHostPeer(conn, sid, gamePort);
                statusDirty = true;
                Log.Info("incoming {0} accepted ({1}); local relay socket 127.0.0.1:{2}", S(sid), kind, p.LocalPort);
                return;
            }
            steam.Close(conn, code, why);
            Log.Info("incoming {0} rejected: {1}", S(sid), why);
        }

        void ClosePeer(Peer p, string why)
        {
            LogStats(p, "gone (" + why + ")");
            steam.Close(p.Conn, 0, "");
            relay.Remove(p.Conn);
            statusDirty = true;
        }

        // ------------------------------------------------------------------
        // Hosting
        // ------------------------------------------------------------------

        void ApplyHosting()
        {
            if (hostWanted && steam.Ok)
            {
                if (listen == 0)
                {
                    listen = Steam.SteamAPI_ISteamNetworkingSockets_CreateListenSocketP2P(steam.Sockets, VirtualPort, 0, IntPtr.Zero);
                    if (listen == 0)
                    {
                        if (!listenWarned) Log.Warn("hosting: CreateListenSocketP2P failed");
                        listenWarned = true;
                    }
                    else
                    {
                        listenWarned = false;
                        statusDirty = true;
                        Log.Info("hosting: listening on Steam P2P (virtual port {0}), relaying to game port {1}; friends only {2}, invited {3}",
                            VirtualPort, gamePort, friendsOnly, allow.Count);
                    }
                }
                if (listen != 0 && !presenceOn) SetPresence(true);
            }
            else if (!hostWanted)
            {
                if (listen != 0)
                {
                    List<Peer> hosted = new List<Peer>();
                    foreach (Peer p in relay.All) if (!p.IsTunnel) hosted.Add(p);
                    foreach (Peer p in hosted)
                    {
                        steam.Close(p.Conn, Steam.EndNotHosting, "host closed the world");
                        LogStats(p, "closed (hosting off)");
                        relay.Remove(p.Conn);
                    }
                    Steam.SteamAPI_ISteamNetworkingSockets_CloseListenSocket(steam.Sockets, listen);
                    listen = 0;
                    statusDirty = true;
                    Log.Info("hosting off: listen socket closed");
                }
                if (presenceOn) SetPresence(false);
            }
        }

        void SetPresence(bool on)
        {
            if (!steam.Ok) return;
            if (on)
            {
                string me = S(steam.Me);
                int size = HostPeers() + 1;
                bool ok = steam.SetPresence("connect", ConnectPrefix + me);
                steam.SetPresence("status", "SurrounDead co-op (SDCoop " + modVersion + ")");
                steam.SetPresence("sdcoop", modVersion);
                steam.SetPresence("steam_player_group", me);
                steam.SetPresence("steam_player_group_size", S(size));
                if (!presenceOn) Log.Info("rich presence on: friends see Join Game (ok {0})", ok);
                presenceOn = true;
                presenceAt = Now();
                presenceSize = size;
            }
            else
            {
                steam.ClearPresence();
                presenceOn = false;
                presenceSize = -1;
                Log.Info("rich presence cleared");
            }
        }

        // ------------------------------------------------------------------
        // Joining (client tunnel)
        // ------------------------------------------------------------------

        void StartJoin(ulong host, string req)
        {
            if (joinConn != 0)
            {
                steam.Close(joinConn, Steam.EndLeave, "new join");
                Peer old = relay.Get(joinConn);
                if (old != null) LogStats(old, "replaced");
                relay.Remove(joinConn);
                joinConn = 0;
            }
            joinReq = req ?? "";
            joinHost = host;
            joinCode = 0;
            joinReason = "";
            joinPort = 0;
            statusDirty = true;
            if (!IsSteamId(host))
            {
                FailJoin("bad_id", 0);
                return;
            }
            if (!steam.Ok)
            {
                if (steam.State == "starting" || (steam.State == "init_failed" && initAttempts < 30 && steam.Error != "shut down"))
                {
                    joinPending = true;
                    joinState = "connecting";
                    joinReason = "waiting_for_steam";
                    joinAt = Now();
                    Log.Info("join {0}: waiting for Steam", joinReq);
                }
                else FailJoin("no_steam", 0);
                return;
            }
            if (host == steam.Me)
            {
                FailJoin("self", 0);
                return;
            }
            uint conn = steam.ConnectP2P(host, VirtualPort);
            if (conn == 0)
            {
                FailJoin("connect_failed", 0);
                return;
            }
            joinConn = conn;
            joinState = "connecting";
            joinAt = Now();
            Log.Info("join {0}: connecting to host {1} through Steam", joinReq, S(host));
        }

        void FailJoin(string reason, int code)
        {
            joinState = "failed";
            joinReason = reason;
            joinCode = code;
            statusDirty = true;
            Log.Info("join {0}: failed ({1}{2})", joinReq, reason, code != 0 ? ", Steam end reason " + code : "");
        }

        void OnTunnelUp()
        {
            if (joinState == "ready") return;
            Peer p = relay.AddTunnel(joinConn, joinHost);
            p.LinkUp = true;
            joinPort = p.LocalPort;
            joinState = "ready";
            statusDirty = true;
            Log.Info("join {0}: Steam tunnel to {1} is up; the game connects to 127.0.0.1:{2}", joinReq, S(joinHost), joinPort);
        }

        static string Reason(int code)
        {
            switch (code)
            {
                case Steam.EndNotFriend: return "not_friend";
                case Steam.EndNotHosting: return "not_hosting";
                case Steam.EndFull: return "full";
                case Steam.EndLeave:
                case Steam.EndShutdown: return "host_left";
                case Steam.EndIdle: return "idle";
                case 4001:
                case 5003: return "timeout";
                case 5010: return "not_hosting";   // the host has no listen socket
                case 5008: return "rendezvous";
                case 5009: return "nat";
            }
            if (code >= 3000 && code < 4000) return "local_network";
            if (code >= 4000 && code < 5000) return "remote_problem";
            return code != 0 ? "error" : "closed";
        }

        void OnTunnelClosed(int state)
        {
            int er;
            string ed;
            steam.Remote(joinConn, out er, out ed);
            Peer p = relay.Get(joinConn);
            if (p != null) LogStats(p, "closed (Steam end reason " + er + ")");
            bool wasReady = joinState == "ready";
            relay.Remove(joinConn);
            steam.Close(joinConn, 0, "");
            joinConn = 0;
            joinPort = 0;
            if (wasReady)
            {
                joinState = "closed";
                joinReason = Reason(er);
                joinCode = er;
                statusDirty = true;
                Log.Info("join {0}: tunnel closed ({1}, end reason {2})", joinReq, state == Steam.StateClosedByPeer ? "by the host" : "problem", er);
            }
            else
            {
                FailJoin(Reason(er), er);
            }
        }

        void Leave(string why)
        {
            joinPending = false;
            if (joinConn != 0)
            {
                Peer p = relay.Get(joinConn);
                if (p != null) LogStats(p, "left (" + why + ")");
                steam.Close(joinConn, Steam.EndLeave, "left");
                relay.Remove(joinConn);
                joinConn = 0;
            }
            if (joinState != "idle") Log.Info("join {0}: tunnel closed ({1})", joinReq, why);
            joinState = "idle";
            joinPort = 0;
            statusDirty = true;
        }

        // ------------------------------------------------------------------
        // Commands from the mod
        // ------------------------------------------------------------------

        void Command(string line)
        {
            string[] t = Ipc.Split(line);
            if (t.Length == 0) return;
            string verb = t[0].ToLowerInvariant();
            ulong id;
            switch (verb)
            {
                case "host":
                    {
                        bool on = t.Length > 1 && t[1] == "1";
                        int port;
                        if (t.Length > 2 && int.TryParse(t[2], NumberStyles.Integer, Inv, out port) && port > 0 && port < 65536) gamePort = port;
                        if (on != hostWanted) Log.Info("mod: hosting {0} (game port {1})", on ? "on" : "off", gamePort);
                        hostWanted = on;
                        ApplyHosting();
                        statusDirty = true;
                        break;
                    }
                case "join":
                    if (t.Length > 1 && ulong.TryParse(t[1], NumberStyles.Integer, Inv, out id))
                    {
                        Log.Info("mod: join request {0} to host {1}", t.Length > 2 ? t[2] : "", S(id));
                        StartJoin(id, t.Length > 2 ? t[2] : "");
                    }
                    break;
                case "leave":
                    Leave("asked by the mod");
                    break;
                case "config":
                    {
                        Dictionary<string, string> kv = Ipc.Pairs(t, 1);
                        string v;
                        if (kv.TryGetValue("friends_only", out v)) friendsOnly = v != "0";
                        if (kv.TryGetValue("allow", out v)) ParseAllow(v);
                        if (kv.TryGetValue("version", out v) && v != "") modVersion = v;
                        Log.Info("mod: config friends only {0}, invited {1}, mod {2}", friendsOnly, allow.Count, modVersion);
                        if (presenceOn) SetPresence(true);
                        statusDirty = true;
                        break;
                    }
                case "invite":
                    if (t.Length > 1 && ulong.TryParse(t[1], NumberStyles.Integer, Inv, out id) && IsSteamId(id))
                    {
                        allow.Add(id);
                        bool ok = steam.Ok && Steam.SteamAPI_ISteamFriends_InviteUserToGame(steam.Friends, id, Steam.Z(ConnectPrefix + S(steam.Me)));
                        Log.Info("mod: invite {0} (Steam invite sent {1})", S(id), ok);
                    }
                    break;
                case "friends":
                    friendsDirty = true;
                    friendsAt = -100000;
                    break;
                case "quit":
                    quit = true;
                    quitReason = "asked by the mod";
                    break;
                default:
                    Log.Warn("mod: unknown command '{0}'", verb);
                    break;
            }
        }

        // ------------------------------------------------------------------
        // Friends
        // ------------------------------------------------------------------

        void RefreshFriends(long t)
        {
            friendsAt = t;
            friendsDirty = false;
            if (!steam.Ok) return;
            int n = Steam.SteamAPI_ISteamFriends_GetFriendCount(steam.Friends, Steam.FriendFlagImmediate);
            int inGame = 0, hosting = 0;
            byte[] gi = new byte[32];
            StringBuilder b = new StringBuilder();
            for (int i = 0; i < n && i < 2000; i++)
            {
                ulong id = Steam.SteamAPI_ISteamFriends_GetFriendByIndex(steam.Friends, i, Steam.FriendFlagImmediate);
                if (id == 0) continue;
                Array.Clear(gi, 0, gi.Length);
                if (!Steam.SteamAPI_ISteamFriends_GetFriendGamePlayed(steam.Friends, id, gi)) continue;
                // FriendGameInfo_t.m_gameID: CGameID, app id in the low 24 bits
                ulong game = BitConverter.ToUInt64(gi, 0);
                if ((uint)(game & 0xFFFFFF) != appId) continue;
                inGame++;
                long asked;
                if (!presenceAsked.TryGetValue(id, out asked) || t - asked > 30000)
                {
                    presenceAsked[id] = t;
                    Steam.SteamAPI_ISteamFriends_RequestFriendRichPresence(steam.Friends, id);
                }
                string ver = steam.FriendPresence(id, "sdcoop");
                bool host = ver != "" && steam.FriendPresence(id, "connect").StartsWith(ConnectPrefix, StringComparison.Ordinal);
                if (host) hosting++;
                string name = Steam.Utf8(Steam.SteamAPI_ISteamFriends_GetFriendPersonaName(steam.Friends, id), 512);
                b.Append(S(id)).Append('\t').Append(host ? "1" : "0").Append('\t').Append(Ipc.Field(host ? ver : ""))
                    .Append('\t').Append(Ipc.Field(name)).Append('\n');
            }
            if (n != friendsTotal || inGame != friendsInGame || hosting != friendsHosting) statusDirty = true;
            friendsTotal = n;
            friendsInGame = inGame;
            friendsHosting = hosting;
            string text = b.ToString();
            if (text != friendsText)
            {
                friendsText = text;
                friendsSeq++;
                friendsWritePending = true;
                statusDirty = true;
            }
        }

        void WriteFriends()
        {
            if (ipc.Write("friends.txt", "seq=" + S(friendsSeq) + "\n" + friendsText)) friendsWritePending = false;
        }

        // ------------------------------------------------------------------
        // Status for the mod
        // ------------------------------------------------------------------

        void WriteStatus(long t)
        {
            if (friendsWritePending) WriteFriends();
            statusSeq++;
            long unix = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
            StringBuilder b = new StringBuilder();
            b.Append("sdcoop_steamlink=1\n");
            b.Append("version=").Append(Version).Append('\n');
            b.Append("pid=").Append(S(Win.GetCurrentProcessId())).Append('\n');
            b.Append("game_pid=").Append(S(gamePid)).Append('\n');
            b.Append("session=").Append(session).Append('\n');
            b.Append("time=").Append(S(unix)).Append('\n');
            b.Append("seq=").Append(S(statusSeq)).Append('\n');
            b.Append("steam=").Append(steam.State).Append('\n');
            b.Append("steamid=").Append(steam.Ok ? S(steam.Me) : "").Append('\n');
            // own Steam name: the mod's player name when its config leaves it empty (never logged)
            b.Append("persona=").Append(steam.Ok ? Ipc.Field(Steam.Utf8(Steam.SteamAPI_ISteamFriends_GetPersonaName(steam.Friends), 512)) : "").Append('\n');
            b.Append("logged_on=").Append(steam.LoggedOn() ? "1" : "0").Append('\n');
            b.Append("relay=").Append(S(steam.Ok ? steam.RelayStatus() : 0)).Append('\n');
            b.Append("hosting=").Append(hostWanted ? "1" : "0").Append('\n');
            b.Append("listen=").Append(listen != 0 ? "1" : "0").Append('\n');
            b.Append("friends_only=").Append(friendsOnly ? "1" : "0").Append('\n');
            b.Append("peers=").Append(S(HostPeers())).Append('\n');
            foreach (Peer p in relay.All)
            {
                if (p.IsTunnel) continue;
                b.Append("peer=").Append(S(p.SteamId)).Append(' ').Append(p.LinkUp ? "up" : "connecting").Append(' ')
                    .Append(S(p.ToGameBytes)).Append(' ').Append(S(p.FromGameBytes)).Append(' ').Append(S(p.Ping)).Append('\n');
            }
            b.Append("join_req=").Append(joinReq).Append('\n');
            b.Append("join_state=").Append(joinState).Append('\n');
            b.Append("join_host=").Append(joinHost != 0 ? S(joinHost) : "").Append('\n');
            b.Append("join_port=").Append(S(joinPort)).Append('\n');
            b.Append("join_reason=").Append(joinReason).Append('\n');
            b.Append("join_code=").Append(S(joinCode)).Append('\n');
            Peer tun = joinConn != 0 ? relay.Get(joinConn) : null;
            b.Append("join_ping=").Append(S(tun != null ? tun.Ping : -1)).Append('\n');
            b.Append("invite_seq=").Append(S(inviteSeq)).Append('\n');
            b.Append("invite_host=").Append(inviteHost != 0 ? S(inviteHost) : "").Append('\n');
            b.Append("friends_seq=").Append(S(friendsSeq)).Append('\n');
            b.Append("friends_total=").Append(S(friendsTotal)).Append('\n');
            b.Append("friends_ingame=").Append(S(friendsInGame)).Append('\n');
            b.Append("friends_hosting=").Append(S(friendsHosting)).Append('\n');
            if (ipc.Write("status.txt", b.ToString()))
            {
                statusDirty = false;
                statusAt = t;
            }
            else
            {
                statusAt = t - 900;   // the mod was reading it: again in ~100 ms
            }
        }

        // ------------------------------------------------------------------
        // Shutdown
        // ------------------------------------------------------------------

        void Shutdown()
        {
            Log.Info("shutting down ({0})", quitReason);
            try
            {
                if (relay != null)
                {
                    foreach (Peer p in relay.All)
                    {
                        LogStats(p, "closed (helper exit)");
                        steam.Close(p.Conn, Steam.EndShutdown, "helper exit");
                    }
                    relay.Clear();
                }
                if (listen != 0 && steam.Ok) Steam.SteamAPI_ISteamNetworkingSockets_CloseListenSocket(steam.Sockets, listen);
                listen = 0;
                if (presenceOn) SetPresence(false);
                SetTimer(false);
                steam.Shutdown();
            }
            catch (Exception e)
            {
                Log.Warn("shutdown: {0}", e.Message);
            }
            if (ipc != null)
            {
                ipc.Delete("status.txt");
                ipc.Delete("friends.txt");
            }
            Log.Info("bye");
            Log.Close();
        }
    }
}

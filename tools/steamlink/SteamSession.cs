// SDCoopSteamLink: the Steam side - init, manual callback dispatch, P2P
// connections (ISteamNetworkingSockets), friends and rich presence.
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

namespace SDCoopSteamLink
{
    class SteamSession
    {
        public IntPtr Sockets, Utils, Friends, User, SUtils;
        public int Pipe;
        public uint PollGroup;
        public ulong Me;
        public uint AppId;
        // "starting" | "ok" | "no_dll" | "init_failed"
        public string State = "starting";
        public string Error = "";
        public string DllPath = "";
        bool dllLoaded;

        public bool Ok { get { return State == "ok"; } }

        // The game's steam_api64.dll: an explicit path, or found from the exe's
        // folder upwards (...\SurrounDead\Binaries\Win64\ue4ss\Mods\SDCoop\steamlink).
        public static string FindDll(string startDir, string explicitPath, string gameRoot)
        {
            if (!string.IsNullOrEmpty(explicitPath)) return File.Exists(explicitPath) ? Path.GetFullPath(explicitPath) : null;
            List<string> roots = new List<string>();
            if (!string.IsNullOrEmpty(gameRoot)) roots.Add(gameRoot);
            string win64 = GameWatch.FindWin64(startDir);
            if (win64 != null)
            {
                // <root>\SurrounDead\Binaries\Win64
                DirectoryInfo d = new DirectoryInfo(win64);
                if (d.Parent != null && d.Parent.Parent != null && d.Parent.Parent.Parent != null) roots.Add(d.Parent.Parent.Parent.FullName);
            }
            foreach (string root in roots)
            {
                string sw = Path.Combine(root, @"Engine\Binaries\ThirdParty\Steamworks");
                string p = Path.Combine(sw, @"Steamv157\Win64\steam_api64.dll");
                if (File.Exists(p)) return p;
                if (Directory.Exists(sw))
                {
                    // a later game update may ship another SDK folder
                    string[] dirs = Directory.GetDirectories(sw, "Steamv*");
                    Array.Sort(dirs, StringComparer.OrdinalIgnoreCase);
                    for (int i = dirs.Length - 1; i >= 0; i--)
                    {
                        string q = Path.Combine(dirs[i], @"Win64\steam_api64.dll");
                        if (File.Exists(q)) return q;
                    }
                }
            }
            string local = Path.Combine(startDir, "steam_api64.dll");
            return File.Exists(local) ? local : null;
        }

        // Launched by the game, which Steam started: SteamAppId is already in the
        // environment. Otherwise it is set here - before steam_api64.dll loads,
        // because its C runtime copies the environment when it loads.
        public static void PrepareEnv(uint appId)
        {
            string id = appId.ToString(System.Globalization.CultureInfo.InvariantCulture);
            if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("SteamAppId"))) Environment.SetEnvironmentVariable("SteamAppId", id);
            if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("SteamGameId"))) Environment.SetEnvironmentVariable("SteamGameId", id);
        }

        public bool LoadDll(string path, uint appId)
        {
            if (dllLoaded) return true;
            PrepareEnv(appId);
            if (string.IsNullOrEmpty(path) || !File.Exists(path))
            {
                State = "no_dll";
                Error = "steam_api64.dll of the game not found";
                return false;
            }
            DllPath = path;
            Win.SetDllDirectoryW(Path.GetDirectoryName(path));
            IntPtr h = Win.LoadLibraryW(path);
            if (h == IntPtr.Zero)
            {
                State = "no_dll";
                Error = "LoadLibrary failed (" + Marshal.GetLastWin32Error() + ")";
                return false;
            }
            dllLoaded = true;
            return true;
        }

        // appIdDir: where a steam_appid.txt may be written as a last resort (the
        // helper's own folder), or null.
        public bool Init(uint appId, string appIdDir)
        {
            if (!dllLoaded) return false;
            PrepareEnv(appId);
            bool ok;
            try
            {
                ok = Steam.SteamAPI_Init();
                if (!ok && !string.IsNullOrEmpty(appIdDir))
                {
                    // steam_api looks for steam_appid.txt in the working folder when
                    // it finds no SteamAppId in the environment
                    // (read only inside SteamAPI_Init, so it is removed right after)
                    string f = Path.Combine(appIdDir, "steam_appid.txt");
                    bool made = !File.Exists(f);
                    if (made) File.WriteAllText(f, appId.ToString(System.Globalization.CultureInfo.InvariantCulture));
                    Directory.SetCurrentDirectory(appIdDir);
                    ok = Steam.SteamAPI_Init();
                    if (made)
                    {
                        try { File.Delete(f); } catch (Exception) { }
                    }
                    if (ok) Log.Info("SteamAPI_Init worked with steam_appid.txt");
                }
            }
            catch (Exception e)
            {
                State = "init_failed";
                Error = "SteamAPI_Init: " + e.GetType().Name;
                return false;
            }
            if (!ok)
            {
                bool running = false;
                try { running = Steam.SteamAPI_IsSteamRunning(); } catch (Exception) { }
                State = "init_failed";
                Error = running
                    ? "SteamAPI_Init failed although Steam runs (not logged in, game not owned, or Steam not reachable from this process)"
                    : "SteamAPI_Init failed: Steam is not running (or not reachable from this process)";
                return false;
            }
            Steam.SteamAPI_ManualDispatch_Init();
            Pipe = Steam.SteamAPI_GetHSteamPipe();
            Sockets = Steam.SteamAPI_SteamNetworkingSockets_SteamAPI_v012();
            Utils = Steam.SteamAPI_SteamNetworkingUtils_SteamAPI_v004();
            Friends = Steam.SteamAPI_SteamFriends_v017();
            User = Steam.SteamAPI_SteamUser_v021();
            SUtils = Steam.SteamAPI_SteamUtils_v010();
            if (Sockets == IntPtr.Zero || Utils == IntPtr.Zero || Friends == IntPtr.Zero || User == IntPtr.Zero || SUtils == IntPtr.Zero)
            {
                State = "init_failed";
                Error = "a Steam interface is missing";
                Steam.SteamAPI_Shutdown();
                return false;
            }
            Me = Steam.SteamAPI_ISteamUser_GetSteamID(User);
            AppId = Steam.SteamAPI_ISteamUtils_GetAppID(SUtils);
            Steam.SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess(Utils);
            Steam.SteamAPI_ISteamNetworkingSockets_InitAuthentication(Sockets);
            PollGroup = Steam.SteamAPI_ISteamNetworkingSockets_CreatePollGroup(Sockets);
            State = "ok";
            Error = "";
            return true;
        }

        public bool LoggedOn()
        {
            return Ok && Steam.SteamAPI_ISteamUser_BLoggedOn(User);
        }

        // Pumps Steam callbacks: handler(callback id, param pointer, param size).
        public int RunCallbacks(Action<int, IntPtr, int> handler)
        {
            if (!Ok) return 0;
            Steam.SteamAPI_ManualDispatch_RunFrame(Pipe);
            CallbackMsg msg = new CallbackMsg();
            int n = 0;
            while (n < 256 && Steam.SteamAPI_ManualDispatch_GetNextCallback(Pipe, ref msg))
            {
                n++;
                try
                {
                    handler(msg.Callback, msg.Param, msg.ParamSize);
                }
                catch (Exception e)
                {
                    Log.Warn("callback {0}: {1}: {2}", msg.Callback, e.GetType().Name, e.Message);
                }
                finally
                {
                    Steam.SteamAPI_ManualDispatch_FreeLastCallback(Pipe);
                }
            }
            return n;
        }

        // SteamRelayNetworkStatus_t (272 bytes) / SteamNetAuthenticationStatus_t (260 bytes)
        readonly byte[] details = new byte[1024];

        public int RelayStatus()
        {
            return Ok ? Steam.SteamAPI_ISteamNetworkingUtils_GetRelayNetworkStatus(Utils, details) : 0;
        }

        public int AuthStatus()
        {
            return Ok ? Steam.SteamAPI_ISteamNetworkingSockets_GetAuthenticationStatus(Sockets, details) : 0;
        }

        readonly byte[] info = new byte[Steam.InfoSize];
        readonly byte[] rts = new byte[512];

        // Connection state and ping (-1 when unknown).
        public int ConnState(uint conn, out int ping)
        {
            ping = -1;
            if (!Ok || conn == 0) return Steam.StateNone;
            Array.Clear(rts, 0, rts.Length);
            int r = Steam.SteamAPI_ISteamNetworkingSockets_GetConnectionRealTimeStatus(Sockets, conn, rts, 0, IntPtr.Zero);
            if (r == Steam.ResultOK)
            {
                ping = BitConverter.ToInt32(rts, 4);
                return BitConverter.ToInt32(rts, 0);
            }
            Array.Clear(info, 0, info.Length);
            if (Steam.SteamAPI_ISteamNetworkingSockets_GetConnectionInfo(Sockets, conn, info)) return BitConverter.ToInt32(info, Steam.InfoState);
            return Steam.StateNone;
        }

        // Remote SteamID64 of a connection (0 when unknown), its end reason and debug text.
        public ulong Remote(uint conn, out int endReason, out string endDebug)
        {
            endReason = 0;
            endDebug = "";
            if (!Ok || conn == 0) return 0;
            Array.Clear(info, 0, info.Length);
            if (!Steam.SteamAPI_ISteamNetworkingSockets_GetConnectionInfo(Sockets, conn, info)) return 0;
            endReason = BitConverter.ToInt32(info, Steam.InfoEndReason);
            endDebug = Steam.Utf8(info, Steam.InfoEndDebug, 128);
            return Steam.SteamAPI_SteamNetworkingIdentity_GetSteamID64(info);
        }

        public uint ConnectP2P(ulong host, int virtualPort)
        {
            byte[] id = new byte[136];
            Steam.SteamAPI_SteamNetworkingIdentity_Clear(id);
            Steam.SteamAPI_SteamNetworkingIdentity_SetSteamID64(id, host);
            uint conn = Steam.SteamAPI_ISteamNetworkingSockets_ConnectP2P(Sockets, id, virtualPort, 0, IntPtr.Zero);
            if (conn != 0) Steam.SteamAPI_ISteamNetworkingSockets_SetConnectionPollGroup(Sockets, conn, PollGroup);
            return conn;
        }

        public void Close(uint conn, int reason, string debug)
        {
            if (!Ok || conn == 0) return;
            Steam.SteamAPI_ISteamNetworkingSockets_CloseConnection(Sockets, conn, reason, Steam.Z(debug), false);
        }

        public bool IsFriend(ulong id)
        {
            return Ok && Steam.SteamAPI_ISteamFriends_GetFriendRelationship(Friends, id) == Steam.RelationshipFriend;
        }

        public bool SetPresence(string key, string value)
        {
            return Ok && Steam.SteamAPI_ISteamFriends_SetRichPresence(Friends, Steam.Z(key), Steam.Z(value));
        }

        public void ClearPresence()
        {
            if (Ok) Steam.SteamAPI_ISteamFriends_ClearRichPresence(Friends);
        }

        public string FriendPresence(ulong id, string key)
        {
            return Steam.Utf8(Steam.SteamAPI_ISteamFriends_GetFriendRichPresence(Friends, id, Steam.Z(key)), 512);
        }

        public void Shutdown()
        {
            if (!Ok) return;
            try
            {
                if (PollGroup != 0) Steam.SteamAPI_ISteamNetworkingSockets_DestroyPollGroup(Sockets, PollGroup);
                Steam.SteamAPI_Shutdown();
            }
            catch (Exception e)
            {
                Log.Warn("steam shutdown: {0}", e.Message);
            }
            State = "init_failed";
            Error = "shut down";
        }
    }

    // The P2P link over Steam: one ISteamNetworkingSockets connection per peer,
    // all in one poll group. Datagrams go unreliable, no Nagle delay.
    class SteamLink : ILink
    {
        readonly SteamSession s;
        readonly IntPtr[] msgs = new IntPtr[64];
        byte[] buf = new byte[65536];
        public long SendFailures;

        public SteamLink(SteamSession session) { s = session; }

        public bool Send(uint conn, byte[] data, int len)
        {
            if (!s.Ok) return false;
            int r = Steam.SteamAPI_ISteamNetworkingSockets_SendMessageToConnection(s.Sockets, conn, data, (uint)len,
                Steam.SendUnreliableNoNagle, IntPtr.Zero);
            if (r != Steam.ResultOK)
            {
                SendFailures++;
                return false;
            }
            return true;
        }

        public int Pump(Action<uint, byte[], int> onMessage)
        {
            if (!s.Ok || s.PollGroup == 0) return 0;
            int total = 0;
            for (int round = 0; round < 32; round++)
            {
                int n = Steam.SteamAPI_ISteamNetworkingSockets_ReceiveMessagesOnPollGroup(s.Sockets, s.PollGroup, msgs, msgs.Length);
                if (n <= 0) break;
                for (int i = 0; i < n; i++)
                {
                    IntPtr m = msgs[i];
                    try
                    {
                        // SteamNetworkingMessage_t: m_pData 0, m_cbSize 8, m_conn 12
                        IntPtr data = Marshal.ReadIntPtr(m, 0);
                        int size = Marshal.ReadInt32(m, 8);
                        uint conn = (uint)Marshal.ReadInt32(m, 12);
                        if (size > buf.Length) buf = new byte[size];
                        if (size > 0) Marshal.Copy(data, buf, 0, size);
                        if (size >= 0) onMessage(conn, buf, size);
                    }
                    finally
                    {
                        Steam.SteamAPI_SteamNetworkingMessage_t_Release(m);
                    }
                }
                total += n;
                if (n < msgs.Length) break;
            }
            return total;
        }
    }
}

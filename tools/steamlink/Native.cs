// SDCoopSteamLink: P/Invoke declarations.
//
// Steam: the flat C API of the game's own steam_api64.dll (Steamworks SDK 1.57,
// SurrounDead\..\Engine\Binaries\ThirdParty\Steamworks\Steamv157\Win64).
// The DLL is loaded by full path before the first call (SteamSession.LoadDll),
// so "steam_api64" below binds to that already loaded module.
// Interface versions exported by that DLL: SteamNetworkingSockets v012,
// SteamNetworkingUtils v004, SteamFriends v017, SteamUser v021, SteamUtils v010.
// C++ bool is one byte: every bool crossing into steam_api is marshalled as I1.
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace SDCoopSteamLink
{
    // steam_api_common.h CallbackMsg_t (pack 8 on Win64): 24 bytes
    [StructLayout(LayoutKind.Sequential)]
    struct CallbackMsg
    {
        public int User;
        public int Callback;
        public IntPtr Param;
        public int ParamSize;
    }

    static class Steam
    {
        const string Dll = "steam_api64";
        const CallingConvention CC = CallingConvention.Cdecl;

        // ---- core / manual dispatch
        [DllImport(Dll, CallingConvention = CC)]
        [return: MarshalAs(UnmanagedType.I1)]
        public static extern bool SteamAPI_Init();
        [DllImport(Dll, CallingConvention = CC)]
        public static extern void SteamAPI_Shutdown();
        [DllImport(Dll, CallingConvention = CC)]
        [return: MarshalAs(UnmanagedType.I1)]
        public static extern bool SteamAPI_IsSteamRunning();
        [DllImport(Dll, CallingConvention = CC)]
        public static extern int SteamAPI_GetHSteamPipe();
        [DllImport(Dll, CallingConvention = CC)]
        public static extern void SteamAPI_ManualDispatch_Init();
        [DllImport(Dll, CallingConvention = CC)]
        public static extern void SteamAPI_ManualDispatch_RunFrame(int pipe);
        [DllImport(Dll, CallingConvention = CC)]
        [return: MarshalAs(UnmanagedType.I1)]
        public static extern bool SteamAPI_ManualDispatch_GetNextCallback(int pipe, ref CallbackMsg msg);
        [DllImport(Dll, CallingConvention = CC)]
        public static extern void SteamAPI_ManualDispatch_FreeLastCallback(int pipe);

        // ---- interface accessors
        [DllImport(Dll, CallingConvention = CC)]
        public static extern IntPtr SteamAPI_SteamNetworkingSockets_SteamAPI_v012();
        [DllImport(Dll, CallingConvention = CC)]
        public static extern IntPtr SteamAPI_SteamNetworkingUtils_SteamAPI_v004();
        [DllImport(Dll, CallingConvention = CC)]
        public static extern IntPtr SteamAPI_SteamFriends_v017();
        [DllImport(Dll, CallingConvention = CC)]
        public static extern IntPtr SteamAPI_SteamUser_v021();
        [DllImport(Dll, CallingConvention = CC)]
        public static extern IntPtr SteamAPI_SteamUtils_v010();

        // ---- ISteamUser / ISteamUtils
        [DllImport(Dll, CallingConvention = CC)]
        public static extern ulong SteamAPI_ISteamUser_GetSteamID(IntPtr self);
        [DllImport(Dll, CallingConvention = CC)]
        [return: MarshalAs(UnmanagedType.I1)]
        public static extern bool SteamAPI_ISteamUser_BLoggedOn(IntPtr self);
        [DllImport(Dll, CallingConvention = CC)]
        public static extern uint SteamAPI_ISteamUtils_GetAppID(IntPtr self);

        // ---- ISteamFriends
        [DllImport(Dll, CallingConvention = CC)]
        public static extern int SteamAPI_ISteamFriends_GetFriendCount(IntPtr self, int flags);
        [DllImport(Dll, CallingConvention = CC)]
        public static extern ulong SteamAPI_ISteamFriends_GetFriendByIndex(IntPtr self, int index, int flags);
        [DllImport(Dll, CallingConvention = CC)]
        public static extern int SteamAPI_ISteamFriends_GetFriendRelationship(IntPtr self, ulong friend);
        [DllImport(Dll, CallingConvention = CC)]
        public static extern IntPtr SteamAPI_ISteamFriends_GetFriendPersonaName(IntPtr self, ulong friend);
        [DllImport(Dll, CallingConvention = CC)]
        public static extern IntPtr SteamAPI_ISteamFriends_GetPersonaName(IntPtr self);
        [DllImport(Dll, CallingConvention = CC)]
        [return: MarshalAs(UnmanagedType.I1)]
        public static extern bool SteamAPI_ISteamFriends_GetFriendGamePlayed(IntPtr self, ulong friend, byte[] info);
        [DllImport(Dll, CallingConvention = CC)]
        public static extern IntPtr SteamAPI_ISteamFriends_GetFriendRichPresence(IntPtr self, ulong friend, byte[] key);
        [DllImport(Dll, CallingConvention = CC)]
        public static extern void SteamAPI_ISteamFriends_RequestFriendRichPresence(IntPtr self, ulong friend);
        [DllImport(Dll, CallingConvention = CC)]
        [return: MarshalAs(UnmanagedType.I1)]
        public static extern bool SteamAPI_ISteamFriends_SetRichPresence(IntPtr self, byte[] key, byte[] value);
        [DllImport(Dll, CallingConvention = CC)]
        public static extern void SteamAPI_ISteamFriends_ClearRichPresence(IntPtr self);
        [DllImport(Dll, CallingConvention = CC)]
        [return: MarshalAs(UnmanagedType.I1)]
        public static extern bool SteamAPI_ISteamFriends_InviteUserToGame(IntPtr self, ulong friend, byte[] connect);

        // ---- ISteamNetworkingSockets
        [DllImport(Dll, CallingConvention = CC)]
        public static extern uint SteamAPI_ISteamNetworkingSockets_CreateListenSocketP2P(IntPtr self, int virtualPort, int nOptions, IntPtr options);
        [DllImport(Dll, CallingConvention = CC)]
        public static extern uint SteamAPI_ISteamNetworkingSockets_ConnectP2P(IntPtr self, byte[] identity, int virtualPort, int nOptions, IntPtr options);
        [DllImport(Dll, CallingConvention = CC)]
        public static extern int SteamAPI_ISteamNetworkingSockets_AcceptConnection(IntPtr self, uint conn);
        [DllImport(Dll, CallingConvention = CC)]
        [return: MarshalAs(UnmanagedType.I1)]
        public static extern bool SteamAPI_ISteamNetworkingSockets_CloseConnection(IntPtr self, uint conn, int reason, byte[] debug,
            [MarshalAs(UnmanagedType.I1)] bool linger);
        [DllImport(Dll, CallingConvention = CC)]
        [return: MarshalAs(UnmanagedType.I1)]
        public static extern bool SteamAPI_ISteamNetworkingSockets_CloseListenSocket(IntPtr self, uint socket);
        [DllImport(Dll, CallingConvention = CC)]
        public static extern int SteamAPI_ISteamNetworkingSockets_SendMessageToConnection(IntPtr self, uint conn, byte[] data, uint size,
            int flags, IntPtr outMessageNumber);
        [DllImport(Dll, CallingConvention = CC)]
        public static extern int SteamAPI_ISteamNetworkingSockets_ReceiveMessagesOnConnection(IntPtr self, uint conn,
            [Out] IntPtr[] messages, int max);
        [DllImport(Dll, CallingConvention = CC)]
        public static extern int SteamAPI_ISteamNetworkingSockets_ReceiveMessagesOnPollGroup(IntPtr self, uint group,
            [Out] IntPtr[] messages, int max);
        [DllImport(Dll, CallingConvention = CC)]
        [return: MarshalAs(UnmanagedType.I1)]
        public static extern bool SteamAPI_ISteamNetworkingSockets_GetConnectionInfo(IntPtr self, uint conn, byte[] info);
        [DllImport(Dll, CallingConvention = CC)]
        public static extern int SteamAPI_ISteamNetworkingSockets_GetConnectionRealTimeStatus(IntPtr self, uint conn, byte[] status,
            int nLanes, IntPtr lanes);
        [DllImport(Dll, CallingConvention = CC)]
        public static extern uint SteamAPI_ISteamNetworkingSockets_CreatePollGroup(IntPtr self);
        [DllImport(Dll, CallingConvention = CC)]
        [return: MarshalAs(UnmanagedType.I1)]
        public static extern bool SteamAPI_ISteamNetworkingSockets_DestroyPollGroup(IntPtr self, uint group);
        [DllImport(Dll, CallingConvention = CC)]
        [return: MarshalAs(UnmanagedType.I1)]
        public static extern bool SteamAPI_ISteamNetworkingSockets_SetConnectionPollGroup(IntPtr self, uint conn, uint group);
        [DllImport(Dll, CallingConvention = CC)]
        [return: MarshalAs(UnmanagedType.I1)]
        public static extern bool SteamAPI_ISteamNetworkingSockets_CreateSocketPair(IntPtr self, out uint conn1, out uint conn2,
            [MarshalAs(UnmanagedType.I1)] bool loopback, IntPtr identity1, IntPtr identity2);
        [DllImport(Dll, CallingConvention = CC)]
        public static extern int SteamAPI_ISteamNetworkingSockets_InitAuthentication(IntPtr self);
        [DllImport(Dll, CallingConvention = CC)]
        public static extern int SteamAPI_ISteamNetworkingSockets_GetAuthenticationStatus(IntPtr self, byte[] details);

        // ---- ISteamNetworkingUtils
        [DllImport(Dll, CallingConvention = CC)]
        public static extern void SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess(IntPtr self);
        [DllImport(Dll, CallingConvention = CC)]
        public static extern int SteamAPI_ISteamNetworkingUtils_GetRelayNetworkStatus(IntPtr self, byte[] details);

        // ---- value types
        [DllImport(Dll, CallingConvention = CC)]
        public static extern void SteamAPI_SteamNetworkingMessage_t_Release(IntPtr message);
        [DllImport(Dll, CallingConvention = CC)]
        public static extern void SteamAPI_SteamNetworkingIdentity_Clear(byte[] identity);
        [DllImport(Dll, CallingConvention = CC)]
        public static extern void SteamAPI_SteamNetworkingIdentity_SetSteamID64(byte[] identity, ulong steamId);
        [DllImport(Dll, CallingConvention = CC)]
        public static extern ulong SteamAPI_SteamNetworkingIdentity_GetSteamID64(byte[] identity);

        // ---- constants (steamnetworkingtypes.h, isteamfriends.h)
        public const int SendUnreliableNoNagle = 1;     // k_nSteamNetworkingSend_UnreliableNoNagle
        public const int ResultOK = 1;                  // k_EResultOK
        public const int FriendFlagImmediate = 0x04;    // k_EFriendFlagImmediate
        public const int RelationshipFriend = 3;        // k_EFriendRelationshipFriend
        public const int AvailabilityCurrent = 100;     // k_ESteamNetworkingAvailability_Current
        public const int CbConnStatusChanged = 1221;    // SteamNetConnectionStatusChangedCallback_t
        public const int CbRichPresenceJoin = 337;      // GameRichPresenceJoinRequested_t
        public const int CbFriendRichPresence = 336;    // FriendRichPresenceUpdate_t
        public const int CbPersonaState = 304;          // PersonaStateChange_t
        public const int CbRelayStatus = 1281;          // SteamRelayNetworkStatus_t
        // ESteamNetworkingConnectionState
        public const int StateNone = 0, StateConnecting = 1, StateFindingRoute = 2, StateConnected = 3,
            StateClosedByPeer = 4, StateProblemLocally = 5;
        // SteamNetConnectionInfo_t (pack 8): identity at 0 (136 bytes), m_eState 176,
        // m_eEndReason 180, m_szEndDebug 184 (128), m_szConnectionDescription 312 (128).
        // The callback SteamNetConnectionStatusChangedCallback_t: m_hConn 0, m_info 8.
        // --steamcheck verifies these offsets with a local socket pair.
        public const int InfoSize = 1024, InfoState = 176, InfoEndReason = 180, InfoEndDebug = 184, InfoDescription = 312;
        public const int CbInfoOffset = 8;
        // m_eOldState after m_info (696 bytes); the callback is 712 bytes. Closing
        // a connection ourselves posts one more callback: state None, old state = last state.
        public const int CbOldState = 704;
        // App-defined close reasons (k_ESteamNetConnectionEnd_App_Min = 1000)
        public const int EndNotFriend = 1001, EndNotHosting = 1002, EndFull = 1003, EndLeave = 1004, EndShutdown = 1005,
            EndIdle = 1006, EndTimeout = 1007;

        public static byte[] Z(string s)
        {
            byte[] b = Encoding.UTF8.GetBytes(s ?? "");
            byte[] z = new byte[b.Length + 1];
            Buffer.BlockCopy(b, 0, z, 0, b.Length);
            return z;
        }

        public static string Utf8(IntPtr p, int max)
        {
            if (p == IntPtr.Zero) return "";
            int n = 0;
            while (n < max && Marshal.ReadByte(p, n) != 0) n++;
            if (n == 0) return "";
            byte[] b = new byte[n];
            Marshal.Copy(p, b, 0, n);
            return Encoding.UTF8.GetString(b);
        }

        public static string Utf8(byte[] buf, int offset, int max)
        {
            int n = 0;
            while (n < max && offset + n < buf.Length && buf[offset + n] != 0) n++;
            return Encoding.UTF8.GetString(buf, offset, n);
        }
    }

    // ---- Windows
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PROCESSENTRY32W
    {
        public uint dwSize;
        public uint cntUsage;
        public uint th32ProcessID;
        public IntPtr th32DefaultHeapID;
        public uint th32ModuleID;
        public uint cntThreads;
        public uint th32ParentProcessID;
        public int pcPriClassBase;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string szExeFile;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFOW
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION
    {
        public IntPtr hProcess, hThread;
        public int dwProcessId, dwThreadId;
    }

    static class Win
    {
        [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr LoadLibraryW(string path);
        [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool SetDllDirectoryW(string path);
        [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool MoveFileExW(string from, string to, int flags);
        public const int MOVEFILE_REPLACE_EXISTING = 1, MOVEFILE_WRITE_THROUGH = 8;
        [DllImport("kernel32")]
        public static extern bool AttachConsole(int pid);
        [DllImport("winmm")]
        public static extern uint timeBeginPeriod(uint ms);
        [DllImport("winmm")]
        public static extern uint timeEndPeriod(uint ms);

        [DllImport("kernel32", SetLastError = true)]
        public static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
        [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool Process32FirstW(IntPtr snapshot, ref PROCESSENTRY32W entry);
        [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool Process32NextW(IntPtr snapshot, ref PROCESSENTRY32W entry);
        [DllImport("kernel32", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32", SetLastError = true)]
        public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool QueryFullProcessImageNameW(IntPtr process, int flags, StringBuilder name, ref int size);
        [DllImport("kernel32", SetLastError = true)]
        public static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);
        [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool CreateProcessW(string application, StringBuilder commandLine, IntPtr processAttributes,
            IntPtr threadAttributes, bool inheritHandles, uint flags, IntPtr environment, string currentDirectory,
            ref STARTUPINFOW startupInfo, out PROCESS_INFORMATION processInfo);
        [DllImport("kernel32")]
        public static extern int GetCurrentProcessId();

        public const uint TH32CS_SNAPPROCESS = 2;
        public const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        public static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);
    }
}

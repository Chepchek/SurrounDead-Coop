// SDCoopSteamLink: the UDP relay between the game (127.0.0.1) and the P2P link.
//
// Host side: one local UDP socket per remote player, "connected" to the game's
// listen port (127.0.0.1:7777), so the game's IpNetDriver sees every friend as
// its own 127.0.0.1:<port> client.
// Client side (tunnel): one local UDP socket on 127.0.0.1:<free port>; the
// game opens "127.0.0.1:<port>", the relay learns the game's endpoint from its
// first datagram.
// The link (Steam P2P, or memory for --selftest) carries each datagram as one
// unreliable message, in both directions.
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;

namespace SDCoopSteamLink
{
    interface ILink
    {
        bool Send(uint conn, byte[] data, int len);
        // Delivers every waiting message: onMessage(conn, buffer, length).
        int Pump(Action<uint, byte[], int> onMessage);
    }

    class Peer
    {
        public uint Conn;
        public ulong SteamId;
        public bool IsTunnel;          // client side
        public Socket Udp;
        public IPEndPoint Game;        // host: the game's listen port; tunnel: learned
        public int LocalPort;
        public bool LinkUp;            // the P2P connection is established
        public long ToGamePkts, ToGameBytes, FromGamePkts, FromGameBytes, Dropped;
        public long Created, LastFromGame, LastFromLink, LastStats;
        public int Ping = -1;
    }

    class Relay
    {
        const int SIO_UDP_CONNRESET = unchecked((int)0x9800000C);
        readonly ILink link;
        readonly Dictionary<uint, Peer> peers = new Dictionary<uint, Peer>();
        readonly Dictionary<Socket, Peer> bySocket = new Dictionary<Socket, Peer>();
        readonly List<Socket> readList = new List<Socket>();
        readonly byte[] buf = new byte[65536];
        readonly Func<long> now;

        public Relay(ILink link, Func<long> now)
        {
            this.link = link;
            this.now = now;
        }

        public int Count { get { return peers.Count; } }
        public IEnumerable<Peer> All { get { return peers.Values; } }

        public Peer Get(uint conn)
        {
            Peer p;
            return peers.TryGetValue(conn, out p) ? p : null;
        }

        static Socket NewUdp()
        {
            Socket s = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
            try
            {
                // an ICMP "port unreachable" (game not listening yet) must not
                // turn into an error on the next receive
                s.IOControl(SIO_UDP_CONNRESET, new byte[] { 0, 0, 0, 0 }, null);
            }
            catch (Exception) { }
            s.ReceiveBufferSize = 1 << 20;
            s.SendBufferSize = 1 << 20;
            s.Bind(new IPEndPoint(IPAddress.Loopback, 0));
            s.Blocking = false;
            return s;
        }

        Peer Add(uint conn, ulong sid, bool tunnel, Socket s)
        {
            Remove(conn);
            Peer p = new Peer();
            p.Conn = conn;
            p.SteamId = sid;
            p.IsTunnel = tunnel;
            p.Udp = s;
            p.LocalPort = ((IPEndPoint)s.LocalEndPoint).Port;
            p.Created = now();
            p.LastFromGame = p.Created;
            p.LastFromLink = p.Created;
            p.LastStats = p.Created;
            peers[conn] = p;
            bySocket[s] = p;
            return p;
        }

        // Host side: a remote player's datagrams go to the game's listen port.
        public Peer AddHostPeer(uint conn, ulong sid, int gamePort)
        {
            Socket s = NewUdp();
            IPEndPoint game = new IPEndPoint(IPAddress.Loopback, gamePort);
            s.Connect(game);
            Peer p = Add(conn, sid, false, s);
            p.Game = game;
            return p;
        }

        // Client side: the local endpoint the game connects to.
        public Peer AddTunnel(uint conn, ulong sid)
        {
            return Add(conn, sid, true, NewUdp());
        }

        public void Remove(uint conn)
        {
            Peer p;
            if (!peers.TryGetValue(conn, out p)) return;
            peers.Remove(conn);
            bySocket.Remove(p.Udp);
            try { p.Udp.Close(); } catch (Exception) { }
        }

        public void Clear()
        {
            List<uint> all = new List<uint>(peers.Keys);
            foreach (uint c in all) Remove(c);
        }

        // Game -> link. Waits up to timeoutUs for a datagram on any peer socket.
        public int PollGame(int timeoutUs)
        {
            if (peers.Count == 0) return 0;
            readList.Clear();
            foreach (Peer p in peers.Values) readList.Add(p.Udp);
            try
            {
                Socket.Select(readList, null, null, timeoutUs);
            }
            catch (SocketException) { return 0; }
            catch (ObjectDisposedException) { return 0; }
            int n = 0;
            for (int i = 0; i < readList.Count; i++)
            {
                Peer p;
                if (bySocket.TryGetValue(readList[i], out p)) n += Drain(p);
            }
            return n;
        }

        int Drain(Peer p)
        {
            int n = 0;
            for (int i = 0; i < 512; i++)
            {
                int len;
                EndPoint from = new IPEndPoint(IPAddress.Any, 0);
                try
                {
                    len = p.Udp.ReceiveFrom(buf, ref from);
                }
                catch (SocketException e)
                {
                    if (e.SocketErrorCode == SocketError.ConnectionReset || e.SocketErrorCode == SocketError.MessageSize) continue;
                    break;   // WouldBlock: nothing more
                }
                catch (ObjectDisposedException)
                {
                    break;
                }
                IPEndPoint ep = from as IPEndPoint;
                if (p.IsTunnel)
                {
                    // only the game on this computer talks to the tunnel
                    if (ep == null || !IPAddress.IsLoopback(ep.Address)) continue;
                    if (p.Game == null || !p.Game.Equals(ep)) p.Game = ep;
                }
                n++;
                p.FromGamePkts++;
                p.FromGameBytes += len;
                p.LastFromGame = now();
                if (!link.Send(p.Conn, buf, len)) p.Dropped++;
            }
            return n;
        }

        // Link -> game.
        public int PumpLink()
        {
            return link.Pump(OnLinkMessage);
        }

        void OnLinkMessage(uint conn, byte[] data, int len)
        {
            Peer p;
            if (!peers.TryGetValue(conn, out p)) return;
            p.LastFromLink = now();
            if (p.Game == null || len <= 0)
            {
                p.Dropped++;
                return;
            }
            try
            {
                if (p.IsTunnel) p.Udp.SendTo(data, 0, len, SocketFlags.None, p.Game);
                else p.Udp.Send(data, 0, len, SocketFlags.None);
                p.ToGamePkts++;
                p.ToGameBytes += len;
            }
            catch (SocketException)
            {
                p.Dropped++;
            }
            catch (ObjectDisposedException)
            {
                p.Dropped++;
            }
        }
    }

    // In-process link for --selftest: conn ids are shared by both ends.
    class MemoryLink : ILink
    {
        readonly Queue<KeyValuePair<uint, byte[]>> inbox = new Queue<KeyValuePair<uint, byte[]>>();
        public readonly Dictionary<uint, MemoryLink> Routes = new Dictionary<uint, MemoryLink>();
        public long Sent;

        public bool Send(uint conn, byte[] data, int len)
        {
            MemoryLink other;
            if (!Routes.TryGetValue(conn, out other)) return false;
            byte[] copy = new byte[len];
            Buffer.BlockCopy(data, 0, copy, 0, len);
            other.inbox.Enqueue(new KeyValuePair<uint, byte[]>(conn, copy));
            Sent++;
            return true;
        }

        public int Pump(Action<uint, byte[], int> onMessage)
        {
            int n = 0;
            while (inbox.Count > 0)
            {
                KeyValuePair<uint, byte[]> m = inbox.Dequeue();
                onMessage(m.Key, m.Value, m.Value.Length);
                n++;
            }
            return n;
        }
    }
}

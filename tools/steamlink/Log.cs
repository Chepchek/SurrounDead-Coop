// SDCoopSteamLink: a small log file next to the exe (helper_log.txt).
// English, one line per event. No personal data: SteamIDs only where they are
// needed to tell connections apart; never persona names, never IP addresses.
using System;
using System.Globalization;
using System.IO;
using System.Text;

namespace SDCoopSteamLink
{
    static class Log
    {
        static StreamWriter writer;
        static readonly object gate = new object();
        static long written;
        const long MaxBytes = 4L * 1024 * 1024;

        // Also print every line to stdout (--selftest / --steamcheck).
        public static bool Echo;

        // Opens (truncates) the log; the previous one is kept as helper_log.old.txt.
        public static void Open(string path)
        {
            lock (gate)
            {
                try
                {
                    if (File.Exists(path))
                    {
                        string old = Path.Combine(Path.GetDirectoryName(path), Path.GetFileNameWithoutExtension(path) + ".old.txt");
                        try
                        {
                            if (File.Exists(old)) File.Delete(old);
                            File.Move(path, old);
                        }
                        catch (Exception) { }
                    }
                    FileStream fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
                    writer = new StreamWriter(fs, new UTF8Encoding(false));
                    writer.AutoFlush = true;
                    written = 0;
                }
                catch (Exception)
                {
                    writer = null;
                }
            }
        }

        public static void Info(string fmt, params object[] args) { Write("", fmt, args); }
        public static void Warn(string fmt, params object[] args) { Write("[WARN] ", fmt, args); }

        static void Write(string level, string fmt, object[] args)
        {
            string msg;
            try
            {
                msg = (args == null || args.Length == 0) ? fmt : string.Format(CultureInfo.InvariantCulture, fmt, args);
            }
            catch (FormatException)
            {
                msg = fmt;
            }
            string line = DateTime.Now.ToString("HH:mm:ss.fff", CultureInfo.InvariantCulture) + " " + level + msg;
            lock (gate)
            {
                if (Echo)
                {
                    try { Console.WriteLine(line); } catch (Exception) { }
                }
                if (writer == null || written > MaxBytes) return;
                try
                {
                    writer.WriteLine(line);
                    written += line.Length + 2;
                    if (written > MaxBytes) writer.WriteLine("... log size limit reached, further lines dropped");
                }
                catch (Exception) { }
            }
        }

        public static void Close()
        {
            lock (gate)
            {
                if (writer == null) return;
                try { writer.Dispose(); } catch (Exception) { }
                writer = null;
            }
        }
    }
}

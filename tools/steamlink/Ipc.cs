// SDCoopSteamLink: talking to the Lua mod through small files in the helper's
// folder (Mods\SDCoop\steamlink). Files were chosen over a local socket: UE4SS
// Lua has file IO but no sockets, and files are easy to read in a bug report.
//
// Lua -> helper: one command per file, cmd_<session>_<seq>.txt, written as
//   .tmp and renamed (a new name, so the rename is atomic). The helper reads
//   them in name order and deletes them. Files of another session (an older
//   game run) are ignored and removed after two minutes.
// Helper -> Lua: status.txt and friends.txt, rewritten whole: .tmp then
//   MoveFileEx(REPLACE_EXISTING). If Lua has the file open at that moment the
//   replace fails and is retried on the next write.
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace SDCoopSteamLink
{
    class Ipc
    {
        public readonly string Dir;
        readonly string session;
        static readonly Encoding Utf8 = new UTF8Encoding(false);

        public Ipc(string dir, string session)
        {
            Dir = dir;
            this.session = session ?? "";
        }

        // Session id of a command file name, or null when it is not one.
        public static string SessionOf(string fileName)
        {
            string n = Path.GetFileNameWithoutExtension(fileName);
            if (!n.StartsWith("cmd_", StringComparison.Ordinal)) return null;
            string rest = n.Substring(4);
            int us = rest.LastIndexOf('_');
            return us > 0 ? rest.Substring(0, us) : null;
        }

        public List<string> TakeCommands()
        {
            List<string> lines = new List<string>();
            string[] files;
            try
            {
                files = Directory.GetFiles(Dir, "cmd_*.txt");
            }
            catch (Exception)
            {
                return lines;
            }
            Array.Sort(files, StringComparer.Ordinal);
            foreach (string f in files)
            {
                string s = SessionOf(f);
                if (s == null) continue;
                if (session != "" && s != session)
                {
                    try
                    {
                        if ((DateTime.UtcNow - File.GetLastWriteTimeUtc(f)).TotalSeconds > 120) File.Delete(f);
                    }
                    catch (Exception) { }
                    continue;
                }
                string text = null;
                try
                {
                    text = File.ReadAllText(f, Utf8);
                    File.Delete(f);
                }
                catch (IOException) { continue; }
                catch (UnauthorizedAccessException) { continue; }
                foreach (string raw in text.Split('\n'))
                {
                    string line = raw.Trim();
                    if (line.Length > 0 && line.Length < 2000) lines.Add(line);
                }
            }
            return lines;
        }

        public bool Write(string name, string content)
        {
            string final = Path.Combine(Dir, name);
            string tmp = final + ".tmp";
            try
            {
                File.WriteAllText(tmp, content, Utf8);
            }
            catch (Exception)
            {
                return false;
            }
            return Win.MoveFileExW(tmp, final, Win.MOVEFILE_REPLACE_EXISTING | Win.MOVEFILE_WRITE_THROUGH);
        }

        public void Delete(string name)
        {
            try { File.Delete(Path.Combine(Dir, name)); } catch (Exception) { }
            try { File.Delete(Path.Combine(Dir, name + ".tmp")); } catch (Exception) { }
        }

        // "key=value" tokens of a command line (after the verb).
        public static Dictionary<string, string> Pairs(string[] tokens, int from)
        {
            Dictionary<string, string> d = new Dictionary<string, string>(StringComparer.Ordinal);
            for (int i = from; i < tokens.Length; i++)
            {
                int eq = tokens[i].IndexOf('=');
                if (eq > 0) d[tokens[i].Substring(0, eq)] = tokens[i].Substring(eq + 1);
            }
            return d;
        }

        public static string[] Split(string line)
        {
            return line.Split(new char[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
        }

        // Text without tabs / line breaks (for one field of friends.txt).
        public static string Field(string s)
        {
            if (string.IsNullOrEmpty(s)) return "";
            StringBuilder b = new StringBuilder(s.Length);
            foreach (char c in s) b.Append(c == '\t' || c == '\r' || c == '\n' ? ' ' : c);
            return b.ToString();
        }
    }
}

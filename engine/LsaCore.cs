// LsaCore.cs - decryption core for LSAV Decryptor (batch edition)
//
// Compiled at runtime by engine\lsa-engine.ps1 through Add-Type, so nothing
// has to be installed. Written for C# 5 / .NET Framework 4.x on purpose:
// that is the compiler built into every Windows 10/11 PowerShell 5.1.
//
// MIUI / HyperOS Gallery "Secret Album" scheme:
//   cipher : AES-128-CTR, 128-bit big-endian counter
//   key    : first 16 bytes of the Gallery APK signing certificate (DER)
//   IV     : 11 13 21 23 31 33 41 43 51 53 61 66 67 68 71 72
//   .lsa   : whole file encrypted
//   .lsav  : only the first 1024 bytes encrypted, the rest is plain
//   name   : the file name carries MD5(key) as a 32-hex tag, which lets us
//            check a key without decrypting anything.

using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace LsavDecryptor
{
    public sealed class DecryptResult
    {
        public string Input;
        public string Output;
        public bool Ok;
        public string Error;
        public string Format;      // JPEG, PNG, MP4 ...
        public string Mode;        // "full" or "header"
        public bool Verified;      // file structure checked end to end
        public string KeyHex;
        public bool KeyTagMatched; // MD5 tag in the name matched the key
        public long Bytes;
    }

    public sealed class FoundKey
    {
        public string KeyHex;
        public string Md5;
        public string Source;
    }

    public static class Core
    {
        public static readonly byte[] IV = new byte[] {
            17, 19, 33, 35, 49, 51, 65, 67, 81, 83, 97, 102, 103, 104, 113, 114 };

        public const string DefaultKeyHex = "3082046c30820354a003020102020900";
        public const int VideoHeader = 1024;
        const int Chunk = 1 << 20;

        // ------------------------------------------------------------------
        // Helpers
        // ------------------------------------------------------------------

        public static byte[] FromHex(string hex)
        {
            hex = hex.Trim().Replace(" ", "").Replace(":", "");
            if (hex.Length != 32) throw new ArgumentException("Key must be 32 hex characters (16 bytes): " + hex);
            byte[] b = new byte[16];
            for (int i = 0; i < 16; i++) b[i] = Convert.ToByte(hex.Substring(i * 2, 2), 16);
            return b;
        }

        public static string ToHex(byte[] b)
        {
            StringBuilder sb = new StringBuilder(b.Length * 2);
            foreach (byte x in b) sb.Append(x.ToString("x2"));
            return sb.ToString();
        }

        public static string Md5Hex(byte[] data)
        {
            using (MD5 md5 = MD5.Create()) return ToHex(md5.ComputeHash(data));
        }

        static bool IsHex32(string s)
        {
            if (s == null || s.Length != 32) return false;
            foreach (char c in s)
                if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) return false;
            return true;
        }

        /// <summary>Every 32-hex token in a file name (candidate MD5(key) tags).</summary>
        public static List<string> NameTags(string fileName)
        {
            List<string> tags = new List<string>();
            foreach (string t in Path.GetFileName(fileName).Split(new char[] { '.', '_', '-', ' ' }))
                if (IsHex32(t)) tags.Add(t.ToLowerInvariant());
            return tags;
        }

        // ------------------------------------------------------------------
        // AES-128-CTR keystream with random access (start at any offset)
        // ------------------------------------------------------------------

        public sealed class Ctr : IDisposable
        {
            readonly Aes aes;
            readonly ICryptoTransform ecb;
            readonly byte[] counter = new byte[16];
            byte[] ks = new byte[0];
            int ksPos;

            public Ctr(byte[] key, long offset)
            {
                aes = Aes.Create();
                aes.Mode = CipherMode.ECB;
                aes.Padding = PaddingMode.None;
                aes.Key = key;
                ecb = aes.CreateEncryptor();
                Buffer.BlockCopy(IV, 0, counter, 0, 16);
                AddToCounter(counter, (ulong)(offset / 16));
                int skip = (int)(offset % 16);
                if (skip > 0) { Refill(1); ksPos = skip; }
            }

            static void AddToCounter(byte[] c, ulong n)
            {
                int i = 15;
                ulong carry = n;
                while (carry != 0 && i >= 0)
                {
                    ulong sum = c[i] + (carry & 0xFF);
                    c[i] = (byte)sum;
                    carry = (carry >> 8) + (sum >> 8);
                    i--;
                }
            }

            void Refill(int blocks)
            {
                byte[] input = new byte[blocks * 16];
                for (int i = 0; i < blocks; i++)
                {
                    Buffer.BlockCopy(counter, 0, input, i * 16, 16);
                    AddToCounter(counter, 1);
                }
                if (ks.Length != input.Length) ks = new byte[input.Length];
                int done = 0;
                while (done < input.Length)
                    done += ecb.TransformBlock(input, done, input.Length - done, ks, done);
                ksPos = 0;
            }

            public void Xor(byte[] buf, int off, int len)
            {
                while (len > 0)
                {
                    if (ksPos >= ks.Length) Refill(Math.Min(65536, (len + 15) / 16));
                    int n = Math.Min(len, ks.Length - ksPos);
                    for (int i = 0; i < n; i++) buf[off + i] ^= ks[ksPos + i];
                    ksPos += n; off += n; len -= n;
                }
            }

            public void Dispose() { ecb.Dispose(); aes.Dispose(); }
        }

        /// <summary>Read `count` bytes at `offset` and decrypt the part below encLimit.</summary>
        static byte[] ReadPlain(FileStream fs, byte[] key, long offset, int count, long encLimit)
        {
            if (offset < 0 || offset >= fs.Length) return new byte[0];
            count = (int)Math.Min(count, fs.Length - offset);
            byte[] buf = new byte[count];
            fs.Seek(offset, SeekOrigin.Begin);
            int got = 0;
            while (got < count)
            {
                int n = fs.Read(buf, got, count - got);
                if (n <= 0) break;
                got += n;
            }
            if (offset < encLimit)
            {
                int encLen = (int)Math.Min(count, encLimit - offset);
                using (Ctr c = new Ctr(key, offset)) c.Xor(buf, 0, encLen);
            }
            return buf;
        }

        // ------------------------------------------------------------------
        // Format detection and validation
        // ------------------------------------------------------------------

        static bool Eq(byte[] d, int off, params byte[] sig)
        {
            if (d.Length < off + sig.Length) return false;
            for (int i = 0; i < sig.Length; i++) if (d[off + i] != sig[i]) return false;
            return true;
        }

        static string Ascii(byte[] d, int off, int len)
        {
            if (d.Length < off + len) return "";
            return Encoding.ASCII.GetString(d, off, len);
        }

        /// <summary>Returns "FORMAT|.ext" or null when the bytes are not a known media file.</summary>
        public static string Detect(byte[] h)
        {
            if (Eq(h, 0, 0xFF, 0xD8, 0xFF)) return "JPEG|.jpg";
            if (Eq(h, 0, 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)) return "PNG|.png";
            if (Ascii(h, 0, 6) == "GIF87a" || Ascii(h, 0, 6) == "GIF89a") return "GIF|.gif";
            if (Ascii(h, 0, 4) == "RIFF" && Ascii(h, 8, 4) == "WEBP") return "WEBP|.webp";
            if (Eq(h, 0, 0x1A, 0x45, 0xDF, 0xA3))
                return (Ascii(h, 0, Math.Min(h.Length, 64)).IndexOf("webm", StringComparison.Ordinal) >= 0) ? "WEBM|.webm" : "MKV|.mkv";
            if (Ascii(h, 4, 4) == "ftyp")
            {
                uint size = BE32(h, 0);
                if (size < 8 || size > 4096) return null;
                string brand = Ascii(h, 8, 4);
                switch (brand)
                {
                    case "heic": case "heix": case "hevc": case "hevx": case "heim":
                    case "heis": case "hevm": case "hevs": case "mif1": case "msf1":
                        return "HEIC|.heic";
                    case "avif": case "avis":
                        return "AVIF|.avif";
                    case "qt  ":
                        return "MOV|.mov";
                }
                if (brand.StartsWith("3gp") || brand.StartsWith("3g2")) return "3GP|.3gp";
                return "MP4|.mp4";
            }
            return null;
        }

        static uint BE32(byte[] d, int o)
        {
            return ((uint)d[o] << 24) | ((uint)d[o + 1] << 16) | ((uint)d[o + 2] << 8) | d[o + 3];
        }

        static bool IsBoxType(byte[] d, int o)
        {
            for (int i = 0; i < 4; i++)
            {
                byte c = d[o + i];
                if (!((c >= 0x20 && c <= 0x7E) || c == 0xA9)) return false;
            }
            return true;
        }

        /// <summary>Walk the ISO-BMFF box chain (MP4/MOV/HEIC/3GP) to the end of the file.</summary>
        static bool ValidBoxes(FileStream fs, byte[] key, long encLimit)
        {
            long len = fs.Length, off = 0;
            int boxes = 0;
            while (off < len)
            {
                if (++boxes > 100000) return false;
                if (len - off < 8) return false;
                byte[] h = ReadPlain(fs, key, off, 16, encLimit);
                long size = BE32(h, 0);
                if (!IsBoxType(h, 4)) return false;
                if (size == 0) return true;               // box runs to end of file
                if (size == 1)
                {
                    if (h.Length < 16) return false;
                    size = 0;
                    for (int i = 8; i < 16; i++) size = (size << 8) | h[i];
                    if (size < 16) return false;
                }
                else if (size < 8) return false;
                off += size;
            }
            return off == len;
        }

        // Formats whose check is strong enough to overrule the expected layout.
        static bool StrongCheck(string fmt)
        {
            return fmt == "MP4" || fmt == "MOV" || fmt == "HEIC" || fmt == "AVIF" || fmt == "3GP" || fmt == "PNG";
        }

        static bool ValidTail(FileStream fs, byte[] key, long encLimit, string fmt)
        {
            long len = fs.Length;
            switch (fmt)
            {
                case "JPEG":
                {
                    // EOI marker (FF D9) at the very end, allowing zero padding.
                    byte[] t = ReadPlain(fs, key, Math.Max(0, len - 64), 64, encLimit);
                    int i = t.Length - 1;
                    while (i > 0 && t[i] == 0x00) i--;
                    return i >= 1 && t[i - 1] == 0xFF && t[i] == 0xD9;
                }
                case "PNG":
                {
                    byte[] t = ReadPlain(fs, key, Math.Max(0, len - 64), 64, encLimit);
                    for (int i = 0; i + 8 <= t.Length; i++)
                        if (Eq(t, i, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82)) return true;
                    return false;
                }
                case "GIF":
                {
                    byte[] t = ReadPlain(fs, key, Math.Max(0, len - 16), 16, encLimit);
                    for (int i = t.Length - 1; i >= 0; i--) if (t[i] == 0x3B) return true;
                    return false;
                }
                case "WEBP":
                {
                    byte[] h = ReadPlain(fs, key, 0, 8, encLimit);
                    long riff = LE32(h, 4);
                    return riff + 8 == len || riff + 9 == len;
                }
                case "MP4": case "MOV": case "HEIC": case "AVIF": case "3GP":
                    return ValidBoxes(fs, key, encLimit);
                default:
                    return false;  // MKV/WEBM: no cheap end-to-end check
            }
        }

        // ------------------------------------------------------------------
        // Decrypt one file
        // ------------------------------------------------------------------

        public static DecryptResult DecryptFile(string input, string outDir, IList<string> keyHexes)
        {
            DecryptResult r = new DecryptResult();
            r.Input = input;
            try
            {
                FileInfo fi = new FileInfo(input);
                if (!fi.Exists) throw new IOException("file not found");
                r.Bytes = fi.Length;
                if (fi.Length < 16) throw new IOException("file is too small to be an encrypted photo or video");

                bool isVideo = fi.Extension.Equals(".lsav", StringComparison.OrdinalIgnoreCase);
                List<string> tags = NameTags(fi.Name);

                // Order keys: keys whose MD5 matches the name tag go first.
                List<string> ordered = new List<string>();
                List<string> rest = new List<string>();
                foreach (string k in keyHexes)
                {
                    string kh = k.ToLowerInvariant();
                    if (ordered.Contains(kh) || rest.Contains(kh)) continue;
                    if (tags.Contains(Md5Hex(FromHex(kh)))) ordered.Add(kh); else rest.Add(kh);
                }
                bool anyTagMatch = ordered.Count > 0;
                ordered.AddRange(rest);

                using (FileStream fs = new FileStream(input, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16))
                {
                    byte[] key = null;
                    string fmt = null, ext = null;
                    foreach (string kh in ordered)
                    {
                        byte[] k = FromHex(kh);
                        string d = Detect(ReadPlain(fs, k, 0, 64, long.MaxValue));
                        if (d != null)
                        {
                            key = k; r.KeyHex = kh;
                            fmt = d.Split('|')[0]; ext = d.Split('|')[1];
                            break;
                        }
                    }
                    if (key == null)
                    {
                        if (tags.Count > 0 && !anyTagMatch)
                            throw new IOException("different key (fingerprint " + tags[0] + ")");
                        throw new IOException("no saved key fits this file (tried " + ordered.Count + ")");
                    }
                    r.KeyTagMatched = tags.Contains(Md5Hex(key));
                    r.Format = fmt;

                    // Decide how much of the file is encrypted. Expected: videos=header, photos=full.
                    long preferred = isVideo ? VideoHeader : long.MaxValue;
                    long other = isVideo ? long.MaxValue : VideoHeader;
                    long encLimit = preferred;
                    if (fi.Length <= VideoHeader) r.Verified = ValidTail(fs, key, preferred, fmt);
                    else if (ValidTail(fs, key, preferred, fmt)) r.Verified = true;
                    else if (StrongCheck(fmt) && ValidTail(fs, key, other, fmt)) { r.Verified = true; encLimit = other; }
                    r.Mode = (encLimit == VideoHeader) ? "header" : "full";

                    Directory.CreateDirectory(outDir);
                    string tmp = Path.Combine(outDir, ".lsav-" + Guid.NewGuid().ToString("N") + ".part");
                    try
                    {
                        using (FileStream os = new FileStream(tmp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1 << 16))
                        using (Ctr c = new Ctr(key, 0))
                        {
                            fs.Seek(0, SeekOrigin.Begin);
                            byte[] buf = new byte[Chunk];
                            long pos = 0;
                            int n;
                            while ((n = fs.Read(buf, 0, buf.Length)) > 0)
                            {
                                if (pos < encLimit)
                                {
                                    int encLen = (int)Math.Min(n, encLimit - pos);
                                    c.Xor(buf, 0, encLen);
                                }
                                os.Write(buf, 0, n);
                                pos += n;
                            }
                        }
                        string final = UniquePath(outDir, OutputStem(fi.Name), ext);
                        File.Move(tmp, final);
                        try { File.SetLastWriteTimeUtc(final, fi.LastWriteTimeUtc); } catch { }
                        r.Output = final;
                        r.Ok = true;
                    }
                    finally
                    {
                        if (File.Exists(tmp)) try { File.Delete(tmp); } catch { }
                    }
                }
            }
            catch (Exception e)
            {
                r.Ok = false;
                r.Error = e.Message;
            }
            return r;
        }

        static readonly string[] MediaExts = { "jpg", "jpeg", "png", "gif", "webp", "heic", "heif",
            "mp4", "mov", "3gp", "mkv", "webm", "avif", "dng", "lsa", "lsav" };

        /// <summary>Clean base name: drop the key tag and media extensions; keep the rest.</summary>
        public static string OutputStem(string fileName)
        {
            string name = Path.GetFileName(fileName);
            List<string> parts = new List<string>(name.Split('.'));
            while (parts.Count > 1 && Array.IndexOf(MediaExts, parts[parts.Count - 1].ToLowerInvariant()) >= 0)
                parts.RemoveAt(parts.Count - 1);
            List<string> kept = new List<string>();
            foreach (string p in parts) if (!IsHex32(p)) kept.Add(p);
            string stem = string.Join(".", kept.ToArray()).Trim();
            if (stem.Length == 0) stem = string.Join(".", parts.ToArray());   // name was only a hash: keep it
            foreach (char bad in Path.GetInvalidFileNameChars()) stem = stem.Replace(bad, '_');
            return stem.Length == 0 ? "file" : stem;
        }

        public static string UniquePath(string dir, string stem, string ext)
        {
            string p = Path.Combine(dir, stem + ext);
            int n = 1;
            while (File.Exists(p)) { p = Path.Combine(dir, stem + " (" + n + ")" + ext); n++; }
            return p;
        }

        // ------------------------------------------------------------------
        // Key extraction from a Gallery APK (v1 JAR signature, v2/v3 block)
        // ------------------------------------------------------------------

        public static List<FoundKey> KeysFromApk(string apkPath)
        {
            List<FoundKey> found = new List<FoundKey>();
            List<string> seen = new List<string>();
            byte[] apk = File.ReadAllBytes(apkPath);
            int eocd = -1;
            for (int i = apk.Length - 22; i >= Math.Max(0, apk.Length - 65557); i--)
                if (apk[i] == 0x50 && apk[i + 1] == 0x4B && apk[i + 2] == 0x05 && apk[i + 3] == 0x06) { eocd = i; break; }
            if (eocd < 0) throw new IOException("not a valid APK/ZIP file");
            int cdCount = LE16(apk, eocd + 10);
            long cdOffset = LE32(apk, eocd + 16);

            // v2 / v3 / v3.1 APK Signature Scheme block
            try
            {
                if (cdOffset >= 24 && Encoding.ASCII.GetString(apk, (int)cdOffset - 16, 16) == "APK Sig Block 42")
                {
                    long blockSize = LE64(apk, (int)cdOffset - 24);
                    long start = cdOffset - blockSize - 8;
                    long p = start + 8, end = cdOffset - 24;
                    while (p + 12 <= end)
                    {
                        long pairLen = LE64(apk, (int)p);
                        uint id = (uint)LE32(apk, (int)p + 8);
                        int val = (int)p + 12;
                        string scheme = null;
                        if (id == 0x7109871a) scheme = "APK v2 signature";
                        else if (id == 0xf05368c0) scheme = "APK v3 signature";
                        else if (id == 0x1b93ad61) scheme = "APK v3.1 signature";
                        if (scheme != null)
                        {
                            // signers[0] -> signed data -> digests, certificates[0]
                            int q = val + 4;            // signers sequence length
                            q += 4;                     // signer length
                            q += 4;                     // signed data length
                            int digestsLen = (int)LE32(apk, q); q += 4 + digestsLen;
                            q += 4;                     // certificates sequence length
                            int certLen = (int)LE32(apk, q); q += 4;
                            byte[] cert = new byte[certLen];
                            Buffer.BlockCopy(apk, q, cert, 0, certLen);
                            AddCert(found, seen, cert, scheme);
                        }
                        p += 8 + pairLen;
                    }
                }
            }
            catch { /* fall through to v1 */ }

            // v1 JAR signature: META-INF/*.RSA|.DSA|.EC (PKCS#7)
            int c = (int)cdOffset;
            for (int e = 0; e < cdCount && c + 46 <= apk.Length; e++)
            {
                if (LE32(apk, c) != 0x02014b50) break;
                int method = LE16(apk, c + 10);
                int csize = (int)LE32(apk, c + 20);
                int nlen = LE16(apk, c + 28), xlen = LE16(apk, c + 30), klen = LE16(apk, c + 32);
                int local = (int)LE32(apk, c + 42);
                string name = Encoding.UTF8.GetString(apk, c + 46, nlen);
                c += 46 + nlen + xlen + klen;
                string up = name.ToUpperInvariant();
                if (!up.StartsWith("META-INF/") || !(up.EndsWith(".RSA") || up.EndsWith(".DSA") || up.EndsWith(".EC"))) continue;
                try
                {
                    int lnlen = LE16(apk, local + 26), lxlen = LE16(apk, local + 28);
                    int dataStart = local + 30 + lnlen + lxlen;
                    byte[] raw = new byte[csize];
                    Buffer.BlockCopy(apk, dataStart, raw, 0, csize);
                    byte[] pkcs7 = raw;
                    if (method == 8)
                        using (DeflateStream ds = new DeflateStream(new MemoryStream(raw), CompressionMode.Decompress))
                        using (MemoryStream ms = new MemoryStream()) { ds.CopyTo(ms); pkcs7 = ms.ToArray(); }
                    byte[] cert = FirstCertFromPkcs7(pkcs7);
                    if (cert != null) AddCert(found, seen, cert, "APK v1 signature (" + name + ")");
                }
                catch { }
            }
            return found;
        }

        static void AddCert(List<FoundKey> found, List<string> seen, byte[] cert, string source)
        {
            if (cert.Length < 16) return;
            byte[] k = new byte[16];
            Buffer.BlockCopy(cert, 0, k, 0, 16);
            string hex = ToHex(k);
            if (seen.Contains(hex)) return;
            seen.Add(hex);
            FoundKey f = new FoundKey();
            f.KeyHex = hex; f.Md5 = Md5Hex(k); f.Source = source;
            found.Add(f);
        }

        // Minimal DER walk: ContentInfo -> [0] -> SignedData -> certificates [0] -> first cert
        static byte[] FirstCertFromPkcs7(byte[] d)
        {
            int p = 0, len;
            if (!Tlv(d, ref p, 0x30, out len)) return null;          // ContentInfo
            int hl; int oidLen;
            if (!Tlv(d, ref p, 0x06, out oidLen)) return null; p += oidLen;
            if (!Tlv(d, ref p, 0xA0, out len)) return null;          // [0] explicit
            if (!Tlv(d, ref p, 0x30, out len)) return null;          // SignedData
            int end = p + len;
            if (!Tlv(d, ref p, 0x02, out len)) return null; p += len; // version
            if (!Tlv(d, ref p, 0x31, out len)) return null; p += len; // digestAlgorithms
            if (!Tlv(d, ref p, 0x30, out len)) return null; p += len; // encapContentInfo
            if (p >= end || d[p] != 0xA0) return null;
            if (!Tlv(d, ref p, 0xA0, out len)) return null;          // certificates
            int certStart = p;
            if (!Tlv(d, ref p, 0x30, out len)) return null;
            hl = p - certStart;
            byte[] cert = new byte[hl + len];
            Buffer.BlockCopy(d, certStart, cert, 0, cert.Length);
            return cert;
        }

        static bool Tlv(byte[] d, ref int p, byte tag, out int len)
        {
            len = 0;
            if (p + 2 > d.Length || d[p] != tag) return false;
            p++;
            int b = d[p++];
            if (b < 0x80) { len = b; return true; }
            int n = b & 0x7F;
            if (n == 0 || n > 4 || p + n > d.Length) return false;
            for (int i = 0; i < n; i++) len = (len << 8) | d[p++];
            return len >= 0;
        }

        static int LE16(byte[] d, int o) { return d[o] | (d[o + 1] << 8); }
        static long LE32(byte[] d, int o) { return (uint)(d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (d[o + 3] << 24)); }
        static long LE64(byte[] d, int o) { return (long)((ulong)LE32(d, o) | ((ulong)LE32(d, o + 4) << 32)); }

        // ------------------------------------------------------------------
        // Deep key search: recover a certificate-shaped key from its MD5 tag
        //
        // A DER X.509 v3 certificate always starts:
        //   30 82 [certLen:2] 30 82 [tbsLen:2] A0 03 02 01 02 02 [serialLen] [serial0]
        // so the 16-byte key has only four unknowns. certLen - tbsLen is fixed
        // by the signature algorithm and key size, which keeps the space small.
        // ------------------------------------------------------------------

        static uint[] T = BuildT();
        static uint[] BuildT()
        {
            uint[] t = new uint[64];
            for (int i = 0; i < 64; i++) t[i] = (uint)(long)Math.Floor(Math.Abs(Math.Sin(i + 1)) * 4294967296.0);
            return t;
        }
        static readonly int[] S = {
            7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
            5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
            4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
            6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21 };

        /// <summary>MD5 of exactly 16 bytes given as four little-endian words. Returns the four state words.</summary>
        static void Md5Of16(uint[] m, uint w0, uint w1, uint w2, uint w3, out uint ra, out uint rb, out uint rc, out uint rd)
        {
            m[0] = w0; m[1] = w1; m[2] = w2; m[3] = w3; m[4] = 0x80; m[14] = 128;
            uint a = 0x67452301, b = 0xefcdab89, c = 0x98badcfe, d = 0x10325476;
            for (int i = 0; i < 64; i++)
            {
                uint f; int g;
                if (i < 16) { f = (b & c) | (~b & d); g = i; }
                else if (i < 32) { f = (d & b) | (~d & c); g = (5 * i + 1) & 15; }
                else if (i < 48) { f = b ^ c ^ d; g = (3 * i + 5) & 15; }
                else { f = c ^ (b | ~d); g = (7 * i) & 15; }
                uint tmp = d; d = c; c = b;
                uint x = a + f + T[i] + m[g];
                b = b + ((x << S[i]) | (x >> (32 - S[i])));
                a = tmp;
            }
            ra = a + 0x67452301; rb = b + 0xefcdab89; rc = c + 0x98badcfe; rd = d + 0x10325476;
        }

        public static string Md5Of16Hex(byte[] k)
        {
            uint a, b, c, d;
            Md5Of16(new uint[16], W(k, 0), W(k, 4), W(k, 8), W(k, 12), out a, out b, out c, out d);
            byte[] o = new byte[16];
            PutW(o, 0, a); PutW(o, 4, b); PutW(o, 8, c); PutW(o, 12, d);
            return ToHex(o);
        }
        static uint W(byte[] k, int o) { return (uint)(k[o] | (k[o + 1] << 8) | (k[o + 2] << 16) | (k[o + 3] << 24)); }
        static void PutW(byte[] o, int i, uint v) { o[i] = (byte)v; o[i + 1] = (byte)(v >> 8); o[i + 2] = (byte)(v >> 16); o[i + 3] = (byte)(v >> 24); }

        /// <summary>
        /// Search cert lengths [certFrom, certTo) with the given certLen-tbsLen gaps.
        /// Returns "keyhex|md5" lines for every tag that was cracked.
        /// </summary>
        public static string[] SearchKeys(string[] md5Tags, int certFrom, int certTo, int[] gaps)
        {
            int nt = md5Tags.Length;
            uint[] ta = new uint[nt], tb = new uint[nt], tc = new uint[nt], td = new uint[nt];
            for (int i = 0; i < nt; i++)
            {
                byte[] h = new byte[16];
                for (int j = 0; j < 16; j++) h[j] = Convert.ToByte(md5Tags[i].Substring(j * 2, 2), 16);
                ta[i] = W(h, 0); tb[i] = W(h, 4); tc[i] = W(h, 8); td[i] = W(h, 12);
            }
            List<string> hits = new List<string>();
            object gate = new object();
            const uint w2 = 0x010203A0;              // A0 03 02 01

            Parallel.For(certFrom, certTo, delegate (int certLen)
            {
                uint[] m = new uint[16];
                uint w0 = 0x00008230u | ((uint)(certLen >> 8) << 16) | ((uint)(certLen & 0xFF) << 24);
                foreach (int gap in gaps)
                {
                    int tbs = certLen - gap;
                    if (tbs < 256 || tbs > 0xFFFF) continue;
                    uint w1 = 0x00008230u | ((uint)(tbs >> 8) << 16) | ((uint)(tbs & 0xFF) << 24);
                    for (int sl = 1; sl <= 21; sl++)
                        for (int s0 = 0; s0 < 256; s0++)
                        {
                            uint w3 = 0x00000202u | ((uint)sl << 16) | ((uint)s0 << 24);
                            uint a, b, c, d;
                            Md5Of16(m, w0, w1, w2, w3, out a, out b, out c, out d);
                            for (int i = 0; i < nt; i++)
                                if (a == ta[i] && b == tb[i] && c == tc[i] && d == td[i])
                                {
                                    byte[] k = new byte[16];
                                    PutW(k, 0, w0); PutW(k, 4, w1); PutW(k, 8, w2); PutW(k, 12, w3);
                                    lock (gate) hits.Add(ToHex(k) + "|" + md5Tags[i]);
                                }
                        }
                }
            });
            return hits.ToArray();
        }
    }
}

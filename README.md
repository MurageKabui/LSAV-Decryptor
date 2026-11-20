# LSAV Decryptor (batch edition)

Recover the photos (`.lsa`) and videos (`.lsav`) that Xiaomi, Redmi and POCO phones lock away in the Gallery **Secret Album** (MIUI 12 to HyperOS). It's free, works offline, and you just double-click it. There's nothing to install except ADB, and the tool can download ADB for you from Google.

```
  ┌──────────────────────────────────────────────────────────────┐
  │  LSAV DECRYPTOR                                      v1.1.0  │
  │  Recover MIUI / HyperOS Secret Album photos and videos       │
  │  Free  .  offline  .  nothing leaves your PC                 │
  ├──────────────────────────────────────────────────────────────┤
  │  Guide   blog.denniskabui.com/writing/decrypting-miui-cloud  │
  │  Source  github.com/MurageKabui/LSAV-Decryptor               │
  └──────────────────────────────────────────────────────────────┘
     Main menu

     1   Decrypt .lsa / .lsav files that are on this PC
     2   Scan a phone over ADB, pull the files and decrypt
     3   Key tools
     4   Open the decrypted folder
     G   Open the guide and source code in your browser
     H   How to turn on USB debugging
     Q   Quit
```

Full guide: [blog.denniskabui.com/writing/decrypting-miui-cloud](https://blog.denniskabui.com/writing/decrypting-miui-cloud)  
Source and downloads: [github.com/MurageKabui/LSAV-Decryptor](https://github.com/MurageKabui/LSAV-Decryptor)

---

## What it does

- **Decrypts files you already have.** Paste or drag in one file, or a folder. Subfolders are searched too.
- **Finds the files on the phone for you.** Over ADB it searches internal storage and the SD card for every `.lsa` / `.lsav` file and shows where they are and how big they are. You can copy and decrypt all of them, or only the ones you pick by number, range, type or folder.
- **Checks the key before it decrypts.** Every encrypted file name contains the MD5 fingerprint of the key that encrypted it. The tool compares that fingerprint with its keys first, so it never saves garbage output from a wrong key.
- **Gets the right key when the built-in one doesn't fit.** It can pull the Gallery app from the phone and read the key from its signing certificate. It can also rebuild the key from the fingerprint in the file names, offline.
- **Verifies every output.** It walks the MP4/MOV/HEIC box structure to the last byte and checks the JPEG, PNG and GIF end markers. If a video turns out to be fully encrypted instead of header-only, it notices and switches.
- **Keeps your outputs safe.** It never overwrites a file. Output is written to a temporary file and renamed only when it's complete. Files keep the original date.
- **Can resume.** Run it again on the same folder and the files that already worked are skipped. After you add a key, *Retry* decrypts only the files that failed.

---

## Requirements and dependencies

| Dependency | Needed for | Where it comes from |
|---|---|---|
| **Windows 10 or 11** | Everything | Windows 7 and 8 are not supported. Windows 10/11 in S mode can't run scripts at all. |
| **Windows PowerShell 5.1** | The decryption engine | Built into Windows 10/11 (`powershell.exe`). Nothing to install. |
| **.NET Framework 4.x** | Compiles the engine in memory on each run | Built into Windows 10/11 |
| **`cmd.exe`, `choice.exe`, `where.exe`, `explorer.exe`** | The menus | Built into Windows |
| **ADB** (Android SDK Platform-Tools) | Option 2 (scan a phone) and extracting a key from a phone | If ADB isn't on your `PATH`, the tool offers to download Google's official package (about 7 MB) into `tools\platform-tools\`. Manual download: <https://developer.android.com/tools/releases/platform-tools> |
| **USB driver for the phone** | Option 2 | Usually installed by Windows automatically. If the phone doesn't show up: [Google USB Driver](https://developer.android.com/studio/run/win-usb) or the Xiaomi USB driver. |
| **A USB data cable** | Option 2 | Charge-only cables won't work |
| **Internet** | Only the one-time ADB download | Decryption is fully offline |
| **Free disk space** | Pull + decrypt | About twice the size of the files. The scan screen warns you if there isn't enough. |

There's no Python, no pip, no Node, no installer and no admin rights needed.

---

## Quick start

1. Put the folder anywhere, for example `D:\Projects\lsav-decryptor-batch`.
2. Double-click **`LSAV-Decryptor.bat`**.
3. Press **1** if you already copied the files to your PC, or **2** to get them straight from the phone.

Every menu is a single keypress. You never need to type a command.

---

## The flow, screen by screen

```
LSAV-Decryptor.bat
│
├── 1  Decrypt files on this PC
│      └─ Paste or drag a file or folder ─▶ decrypt ─▶ result screen
│
├── 2  Scan a phone over ADB
│      ├─ ADB missing? ─▶ offer to download it from Google
│      ├─ Choose a phone  (number keys; R refresh, H help, B back)
│      │     shows name, Android version, serial and status:
│      │     ready / tap Allow on the phone / offline
│      ├─ Scan  ─▶ summary by folder: count, photos, videos, size
│      │     A  Pull all and decrypt   (recommended)
│      │     P  Pull all only
│      │     L  Pick specific files  (numbered list, then type 3-12, videos, -DCIM ...)
│      │     S  Scan again
│      └─ Pull (progress bar) ─▶ decrypt ─▶ result screen
│
├── 3  Key tools
│      ├─ 1  Extract the key from a connected phone
│      ├─ 2  Extract the key from a Gallery APK on this PC
│      ├─ 3  Deep key search (offline, from file names)
│      ├─ 4  Show saved keys
│      └─ R  Retry the files that failed   (after a failed run)
│
├── 4  Open the decrypted folder
├── G  Open the guide and the GitHub page
└── H  How to turn on USB debugging
```

### Option 1: decrypt files on this PC

You'll see a prompt: **Path :**. Drag the `.lsa`/`.lsav` file, or the folder holding them, onto the window and press **Enter**. The tool:

1. finds every `.lsa`/`.lsav` file, subfolders included;
2. picks the right key for each file (fingerprint first, then magic bytes);
3. decrypts the file, checks the structure, and saves it with the right extension;
4. shows one line per file, then the totals, then **where the files are**.

The result screen gives you **O** (open the folder), **M** (main menu) and, if something failed, **K** (Key tools) and **R** (retry).

### Option 2: scan a phone over ADB

1. Turn on USB debugging (press **H** in the tool for the steps), plug the phone in and tap **Allow** on the phone.
2. Press **2**. The phones connected to the PC are listed with a number. Press that number.
3. The tool searches `/sdcard` and any SD card for `.lsa` and `.lsav` files and shows a summary grouped by folder.
4. Press **A** for everything, or **L** to pick specific files (see below). Every chosen file is copied into `pulled\<serial>_<date>\`, keeping the phone's folder structure, with a live progress bar. Then they're all decrypted into `decrypted\<serial>_<date>\`.
5. The result screen tells you exactly where your photos and videos are.

Nothing on the phone is changed or deleted. The tool only reads.

### Picking specific files

Press **L** on the scan screen. You'll see every file with a number, its size and whether it's a photo or a video. Then you type which ones you want:

| Type | Selects |
|---|---|
| `7` | file 7 |
| `3-12` | files 3 to 12 |
| `1,4,9-12` | several (commas or spaces) |
| `photos` / `videos` / `all` | by type, or everything |
| `secretAlbum` | every file whose path contains that text (any case) |
| `-5`, `-DCIM` | a minus leaves files out: `videos -DCIM`, `all -3-8` |

The tool shows how many files you picked and their total size. Then press **A** to pull and decrypt them, **P** to pull only, or **C** to change the selection. Numbers stay the same between scans of the same phone because the list is sorted by path.

---

## Folder layout

```
lsav-decryptor-batch\
├── LSAV-Decryptor.bat      ← double-click this
├── keys.txt                ← extra keys (the default key is built in)
├── README.md
├── engine\
│   ├── lsa-engine.ps1      ← worker the .bat calls (PowerShell 5.1)
│   └── LsaCore.cs          ← AES-CTR core, compiled in memory on each run
│
│   created when needed:
├── pulled\<serial>_<date>\     encrypted copies from the phone (folders mirrored)
├── decrypted\pc_<date>\        output of option 1
├── decrypted\<serial>_<date>\  output of option 2
│     └── decryption-report.txt   one line per file: source, output, format, key
└── tools\
    ├── platform-tools\     ADB, if downloaded by the tool
    └── gallery-apk\        Gallery app copied from the phone for key extraction
```

Temporary files go to `%TEMP%\lsav-decryptor\`.

### Output names

`IMG_20240101_101010.3e751332435bfad27569ca4efed1b602.lsa` becomes `IMG_20240101_101010.jpg`: the key fingerprint is removed and the real extension is added. If a name is already taken, the new file gets ` (1)`, ` (2)` and so on. Nothing is ever overwritten.

Supported outputs: **JPEG, PNG, GIF, WEBP, HEIC, AVIF, MP4, MOV, 3GP, MKV, WEBM**.

---

## Where the files live on the phone

Usually:

```
Internal storage/MIUI/Gallery/cloud/secretAlbum/
```

Option 2 doesn't rely on that path. It searches all of internal storage and the SD card, so it also finds copies people have moved elsewhere.

---

## How the decryption works

| | |
|---|---|
| Cipher | AES-128 in CTR mode, with a 128-bit big-endian counter |
| Key | The first 16 bytes of the Gallery APK's signing certificate (DER). Default (Global build): `3082046c30820354a003020102020900` |
| IV / initial counter | `11 13 21 23 31 33 41 43 51 53 61 66 67 68 71 72` |
| `.lsa` (photos) | The whole file is encrypted |
| `.lsav` (videos) | Only the first 1024 bytes are encrypted. The rest is plain. |
| File name | Contains `MD5(key)` as a 32-hex tag. For the default key that's `3e751332435bfad27569ca4efed1b602`. |

What the engine does with each file:

1. **Picks a key.** Keys whose MD5 matches the tag in the file name are tried first. A key is accepted only if the first decrypted bytes form a real media header.
2. **Picks the layout.** Photos are expected to be fully encrypted and videos header-only. The engine checks that the whole file parses (MP4 box chain, PNG `IEND`, JPEG `FFD9`, and so on). For MP4-family and PNG files it tries the other layout if the expected one doesn't parse. Files that decrypt but can't be checked end to end are marked **unverified**.
3. **Streams the file** in 1 MB chunks, so a 4 GB video uses as little memory as a photo. It writes to a `.part` file, then renames it.

### Why the key can be rebuilt from a file name

A DER X.509 v3 certificate always starts with:

```
30 82 [cert length] 30 82 [tbs length] A0 03 02 01 02 02 [serial length] [first serial byte]
```

The 16-byte key therefore has only four unknowns. The gap between the two lengths is fixed by the signature type (for example, 280 bytes for RSA-2048 with SHA-1/256). The tool runs MD5 over every certificate-shaped candidate on all CPU cores until one matches the fingerprint in the file name. The quick search covers the RSA 1024/2048/3072/4096 certificates Android uses and takes seconds. The extended search adds EC and DSA certificates.

---

## Key tools, in detail

| Option | Use it when | What it does |
|---|---|---|
| **1 Extract from a phone** | You have the phone the files came from | Runs `pm path com.miui.gallery`, copies the Gallery APK to `tools\gallery-apk\`, reads its v1/v2/v3 signing certificates, and saves new keys to `keys.txt`. It also tells you how many of your files each key unlocks. |
| **2 Extract from an APK** | You have a Gallery APK file | Does the same, from a file you point to |
| **3 Deep key search** | You only have the encrypted files | Rebuilds the key from the fingerprint in the file names, offline, and saves it to `keys.txt` |
| **4 Show saved keys** | Checking | Lists each key with its fingerprint |

You can also add keys by hand to `keys.txt`, one per line (32 hex characters). Text after `#` is a comment.

---

## Troubleshooting

| What you see | What to do |
|---|---|
| **No phone found** | Unlock the phone, use a data cable, and tap **Allow** on the "Allow USB debugging?" prompt. Set the USB mode to **File transfer**. Press **R** to refresh. |
| **"tap Allow on the phone"** | The phone hasn't trusted this PC yet. Unlock it and tap **Allow**. If no prompt appears, go to Developer options → *Revoke USB debugging authorizations* and replug. |
| **"offline"** | Replug the cable, or run `adb kill-server` and refresh. |
| **No files found on the phone** | Open the Secret Album once on the phone and scan again. Some Gallery versions keep it in private app storage, which ADB can't read without root. |
| **FAIL "different key (fingerprint …)"** | The file came from another Gallery build. Use **Key tools → 1** (from the phone) or **→ 3** (deep search), then **R** to retry. |
| **FAIL "no saved key fits this file"** | The name has no fingerprint and no saved key works. Extract the key from the phone that made the file. |
| **"unverified"** | The file decrypted, but its format has no end-to-end check (e.g. MKV), or the file has extra data appended (e.g. motion photos). Open it to confirm. |
| **"The decryption engine could not start"** | PowerShell is locked down on this PC (Constrained Language Mode, usually from a work or school policy). Use a personal PC. |
| **Colours show as odd characters** | The legacy console is turned on (console Properties > "Use legacy console"). Turn it off, or use Windows Terminal. |
| **Window turned black** | That's intentional. The tool sets a black background with bright text so it's readable in every terminal theme, and puts your colours back when you quit with **Q**. |
| **ADB download failed** | Download Platform-Tools by hand and unzip it so `tools\platform-tools\adb.exe` exists, or put `adb.exe` on your `PATH`. |
| **Deep search finds nothing** | The key isn't certificate-based. This can happen if the files were encrypted with per-file keys from Xiaomi Cloud, which are stored in the Gallery's private database. Extract from the phone instead. |

When you're done, turn **USB debugging** off again.

---

## Privacy and safety

- Decryption runs on your PC. Nothing is uploaded, and the only network access is the optional ADB download from `dl.google.com`.
- The tool only **reads** from the phone. It runs `getprop`, a `find` scan, `pm path` and `adb pull`. It never writes to, deletes from or changes the phone.
- It's meant for recovering **your own** photos and videos from **your own** device. It doesn't unlock phones or bypass any password. It decrypts files you already have access to.

---

## FAQ

**Do I need Python?** No. The engine is PowerShell plus a small C# file that Windows compiles in memory.

**Does the phone need to be rooted?** No.

**Does the phone need to stay connected while decrypting?** Only during the scan and the pull. Decryption runs on the copies in `pulled\`.

**Can I run it from a USB stick?** Yes. Everything it creates stays next to the `.bat`.

**Is the output identical to the original?** Yes, bit for bit. Nothing is re-encoded.

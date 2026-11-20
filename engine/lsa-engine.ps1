<#
  lsa-engine.ps1 - worker behind LSAV-Decryptor.bat

  Runs on the Windows PowerShell 5.1 that ships with Windows 10/11.
  Nothing to install: the C# core (LsaCore.cs) is compiled in memory.
  This file is plain ASCII on purpose (PowerShell 5.1 reads BOM-less
  scripts as ANSI).

  Actions
    Decrypt      -InputPath <file|folder> -OutDir <dir> [-KeysFile]
    ScanSummary  -ListFile <scan.txt> [-OutDir <root for free-space check>] [-Full] [-Device <name>]
    NormalizeList -ListFile <scan.txt>       sort + de-duplicate in place
    Scan         -Adb <adb.exe> -Serial <id> -ListFile <scan.txt>   live timer while the phone is searched
    Pull         -Adb <adb.exe> -Serial <id> -ListFile <list> -OutDir <dir>   copy with a progress bar
    Select       -ListFile <scan.txt> -InputPath <selection.txt> -OutDir <selected.txt>
    ExtractKey   -Apk <file.apk> [-KeysFile] [-Compare <folder|file|scan list>]
    FindKey      -InputPath <folder|file|scan list> [-KeysFile] [-Extended]
    ListKeys     [-KeysFile]
    GetAdb       -Dest <tools dir>
    Stamp

  Exit codes
    0 ok | 1 some files failed | 2 nothing to do / not found | 3 all failed
    4 key not found | 5 no certificate in APK | 6 download failed | 9 engine error
#>
param(
    [Parameter(Mandatory = $true)][string]$Action,
    [string]$InputPath,
    [string]$OutDir,
    [string]$KeysFile,
    [string]$ListFile,
    [string]$Apk,
    [string]$Dest,
    [string]$Compare,
    [string]$Device,
    [string]$Adb,
    [string]$Serial,
    [switch]$Full,
    [switch]$Extended
)

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$DefaultKey = '3082046c30820354a003020102020900'

# ---------------------------------------------------------------- output helpers
$HL = [string][char]0x2500
$BlockFull = [string][char]0x2588
$BlockLight = [string][char]0x2591

function W([string]$t, [string]$c = 'White') { Write-Host $t -ForegroundColor $c -NoNewline }
function WL([string]$t = '', [string]$c = 'White') { Write-Host $t -ForegroundColor $c }
function Rule { WL ('   ' + ($HL * 66)) 'Gray' }
function Fit([string]$t, [int]$n) {
    if ($t.Length -le $n) { return $t.PadRight($n) }
    return $t.Substring(0, $n - 3) + '...'
}
function FitPath([string]$t, [int]$n) {
    if ($t.Length -le $n) { return $t.PadRight($n) }
    return '...' + $t.Substring($t.Length - ($n - 3))
}
function Size([double]$b) {
    if ($b -lt 1024) { return ('{0} B' -f $b) }
    if ($b -lt 1MB) { return ('{0:0.0} KB' -f ($b / 1KB)) }
    if ($b -lt 1GB) { return ('{0:0.0} MB' -f ($b / 1MB)) }
    return ('{0:0.00} GB' -f ($b / 1GB))
}
function Bar([double]$frac, [int]$width = 28) {
    if ($frac -lt 0) { $frac = 0 }; if ($frac -gt 1) { $frac = 1 }
    $n = [int][math]::Floor($frac * $width)
    return ($BlockFull * $n) + ($BlockLight * ($width - $n))
}

# ---------------------------------------------------------------- core loading
function Load-Core {
    if ('LsavDecryptor.Core' -as [type]) { return }
    $src = [IO.File]::ReadAllText((Join-Path $Here 'LsaCore.cs'))
    try {
        if ($PSVersionTable.PSEdition -eq 'Core') {
            Add-Type -TypeDefinition $src -Language CSharp -IgnoreWarnings -WarningAction SilentlyContinue
        } else {
            Add-Type -TypeDefinition $src -Language CSharp -ReferencedAssemblies 'System.Core' -IgnoreWarnings -WarningAction SilentlyContinue
        }
    } catch {
        WL '   The decryption engine could not start on this PC.' 'Red'
        WL ('   ' + $_.Exception.Message) 'Gray'
        if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
            WL '   PowerShell is locked down here (Constrained Language Mode, usually set by an' 'Yellow'
            WL '   employer or school). Run the tool on a personal PC.' 'Yellow'
        }
        exit 9
    }
}

# ---------------------------------------------------------------- keys
function Get-KeyList {
    $keys = New-Object System.Collections.Generic.List[string]
    if ($KeysFile -and (Test-Path -LiteralPath $KeysFile)) {
        foreach ($line in [IO.File]::ReadAllLines($KeysFile)) {
            $t = ($line -replace '#.*$', '').Trim() -replace '[\s:]', ''
            if ($t -match '^[0-9a-fA-F]{32}$' -and -not $keys.Contains($t.ToLower())) { $keys.Add($t.ToLower()) }
        }
    }
    if (-not $keys.Contains($DefaultKey)) { $keys.Add($DefaultKey) }
    return , $keys
}

function Save-Key([string]$hex, [string]$note) {
    if (-not $KeysFile) { return $false }
    $known = Get-KeyList
    if ($known.Contains($hex.ToLower())) { return $false }
    $line = '{0}    # {1}, added {2:yyyy-MM-dd}' -f $hex.ToLower(), $note, (Get-Date)
    $prefix = ''
    if ((Test-Path -LiteralPath $KeysFile) -and (Get-Item -LiteralPath $KeysFile).Length -gt 0) {
        $raw = [IO.File]::ReadAllText($KeysFile)
        if (-not $raw.EndsWith("`n")) { $prefix = "`r`n" }
    }
    [IO.File]::AppendAllText($KeysFile, $prefix + $line + "`r`n")
    return $true
}

function Get-Tags([string]$path) {
    # MD5(key) fingerprints from file names in a folder, a file, or an ADB scan list
    $tags = @{}
    $names = @()
    if (Test-Path -LiteralPath $path -PathType Container) {
        $names = Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -eq '.lsa' -or $_.Extension -eq '.lsav' } | ForEach-Object { $_.Name }
    } elseif ($path -match '\.(lsa|lsav)$') {
        $names = @([IO.Path]::GetFileName($path))
    } elseif (Test-Path -LiteralPath $path) {
        $names = [IO.File]::ReadAllLines($path) | ForEach-Object { ($_ -split '\|')[-1] } |
            Where-Object { $_ -match '\.(lsa|lsav)$' } | ForEach-Object { ($_ -split '/')[-1] }
    }
    foreach ($n in $names) {
        foreach ($t in [LsavDecryptor.Core]::NameTags($n)) {
            if ($tags.ContainsKey($t)) { $tags[$t]++ } else { $tags[$t] = 1 }
        }
    }
    return $tags
}

# ================================================================ Decrypt
function Invoke-Decrypt {
    if (-not $InputPath -or -not (Test-Path -LiteralPath $InputPath)) {
        WL '   That path does not exist.' 'Red'; exit 2
    }
    Load-Core
    $item = Get-Item -LiteralPath $InputPath
    if ($item.PSIsContainer) {
        $files = @(Get-ChildItem -LiteralPath $item.FullName -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -eq '.lsa' -or $_.Extension -eq '.lsav' } | Sort-Object FullName)
    } elseif ($item.Extension -eq '.lsa' -or $item.Extension -eq '.lsav') {
        $files = @($item)
    } else {
        WL ('   "{0}" is not a .lsa or .lsav file.' -f $item.Name) 'Red'; exit 2
    }
    if ($files.Count -eq 0) {
        WL '   No .lsa or .lsav files were found there (subfolders included).' 'Yellow'; exit 2
    }

    $keys = Get-KeyList
    $photos = @($files | Where-Object { $_.Extension -eq '.lsa' }).Count
    $videos = $files.Count - $photos
    $total = ($files | Measure-Object -Property Length -Sum).Sum

    $manifest = Join-Path $OutDir '.lsav-done'
    $done = @{}
    if (Test-Path -LiteralPath $manifest) {
        foreach ($l in [IO.File]::ReadAllLines($manifest)) { if ($l) { $done[$l] = $true } }
    }

    WL ''
    W '   Files  '; W ("$($files.Count)") 'White'; W ("   ($photos photos, $videos videos, " + (Size $total) + ')') 'Gray'
    W '      Keys  '; WL ("$($keys.Count)") 'White'
    Rule

    $ok = 0; $fail = 0; $skip = 0; $unverified = 0
    $foreign = @{}
    $report = New-Object System.Collections.Generic.List[string]
    $width = ("$($files.Count)").Length
    $i = 0
    foreach ($f in $files) {
        $i++
        $num = ('[{0}/{1}]' -f ("$i").PadLeft($width), $files.Count)
        if ($done.ContainsKey($f.FullName)) { $skip++; continue }
        $r = [LsavDecryptor.Core]::DecryptFile($f.FullName, $OutDir, $keys)
        W ('   ' + $num + '  ') 'Gray'
        if ($r.Ok) {
            $ok++
            W 'OK    ' 'Green'
            W (Fit ([IO.Path]::GetFileName($r.Output)) 34) 'White'
            W (' ' + (Fit $r.Format 5) + ' ' + (Size $r.Bytes).PadLeft(9)) 'Gray'
            if ($r.Verified) { WL '  verified' 'Green' } else { WL '  unverified' 'Yellow'; $unverified++ }
            [IO.File]::AppendAllText($manifest, $f.FullName + "`r`n")
            $report.Add(('OK    {0}  ->  {1}  [{2}, {3} layout, {4}, key {5}]' -f $f.FullName, $r.Output, $r.Format,
                    $r.Mode, ($(if ($r.Verified) { 'verified' } else { 'unverified' })), $r.KeyHex))
        } else {
            $fail++
            W 'FAIL  ' 'Red'
            W (Fit $f.Name 34) 'White'
            WL (' ' + $r.Error) 'Gray'
            if ($r.Error -match 'fingerprint ([0-9a-f]{32})') { $foreign[$Matches[1]] = $true }
            $report.Add(('FAIL  {0}  ->  {1}' -f $f.FullName, $r.Error))
        }
    }

    Rule
    W '   Decrypted '; W ("$ok") 'Green'
    W '    Failed '; W ("$fail") ($(if ($fail) { 'Red' } else { 'Gray' }))
    if ($skip) { W '    Already done earlier '; W ("$skip") 'Gray' }
    WL ''
    if ($unverified) {
        WL ("   $unverified file(s) decrypted but could not be checked end to end - open them to confirm.") 'Yellow'
    }
    if ($foreign.Count) {
        WL ''
        WL ('   {0} key fingerprint(s) in the failed file names are not in keys.txt:' -f $foreign.Count) 'Yellow'
        foreach ($t in $foreign.Keys) { WL ('     ' + $t) 'Gray' }
        WL '   Those files come from a different Gallery build. Fix: Key tools in the main menu' 'Yellow'
        WL '   (extract the key from the phone, or run the offline deep key search).' 'Yellow'
    } elseif ($fail -and -not $ok) {
        WL '   Nothing decrypted. Open Key tools in the main menu to get the right key.' 'Yellow'
    }

    if ($report.Count) {
        if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
        $rp = Join-Path $OutDir 'decryption-report.txt'
        $head = @('LSAV Decryptor report  ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), 'Source: ' + $item.FullName, '')
        [IO.File]::AppendAllText($rp, (($head + $report) -join "`r`n") + "`r`n`r`n")
    }

    if ($ok -eq 0 -and $fail -eq 0) { exit 0 }      # everything was already done
    if ($fail -eq 0) { exit 0 }
    if ($ok -eq 0) { exit 3 }
    exit 1
}

# ================================================================ ScanSummary
# A scan list holds "size|/path" lines (size may be missing on old phones).
function Read-ScanList([string]$file) {
    $items = New-Object System.Collections.Generic.List[object]
    if (-not $file -or -not (Test-Path -LiteralPath $file)) { return , $items }
    $seen = @{}
    foreach ($line in [IO.File]::ReadAllLines($file)) {
        $line = $line.Trim([char]0xFEFF, ' ', "`t", "`r")
        if (-not $line) { continue }
        $size = -1; $p = $line
        if ($line -match '^(\d+)\|(.+)$') { $size = [int64]$Matches[1]; $p = $Matches[2] }
        $p = $p -replace '/{2,}', '/'
        if ($p -notmatch '\.(lsa|lsav)$' -or $seen.ContainsKey($p)) { continue }
        $seen[$p] = $true
        $items.Add((New-Object psobject -Property @{
            Size = $size; Path = $p; Dir = $p.Substring(0, [math]::Max(0, $p.LastIndexOf('/')))
            Video = ($p -match '\.lsav$'); Line = $(if ($size -ge 0) { "$size|$p" } else { $p }) }))
    }
    return , $items
}

function Write-ScanList($items, [string]$file) {
    $utf8 = New-Object Text.UTF8Encoding($false)   # no BOM: the .bat reads this file
    $text = (($items | ForEach-Object { $_.Line }) -join "`n") + "`n"
    [IO.File]::WriteAllText($file, $text, $utf8)
}

function Write-Totals($items, [string]$label) {
    $videos = @($items | Where-Object { $_.Video }).Count
    $photos = $items.Count - $videos
    $known = @($items | Where-Object { $_.Size -ge 0 })
    $total = ($known | Measure-Object -Property Size -Sum).Sum
    W ('   ' + $label + ' '); W ("$($items.Count)") 'Green'
    W ('   ({0} photos, {1} videos' -f $photos, $videos) 'Gray'
    if ($known.Count) { WL (', ' + (Size $total) + ')') 'Gray' } else { WL ')' 'Gray' }
}

# ================================================================ ADB helpers
function Quote-Arg([string]$a) {
    if ($a -eq '') { return '""' }
    if ($a -notmatch '[\s"]') { return $a }
    $e = $a -replace '(\\*)"', '$1$1\"'
    $e = $e -replace '(\\+)$', '$1$1'
    return '"' + $e + '"'
}

function Start-Adb([string[]]$argv) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Adb
    $psi.Arguments = (@($argv | ForEach-Object { Quote-Arg $_ })) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    return [Diagnostics.Process]::Start($psi)
}

function Invoke-AdbQuiet([string[]]$argv) {
    $p = Start-Adb $argv
    $o = $p.StandardOutput.ReadToEndAsync()
    $e = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    [void]$o.Wait(5000); [void]$e.Wait(5000)
    return $p.ExitCode
}

function Line-Width {
    try { $w = [Console]::WindowWidth - 1 } catch { $w = 99 }
    if ($w -lt 40) { $w = 79 }
    return $w
}

function Status([string]$text, [string]$color = 'Cyan') {
    $w = Line-Width
    if ($text.Length -gt $w - 1) { $text = $text.Substring(0, $w - 1) }
    Write-Host ("`r" + $text.PadRight($w)) -ForegroundColor $color -NoNewline
}

function Need-Adb {
    if (-not $Adb -or -not (Test-Path -LiteralPath $Adb)) { WL '   ADB was not found.' 'Red'; exit 9 }
    if (-not $Serial) { WL '   No phone was selected.' 'Red'; exit 9 }
}

# ================================================================ Scan
# Searches the phone while showing a timer and a running count.
function Invoke-Scan {
    Need-Adb
    $cmd = @'
for d in /sdcard /storage/????-????; do [ -d $d/ ] || continue; if stat -c %s / >/dev/null 2>&1; then find $d/ -type f \( -iname '*.lsa' -o -iname '*.lsav' \) -exec stat -c '%s|%n' {} + 2>/dev/null; else find $d/ -type f \( -iname '*.lsa' -o -iname '*.lsav' \) 2>/dev/null; fi; done
'@
    WL '   Please wait while the phone is searched. On phones with lots of files this' 'Gray'
    WL '   can take a minute or two. Keep the phone connected and unlocked.' 'Gray'
    WL ''
    $p = Start-Adb @('-s', $Serial, 'exec-out', $cmd.Trim())
    $errTask = $p.StandardError.ReadToEndAsync()
    $sr = $p.StandardOutput
    $lines = New-Object System.Collections.Generic.List[string]
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $spin = @('|', '/', '-', '\')
    $k = 0; $last = -1000
    $task = $sr.ReadLineAsync()
    while ($true) {
        if ($task.Wait(150)) {
            $line = $task.Result
            if ($null -eq $line) { break }
            $line = $line.Trim()
            if ($line) { $lines.Add($line) }
            $task = $sr.ReadLineAsync()
        }
        if ($sw.ElapsedMilliseconds - $last -ge 250) {
            $last = $sw.ElapsedMilliseconds; $k++
            Status ('   {0}  Searching   {1:mm\:ss} elapsed   {2} file(s) found so far' -f $spin[$k % 4], $sw.Elapsed, $lines.Count)
        }
    }
    $p.WaitForExit()
    [void]$errTask.Wait(3000)
    $sw.Stop()

    [IO.File]::WriteAllText($ListFile, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
    $items = Read-ScanList $ListFile
    Write-ScanList @($items | Sort-Object Path) $ListFile

    if ($items.Count -eq 0 -and $p.ExitCode -ne 0) {
        Status ('   Search stopped after {0:mm\:ss}. Lost contact with the phone.' -f $sw.Elapsed) 'Red'
        WL ''
        exit 3
    }
    $color = $(if ($items.Count) { 'Green' } else { 'Yellow' })
    Status ('   Done in {0:mm\:ss}.   {1} file(s) found.' -f $sw.Elapsed, $items.Count) $color
    WL ''
    if ($items.Count -eq 0) { exit 2 }
    exit 0
}

# ================================================================ Pull
# Copies the files in a scan list, mirroring the phone's folders.
function Invoke-Pull {
    Need-Adb
    $items = Read-ScanList $ListFile
    $n = $items.Count
    if ($n -eq 0) { WL '   The file list is empty.' 'Red'; exit 2 }
    [void][IO.Directory]::CreateDirectory($OutDir)
    $total = ($items | Where-Object { $_.Size -ge 0 } | Measure-Object -Property Size -Sum).Sum

    W '   Copying '; W ("$n") 'White'; W ' file(s)'
    if ($total) { W (' (' + (Size $total) + ')') 'Gray' }
    WL ' into:'
    WL ('   ' + $OutDir) 'Cyan'
    WL '   Please wait. Keep the phone connected and unlocked.' 'Gray'
    WL ''

    $bad = [IO.Path]::GetInvalidFileNameChars()
    $fail = New-Object System.Collections.Generic.List[string]
    $ok = 0; $i = 0; $done = 0
    $sw = [Diagnostics.Stopwatch]::StartNew()
    foreach ($it in $items) {
        $i++
        $parts = @($it.Path.TrimStart('/').Split('/') | Where-Object { $_ } | ForEach-Object {
                $seg = $_; foreach ($ch in $bad) { $seg = $seg.Replace([string]$ch, '_') }; $seg })
        $local = $OutDir
        foreach ($seg in $parts) { $local = [IO.Path]::Combine($local, $seg) }
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($local))

        $frac = ($i - 1) / $n
        Status ('   ' + (Bar $frac 24) + ('  {0,3:0}%  {1}/{2}  {3:mm\:ss}  ' -f ($frac * 100), $i, $n, $sw.Elapsed) + $parts[-1])

        $rc = Invoke-AdbQuiet @('-s', $Serial, 'pull', '-a', $it.Path, $local)
        if ($rc -ne 0) { $rc = Invoke-AdbQuiet @('-s', $Serial, 'pull', $it.Path, $local) }
        if ($rc -eq 0 -and (Test-Path -LiteralPath $local)) { $ok++ } else { $fail.Add($it.Path) }
    }
    $sw.Stop()
    Status ('   ' + (Bar 1 24) + ('  100%  {0}/{0}  {1:mm\:ss}' -f $n, $sw.Elapsed)) 'Green'
    WL ''
    WL ''
    W '   Copied '; W ("$ok") 'Green'; WL (" of $n file(s).")
    if ($fail.Count) {
        $fl = Join-Path $OutDir 'pull-failed.txt'
        [IO.File]::WriteAllLines($fl, $fail.ToArray())
        WL ('   {0} file(s) could not be copied. The list is in:' -f $fail.Count) 'Yellow'
        WL ('   ' + $fl) 'Gray'
    }
    if ($ok -eq 0) { exit 2 }
    exit 0
}

# ================================================================ NormalizeList
# Sort, de-duplicate and clean the raw scan so file numbers stay stable.
function Invoke-NormalizeList {
    $items = Read-ScanList $ListFile
    $sorted = @($items | Sort-Object Path)
    Write-ScanList $sorted $ListFile
    exit 0
}

# ================================================================ Select
# Selection grammar (commas or spaces between parts, any case):
#   7   3-12   all   photos   videos   <text: path contains it>
#   prefix any part with - to leave those files out
function Invoke-Select {
    $items = Read-ScanList $ListFile
    if ($items.Count -eq 0) { WL '   The file list is empty. Scan again.' 'Red'; exit 2 }
    $raw = ''
    if ($InputPath -and (Test-Path -LiteralPath $InputPath)) { $raw = [IO.File]::ReadAllText($InputPath) }
    $raw = $raw.Replace('"', '').Trim()
    $tokens = @($raw -split '[,;\s]+' | Where-Object { $_ })
    if ($tokens.Count -eq 0) { exit 2 }

    $n = $items.Count
    $inc = New-Object 'bool[]' ($n + 1)
    $exc = New-Object 'bool[]' ($n + 1)
    $anyInclude = $false
    $notes = New-Object System.Collections.Generic.List[string]

    foreach ($tok in $tokens) {
        $neg = $false
        $t = $tok
        if ($t.Length -gt 1 -and $t.StartsWith('-')) { $neg = $true; $t = $t.Substring(1) }
        if ($neg) { $target = $exc } else { $target = $inc }
        if (-not $neg) { $anyInclude = $true }
        $hit = 0
        if ($t -match '^\d+$') {
            $a = [int]$t
            if ($a -ge 1 -and $a -le $n) { $target[$a] = $true; $hit = 1 }
            else { $notes.Add("there is no file $a (the list has $n)") }
            continue
        }
        if ($t -match '^(\d+)-(\d+)$') {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            if ($a -gt $b) { $tmp = $a; $a = $b; $b = $tmp }
            if ($a -gt $n) { $notes.Add("$t is past the end of the list (it has $n)"); continue }
            if ($b -gt $n) { $notes.Add("$t was cut to $a-$n"); $b = $n }
            if ($a -lt 1) { $a = 1 }
            for ($i = $a; $i -le $b; $i++) { $target[$i] = $true }
            continue
        }
        for ($i = 1; $i -le $n; $i++) {
            $it = $items[$i - 1]
            $match = $false
            switch ($t.ToLower()) {
                'all'    { $match = $true }
                'photos' { $match = -not $it.Video }
                'photo'  { $match = -not $it.Video }
                'videos' { $match = $it.Video }
                'video'  { $match = $it.Video }
                default  { $match = $it.Path.IndexOf($t, [StringComparison]::OrdinalIgnoreCase) -ge 0 }
            }
            if ($match) { $target[$i] = $true; $hit++ }
        }
        if ($hit -eq 0) { $notes.Add("nothing matches ""$t""") }
    }
    if (-not $anyInclude) { for ($i = 1; $i -le $n; $i++) { $inc[$i] = $true } }

    $chosen = New-Object System.Collections.Generic.List[object]
    for ($i = 1; $i -le $n; $i++) { if ($inc[$i] -and -not $exc[$i]) { $chosen.Add($items[$i - 1]) } }

    foreach ($note in $notes) { WL ('   Note: ' + $note) 'Yellow' }
    if ($chosen.Count -eq 0) { WL '   No files selected. Try again.' 'Yellow'; exit 2 }
    Write-ScanList $chosen $OutDir
    Write-Totals $chosen 'Selected'
    if ($chosen.Count -le 12) {
        foreach ($it in $chosen) { WL ('     ' + (FitPath $it.Path 70)) 'Gray' }
    }
    exit 0
}

# ================================================================ ScanSummary
function Invoke-ScanSummary {
    $items = Read-ScanList $ListFile
    if ($items.Count -eq 0) { exit 2 }

    $videos = @($items | Where-Object { $_.Video }).Count
    $photos = $items.Count - $videos
    $known = @($items | Where-Object { $_.Size -ge 0 })
    $total = ($known | Measure-Object -Property Size -Sum).Sum
    if (-not $total) { $total = 0 }

    W '   Found '; W ("$($items.Count)") 'Green'; W ' encrypted files'
    if ($Device) { W ' on '; W $Device 'White' }
    WL ''
    W ('   {0} photos (.lsa)   {1} videos (.lsav)' -f $photos, $videos) 'Gray'
    if ($known.Count) { WL ('   ' + (Size $total) + ' total') 'Gray' } else { WL '' }
    WL ''

    if ($Full) {
        $w = ("$($items.Count)").Length
        WL ('   {0}  {1}{2}{3}' -f ('#'.PadLeft($w)), (Fit 'File on the phone' 60), 'Size'.PadLeft(10), '   Type') 'Cyan'
        $i = 0
        foreach ($it in $items) {
            $i++
            $s = $(if ($it.Size -ge 0) { Size $it.Size } else { '?' })
            W ('   ' + ("$i").PadLeft($w) + '  ') 'Yellow'
            W ((FitPath $it.Path 60) + $s.PadLeft(10)) 'White'
            if ($it.Video) { WL '   video' 'Cyan' } else { WL '   photo' 'Green' }
        }
    } else {
        WL ('   {0}{1}{2}' -f (Fit 'Folder on the phone' 50), 'Files'.PadLeft(7), 'Size'.PadLeft(11)) 'Cyan'
        foreach ($g in ($items | Group-Object Dir | Sort-Object Count -Descending)) {
            $gs = ($g.Group | Where-Object { $_.Size -ge 0 } | Measure-Object -Property Size -Sum).Sum
            $s = $(if ($gs) { Size $gs } else { '?' })
            WL ('   {0}{1}{2}' -f (FitPath $g.Name 50), ("$($g.Count)").PadLeft(7), $s.PadLeft(11))
        }
    }

    if ($OutDir -and $total -gt 0) {
        try {
            $drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $OutDir).Path))
            $need = [int64]($total * 2.05)
            if ($drive.AvailableFreeSpace -lt $need) {
                WL ''
                WL ('   Warning: pulling and decrypting needs about {0}, but {1} has only {2} free.' -f (Size $need), $drive.Name, (Size $drive.AvailableFreeSpace)) 'Yellow'
            }
        } catch { }
    }
    exit 0
}

# ================================================================ ExtractKey
function Invoke-ExtractKey {
    if (-not $Apk -or -not (Test-Path -LiteralPath $Apk)) { WL '   APK file not found.' 'Red'; exit 2 }
    Load-Core
    WL ('   Reading signing certificates from ' + [IO.Path]::GetFileName($Apk) + ' (' + (Size (Get-Item -LiteralPath $Apk).Length) + ')') 'Gray'
    try { $found = [LsavDecryptor.Core]::KeysFromApk($Apk) }
    catch { WL ('   Could not read the APK: ' + $_.Exception.Message) 'Red'; exit 5 }
    if ($found.Count -eq 0) { WL '   No signing certificate was found in this APK.' 'Red'; exit 5 }

    $tags = @{}
    if ($Compare -and (Test-Path -LiteralPath $Compare)) { $tags = Get-Tags $Compare }
    $known = Get-KeyList
    WL ''
    foreach ($k in $found) {
        W '   Key          '; WL $k.KeyHex 'Green'
        W '   Fingerprint  '; WL $k.Md5 'White'
        W '   From         '; WL $k.Source 'Gray'
        if ($tags.Count) {
            $m = $(if ($tags.ContainsKey($k.Md5)) { $tags[$k.Md5] } else { 0 })
            W '   Your files   '
            if ($m) { WL ("$m file(s) carry this fingerprint - this is their key") 'Green' }
            else { WL 'no file name carries this fingerprint' 'Yellow' }
        }
        if ($known.Contains($k.KeyHex)) { WL '   Status       already saved' 'Gray' }
        elseif (Save-Key $k.KeyHex ('extracted from ' + [IO.Path]::GetFileName($Apk))) { WL '   Status       saved to keys.txt' 'Green' }
        WL ''
    }
    if ($tags.Count) {
        $all = Get-KeyList
        $md5s = @($all | ForEach-Object { [LsavDecryptor.Core]::Md5Hex([LsavDecryptor.Core]::FromHex($_)) })
        $left = @($tags.Keys | Where-Object { $md5s -notcontains $_ })
        if ($left.Count) {
            WL ('   {0} fingerprint(s) in your files still have no key. Try the deep key search.' -f $left.Count) 'Yellow'
        } else {
            WL '   Every file fingerprint now has a matching key.' 'Green'
        }
    }
    exit 0
}

# ================================================================ FindKey
function Invoke-FindKey {
    if (-not $InputPath -or -not (Test-Path -LiteralPath $InputPath)) { WL '   That path does not exist.' 'Red'; exit 2 }
    Load-Core
    $tags = Get-Tags $InputPath
    if ($tags.Count -eq 0) {
        WL '   None of these file names carry a key fingerprint (a 32-character hex tag),' 'Yellow'
        WL '   so the key cannot be recovered from the names. Extract it from the phone instead.' 'Yellow'
        exit 2
    }
    $known = Get-KeyList
    $knownMd5 = @($known | ForEach-Object { [LsavDecryptor.Core]::Md5Hex([LsavDecryptor.Core]::FromHex($_)) })
    $todo = @($tags.Keys | Where-Object { $knownMd5 -notcontains $_ })
    W '   Fingerprints in file names: '; W ("$($tags.Count)") 'White'; W '    already solved: '; W ("$($tags.Count - $todo.Count)") 'Green'
    W '    to search: '; WL ("$($todo.Count)") 'White'
    if ($todo.Count -eq 0) { WL ''; WL '   Every file already matches a saved key. Nothing to search.' 'Green'; exit 0 }

    if ($Extended) {
        $gaps = @(60..70) + @(85..95) + @(117..125) + @(147..153) + @(276..282) + @(404..410) + @(532..538)
        $gaps = @($gaps | Where-Object { @(151, 149, 280, 278, 408, 406, 536, 534) -notcontains $_ })
        WL '   Mode: extended (EC, DSA and unusual RSA certificates). This can take several minutes.' 'Gray'
    } else {
        $gaps = @(151, 149, 280, 278, 408, 406, 536, 534)
        WL '   Mode: quick (RSA 1024/2048/3072/4096 certificates, which is what Android uses).' 'Gray'
    }
    WL ('   Using {0} CPU cores. Press Ctrl+C to stop.' -f [Environment]::ProcessorCount) 'Gray'
    WL ''

    $from = 256; $to = 4096; $step = 128
    $hits = @{}
    $sw = [Diagnostics.Stopwatch]::StartNew()
    for ($c = $from; $c -lt $to; $c += $step) {
        $remaining = @($todo | Where-Object { -not $hits.ContainsKey($_) })
        if ($remaining.Count -eq 0) { break }
        $res = [LsavDecryptor.Core]::SearchKeys([string[]]$remaining, $c, [math]::Min($c + $step, $to), [int[]]$gaps)
        foreach ($h in $res) { $p = $h -split '\|'; $hits[$p[1]] = $p[0] }
        $frac = ($c + $step - $from) / ($to - $from)
        $eta = ''
        if ($frac -gt 0.06 -and $frac -lt 1) { $eta = ('  about {0:0}s left' -f ($sw.Elapsed.TotalSeconds / $frac * (1 - $frac))) }
        W ("`r   " + (Bar $frac) + ('  {0,3:0}%' -f ($frac * 100)) + ('  found {0}/{1}' -f $hits.Count, $todo.Count) + $eta.PadRight(20)) 'Cyan'
    }
    WL ''
    WL ''
    if ($hits.Count -eq 0) {
        WL '   No key found in this search space.' 'Yellow'
        if (-not $Extended) { exit 4 }
        WL '   The key is probably not certificate-based. Extract it from the phone instead.' 'Yellow'
        exit 4
    }
    foreach ($t in $hits.Keys) {
        W '   Recovered key  '; W $hits[$t] 'Green'; WL ('   (fingerprint ' + $t + ', ' + $tags[$t] + ' file(s))') 'Gray'
        if (Save-Key $hits[$t] ('recovered by deep key search, fingerprint ' + $t)) { WL '                  saved to keys.txt' 'Green' }
    }
    if ($hits.Count -lt $todo.Count) {
        WL ''
        WL ('   {0} fingerprint(s) still unsolved.' -f ($todo.Count - $hits.Count)) 'Yellow'
        exit 1
    }
    exit 0
}

# ================================================================ ListKeys
function Invoke-ListKeys {
    Load-Core
    $keys = Get-KeyList
    WL ('   {0}{1}' -f (Fit 'Key' 36), 'Fingerprint (appears in file names)') 'Cyan'
    foreach ($k in $keys) {
        $note = $(if ($k -eq $DefaultKey) { '  built-in' } else { '' })
        W ('   ' + (Fit $k 36)) 'White'; W ([LsavDecryptor.Core]::Md5Hex([LsavDecryptor.Core]::FromHex($k))) 'Gray'; WL $note 'Gray'
    }
    exit 0
}

# ================================================================ GetAdb
function Invoke-GetAdb {
    $url = 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    $zip = Join-Path $Dest 'platform-tools.zip'
    WL '   Downloading Android SDK Platform-Tools from Google...' 'Gray'
    WL ('   ' + $url) 'Gray'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        WL '   Unpacking...' 'Gray'
        Expand-Archive -LiteralPath $zip -DestinationPath $Dest -Force
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    } catch {
        WL ('   Download failed: ' + $_.Exception.Message) 'Red'
        WL '   Download it yourself from https://developer.android.com/tools/releases/platform-tools' 'Yellow'
        WL ('   and unzip it so this file exists: ' + (Join-Path $Dest 'platform-tools\adb.exe')) 'Yellow'
        exit 6
    }
    if (Test-Path -LiteralPath (Join-Path $Dest 'platform-tools\adb.exe')) { WL '   ADB is ready.' 'Green'; exit 0 }
    WL '   The download did not contain adb.exe.' 'Red'; exit 6
}

# ================================================================ dispatch
try {
    switch ($Action) {
        'Decrypt'     { Invoke-Decrypt }
        'ScanSummary' { Invoke-ScanSummary }
        'NormalizeList' { Invoke-NormalizeList }
        'Scan'        { Invoke-Scan }
        'Pull'        { Invoke-Pull }
        'Select'      { Invoke-Select }
        'ExtractKey'  { Invoke-ExtractKey }
        'FindKey'     { Invoke-FindKey }
        'ListKeys'    { Invoke-ListKeys }
        'GetAdb'      { Invoke-GetAdb }
        'Stamp'       { [Console]::Out.Write((Get-Date -Format 'yyyy-MM-dd_HHmmss')); exit 0 }
        default       { WL "   Unknown action: $Action" 'Red'; exit 9 }
    }
} catch {
    WL ('   Engine error: ' + $_.Exception.Message) 'Red'
    exit 9
}

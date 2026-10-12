#Requires -Version 5.1
<#
.SYNOPSIS
    Fix the Wallpaper Engine UI crash (no tray icon, main window never opens).

.DESCRIPTION
    Wallpaper Engine's UI (wallpaperui.exe) is rendered by an embedded Chromium
    (libcef.dll). On some GPU / driver combinations the UI hardware-acceleration
    path crashes wallpaperui.exe right after launch. The background service
    keeps running, but the tray icon never appears and the main window never
    opens.

    This script:
      1. Locates the Wallpaper Engine install folder (Steam auto-detect).
      2. Stops Wallpaper Engine (service + processes).
      3. Backs up config.json.
      4. Sets "uihardwareacceleration" to false.
      5. Adds --disable-gpu to "cefcommandline".
      6. Restarts Wallpaper Engine and verifies the UI process is alive.

    Safe and idempotent: config.json is backed up before any edit, and the
    script does nothing if the values are already patched.

.PARAMETER InstallDir
    Wallpaper Engine install folder. Auto-detected when omitted.

.PARAMETER ConfigPath
    Patch this config.json directly instead of auto-detecting the install.

.PARAMETER DryRun
    Report what would change. Touches no file and no service.

.PARAMETER FileOnly
    Patch config.json only. Do not touch the service or the running app.

.PARAMETER NoRestart
    Do not restart Wallpaper Engine after patching.

.EXAMPLE
    .\fix-wallpaper-ui.ps1 -DryRun
    Preview what would change.

.EXAMPLE
    .\fix-wallpaper-ui.ps1
    Apply the fix and restart Wallpaper Engine.

.NOTES
    Run as Administrator (the .bat wrapper does this for you).
    https://github.com/CREAMSOU/wallpaper-engine-ui-fix
#>

[CmdletBinding()]
param(
    [string]$InstallDir,
    [string]$ConfigPath,
    [switch]$DryRun,
    [switch]$FileOnly,
    [switch]$NoRestart
)

$ErrorActionPreference = 'Stop'
$ServiceName = 'Wallpaper Engine Service'
$ProcessNames = @('wallpaper64', 'wallpaper32', 'wallpaperui', 'wallpaperservice64', 'wallpaperservice32')

function Write-Step($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "[ok] $m" -ForegroundColor Green }
function Write-Note($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Fail($m) { Write-Host "[x] $m" -ForegroundColor Red }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Read a text file and remember whether it had a UTF-8 BOM.
function Read-ConfigText($path) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $enc = New-Object System.Text.UTF8Encoding($hasBom)
    return @{ Text = [System.IO.File]::ReadAllText($path, $enc); HasBom = $hasBom }
}

function Write-ConfigText($path, $text, $hasBom) {
    $enc = New-Object System.Text.UTF8Encoding($hasBom)
    [System.IO.File]::WriteAllText($path, $text, $enc)
}

# --- Locate Wallpaper Engine -------------------------------------------------

function Get-SteamLibraries {
    $libs = New-Object System.Collections.Generic.List[string]
    $steam = $null
    $k = Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue
    if ($k -and $k.SteamPath) { $steam = $k.SteamPath }
    if (-not $steam) {
        $k2 = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction SilentlyContinue
        if ($k2 -and $k2.InstallPath) { $steam = $k2.InstallPath }
    }
    if ($steam -and (Test-Path $steam)) {
        $libs.Add($steam)
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            $raw = Get-Content $vdf -Raw -ErrorAction SilentlyContinue
            foreach ($m in [regex]::Matches($raw, '"path"\s+"([^"]+)"')) {
                $p = $m.Groups[1].Value -replace '\\\\', '\'
                if (Test-Path $p) { $libs.Add($p) }
            }
        }
    }
    return $libs
}

function Find-WallpaperEngineDir {
    param([string]$Explicit)
    if ($Explicit) {
        if (Test-Path (Join-Path $Explicit 'config.json')) { return (Resolve-Path $Explicit).Path }
        return $null
    }
    foreach ($lib in (Get-SteamLibraries)) {
        $cand = Join-Path $lib 'steamapps\common\wallpaper_engine'
        if (Test-Path (Join-Path $cand 'config.json')) { return (Resolve-Path $cand).Path }
    }
    $fallbacks = @(
        (Join-Path $env:USERPROFILE 'AppData\Local\Programs\wallpaper_engine'),
        'C:\Program Files (x86)\Steam\steamapps\common\wallpaper_engine',
        'C:\Program Files\Steam\steamapps\common\wallpaper_engine'
    )
    foreach ($f in $fallbacks) {
        if (Test-Path (Join-Path $f 'config.json')) { return (Resolve-Path $f).Path }
    }
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if ($d.Name -notmatch '^[A-Z]$') { continue }
        foreach ($sub in @('steam\steamapps\common\wallpaper_engine',
                           'SteamLibrary\steamapps\common\wallpaper_engine',
                           'Games\steamapps\common\wallpaper_engine')) {
            $cand = Join-Path $d.Root $sub
            if (Test-Path (Join-Path $cand 'config.json')) { return (Resolve-Path $cand).Path }
        }
    }
    return $null
}

# --- Patch logic -------------------------------------------------------------

# Pure text transform: keeps every other byte of the user's config intact.
function Invoke-PatchText {
    param([string]$Text)
    $log = New-Object System.Collections.Generic.List[string]
    $eol = if ($Text -match "`r`n") { "`r`n" } else { "`n" }

    # 1) uihardwareacceleration -> false
    if ($Text -match '"uihardwareacceleration"\s*:') {
        if ($Text -match '"uihardwareacceleration"\s*:\s*true') {
            $Text = [regex]::Replace($Text,
                '"uihardwareacceleration"\s*:\s*true', '"uihardwareacceleration" : false')
            $log.Add('uihardwareacceleration: true -> false')
        } else {
            $log.Add('uihardwareacceleration: already disabled, no change')
        }
    } else {
        $log.Add('uihardwareacceleration: field not found, skipped')
    }

    # 2) cefcommandline -> ensure --disable-gpu
    $m = [regex]::Match($Text, '"cefcommandline"\s*:\s*"([^"]*)"')
    if ($m.Success) {
        $cur = $m.Groups[1].Value.Trim()
        $flags = @($cur -split '\s+' | Where-Object { $_ })
        if ($flags -notcontains '--disable-gpu') {
            $flags += '--disable-gpu'
            $newVal = ($flags -join ' ')
            $Text = $Text.Substring(0, $m.Index) + '"cefcommandline" : "' + $newVal + '"' +
                    $Text.Substring($m.Index + $m.Length)
            $log.Add("cefcommandline: `"$cur`" -> `"$newVal`"")
        } else {
            $log.Add('cefcommandline: --disable-gpu already present, no change')
        }
    } else {
        $mi = [regex]::Match($Text, '(?m)^([ \t]*)"uihardwareacceleration"\s*:.*$')
        if ($mi.Success) {
            $indent = $mi.Groups[1].Value
            $line = $indent + '"cefcommandline" : "--disable-gpu",' + $eol
            $Text = $Text.Insert($mi.Index, $line)
            $log.Add('cefcommandline: field missing, inserted "--disable-gpu"')
        } else {
            $log.Add('cefcommandline: insert point not found, skipped')
        }
    }

    return @{ Text = $Text; Log = $log }
}

# --- Runtime actions ---------------------------------------------------------

function Stop-WallpaperEngine {
    foreach ($n in $ProcessNames) {
        $ps = Get-Process -Name $n -ErrorAction SilentlyContinue
        if ($ps) {
            $ps | Stop-Process -Force -ErrorAction SilentlyContinue
            Write-Note "stopped process: $n"
        }
    }
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        try { Stop-Service -Name $ServiceName -Force -ErrorAction Stop; Write-Ok "service stopped" }
        catch { Write-Note "could not stop service (needs admin): $($_.Exception.Message)" }
    }
    Start-Sleep -Seconds 2
}

function Start-WallpaperEngine {
    param([string]$Root)
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') {
        try { Start-Service -Name $ServiceName -ErrorAction Stop; Write-Ok "service started" }
        catch { Write-Note "could not start service: $($_.Exception.Message)" }
    }
    $exe = Join-Path $Root 'wallpaper64.exe'
    if (-not (Test-Path $exe)) { $exe = Join-Path $Root 'wallpaper32.exe' }
    if (Test-Path $exe) {
        Start-Process $exe
        Write-Ok "launched $(Split-Path $exe -Leaf)"
    } else {
        Write-Note "wallpaper exe not found under $Root"
    }
    Start-Sleep -Seconds 8
}

# --- Main --------------------------------------------------------------------

Write-Host ''
Write-Host 'Wallpaper Engine UI fix' -ForegroundColor White
Write-Host '------------------------' -ForegroundColor DarkGray

# Locate
if ($ConfigPath) {
    if (-not (Test-Path $ConfigPath)) { Write-Fail "config.json not found: $ConfigPath"; exit 2 }
    $cfgPath = (Resolve-Path $ConfigPath).Path
    $root = Split-Path $cfgPath -Parent
} else {
    $root = Find-WallpaperEngineDir -Explicit $InstallDir
    if (-not $root) {
        Write-Fail 'Wallpaper Engine install folder not found.'
        Write-Note 'Pass -InstallDir "X:\...\steamapps\common\wallpaper_engine" to point at it manually.'
        exit 2
    }
    $cfgPath = Join-Path $root 'config.json'
}
Write-Ok "install folder : $root"
Write-Ok "config.json    : $cfgPath"

$read = Read-ConfigText $cfgPath
$patch = Invoke-PatchText -Text $read.Text

Write-Host ''
Write-Host 'Planned changes:' -ForegroundColor White
foreach ($l in $patch.Log) { Write-Host "  - $l" }

# Validate the patched JSON before touching disk
try {
    $null = $patch.Text | ConvertFrom-Json
    Write-Ok 'patched JSON is valid'
} catch {
    Write-Fail "patched JSON is invalid, aborting: $($_.Exception.Message)"
    exit 3
}

if ($DryRun) {
    Write-Host ''
    Write-Note 'DryRun: nothing was changed.'
    exit 0
}

if ($FileOnly) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $bak = "$cfgPath.bak.$stamp"
    Copy-Item $cfgPath $bak -Force
    Write-ConfigText $cfgPath $patch.Text $read.HasBom
    Write-Host ''
    Write-Ok 'config.json patched (file only, service untouched)'
    Write-Ok "backup: $bak"
    exit 0
}

if (-not (Test-Admin)) {
    Write-Host ''
    Write-Fail 'Not running as Administrator.'
    Write-Note 'Run run-fix.bat (right-click -> Run as administrator) or start PowerShell as admin.'
    exit 4
}

# Stop
$svcBefore = (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue).Status
Write-Host ''
Write-Step 'Stopping Wallpaper Engine...'
Stop-WallpaperEngine

# Backup
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$bak = "$cfgPath.bak.$stamp"
Copy-Item $cfgPath $bak -Force
Write-Ok "backup: $bak"

# Write patched config
Write-ConfigText $cfgPath $patch.Text $read.HasBom
Write-Ok 'config.json patched'

# Restart
if ($NoRestart) {
    Write-Note 'NoRestart set: Wallpaper Engine left stopped.'
} else {
    Write-Host ''
    Write-Step 'Restarting Wallpaper Engine...'
    Start-WallpaperEngine -Root $root

    $ui = Get-Process -Name 'wallpaperui' -ErrorAction SilentlyContinue
    if ($ui) {
        Write-Ok "wallpaperui.exe is running (PID $($ui.Id -join ', '))"
        Write-Host ''
        Write-Ok 'Done. Check the system tray for the Wallpaper Engine icon.'
    } else {
        Write-Note 'wallpaperui.exe not detected yet. Give it a few seconds, then check the tray.'
        Write-Note 'If it still crashes, the GPU driver may need updating.'
    }
}

Write-Host ''
Write-Host "Backup kept at: $bak" -ForegroundColor DarkGray

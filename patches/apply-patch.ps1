<#
.SYNOPSIS
    Applies / reverts the EFZKeepAim companion patch to EFZ's TW_AdsFromThird.lua.

.DESCRIPTION
    EFZ's third-person ADS module leaves the sight whenever the character has any
    running action. The shot itself leaves such an action state for a few frames,
    which drops the scope even when the automatic rack is already suppressed by the
    EFZKeepAim mod. This script adds the one-line exemption hook (idempotent) and
    keeps a timestamped backup next to the file.

    Re-running is safe: it detects both the patched and the reverted state.
    Use -Revert to restore the most recent backup.

.PARAMETER Path
    Path to the EscapeFromZomboidFirearms mod folder, i.e. the folder that contains
    '42'. Default: auto-detected from the Steam library.

.EXAMPLE
    .\apply-patch.ps1
    .\apply-patch.ps1 -Path "D:\Steam\steamapps\workshop\content\108600\3824755284\mods\EscapeFromZomboidFirearms"
    .\apply-patch.ps1 -Revert
#>
[CmdletBinding()]
param(
    [string]$Path,
    [switch]$Revert
)

$ErrorActionPreference = 'Stop'

$RelPath = '42\media\lua\client\TW_AdsFromThird.lua'
$OldLine = "    if actions and not actions:isEmpty() then return 'action' end"
$Marker = 'EFZKeepAim (local patch)'
$NewBlock = @'
    if actions and not actions:isEmpty() then
        -- EFZKeepAim (local patch): the action state of the shot itself lingers for a few frames, and leaving
        -- the sight on that is exactly what the keep-ADS patch removes. Exemption only lasts for its shot window.
        local keep=rawget(_G,'EFZKeepAim')
        if not (keep and type(keep.exempt)=='function' and keep.exempt(p)) then return 'action' end
    end
'@

function Test-Dir([string]$p) {
    # [System.IO.Directory]::Exists returns false for a missing drive instead of throwing
    return [System.IO.Directory]::Exists($p)
}

# ---------------------------------------------------------------------------
# AnimSets retune
#
# Every rack node that is played while aiming carries a transition back to
# IdleRifle (RackRifleAim -> IdleRifle, playing AimToIdle_Rifle). EFZ ships that
# transition with m_blendInTime / m_blendOutTime = 0.5 and m_speedScale = 1.3, so
# finishing a rack costs half a second of the gun dropping out of the sight and
# another half second of raising it again. That is the "slow re-ADS" the mod
# cannot fix from Lua, because the transition is baked into the animset.
#
# Tightening it to 0.08 / 0.08 at 2.2x keeps the transition (no cut frames, the
# gun still travels) but makes it read as a snap instead of a swing.
#
# Only transitions whose target is IdleRifle* are touched; node blend times,
# conditions and events are left alone. Idempotent, and -Revert restores the
# .efzkeepaim.*.bak copies.
# ---------------------------------------------------------------------------
$script:AnimRel = '42\media\AnimSets\player\actions'
$script:AnimBlendIn = '0.08'
$script:AnimBlendOut = '0.08'
$script:AnimSpeed = '2.2'

function Invoke-AnimSets([string]$ModPath, [switch]$RevertAnim) {
    $dir = Join-Path $ModPath $script:AnimRel
    if (-not [System.IO.Directory]::Exists($dir)) {
        Write-Host "AnimSets folder not found, skipped: $dir"
        return
    }
    $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.xml' -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -match 'ack' })

    if ($RevertAnim) {
        $n = 0
        foreach ($f in $files) {
            $bk = Get-ChildItem -LiteralPath $f.DirectoryName -Filter "$($f.Name).efzkeepanimset*.bak" -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($bk) {
                Copy-Item -LiteralPath $bk.FullName -Destination $f.FullName -Force
                $n++
            }
        }
        Write-Host "AnimSets reverted: $n file(s)"
        return
    }

    $script:animFiles = 0
    $script:animEdits = 0
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

    $evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
        param($m)
        $block = $m.Value
        if ($block -notmatch '<m_Target>IdleRifle') { return $block }
        if ($block -match "<m_blendInTime>$([regex]::Escape($script:AnimBlendIn))<") { return $block }
        $b = [regex]::Replace($block, '(<m_blendInTime>)[^<]*(</m_blendInTime>)', "`${1}$($script:AnimBlendIn)`${2}")
        $b = [regex]::Replace($b, '(<m_blendOutTime>)[^<]*(</m_blendOutTime>)', "`${1}$($script:AnimBlendOut)`${2}")
        $b = [regex]::Replace($b, '(<m_speedScale>)[^<]*(</m_speedScale>)', "`${1}$($script:AnimSpeed)`${2}")
        $script:animEdits++
        return $b
    }

    foreach ($f in $files) {
        $raw = [System.IO.File]::ReadAllText($f.FullName)
        $before = $script:animEdits
        $new = [regex]::Replace($raw, '(?s)<m_Transitions>.*?</m_Transitions>', $evaluator)
        if ($script:animEdits -gt $before) {
            Copy-Item -LiteralPath $f.FullName -Destination "$($f.FullName).efzkeepanimset.$stamp.bak" -Force
            [System.IO.File]::WriteAllText($f.FullName, $new, (New-Object System.Text.UTF8Encoding($false)))
            $script:animFiles++
        }
    }
    Write-Host "AnimSets: $($script:animFiles) file(s), $($script:animEdits) transition(s) retuned"
}


function Find-EfzFolder {
    $roots = @()

    # 1) the registry knows where Steam itself is, wherever it was installed
    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        try {
            $p = (Get-ItemProperty -Path $key -ErrorAction Stop).SteamPath
            if ($p) { $roots += ($p -replace '/', '\') }
        } catch { }
    }

    # 2) conventional locations
    if ($env:ProgramFiles) { $roots += (Join-Path $env:ProgramFiles 'Steam') }
    if (${env:ProgramFiles(x86)}) { $roots += (Join-Path ${env:ProgramFiles(x86)} 'Steam') }
    foreach ($extra in @(
            'D:\Steam', 'D:\SteamLibrary', 'E:\SteamLibrary',
            'D:\Program Files (x86)\Steam', 'D:\Program Files\Steam',
            'E:\Program Files (x86)\Steam', 'F:\SteamLibrary')) {
        $roots += $extra
    }
    # Join-Path throws on a drive that does not exist, so drop those roots up front
    $roots = @($roots | Where-Object { $_ -and [System.IO.Directory]::Exists($_) } | Select-Object -Unique)

    # 3) every library listed in libraryfolders.vdf (this is what actually holds workshop content)
    $libraries = @()
    foreach ($root in $roots) {
        $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
        if ([System.IO.File]::Exists($vdf)) {
            $content = Get-Content -LiteralPath $vdf -Raw
            foreach ($m in [regex]::Matches($content, '"path"\s+"([^"]+)"')) {
                $libraries += ($m.Groups[1].Value -replace '\\\\', '\')
            }
        }
    }
    $all = @($roots + $libraries | Select-Object -Unique)

    $candidates = @()
    foreach ($root in $all) {
        if (-not [System.IO.Directory]::Exists($root)) { continue }
        $ws = Join-Path $root 'steamapps\workshop\content\108600'
        if (Test-Dir $ws) { $candidates += $ws }
    }

    foreach ($c in $candidates) {
        foreach ($item in (Get-ChildItem -LiteralPath $c -Directory -ErrorAction SilentlyContinue)) {
            $mods = Join-Path $item.FullName 'mods\EscapeFromZomboidFirearms'
            if ([System.IO.File]::Exists((Join-Path $mods $RelPath))) { return $mods }
        }
    }
    return $null
}

if (-not $Path) {
    $Path = Find-EfzFolder
    if (-not $Path) {
        throw "Could not find EscapeFromZomboidFirearms automatically. Pass -Path <mod folder>."
    }
    Write-Host "Auto-detected: $Path"
}

$file = Join-Path $Path $RelPath

# 动画集与 hook 补丁互相独立，先各自处理（-Revert 时一起还原）
if ($Revert) { Invoke-AnimSets -ModPath $Path -RevertAnim } else { Invoke-AnimSets -ModPath $Path }

if (-not [System.IO.File]::Exists($file)) {
    throw "Not found: $file"
}

$lines = Get-Content -LiteralPath $file
$text = $lines -join "`n"
$patched = $text.Contains($Marker)

if ($Revert) {
    if (-not $patched) { Write-Host 'File is not patched, nothing to revert.'; return }
    # 精确匹配本文件的备份：不能用 '*efzkeepaim*.bak'，动画集的备份也含这段字符，
    # 会把 XML 备份盖到 lua 上（踩过一次）。
    $backup = Get-ChildItem -LiteralPath (Split-Path -Parent $file) -Filter 'TW_AdsFromThird.lua.efzkeepaim*.bak' -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $backup) { throw 'No backup found; restore the file through Steam (verify integrity).' }
    Copy-Item -LiteralPath $backup.FullName -Destination $file -Force
    Write-Host "Reverted from $($backup.FullName)"
    return
}

if ($patched) {
    Write-Host 'Already patched, nothing to do.'
    return
}

$idx = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -eq $OldLine) { $idx = $i; break }
}
if ($idx -lt 0) {
    throw "Anchor line not found - EFZ probably updated and changed blocked(). Re-check patches\TW_AdsFromThird.lua.patch."
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Copy-Item -LiteralPath $file -Destination "$file.efzkeepaim.$stamp.bak" -Force

$out = @()
$out += $lines[0..($idx - 1)]
$out += $NewBlock -split "`r?`n"
$out += $lines[($idx + 1)..($lines.Count - 1)]
Set-Content -LiteralPath $file -Value $out -Encoding UTF8NoBOM

Write-Host "Patched: $file"
Write-Host "Backup:  $file.efzkeepaim.$stamp.bak"
Write-Host 'Restart Project Zomboid so the file is reloaded.'

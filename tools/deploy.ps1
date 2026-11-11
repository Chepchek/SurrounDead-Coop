# Deploys the SDCoop Lua scripts into the game and into the local test client.
#
#   powershell -ExecutionPolicy Bypass -File tools\deploy.ps1
#
# * copies mods\SDCoop\scripts\*.lua into each target's ue4ss\Mods\SDCoop\scripts
# * removes .lua files that no longer exist in the source
# * makes sure mods.txt enables SDCoop
# * never overwrites an existing config.ini (settings belong to each install);
#   the local test client gets auto_join = true on first deploy

param(
    [string]$GameDir = "C:\Program Files (x86)\Steam\steamapps\common\SurrounDead",
    [string]$ClientDir = (Join-Path $PSScriptRoot "..\work\client_root"),
    [switch]$NoClient
)

$ErrorActionPreference = "Stop"
$src = Resolve-Path (Join-Path $PSScriptRoot "..\mods\SDCoop\scripts")

function Deploy-To([string]$root, [string]$label, [hashtable]$firstConfig) {
    $modsDir = Join-Path $root "SurrounDead\Binaries\Win64\ue4ss\Mods"
    if (-not (Test-Path $modsDir)) {
        Write-Warning "[$label] UE4SS not found: $modsDir"
        return
    }
    $modDir = Join-Path $modsDir "SDCoop"
    $dst = Join-Path $modDir "scripts"
    New-Item -ItemType Directory -Force $dst | Out-Null

    $names = @()
    foreach ($f in Get-ChildItem $src -Filter *.lua) {
        Copy-Item $f.FullName (Join-Path $dst $f.Name) -Force
        $names += $f.Name
    }
    foreach ($old in Get-ChildItem $dst -Filter *.lua) {
        if ($names -notcontains $old.Name) {
            Remove-Item $old.FullName -Force
            Write-Host "[$label] removed stale $($old.Name)"
        }
    }

    # Steam join helper (sdc_steamlink); in use while the game runs
    $helper = Join-Path $PSScriptRoot "..\mods\SDCoop\steamlink\SDCoopSteamLink.exe"
    if (Test-Path $helper) {
        $h = Join-Path $modDir "steamlink"
        New-Item -ItemType Directory -Force $h | Out-Null
        try { Copy-Item $helper $h -Force -ErrorAction Stop } catch { Write-Warning "[$label] steamlink exe in use: $_" }
    }

    $modsTxt = Join-Path $modsDir "mods.txt"
    if (Test-Path $modsTxt) {
        $lines = Get-Content $modsTxt
        if (-not ($lines -match '^\s*SDCoop\s*:')) {
            # Keybinds must stay last.
            $out = @()
            $added = $false
            foreach ($l in $lines) {
                if (-not $added -and $l -match '^\s*Keybinds\s*:') { $out += "SDCoop : 1"; $added = $true }
                $out += $l
            }
            if (-not $added) { $out += "SDCoop : 1" }
            Set-Content -Path $modsTxt -Value $out -Encoding ascii
            Write-Host "[$label] enabled SDCoop in mods.txt"
        } elseif ($lines -match '^\s*SDCoop\s*:\s*0') {
            (Get-Content $modsTxt) -replace '^\s*SDCoop\s*:\s*0', 'SDCoop : 1' | Set-Content $modsTxt -Encoding ascii
            Write-Host "[$label] re-enabled SDCoop in mods.txt"
        }
    }

    # A new build gets a fresh chance to build its menu: the crash marker is
    # also left behind when the game is killed while the menu is being built.
    $marker = Join-Path $modDir "ui_build.marker"
    if (Test-Path $marker) {
        Remove-Item $marker -Force
        Write-Host "[$label] removed stale ui_build.marker"
    }

    $cfg = Join-Path $modDir "config.ini"
    if (-not (Test-Path $cfg) -and $firstConfig) {
        $body = "# SDCoop settings (created by deploy.ps1; the mod adds the remaining keys)`r`n"
        foreach ($k in $firstConfig.Keys) { $body += "$k = $($firstConfig[$k])`r`n" }
        [IO.File]::WriteAllText($cfg, $body, (New-Object Text.UTF8Encoding($false)))
        Write-Host "[$label] created config.ini"
    }
    Write-Host "[$label] deployed $($names.Count) scripts -> $dst"
}

Deploy-To $GameDir "game" $null
if (-not $NoClient -and (Test-Path $ClientDir)) {
    Deploy-To (Resolve-Path $ClientDir) "test-client" @{ auto_join = "true"; host_ip = "127.0.0.1"; player_name = "Client" }
}

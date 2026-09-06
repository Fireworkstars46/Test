$ErrorActionPreference = 'Stop'

# v3.14 is the first stable release candidate after the v3.12 in-process
# self-test passed 14/14 and the v3.13 real close/reopen test passed 14/14.
# Keep both diagnostic test modes and optional logging available for future OBS
# updates, but remove the DEBUG product/version labeling for normal daily use.
& ./build-v3.13-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.14 stable patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.13.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.14.0";' 'stable plugin version'

# Keep all diagnostics, including Full Self-Test, Real Restart Test, and optional
# debug logging. Only the build/product presentation changes from DEBUG to stable.
$s = $s.Replace('OBS UI Scale v3.13 DEBUG LOG', 'OBS UI Scale v3.14 LOG')
$s = $s.Replace('OBS UI Scale v3.13 DEBUG', 'OBS UI Scale v3.14')
$s = $s.Replace('OBS UI Scale v3.13', 'OBS UI Scale v3.14')
$s = $s.Replace('v3.13 DEBUG', 'v3.14')
$s = $s.Replace('v3.13', 'v3.14')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.13.0', '3.14.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.14.0', 'OBS-UI-Scale-Setup-3.14.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.14 stable build with diagnostics retained.'

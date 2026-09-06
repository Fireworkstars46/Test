$ErrorActionPreference = 'Stop'

# v3.17 is the stable release after v3.16.1's Complete User-Action Test passed
# 29/29 on the target OBS setup. Keep every diagnostic/recovery feature from
# v3.16.1, but remove DEBUG product/version branding for normal daily use.
& ./build-v3.16.1-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.17 stable patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.16.1-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.17.0";' 'stable plugin version'

# Keep Full Self-Test, Real Restart Test, Complete User-Action Test, abandoned
# test recovery, and optional debug logging. Only user-facing build/version
# presentation changes from DEBUG to stable.
$s = $s.Replace('OBS UI Scale v3.16.1 DEBUG LOG', 'OBS UI Scale v3.17 LOG')
$s = $s.Replace('OBS UI Scale v3.16.1 DEBUG', 'OBS UI Scale v3.17')
$s = $s.Replace('OBS UI Scale v3.16.1', 'OBS UI Scale v3.17')
$s = $s.Replace('v3.16.1 DEBUG', 'v3.17')
$s = $s.Replace('v3.16.1', 'v3.17')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.16.1', '3.17.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.17.0', 'OBS-UI-Scale-Setup-3.17.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.17 stable build with all diagnostics and recovery retained.'

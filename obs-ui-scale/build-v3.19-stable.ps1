$ErrorActionPreference = 'Stop'

# v3.19 is the stable release after v3.18.1's Complete Combination-Matrix Test
# passed 39/39 on the target OBS setup. Keep all diagnostics, recovery, logging,
# real Apply-path testing, restart testing, and the full combination matrix.
# Only remove DEBUG product/version branding for normal daily use.
& ./build-v3.18.1-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.19 stable patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.18.1-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.19.0";' 'stable plugin version'

# Keep Full Self-Test, Real Restart Test, Complete Combination-Matrix Test,
# abandoned-test recovery, and optional debug logging. Only user-facing build/
# version presentation changes from DEBUG to stable.
$s = $s.Replace('OBS UI Scale v3.18.1 DEBUG LOG', 'OBS UI Scale v3.19 LOG')
$s = $s.Replace('OBS UI Scale v3.18.1 DEBUG', 'OBS UI Scale v3.19')
$s = $s.Replace('OBS UI Scale v3.18.1', 'OBS UI Scale v3.19')
$s = $s.Replace('v3.18.1 DEBUG', 'v3.19')
$s = $s.Replace('v3.18.1', 'v3.19')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.18.1', '3.19.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.19.0', 'OBS-UI-Scale-Setup-3.19.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.19 stable build with the passing 39/39 combination matrix retained.'

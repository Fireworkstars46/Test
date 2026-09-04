$ErrorActionPreference = 'Stop'

# v3.4 fixes v3.3's restart restore edge case. OBS can auto-apply the UI scale
# more than once during startup, so v3.3's "use the saved manual height only on
# the first Apply" flag could let a later startup Apply replace the saved target
# with OBS's reopened/taller geometry. Treat the persisted manual height as the
# canonical manual target on every Apply until the user genuinely drags again.
# The existing manual-drag capture updates the persisted value immediately, so
# subsequent Apply presses still use the user's newest position.
& ./build-v3.3-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.4 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.3.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.4.0-debug";' 'plugin version'

Replace-Required @'
        if (QDockWidget *sceneDockBeforeApply = ScenesDock()) {
            const int currentDockHeight = sceneDockBeforeApply->isVisible() ? sceneDockBeforeApply->height() : -1;
            if (!startupSavedDockRestoreUsed_ && savedManualSceneDockHeight_ > 0 && currentDockHeight > 0) {
                applyPreservedSceneDockHeight_ = savedManualSceneDockHeight_;
                startupSavedDockRestoreUsed_ = true;
                DebugWrite(QStringLiteral("STARTUP MANUAL DOCK POSITION LOADED height=%1")
                               .arg(savedManualSceneDockHeight_));
            } else {
                applyPreservedSceneDockHeight_ = currentDockHeight;
            }
        } else {
            applyPreservedSceneDockHeight_ = -1;
        }
'@ @'
        if (QDockWidget *sceneDockBeforeApply = ScenesDock()) {
            const int currentDockHeight = sceneDockBeforeApply->isVisible() ? sceneDockBeforeApply->height() : -1;
            if (savedManualSceneDockHeight_ > 0 && currentDockHeight > 0) {
                // The saved manual height is authoritative across repeated startup
                // auto-Apply passes. A genuine user drag updates this saved value,
                // so normal Apply later in the session still follows the newest
                // user-selected position.
                applyPreservedSceneDockHeight_ = savedManualSceneDockHeight_;
                DebugWrite(QStringLiteral("PERSISTED MANUAL DOCK POSITION USED height=%1 current=%2")
                               .arg(savedManualSceneDockHeight_)
                               .arg(currentDockHeight));
            } else {
                applyPreservedSceneDockHeight_ = currentDockHeight;
            }
        } else {
            applyPreservedSceneDockHeight_ = -1;
        }
'@ 'always prefer persisted manual height on Apply'

Replace-Required @'
    int savedManualSceneDockHeight_ = -1;
    bool startupSavedDockRestoreUsed_ = false;
'@ @'
    int savedManualSceneDockHeight_ = -1;
'@ 'remove one-shot startup restore flag'

$s = $s.Replace('OBS UI Scale v3.3 DEBUG', 'OBS UI Scale v3.4 DEBUG')
$s = $s.Replace('OBS UI Scale v3.3 DEBUG LOG', 'OBS UI Scale v3.4 DEBUG LOG')
$s = $s.Replace('v3.3 DEBUG keeps the v3.2 Apply/scene stability fixes and also saves the genuine manual bottom-dock height so the same position is restored after restarting OBS. Debug logging remains optional.',
                'v3.4 DEBUG keeps the v3.2 stability fixes and makes the persisted manual bottom-dock height authoritative across repeated startup Apply passes, so restart restoration cannot be overwritten. Debug logging remains optional.')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.3.0', '3.4.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.3.0', 'OBS-UI-Scale-Debug-Setup-3.4.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.4 DEBUG persistent restart dock restoration.'

$ErrorActionPreference = 'Stop'

# v3.10 keeps the working v3.9 scene-row, mixer, startup, and gesture-qualified
# manual persistence fixes, but corrects Apply preservation. v3.4 made the saved
# manual dock height authoritative on EVERY Apply in order to survive repeated
# startup Apply passes. After v3.5 added a dedicated startup-layout readiness
# path, that behavior became wrong for a user-initiated Apply: if the current
# visible dock height differs from the last persisted manual height, Apply could
# jump back to the old saved value instead of preserving what is on screen.
#
# v3.10 distinguishes startup auto-Apply from normal/user Apply. Only startup
# auto-Apply is allowed to use the persisted manual height. Every other Apply
# snapshots the CURRENT visible Scenes dock height at the exact start of Apply,
# uses that as the temporary row ceiling through the whole Apply settle window,
# and restores that same height afterward. The persistent manual height is still
# changed only by the real separator-drag path from v3.9.
& ./build-v3.9-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.10 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.9.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.10.0-debug";' 'plugin version'

# v3.4 intentionally preferred the persisted manual height on every Apply. Now
# that startup Apply has its own guarded path, use the saved height ONLY there.
# A normal Apply always snapshots the exact current visible dock height.
Replace-Required @'
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
'@ @'
        if (QDockWidget *sceneDockBeforeApply = ScenesDock()) {
            const int currentDockHeight = sceneDockBeforeApply->isVisible() ? sceneDockBeforeApply->height() : -1;
            if (startupApplyUsesSavedManual_ && savedManualSceneDockHeight_ > 0 && currentDockHeight > 0) {
                // On automatic startup Apply only, restore the persisted genuine
                // manual position because OBS may have reopened with different
                // dock geometry before the plugin takes control.
                applyPreservedSceneDockHeight_ = savedManualSceneDockHeight_;
                DebugWrite(QStringLiteral("STARTUP PERSISTED MANUAL DOCK POSITION USED height=%1 current=%2")
                               .arg(savedManualSceneDockHeight_)
                               .arg(currentDockHeight));
            } else {
                // User/manual Apply must preserve exactly what is visible NOW,
                // not an older persisted drag height. v3.2's temporary row ceiling
                // then holds this value throughout Apply so there is no flash/jump.
                applyPreservedSceneDockHeight_ = currentDockHeight;
                DebugWrite(QStringLiteral("APPLY CURRENT DOCK POSITION SNAPSHOT height=%1 savedManual=%2 startup=%3")
                               .arg(currentDockHeight)
                               .arg(savedManualSceneDockHeight_)
                               .arg(startupApplyUsesSavedManual_ ? 1 : 0));
            }
        } else {
            applyPreservedSceneDockHeight_ = -1;
        }
'@ 'preserve current visible dock height on normal Apply'

# Mark only the synchronous entry into the startup Apply path. ApplyScale reads
# this flag immediately when it snapshots applyPreservedSceneDockHeight_; all of
# its delayed restoration work uses that captured value, so the flag can be
# cleared immediately after ApplyScale returns.
Replace-Required @'
            ApplyScale(uiPercent_, textPercent_);
            return;
'@ @'
            startupApplyUsesSavedManual_ = true;
            ApplyScale(uiPercent_, textPercent_);
            startupApplyUsesSavedManual_ = false;
            return;
'@ 'mark startup auto-Apply as the only saved-height restore path'

Replace-Required @'
    int startupAutoApplyGeneration_ = 0;
    bool startupAutoApplyDone_ = false;
'@ @'
    int startupAutoApplyGeneration_ = 0;
    bool startupAutoApplyDone_ = false;
    bool startupApplyUsesSavedManual_ = false;
'@ 'startup Apply source flag'

$s = $s.Replace('OBS UI Scale v3.9 DEBUG', 'OBS UI Scale v3.10 DEBUG')
$s = $s.Replace('OBS UI Scale v3.9 DEBUG LOG', 'OBS UI Scale v3.10 DEBUG LOG')
$s = $s.Replace('v3.9 DEBUG keeps the v3.8 scene-row/mixer fix and saves a manual dock height only from a real user drag of the bottom-row separator, so OBS/window layout changes cannot overwrite it. Debug logging remains optional.',
                'v3.10 DEBUG keeps the v3.9 persistence fix and makes normal Apply preserve the exact currently visible dock height while startup Apply alone restores the persisted manual height. Debug logging remains optional.')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.9.0', '3.10.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.9.0', 'OBS-UI-Scale-Debug-Setup-3.10.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.10 DEBUG current-visible-height Apply preservation.'

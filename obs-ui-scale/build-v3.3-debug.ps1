$ErrorActionPreference = 'Stop'

# v3.3 fixes the remaining restart-only behavior. v3.2 preserves the user's
# manually dragged bottom-dock height while OBS is running, but that learned
# height exists only in Qt dock properties. OBS can reopen with a different
# dock geometry before UI Scale auto-applies, so the user's manual location is
# lost across a full OBS restart.
#
# Persist the genuine manual Scenes-dock height in obs-ui-scale.ini and use it
# as the preserved Apply target on the first Apply after startup. The normal
# minimum-scene-row floor still wins if it is taller than the saved position.
& ./build-v3.2-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.3 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.2.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.3.0-debug";' 'plugin version'

# Load the last genuinely-manual Scenes dock height. Existing installs without
# the key simply use -1 and retain v3.2 behavior until the user drags the dock.
Replace-Required @'
        sceneVisibleRows_ = qBound(1, sceneVisibleRows_, 1000);
'@ @'
        sceneVisibleRows_ = qBound(1, sceneVisibleRows_, 1000);
        savedManualSceneDockHeight_ = settings_ ? settings_->value(QStringLiteral("ui/manualSceneDockHeight"), -1).toInt() : -1;
        if (savedManualSceneDockHeight_ <= 0)
            savedManualSceneDockHeight_ = -1;
'@ 'load persisted manual Scenes dock height'

# v3.1/v3.2 normally preserve whatever height OBS currently has immediately
# before Apply. On the first Apply after plugin startup, prefer our persisted
# genuine manual height instead, because OBS may have reopened the row taller.
Replace-Required @'
        if (QDockWidget *sceneDockBeforeApply = ScenesDock())
            applyPreservedSceneDockHeight_ = sceneDockBeforeApply->isVisible() ? sceneDockBeforeApply->height() : -1;
        else
            applyPreservedSceneDockHeight_ = -1;
'@ @'
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
'@ 'use persisted manual height on first startup Apply'

# Save only from the already-vetted manual-resize path. This timer runs only
# when no scene guard, Apply suppression, or plugin restore is active, so OBS's
# own automatic layout changes are not written as the user's preference.
Replace-Required @'
                            CaptureStableDockTargets();
                            DebugWrite(QStringLiteral("MANUAL DOCK SIZE CAPTURED"));
'@ @'
                            CaptureStableDockTargets();
                            if (QDockWidget *sceneDock = ScenesDock()) {
                                const int manualHeight = sceneDock->height();
                                const int floorHeight = sceneRowLockEnabled_ ? qMax(1, lockedSceneDockHeight_) : 1;
                                if (manualHeight >= floorHeight && manualHeight > 0) {
                                    savedManualSceneDockHeight_ = manualHeight;
                                    if (settings_) {
                                        settings_->setValue(QStringLiteral("ui/manualSceneDockHeight"),
                                                            savedManualSceneDockHeight_);
                                        settings_->sync();
                                    }
                                    DebugWrite(QStringLiteral("MANUAL SCENE DOCK HEIGHT SAVED height=%1")
                                                   .arg(savedManualSceneDockHeight_));
                                }
                            }
                            DebugWrite(QStringLiteral("MANUAL DOCK SIZE CAPTURED"));
'@ 'persist genuine manual dock height'

Replace-Required @'
    bool suppressManualDockCapture_ = false;
    int applyPreservedSceneDockHeight_ = -1;
'@ @'
    bool suppressManualDockCapture_ = false;
    int applyPreservedSceneDockHeight_ = -1;
    int savedManualSceneDockHeight_ = -1;
    bool startupSavedDockRestoreUsed_ = false;
'@ 'startup persistence members'

# Self-identifying UI/log text.
$s = $s.Replace('OBS UI Scale v3.2 DEBUG', 'OBS UI Scale v3.3 DEBUG')
$s = $s.Replace('OBS UI Scale v3.2 DEBUG LOG', 'OBS UI Scale v3.3 DEBUG LOG')
$s = $s.Replace('v3.2 DEBUG keeps the adjustable scene-row minimum, mixer overflow protection, and manual dock preservation, while preventing the temporary taller bottom-row flash during Apply. Debug logging remains optional.',
                'v3.3 DEBUG keeps the v3.2 Apply/scene stability fixes and also saves the genuine manual bottom-dock height so the same position is restored after restarting OBS. Debug logging remains optional.')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.2.0', '3.3.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.2.0', 'OBS-UI-Scale-Debug-Setup-3.3.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.3 DEBUG persistent manual dock height across restarts.'

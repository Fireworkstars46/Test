$ErrorActionPreference = 'Stop'

# v3.1 keeps v3.0's mixer-overflow cleanup and fixes the last Apply behavior:
# a user-manually-positioned bottom dock row must survive Apply. OBS may resize
# the row several times while the scale/layout settles; none of those automatic
# resizes may become the new manual target.
& ./build-v3.0-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.1 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.0.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.1.0-debug";' 'plugin version'

# Capture the user's current Scenes-dock height before Apply releases constraints
# and before proportional scaling starts moving the Qt dock row. Keep manual-size
# capture suppressed until every delayed Apply/row-lock pass has finished.
Replace-Required @'
    void ApplyScale(double requestedUiPercent, double requestedTextPercent)
    {
        ReleaseSceneRowLockConstraints();
        suppressManualDockCapture_ = true;
        ++manualDockCaptureGeneration_;
        const int manualSuppressGeneration = ++manualDockSuppressGeneration_;
        QTimer::singleShot(1500, this, [this, manualSuppressGeneration]() {
            if (manualSuppressGeneration == manualDockSuppressGeneration_)
                suppressManualDockCapture_ = false;
        });
        DebugWrite(QStringLiteral("APPLY START requested UI=%1 text=%2")
'@ @'
    void ApplyScale(double requestedUiPercent, double requestedTextPercent)
    {
        if (QDockWidget *sceneDockBeforeApply = ScenesDock())
            applyPreservedSceneDockHeight_ = sceneDockBeforeApply->isVisible() ? sceneDockBeforeApply->height() : -1;
        else
            applyPreservedSceneDockHeight_ = -1;

        ReleaseSceneRowLockConstraints();
        suppressManualDockCapture_ = true;
        ++manualDockCaptureGeneration_;
        const int manualSuppressGeneration = ++manualDockSuppressGeneration_;

        // OBS and the row-minimum code can continue settling well past the old
        // 1.5 second cutoff. Keep Apply-owned movement out of manual learning,
        // then make the user's pre-Apply position the final saved target.
        QTimer::singleShot(2600, this, [this, manualSuppressGeneration]() {
            if (manualSuppressGeneration != manualDockSuppressGeneration_)
                return;

            if (applyPreservedSceneDockHeight_ > 0) {
                auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
                QDockWidget *sceneDock = ScenesDock();
                if (mainWindow && sceneDock) {
                    const int floorHeight = sceneRowLockEnabled_ ? qMax(1, lockedSceneDockHeight_) : 1;
                    const int restoreHeight = qMax(floorHeight, applyPreservedSceneDockHeight_);
                    restoringDockTargets_ = true;
                    mainWindow->resizeDocks({sceneDock}, {restoreHeight}, Qt::Vertical);
                    restoringDockTargets_ = false;
                    ReassertSceneRowLock();
                    CaptureStableDockTargets();
                    DebugWrite(QStringLiteral("APPLY MANUAL DOCK POSITION RESTORED height=%1")
                                   .arg(restoreHeight));
                }
            }

            applyPreservedSceneDockHeight_ = -1;
            suppressManualDockCapture_ = false;
        });
        DebugWrite(QStringLiteral("APPLY START requested UI=%1 text=%2")
'@ 'preserve manual dock position through Apply'

# v2.9/v3.0 intentionally starts the dock at the selected minimum after Apply.
# For an already-manually-positioned dock, preserve that position instead (but
# never below a newly selected minimum). This executes on each delayed row-lock
# capture, so Qt does not get to leave the row at its temporary Apply height.
Replace-Required @'
        // Applying/changing the setting starts the dock at the selected minimum.
        // After this one-time resize, normal upward dragging remains unrestricted.
        mainWindow->resizeDocks({sceneDock}, {lockedSceneDockHeight_}, Qt::Vertical);
        ReassertSceneRowLock();
'@ @'
        // Keep the user's pre-Apply manual position when one exists. If the user
        // raised the configured minimum above that position, the new minimum wins.
        const int applyDockHeight = applyPreservedSceneDockHeight_ > 0
                                        ? qMax(lockedSceneDockHeight_, applyPreservedSceneDockHeight_)
                                        : lockedSceneDockHeight_;
        mainWindow->resizeDocks({sceneDock}, {applyDockHeight}, Qt::Vertical);
        ReassertSceneRowLock();
'@ 'restore manual height instead of forcing minimum on Apply'

# The final 700ms stable-target capture from v2.6 is still useful, but make sure
# the preserved manual position is re-applied first so the saved target cannot be
# OBS's temporary Apply geometry.
Replace-Required @'
        QTimer::singleShot(700, this, [this, uiPercent]() {
            if (qAbs(currentUiPercent_ - uiPercent) < 0.01 && !sceneDockGuardActive_) {
                CaptureStableDockTargets();
                DebugWrite(QStringLiteral("POST-APPLY DOCK TARGETS CAPTURED"));
            }
        });
'@ @'
        QTimer::singleShot(700, this, [this, uiPercent]() {
            if (qAbs(currentUiPercent_ - uiPercent) < 0.01 && !sceneDockGuardActive_) {
                if (applyPreservedSceneDockHeight_ > 0) {
                    auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
                    QDockWidget *sceneDock = ScenesDock();
                    if (mainWindow && sceneDock) {
                        const int floorHeight = sceneRowLockEnabled_ ? qMax(1, lockedSceneDockHeight_) : 1;
                        const int restoreHeight = qMax(floorHeight, applyPreservedSceneDockHeight_);
                        restoringDockTargets_ = true;
                        mainWindow->resizeDocks({sceneDock}, {restoreHeight}, Qt::Vertical);
                        restoringDockTargets_ = false;
                        ReassertSceneRowLock();
                    }
                }
                CaptureStableDockTargets();
                DebugWrite(QStringLiteral("POST-APPLY DOCK TARGETS CAPTURED"));
            }
        });
'@ 'protect post-Apply stable target capture'

Replace-Required @'
    int manualDockCaptureGeneration_ = 0;
    int manualDockSuppressGeneration_ = 0;
    bool suppressManualDockCapture_ = false;
'@ @'
    int manualDockCaptureGeneration_ = 0;
    int manualDockSuppressGeneration_ = 0;
    bool suppressManualDockCapture_ = false;
    int applyPreservedSceneDockHeight_ = -1;
'@ 'Apply preserved-height member'

# Self-identifying UI/log text.
$s = $s.Replace('OBS UI Scale v3.0 DEBUG', 'OBS UI Scale v3.1 DEBUG')
$s = $s.Replace('OBS UI Scale v3.0 DEBUG LOG', 'OBS UI Scale v3.1 DEBUG LOG')
$s = $s.Replace('v3.0 DEBUG keeps the adjustable minimum scene rows, prevents the Audio Mixer child from overflowing its available dock height, and ignores Apply-generated resizes when learning manual dock positions. Debug logging remains optional.',
                'v3.1 DEBUG keeps the adjustable minimum scene rows and mixer overflow protection, and preserves the user-manually-dragged bottom dock position across Apply. Debug logging remains optional.')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.0.0', '3.1.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.0.0', 'OBS-UI-Scale-Debug-Setup-3.1.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.1 DEBUG Apply manual-position preservation.'

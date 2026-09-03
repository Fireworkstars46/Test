$ErrorActionPreference = 'Stop'

# v3.0 cleans up the two remaining issues found by the v2.9 debug trace:
#  1) stackedMixerArea could internally expand beyond the space actually available
#     in its dock (for example 197px while the AudioMixer parent was only 158px).
#  2) Apply-generated dock resizes could be misclassified as a user manual drag.
#
# Keep v2.9's adjustable minimum scene-row behavior and free upward dragging.
& ./build-v2.9-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.0 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "2.9.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.0.0-debug";' 'plugin version'

# v2.9 intentionally left stackedMixerArea uncapped so the row could grow, but
# OBS can then give that child a stale/oversized actual height after a scene
# switch. Compute the child ceiling dynamically from the current row height:
#   mixer minimum + (current scene dock height - selected scene-row minimum).
# This preserves upward dragging because the ceiling grows with the row.
$oldReassert = @'
    void ReassertSceneRowLock()
    {
        if (!sceneRowLockEnabled_ || lockedSceneDockHeight_ <= 0 || lockedMixerHeight_ <= 0 ||
            sceneRowLockApplying_)
            return;

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        QStackedWidget *mixer = StackedMixerArea();
        if (!mainWindow || !sceneDock || !mixer)
            return;

        sceneRowLockApplying_ = true;

        // This is a MINIMUM only. OBS may not raise the mixer minimum above the
        // scaled row-count target, but the user remains free to drag the whole
        // dock row taller than the minimum.
        mixer->setMaximumHeight(QWIDGETSIZE_MAX);
        mixer->setMinimumHeight(lockedMixerHeight_);
        sceneDock->setMaximumHeight(QWIDGETSIZE_MAX);
        sceneDock->setMinimumHeight(lockedSceneDockHeight_);

        // Only intervene if something actually tries to shrink below the chosen
        // minimum. Never pull a manually enlarged dock back down.
        if (sceneDock->height() < lockedSceneDockHeight_)
            mainWindow->resizeDocks({sceneDock}, {lockedSceneDockHeight_}, Qt::Vertical);

        sceneRowLockApplying_ = false;
    }

'@
$newReassert = @'
    void ReassertSceneRowLock()
    {
        if (!sceneRowLockEnabled_ || lockedSceneDockHeight_ <= 0 || lockedMixerHeight_ <= 0 ||
            sceneRowLockApplying_)
            return;

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        QStackedWidget *mixer = StackedMixerArea();
        if (!mainWindow || !sceneDock || !mixer)
            return;

        sceneRowLockApplying_ = true;

        // The selected row count remains a minimum only. The user can freely
        // drag the dock row taller than this floor.
        sceneDock->setMaximumHeight(QWIDGETSIZE_MAX);
        sceneDock->setMinimumHeight(lockedSceneDockHeight_);

        // stackedMixerArea must never be taller than the space represented by
        // the current dock row. If the row is manually enlarged, this ceiling
        // enlarges by the same amount, so upward dragging stays unrestricted.
        const int extraRowHeight = qMax(0, sceneDock->height() - lockedSceneDockHeight_);
        const int expectedMixerHeight = qMax(1, lockedMixerHeight_ + extraRowHeight);
        mixer->setMinimumHeight(lockedMixerHeight_);
        mixer->setMaximumHeight(expectedMixerHeight);

        if (mixer->height() > expectedMixerHeight)
            mixer->resize(mixer->width(), expectedMixerHeight);

        // Only intervene if something actually tries to shrink below the chosen
        // minimum. Never pull a manually enlarged dock back down.
        if (sceneDock->height() < lockedSceneDockHeight_)
            mainWindow->resizeDocks({sceneDock}, {lockedSceneDockHeight_}, Qt::Vertical);

        if (mixer->parentWidget() && mixer->parentWidget()->layout()) {
            mixer->parentWidget()->layout()->invalidate();
            mixer->parentWidget()->layout()->activate();
        }
        mixer->updateGeometry();

        sceneRowLockApplying_ = false;
    }

'@
Replace-Required $oldReassert $newReassert 'dynamic mixer actual-height ceiling'

# Do not let the quiet Resize watcher classify Apply's own resizeDocks/layout
# work as a manual user drag. Suppress only during the Apply settle window.
Replace-Required @'
    void ApplyScale(double requestedUiPercent, double requestedTextPercent)
    {
        ReleaseSceneRowLockConstraints();
        DebugWrite(QStringLiteral("APPLY START requested UI=%1 text=%2")
'@ @'
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
'@ 'suppress Apply-generated manual capture'

Replace-Required @'
        if (event && event->type() == QEvent::Resize && !sceneDockGuardActive_ &&
            !restoringDockTargets_ && proportionalMode_ && currentUiPercent_ < 99.999) {
'@ @'
        if (event && event->type() == QEvent::Resize && !sceneDockGuardActive_ &&
            !restoringDockTargets_ && !suppressManualDockCapture_ &&
            proportionalMode_ && currentUiPercent_ < 99.999) {
'@ 'skip manual capture during Apply settle'

Replace-Required @'
    int manualDockCaptureGeneration_ = 0;
'@ @'
    int manualDockCaptureGeneration_ = 0;
    int manualDockSuppressGeneration_ = 0;
    bool suppressManualDockCapture_ = false;
'@ 'manual capture suppression members'

# Self-identifying debug UI/log text.
$s = $s.Replace('OBS UI Scale v2.9 DEBUG', 'OBS UI Scale v3.0 DEBUG')
$s = $s.Replace('OBS UI Scale v2.9 DEBUG LOG', 'OBS UI Scale v3.0 DEBUG LOG')
$s = $s.Replace('v2.9 DEBUG uses an adjustable minimum scene-row count (6 by default). You can drag the dock taller, but not below that many rows. Debug logging remains optional.',
                'v3.0 DEBUG keeps the adjustable minimum scene rows, prevents the Audio Mixer child from overflowing its available dock height, and ignores Apply-generated resizes when learning manual dock positions. Debug logging remains optional.')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('2.9.0', '3.0.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-2.9.0', 'OBS-UI-Scale-Debug-Setup-3.0.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.0 DEBUG mixer geometry + manual capture cleanup.'

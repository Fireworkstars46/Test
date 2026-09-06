$ErrorActionPreference = 'Stop'

# v3.16 DEBUG starts from v3.15. v3.15 proved that genuine separator dragging is
# now persisted immediately, but the complete test exposed a second scene-change
# failure: after a real drag was saved (for example 255px), OBS could relayout the
# bottom row to a different live height (for example 275px) when a Scene changed.
#
# Make the newest persisted manual Scenes height the authoritative target for the
# entire Scene/preview-scene repair window. The scene-row minimum still wins if it
# is taller. Each repair first clears/reasserts the Audio Mixer constraints, then
# resizes the real Scenes dock to the authoritative target. The existing stable
# dock properties remain as a fallback only when no genuine manual height exists.
& ./build-v3.15-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.16 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

function Replace-Block([string]$startMarker, [string]$endMarker, [string]$newBlock, [string]$label) {
    $start = $script:s.IndexOf($startMarker)
    if ($start -lt 0) { throw "v3.16 could not locate start of $label" }
    $end = $script:s.IndexOf($endMarker, $start)
    if ($end -lt 0) { throw "v3.16 could not locate end of $label" }
    $script:s = $script:s.Substring(0, $start) + $newBlock.Replace("`r`n", "`n") + $script:s.Substring($end)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.15.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.16.0-debug";' 'plugin version'

# Replace the scene guard with a repair path that targets the newest genuine
# manual height directly instead of relying on a collection of stable properties
# from sibling docks. This is the exact path exercised by the v3.15 failure.
$sceneGuard = @'
    void RestoreAuthoritativeSceneDockTarget()
    {
        if (restoringDockTargets_ || !proportionalMode_ || currentUiPercent_ >= 99.999)
            return;

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        if (!mainWindow || !sceneDock || !sceneDock->isVisible() || sceneDock->isFloating())
            return;
        if (mainWindow->dockWidgetArea(sceneDock) != Qt::BottomDockWidgetArea)
            return;

        const int floorHeight = (sceneRowLockEnabled_ && lockedSceneDockHeight_ > 0)
                                    ? qMax(1, lockedSceneDockHeight_) : 1;

        // A genuine manual drag is the canonical target. If the user has never
        // made one, preserve the older stable-target behavior as a fallback.
        if (savedManualSceneDockHeight_ <= 0) {
            RestoreStableDockTargets();
            return;
        }

        const int targetHeight = qMax(floorHeight, savedManualSceneDockHeight_);

        // Scene changes can recreate/reset Audio Mixer minimums before
        // QMainWindow lays out the bottom row. Remove that hidden blocker first,
        // then establish a mixer ceiling corresponding to the manual row target.
        QStackedWidget *mixer = StackedMixerArea();
        QDockWidget *mixerDock = AudioMixerDock();
        if (mixerDock)
            mixerDock->setMinimumHeight(0);

        if (mixer && lockedMixerHeight_ > 0) {
            const int extraRowHeight = qMax(0, targetHeight - floorHeight);
            const int expectedMixerHeight = qMax(1, lockedMixerHeight_ + extraRowHeight);
            mixer->setMinimumHeight(lockedMixerHeight_);
            mixer->setMaximumHeight(expectedMixerHeight);
            if (mixer->height() > expectedMixerHeight)
                mixer->resize(mixer->width(), expectedMixerHeight);
            mixer->updateGeometry();
            if (mixer->parentWidget() && mixer->parentWidget()->layout()) {
                mixer->parentWidget()->layout()->invalidate();
                mixer->parentWidget()->layout()->activate();
            }
        }

        // Reassert clears any remaining OBS mixer-dock floor. Then resize only
        // the authoritative Scenes dock; sibling docks follow the same row.
        ReassertSceneRowLock();
        restoringDockTargets_ = true;
        mainWindow->resizeDocks({sceneDock}, {targetHeight}, Qt::Vertical);
        restoringDockTargets_ = false;
        ReassertSceneRowLock();

        // Qt can require a second request after the mixer layout invalidation.
        // Do it synchronously only when the first request did not land exactly.
        if (qAbs(sceneDock->height() - targetHeight) > 1) {
            restoringDockTargets_ = true;
            mainWindow->resizeDocks({sceneDock}, {targetHeight}, Qt::Vertical);
            restoringDockTargets_ = false;
            ReassertSceneRowLock();
        }

        // Keep the normal scene guard's stable properties aligned with the
        // authoritative manual target after a successful repair.
        if (qAbs(sceneDock->height() - targetHeight) <= 2)
            CaptureStableDockTargets();

        DebugWrite(QStringLiteral(
            "SCENE AUTHORITATIVE MANUAL HEIGHT RESTORE target=%1 live=%2 savedManual=%3 floor=%4")
                       .arg(targetHeight)
                       .arg(sceneDock->height())
                       .arg(savedManualSceneDockHeight_)
                       .arg(floorHeight));
    }

    void ArmSceneDockGuard()
    {
        if (!proportionalMode_ || currentUiPercent_ >= 99.999)
            return;

        // A Scene change is never allowed to become a manual resize. It also
        // cancels any obsolete quiet-capture generation from older builds.
        ++manualDockCaptureGeneration_;
        sceneDockGuardActive_ = true;
        const int generation = ++sceneDockGuardGeneration_;

        // OBS's mixer/context updates arrive in several deferred turns. Repair
        // the mixer first and then enforce the newest genuine manual target at
        // each quiet point. The window remains short so normal dragging is not
        // blocked for more than the existing scene-change settle period.
        RestoreMixerMinimumTarget();
        ReassertSceneRowLock();
        RestoreAuthoritativeSceneDockTarget();

        const int delays[] = {20, 60, 120, 220, 350, 550, 800, 1100, 1350};
        for (int delay : delays) {
            QTimer::singleShot(delay, this, [this, generation]() {
                if (generation != sceneDockGuardGeneration_ || !sceneDockGuardActive_)
                    return;
                RestoreMixerMinimumTarget();
                ReassertSceneRowLock();
                RestoreAuthoritativeSceneDockTarget();
            });
        }

        QTimer::singleShot(1500, this, [this, generation]() {
            if (generation == sceneDockGuardGeneration_) {
                RestoreMixerMinimumTarget();
                ReassertSceneRowLock();
                RestoreAuthoritativeSceneDockTarget();
                sceneDockGuardActive_ = false;
            }
        });
    }

'@
Replace-Block '    void ArmSceneDockGuard()' '    bool IsManualBottomRowResizeGesture() const' $sceneGuard 'authoritative scene-change dock guard'

# While the scene guard is active, a Resize event should queue the same
# authoritative repair rather than the old multi-dock stable-property restore.
Replace-Required @'
                    QTimer::singleShot(0, this, [this]() {
                        dockRestoreQueued_ = false;
                        RestoreStableDockTargets();
                    });
'@ @'
                    QTimer::singleShot(0, this, [this]() {
                        dockRestoreQueued_ = false;
                        RestoreAuthoritativeSceneDockTarget();
                    });
'@ 'scene guard resize queue uses authoritative manual target'

# Self-identifying debug UI/log text. Keep every v3.15 test, including the exact
# drag -> immediate Scene click regression sequence that exposed this bug.
$s = $s.Replace('OBS UI Scale v3.15 DEBUG', 'OBS UI Scale v3.16 DEBUG')
$s = $s.Replace('OBS UI Scale v3.15 DEBUG LOG', 'OBS UI Scale v3.16 DEBUG LOG')
$s = $s.Replace('OBS UI Scale v3.15 -', 'OBS UI Scale v3.16 -')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.15.0', '3.16.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.15.0', 'OBS-UI-Scale-Debug-Setup-3.16.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.16 DEBUG authoritative manual height on Scene changes.'

$ErrorActionPreference = 'Stop'

# v2.6 is based on the safe v2.5 diagnostic build. The user's trace proved two
# separate things happen on a scene change:
#   1) OBS resets stackedMixerArea's minimum height from the scaled 156px back to
#      about 197px.
#   2) QMainWindow expands the bottom dock row (e.g. 223px -> 264px). Lowering
#      the mixer minimum afterward does NOT automatically shrink the row again.
#
# v2.6 combines the two fixes in the correct order: restore the scaled Audio
# Mixer minimum, then restore the exact compact dock targets captured after
# Apply. It reuses v1.6's temporary resizeDocks guard (no permanent maxHeight),
# which previously could not win because the unscaled mixer minimum blocked it.
& ./build-v2.5-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v2.6 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "2.5.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "2.6.0-debug";' 'plugin version'

if (-not $s.Contains('#include <QStackedWidget>')) {
    $s = $s.Replace('#include <QStandardPaths>', "#include <QStandardPaths>`n#include <QStackedWidget>")
}

# Do not allow another plugin widget with the same objectName to be mistaken for
# OBS's mixer stack. The startup trace showed an AudioMonitorDock temporarily
# matching "stackedMixerArea" before OBS's real QStackedWidget existed.
Replace-Required @'
    QWidget *StackedMixerArea() const
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        if (!mainWindow)
            return nullptr;
        return mainWindow->findChild<QWidget *>(QStringLiteral("stackedMixerArea"),
                                                Qt::FindChildrenRecursively);
    }
'@ @'
    QStackedWidget *StackedMixerArea() const
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        if (!mainWindow)
            return nullptr;
        return mainWindow->findChild<QStackedWidget *>(QStringLiteral("stackedMixerArea"),
                                                       Qt::FindChildrenRecursively);
    }
'@ 'use the real mixer QStackedWidget'

# v2.2 waited 70/150ms before learning the target. The trace showed OBS had
# already reset the minimum by then, so the first Apply incorrectly learned 197.
# Capture synchronously while ApplyCapturedWidgetMetrics has the correct 78%
# value (156 in the trace), then run restore passes for any subsequent OBS reset.
Replace-Required @'
    void ScheduleMixerTargetCapture(double uiPercent)
    {
        // Let ApplyScale's queued style/layout passes settle first, then capture
        // the exact scaled minimum produced by Apply. No dock geometry is saved.
        QTimer::singleShot(70, this, [this, uiPercent]() {
            if (qAbs(currentUiPercent_ - uiPercent) < 0.01)
                CaptureMixerMinimumTarget(uiPercent);
        });
        QTimer::singleShot(150, this, [this, uiPercent]() {
            if (qAbs(currentUiPercent_ - uiPercent) < 0.01) {
                CaptureMixerMinimumTarget(uiPercent);
                RestoreMixerMinimumTarget();
            }
        });
    }
'@ @'
    void ScheduleMixerTargetCapture(double uiPercent)
    {
        if (qAbs(currentUiPercent_ - uiPercent) >= 0.01)
            return;

        CaptureMixerMinimumTarget(uiPercent);
        RestoreMixerMinimumTarget();
        ScheduleMixerMinimumRestore(uiPercent);
    }
'@ 'capture mixer target before OBS can reset it'

# The missing half of v2.2: after lowering the minimum, explicitly ask
# QMainWindow to restore the already-captured compact dock geometry. This is
# transient resizeDocks behavior, not a max-height constraint.
Replace-Required @'
    void ScheduleMixerMinimumRestore(double uiPercent)
    {
        // AudioMixer::queueLayoutUpdate() uses a zero-timeout QTimer and then
        // updateVolumeLayouts() resets stackedMixerArea's minimum size. These
        // passes run after that timer and reapply only our scaled minimum height.
        const int delays[] = {0, 10, 35, 90, 180};
        for (int delay : delays) {
            QTimer::singleShot(delay, this, [this, uiPercent]() {
                if (qAbs(currentUiPercent_ - uiPercent) < 0.01)
                    RestoreMixerMinimumTarget();
            });
        }
    }
'@ @'
    void ScheduleMixerMinimumRestore(double uiPercent)
    {
        // OBS first raises the mixer minimum, then QMainWindow keeps the larger
        // row even after that minimum is lowered. Correct both layers together.
        const int delays[] = {0, 10, 35, 90, 180};
        for (int delay : delays) {
            QTimer::singleShot(delay, this, [this, uiPercent]() {
                if (qAbs(currentUiPercent_ - uiPercent) < 0.01) {
                    RestoreMixerMinimumTarget();
                    RestoreStableDockTargets();
                }
            });
        }
    }
'@ 'restore mixer minimum then dock row'

# Re-enable v1.6's short scene guard now that the mixer minimum no longer blocks
# its resizeDocks requests. The guard expires automatically and never sets a
# permanent maximumHeight.
Replace-Required @'
            self->ScheduleContextBarRescale(self->currentUiPercent_);
            self->ScheduleMixerMinimumRestore(self->currentUiPercent_);
'@ @'
            self->ScheduleContextBarRescale(self->currentUiPercent_);
            self->ScheduleMixerMinimumRestore(self->currentUiPercent_);
            self->ArmSceneDockGuard();
'@ 'combine mixer repair with temporary dock guard'

# Any pending quiet manual-size capture must be cancelled as soon as a scene
# change starts, otherwise the scene-induced 264px expansion could be mistaken
# for a user drag and become the next saved target.
Replace-Required @'
    void ArmSceneDockGuard()
    {
        if (!proportionalMode_ || currentUiPercent_ >= 99.999)
            return;

        sceneDockGuardActive_ = true;
'@ @'
    void ArmSceneDockGuard()
    {
        if (!proportionalMode_ || currentUiPercent_ >= 99.999)
            return;

        ++manualDockCaptureGeneration_;
        sceneDockGuardActive_ = true;
'@ 'cancel manual capture when scene guard starts'

# Let genuine manual dock dragging become the new target. We only schedule a
# quiet capture after the Resize event has finished; no layout calls happen from
# inside the event itself. Scene changes cancel this timer via the generation.
$eventStart = $s.IndexOf('    bool eventFilter(QObject *watched, QEvent *event) override')
if ($eventStart -lt 0) { throw 'v2.6 could not locate eventFilter' }
$returnMarker = '        return QObject::eventFilter(watched, event);'
$returnPos = $s.IndexOf($returnMarker, $eventStart)
if ($returnPos -lt 0) { throw 'v2.6 could not locate eventFilter return' }
$manualCapture = @'
        if (event && event->type() == QEvent::Resize && !sceneDockGuardActive_ &&
            !restoringDockTargets_ && proportionalMode_ && currentUiPercent_ < 99.999) {
            if (auto *dock = qobject_cast<QDockWidget *>(watched)) {
                if (dock->property(PROP_DOCK_STABLE_H).isValid()) {
                    const int generation = ++manualDockCaptureGeneration_;
                    QTimer::singleShot(300, this, [this, generation]() {
                        if (generation == manualDockCaptureGeneration_ &&
                            !sceneDockGuardActive_ && !restoringDockTargets_) {
                            CaptureStableDockTargets();
                            DebugWrite(QStringLiteral("MANUAL DOCK SIZE CAPTURED"));
                        }
                    });
                }
            }
        }

'@
$s = $s.Substring(0, $returnPos) + $manualCapture + $s.Substring($returnPos)

# v1.6's original 120ms capture can be too early during startup/Apply. Keep it,
# but add a final post-settle capture after the later Apply geometry pass so the
# saved target reflects the compact row the user actually sees.
$applyMarker = '        ScheduleMixerTargetCapture(uiPercent);'
$applyPos = $s.IndexOf($applyMarker)
if ($applyPos -lt 0) { throw 'v2.6 could not locate Apply mixer capture call' }
$insertAfter = $applyPos + $applyMarker.Length
$lateCapture = @'
        QTimer::singleShot(700, this, [this, uiPercent]() {
            if (qAbs(currentUiPercent_ - uiPercent) < 0.01 && !sceneDockGuardActive_) {
                CaptureStableDockTargets();
                DebugWrite(QStringLiteral("POST-APPLY DOCK TARGETS CAPTURED"));
            }
        });
'@
$s = $s.Substring(0, $insertAfter) + "`n" + $lateCapture + $s.Substring($insertAfter)

Replace-Required 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v2.5 DEBUG"));' 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v2.6 DEBUG"));' 'dialog title'
$s = $s.Replace('v2.5 DEBUG keeps the v2.2 behavior with safer optional diagnostics. Logging uses timed Apply/scene snapshots only, not low-level Qt resize events.',
                'v2.6 DEBUG uses the trace-proven fix: restore the scaled mixer minimum, then restore the compact dock row. Debug logging remains optional.')

Replace-Required @'
    bool debugLoggingEnabled_ = false;
'@ @'
    bool debugLoggingEnabled_ = false;
    int manualDockCaptureGeneration_ = 0;
'@ 'manual dock capture member'

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('2.5.0', '2.6.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-2.5.0', 'OBS-UI-Scale-Debug-Setup-2.6.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v2.6 DEBUG combined mixer-minimum + dock-row restoration.'

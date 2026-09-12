$ErrorActionPreference = 'Stop'

# v3.25 DEBUG
# Fixes the manual-drag locking seen in the v3.24 trace.
#
# The trace showed the 1-row force repeatedly reaching 71px, but the persistent
# low-row maximum-height latch and scene/apply guards kept fighting the user's
# drag. This build changes low-row mode from a hard latch to a relaxed-layout
# mode: hidden minimum-size hints stay relaxed, but there is no persistent
# maximum-height cap. Manual dragging therefore remains native/free in both
# directions. Low-row snapping, when needed, happens only after drag release.
#
# It also cancels any Scene/Apply guard immediately when a genuine separator
# drag begins, freezes 1/2-row floor recalculation while in low-row mode, and
# batches DEBUG file writes so logging itself cannot make dragging stutter.
& ./build-v3.24-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.25 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}
function Replace-Block([string]$startMarker, [string]$endMarker, [string]$newBlock, [string]$label) {
    $start = $script:s.IndexOf($startMarker)
    if ($start -lt 0) { throw "v3.25 could not locate start of $label" }
    $end = $script:s.IndexOf($endMarker, $start)
    if ($end -lt 0) { throw "v3.25 could not locate end of $label" }
    $script:s = $script:s.Substring(0, $start) + $newBlock.Replace("`r`n", "`n") + $script:s.Substring($end)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.24.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.25.0-debug";' 'plugin version'

# Low-row descendants need their minimum-size hints ignored, but their maximum
# heights must stay unrestricted. The v3.24 max cap is what made the row feel
# physically locked after reaching one row.
Replace-Required @'
        widget->setMinimumHeight(0);
        widget->setMaximumHeight(targetHeight);
        QSizePolicy policy = widget->sizePolicy();
'@ @'
        widget->setMinimumHeight(0);
        // Keep maximumHeight unrestricted. Low-row mode is a minimum-size
        // relaxation, not a hard height lock.
        QSizePolicy policy = widget->sizePolicy();
'@ 'remove descendant low-row hard maximum'

# Same for the QDockWidgets themselves: preserve the normal maximum and vertical
# policy while the user drags. resizeDocks() can still place the row exactly at
# the requested floor because all hidden descendant minimum hints are relaxed.
Replace-Required @'
            dock->setMinimumHeight(dock == sceneDock ? targetHeight : 0);
            dock->setMaximumHeight(targetHeight);
            QSizePolicy dockPolicy = dock->sizePolicy();
            dockPolicy.setVerticalPolicy(QSizePolicy::Ignored);
            dock->setSizePolicy(dockPolicy);
'@ @'
            dock->setMinimumHeight(dock == sceneDock ? targetHeight : 0);
'@ 'remove dock hard maximum/ignored policy'

# A 1<->2 px floor recalc must not tear down and rebuild the whole relaxed tree.
# Keep the low-row relaxation alive while rows <= 2; it is restored only when
# leaving low-row mode or disabling the row feature.
Replace-Required @'
        if (lowRowFloorLatchActive_ && lowRowFloorLatchHeight_ != targetDockHeight)
            ReleaseLowRowFloorLatch();
'@ @'
        if (lowRowFloorLatchActive_ && sceneVisibleRows_ > 2)
            ReleaseLowRowFloorLatch();
'@ 'keep low-row relaxation across tiny floor recalculations'

# The old latch polled the mouse forever and restored/reapplied constraints on
# the next drag. That directly caused the "drag gets locked" behavior. Keep only
# a lightweight state marker; no polling and no automatic restore on drag.
Replace-Required @'
        if (latch) {
            lowRowFloorLatchActive_ = true;
            lowRowFloorLatchHeight_ = targetHeight;
            lowRowLatchSeenRelease_ = false;
            const int generation = ++lowRowFloorLatchGeneration_;
            PollLowRowFloorLatchForUnlock(generation);
        } else if (!reached) {
            lowRowFloorLatchActive_ = true;
            ReleaseLowRowFloorLatch();
        }
'@ @'
        if (latch) {
            lowRowFloorLatchActive_ = true;
            lowRowFloorLatchHeight_ = targetHeight;
            lowRowLatchSeenRelease_ = false;
            ++lowRowFloorLatchGeneration_;
        } else if (!reached) {
            lowRowFloorLatchActive_ = true;
            ReleaseLowRowFloorLatch();
        }
'@ 'remove low-row mouse polling latch'

# 1/2-row floor measurement should remain stable once captured. v3.24's delayed
# refresh oscillated 71->73->71 while the user was dragging.
Replace-Required @'
    void ScheduleSceneRowMinimumRefresh()
    {
        const int generation = ++sceneRowRefreshGeneration_;
'@ @'
    void ScheduleSceneRowMinimumRefresh()
    {
        if (sceneRowLockEnabled_ && sceneVisibleRows_ <= 2)
            return;

        const int generation = ++sceneRowRefreshGeneration_;
'@ 'freeze low-row floor during manual use'

# Manual movement must never run a programmatic low-row force while the mouse is
# still down. Delete the in-drag snap; the quiet settle below can land exactly on
# the floor once the user releases.
Replace-Required @'
                        if (sceneRowLockEnabled_ && sceneVisibleRows_ <= 2 && shrinking &&
                            manualHeight > floorHeight + 2 &&
                            manualHeight <= floorHeight + (pitch * 4)) {
                            ForceBottomRowHeightNow(
                                floorHeight, QStringLiteral("manual low-row snap"), true);
                            manualHeight = sceneDock->height();
                            lastManualObservedHeight_ = manualHeight;
                        }

'@ @'
                        Q_UNUSED(shrinking);
                        Q_UNUSED(pitch);

'@ 'remove force from hot manual drag path'

# After 90ms of quiet, if the released position is close to the requested 1/2
# row floor, finish the last few pixels once. Because there is no hard max latch
# anymore, the next upward drag is immediately free/native.
Replace-Required @'
                                    const int floor = sceneRowLockEnabled_
                                                        ? qMax(1, lockedSceneDockHeight_) : 1;
                                    const int finalHeight = qMax(floor, dock->height());
                                    savedManualSceneDockHeight_ = finalHeight;
'@ @'
                                    const int floor = sceneRowLockEnabled_
                                                        ? qMax(1, lockedSceneDockHeight_) : 1;

                                    if (sceneRowLockEnabled_ && sceneVisibleRows_ <= 2) {
                                        const int pitchNow = qMax(1, CurrentSceneRowHeight());
                                        if (dock->height() > floor + 2 &&
                                            dock->height() <= floor + (pitchNow * 2)) {
                                            ForceBottomRowHeightNow(
                                                floor,
                                                QStringLiteral("manual release low-row settle"),
                                                true);
                                        }
                                    }

                                    const int finalHeight = qMax(floor, dock->height());
                                    savedManualSceneDockHeight_ = finalHeight;
'@ 'snap low row only after drag release'

# A genuine separator press wins over every automated repair immediately, before
# the first Resize arrives. This prevents both Scene and Apply guards from
# holding the row at their old target during a new drag.
$eventMarker = '    bool eventFilter(QObject *watched, QEvent *event) override'
$eventPos = $s.IndexOf($eventMarker)
if ($eventPos -lt 0) { throw 'v3.25 could not locate eventFilter' }
$bracePos = $s.IndexOf('{', $eventPos)
if ($bracePos -lt 0) { throw 'v3.25 could not locate eventFilter opening brace' }
$insertPos = $bracePos + 1
$manualPress = @'

        if (event && event->type() == QEvent::MouseButtonPress &&
            IsManualBottomRowResizeGesture()) {
            if (sceneDockGuardActive_) {
                ++sceneDockGuardGeneration_;
                sceneDockGuardActive_ = false;
                sceneGuardTargetHeight_ = -1;
                DebugWrite(QStringLiteral("MANUAL PRESS CANCELLED ACTIVE SCENE GUARD"));
            }
            if (realApplySmoothGuardActive_) {
                ++realApplySmoothGuardGeneration_;
                realApplySmoothGuardActive_ = false;
                realApplySmoothExpectedHeight_ = -1;
                DebugWrite(QStringLiteral("MANUAL PRESS CANCELLED APPLY SMOOTH GUARD"));
            }
            ++sceneRowRefreshGeneration_;
            ++manualDragSettleGeneration_;
        }
'@
$s = $s.Substring(0, $insertPos) + $manualPress.Replace("`r`n", "`n") + $s.Substring($insertPos)

# If a scene-repair callback fires while the separator is genuinely being
# dragged, cancel it rather than resizing against the user's mouse.
Replace-Required @'
    void RestoreAuthoritativeSceneDockTarget()
    {
        if (restoringDockTargets_ || !proportionalMode_ || currentUiPercent_ >= 99.999)
            return;
'@ @'
    void RestoreAuthoritativeSceneDockTarget()
    {
        if (IsManualBottomRowResizeGesture()) {
            ++sceneDockGuardGeneration_;
            sceneDockGuardActive_ = false;
            sceneGuardTargetHeight_ = -1;
            return;
        }

        if (restoringDockTargets_ || !proportionalMode_ || currentUiPercent_ >= 99.999)
            return;
'@ 'scene repair yields to live manual drag'

Replace-Required @'
    void ArmSceneDockGuard()
    {
        if (!proportionalMode_ || currentUiPercent_ >= 99.999)
            return;
'@ @'
    void ArmSceneDockGuard()
    {
        if (IsManualBottomRowResizeGesture())
            return;
        if (!proportionalMode_ || currentUiPercent_ >= 99.999)
            return;
'@ 'do not arm scene guard during separator drag'

# When low-row mode is already the saved authoritative position, a later Scene
# guard must not resurrect an older 89px/91px target. The floor wins.
Replace-Required @'
        int targetHeight = -1;
        if (sceneDockGuardActive_ && sceneGuardTargetHeight_ > 0)
            targetHeight = qMax(floorHeight, sceneGuardTargetHeight_);
        else if (savedManualSceneDockHeight_ > 0)
'@ @'
        int targetHeight = -1;
        if (sceneRowLockEnabled_ && sceneVisibleRows_ <= 2 &&
            savedManualSceneDockHeight_ > 0 &&
            savedManualSceneDockHeight_ <= floorHeight + 3) {
            targetHeight = floorHeight;
            sceneGuardTargetHeight_ = floorHeight;
        } else if (sceneDockGuardActive_ && sceneGuardTargetHeight_ > 0)
            targetHeight = qMax(floorHeight, sceneGuardTargetHeight_);
        else if (savedManualSceneDockHeight_ > 0)
'@ 'low-row saved target overrides stale scene guard'

# Debug logging used to open/flush/close the Desktop log file for every line.
# Scene guards can produce many lines in a short interval, which itself causes
# stutter. Batch lines for 120ms and write them in one append operation.
$debugWrite = @'
    void FlushDebugBuffer()
    {
        debugFlushScheduled_ = false;
        if (debugPendingLines_.isEmpty() || debugLogPath_.isEmpty())
            return;

        QFile file(debugLogPath_);
        if (!file.open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text))
            return;

        const QByteArray bytes = debugPendingLines_.toUtf8();
        debugPendingLines_.clear();
        file.write(bytes);
        file.flush();
    }

    void DebugWrite(const QString &message)
    {
        if ((!debugLoggingEnabled_ && !completeTestForceLogging_) || debugLogPath_.isEmpty())
            return;

        debugPendingLines_ += QStringLiteral("[%1] %2\r\n")
                                  .arg(QDateTime::currentDateTime().toString(
                                           QStringLiteral("HH:mm:ss.zzz")),
                                       message);

        if (!debugFlushScheduled_) {
            debugFlushScheduled_ = true;
            QTimer::singleShot(120, this, [this]() {
                FlushDebugBuffer();
            });
        }
    }

'@
Replace-Block '    void DebugWrite(const QString &message)' '    QString DebugSceneName() const' $debugWrite 'batched debug file writes'

# Full geometry snapshots remain available to the complete test, but ordinary
# debug mode no longer walks every OBS dock/widget.
Replace-Required @'
    void DebugSnapshot(const QString &label)
    {
        if (!debugLoggingEnabled_)
            return;
'@ @'
    void DebugSnapshot(const QString &label)
    {
        if (!completeTestForceLogging_)
            return;
'@ 'disable expensive geometry snapshots during normal use'

# Flush the final buffered event before OBS exits.
Replace-Required @'
    void DebugFrontendEvent(enum obs_frontend_event event)
    {
        const QString eventName = DebugFrontendEventName(event);
        DebugWrite(QStringLiteral("FRONTEND EVENT %1 scene='%2'").arg(eventName, DebugSceneName()));
    }
'@ @'
    void DebugFrontendEvent(enum obs_frontend_event event)
    {
        const QString eventName = DebugFrontendEventName(event);
        DebugWrite(QStringLiteral("FRONTEND EVENT %1 scene='%2'").arg(eventName, DebugSceneName()));
        if (event == OBS_FRONTEND_EVENT_EXIT)
            FlushDebugBuffer();
    }
'@ 'flush debug buffer on exit'

Replace-Required @'
    bool completeTestForceLogging_ = false;
'@ @'
    bool completeTestForceLogging_ = false;
    QString debugPendingLines_;
    bool debugFlushScheduled_ = false;
'@ 'debug batching members'

$s = $s.Replace('OBS UI Scale v3.24 DEBUG', 'OBS UI Scale v3.25 DEBUG')
$s = $s.Replace('OBS UI Scale v3.24 DEBUG LOG', 'OBS UI Scale v3.25 DEBUG LOG')
$s = $s.Replace('v3.24 DEBUG', 'v3.25 DEBUG')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.24.0', '3.25.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.24.0', 'OBS-UI-Scale-Debug-Setup-3.25.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.25 DEBUG native-free manual drag + low-row relaxed layout.'

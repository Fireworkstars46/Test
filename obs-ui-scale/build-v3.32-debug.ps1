$ErrorActionPreference = 'Stop'

# v3.32 DEBUG
# Fixes the two remaining low-row/manual issues visible in the full v3.31 video:
#
# 1) several bottom-dock contents/text controls stayed visually collapsed or
#    invisible after low-row forcing because the recursive helper left child
#    QSizePolicy::Ignored / SetNoConstraint active indefinitely;
# 2) the manual "perfect row" snap was only temporary. Once the temporary Apply
#    ceiling was released, Qt could expand the row back above the exact N-row
#    geometry.
#
# v3.32 makes recursive child relaxation TEMPORARY only. Child policies/layouts
# are restored immediately after the row is placed, so normal OBS text/buttons
# render normally again.
#
# The exact 1/2-row position is then held only by a lightweight QDockWidget
# maximum-height latch. The latch releases BEFORE the next real separator drag
# (detected from the mouse position/button), so dragging remains native/free.
# A separate mouse-release watcher performs the exact-row snap only AFTER a real
# manual drag ends, never while the mouse is still moving.
& ./build-v3.31-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.32 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}
function Replace-Block([string]$startMarker, [string]$endMarker, [string]$newBlock, [string]$label) {
    $start = $script:s.IndexOf($startMarker)
    if ($start -lt 0) { throw "v3.32 could not locate start of $label" }
    $end = $script:s.IndexOf($endMarker, $start)
    if ($end -lt 0) { throw "v3.32 could not locate end of $label" }
    $script:s = $script:s.Substring(0, $start) + $newBlock.Replace("`r`n", "`n") + $script:s.Substring($end)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.31.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.32.0-debug";' 'plugin version'

if (-not $s.Contains('#include <QCursor>')) {
    if ($s.Contains('#include <QDateTime>')) {
        $s = $s.Replace('#include <QDateTime>', "#include <QDateTime>`n#include <QCursor>")
    } elseif ($s.Contains('#include <QDialog>')) {
        $s = $s.Replace('#include <QDialog>', "#include <QCursor>`n#include <QDialog>")
    } else {
        throw 'v3.32 could not find QCursor include insertion point'
    }
}

# Restore recursive child policies/layout constraints WITHOUT touching the
# QDockWidget max latch. This is what fixes the invisible/collapsed text/buttons.
$releaseMarker = '    void ReleaseLowRowFloorLatch()'
$releasePos = $s.IndexOf($releaseMarker)
if ($releasePos -lt 0) { throw 'v3.32 could not locate ReleaseLowRowFloorLatch' }

$visualRestoreHelper = @'
    void RestoreLowRowDescendantVisualState()
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        if (!mainWindow || !sceneDock)
            return;

        const int rowY = sceneDock->y();
        const auto docks =
            mainWindow->findChildren<QDockWidget *>(QString(),
                                                   Qt::FindDirectChildrenOnly);
        for (QDockWidget *dock : docks) {
            if (!dock || !dock->isVisible() || dock->isFloating())
                continue;
            if (mainWindow->dockWidgetArea(dock) != Qt::BottomDockWidgetArea)
                continue;
            if (qAbs(dock->y() - rowY) > 4)
                continue;

            if (QWidget *content = dock->widget()) {
                const auto descendants =
                    content->findChildren<QWidget *>(QString(),
                                                     Qt::FindChildrenRecursively);
                // Deepest widgets first, then their root content container.
                for (auto it = descendants.crbegin();
                     it != descendants.crend(); ++it)
                    RestoreLowRowWidgetCap(*it);
                RestoreLowRowWidgetCap(content);
            }

            dock->updateGeometry();
        }

        if (QLayout *layout = mainWindow->layout()) {
            layout->invalidate();
            layout->activate();
        }

        DebugWrite(QStringLiteral(
            "LOW ROW CHILD VISUAL POLICIES RESTORED latch=%1 target=%2")
                       .arg(lowRowFloorLatchActive_ ? 1 : 0)
                       .arg(lowRowFloorLatchHeight_));
    }

'@
$s = $s.Substring(0, $releasePos) +
     $visualRestoreHelper.Replace("`r`n", "`n") +
     $s.Substring($releasePos)

# v3.26 intentionally made this a no-op. Re-enable it with a simpler, robust
# splitter-intent check: if the user presses left mouse near the top edge of the
# Scenes dock, release the exact-row max latch BEFORE the splitter can move.
$poll = @'
    void PollLowRowFloorLatchForUnlock(int generation)
    {
        if (!lowRowFloorLatchActive_ ||
            generation != lowRowFloorLatchGeneration_)
            return;

        QDockWidget *sceneDock = ScenesDock();
        auto *mainWindow =
            static_cast<QMainWindow *>(obs_frontend_get_main_window());
        if (!sceneDock || !mainWindow)
            return;

        if (QApplication::mouseButtons() & Qt::LeftButton) {
            const QPoint cursor = QCursor::pos();
            const QPoint dockTopLeft =
                sceneDock->mapToGlobal(QPoint(0, 0));
            const int topY = dockTopLeft.y();
            const int leftX = dockTopLeft.x();
            const int rightX = leftX + sceneDock->width();

            // OBS's horizontal dock splitter is directly above the dock. Use a
            // generous vertical hit band so the latch releases before movement,
            // without reacting to ordinary Scene-list clicks lower in the dock.
            if (cursor.x() >= leftX - 8 && cursor.x() <= rightX + 8 &&
                qAbs(cursor.y() - topY) <= 14) {
                DebugWrite(QStringLiteral(
                    "EXACT ROW LATCH RELEASED BEFORE MANUAL SPLITTER DRAG target=%1")
                               .arg(lowRowFloorLatchHeight_));
                ReleaseLowRowFloorLatch();
                return;
            }
        }

        QTimer::singleShot(24, this, [this, generation]() {
            PollLowRowFloorLatchForUnlock(generation);
        });
    }

'@
Replace-Block '    void PollLowRowFloorLatchForUnlock(int generation)' '    bool ForceBottomRowHeightNow' $poll 'robust exact-row latch unlock watcher'

# Keep the row exact after a successful low-row force by capping only the live
# QDockWidgets themselves. Do NOT leave their child widgets in Ignored policy.
Replace-Required @'
            dock->setMinimumHeight(dock == sceneDock ? targetHeight : 0);

            if (QWidget *content = dock->widget()) {
'@ @'
            dock->setMinimumHeight(dock == sceneDock ? targetHeight : 0);
            dock->setMaximumHeight(targetHeight);

            if (QWidget *content = dock->widget()) {
'@ 'low-row dock-only exact maximum latch'

# When a low-row force latches, immediately restore all child visual policies,
# keep only the dock maximum latch, and start the next-drag unlock watcher.
Replace-Required @'
            lowRowFloorLatchHeight_ = targetHeight;
            lowRowLatchSeenRelease_ = false;
            ++lowRowFloorLatchGeneration_;
'@ @'
            lowRowFloorLatchHeight_ = targetHeight;
            lowRowLatchSeenRelease_ = false;
            const int latchGeneration = ++lowRowFloorLatchGeneration_;

            QTimer::singleShot(55, this, [this, latchGeneration]() {
                if (!lowRowFloorLatchActive_ ||
                    latchGeneration != lowRowFloorLatchGeneration_)
                    return;
                RestoreLowRowDescendantVisualState();
                PollLowRowFloorLatchForUnlock(latchGeneration);
            });
'@ 'temporary child compression + dock-only latch'

# If the low-row target changes because scale/font geometry changes, do not keep
# an old exact maximum. Release it first, then the new force can latch the new
# target cleanly.
Replace-Required @'
        if (targetHeight <= 0 || lowRowForceActive_)
            return false;

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
'@ @'
        if (targetHeight <= 0 || lowRowForceActive_)
            return false;

        if (lowRowFloorLatchActive_ &&
            lowRowFloorLatchHeight_ > 0 &&
            qAbs(lowRowFloorLatchHeight_ - targetHeight) > 2)
            ReleaseLowRowFloorLatch();

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
'@ 'release stale exact-row latch before new target'

# Replace v3.31's manual snap with a direct exact low-row force. Force now keeps
# only a dock maximum latch and automatically restores all child visual state.
$perfectSnap = @'
    void SnapManualSceneDockToExactRows()
    {
        if (!sceneRowLockEnabled_ || sceneVisibleRows_ > 2)
            return;

        QDockWidget *dock = ScenesDock();
        if (!dock)
            return;

        int exactTarget = CalculateSceneDockHeightForRows();
        if (exactTarget <= 0)
            exactTarget = qMax(1, lockedSceneDockHeight_);

        // Physical-floor adoption may have rounded the floor upward. A released
        // manual drag gets one exact geometric attempt instead.
        lockedSceneDockHeight_ = exactTarget;
        dock->setMinimumHeight(exactTarget);

        if (!ForceBottomRowHeightNow(
                exactTarget,
                QStringLiteral("manual released exact-row snap"), true)) {
            DebugWrite(QStringLiteral(
                "MANUAL PERFECT ROW SNAP could not reach exact=%1 live=%2")
                           .arg(exactTarget).arg(dock->height()));
        }

        QTimer::singleShot(150, this, [this, exactTarget]() {
            QDockWidget *dock = ScenesDock();
            if (!dock)
                return;

            const int finalHeight = dock->height();
            const int rows = CountFullyVisibleSceneRows();
            DebugWrite(QStringLiteral(
                "MANUAL PERFECT ROW SNAP SETTLED target=%1 final=%2 rows=%3 fullyVisible=%4")
                           .arg(exactTarget)
                           .arg(finalHeight)
                           .arg(sceneVisibleRows_)
                           .arg(rows));
            PersistManualSceneDockHeightAfterPerfectSnap(finalHeight);
        });
    }

    void PollManualReleaseForPerfectRowSnap(int generation)
    {
        if (generation != manualPerfectSnapGeneration_)
            return;

        if (QApplication::mouseButtons() & Qt::LeftButton) {
            QTimer::singleShot(28, this, [this, generation]() {
                PollManualReleaseForPerfectRowSnap(generation);
            });
            return;
        }

        QDockWidget *dock = ScenesDock();
        if (!dock || !sceneRowLockEnabled_ || sceneVisibleRows_ > 2)
            return;

        const int pitch = qMax(1, CurrentSceneRowHeight());
        int exactTarget = CalculateSceneDockHeightForRows();
        if (exactTarget <= 0)
            exactTarget = qMax(1, lockedSceneDockHeight_);

        if (dock->height() <= exactTarget + (pitch * 2)) {
            SnapManualSceneDockToExactRows();
        } else {
            // A normal upward drag should immediately return every bottom-dock
            // child to vanilla OBS layout/text behavior.
            RestoreLowRowDescendantVisualState();
        }
    }

    void ScheduleManualReleasePerfectRowSnap()
    {
        const int generation = ++manualPerfectSnapGeneration_;
        QTimer::singleShot(28, this, [this, generation]() {
            PollManualReleaseForPerfectRowSnap(generation);
        });
    }

'@
Replace-Block '    void SnapManualSceneDockToExactRows()' '    bool eventFilter(QObject *watched, QEvent *event) override' $perfectSnap 'released-mouse exact-row snapping'

# The old 90ms quiet callback in v3.31 could snap while the user still had the
# mouse held down. Remove that snap; the release watcher above owns it now.
$oldQuietSnap = @'
                                    if (sceneRowLockEnabled_ && sceneVisibleRows_ <= 2) {
                                        const int pitchNow = qMax(1, CurrentSceneRowHeight());
                                        const int exactRowsTarget = CalculateSceneDockHeightForRows();
                                        const int snapBase = exactRowsTarget > 0 ? exactRowsTarget : floor;

                                        // If the user released within roughly two
                                        // row pitches of the configured minimum,
                                        // finish at the exact N-row geometry.
                                        // This removes any partially visible next
                                        // row while keeping higher manual positions
                                        // completely untouched.
                                        if (dock->height() <= snapBase + (pitchNow * 2)) {
                                            SnapManualSceneDockToExactRows();
                                            return;
                                        }
                                    }

                                    const int finalHeight = qMax(floor, dock->height());
'@
$newQuietSnap = @'
                                    const int finalHeight = qMax(floor, dock->height());
'@
Replace-Required $oldQuietSnap $newQuietSnap 'remove mid-drag quiet-timer snap'

# Arm the release watcher on every genuine manual resize. Repeated calls simply
# invalidate the previous tiny timer chain; only the newest drag generation can
# snap after release.
Replace-Required @'
                        lastManualObservedHeight_ = manualHeight;

                        Q_UNUSED(shrinking);
'@ @'
                        lastManualObservedHeight_ = manualHeight;
                        if (sceneRowLockEnabled_ && sceneVisibleRows_ <= 2)
                            ScheduleManualReleasePerfectRowSnap();

                        Q_UNUSED(shrinking);
'@ 'watch genuine manual drag until release'

Replace-Required @'
    int manualDragSettleGeneration_ = 0;
'@ @'
    int manualDragSettleGeneration_ = 0;
    int manualPerfectSnapGeneration_ = 0;
'@ 'manual release watcher member'

$s = $s.Replace('OBS UI Scale v3.31 DEBUG', 'OBS UI Scale v3.32 DEBUG')
$s = $s.Replace('OBS UI Scale v3.31 DEBUG LOG', 'OBS UI Scale v3.32 DEBUG LOG')
$s = $s.Replace('v3.31 DEBUG', 'v3.32 DEBUG')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.31.0', '3.32.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.31.0', 'OBS-UI-Scale-Debug-Setup-3.32.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.32 DEBUG exact released-row latch + restored bottom-dock text/layout.'

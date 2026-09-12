$ErrorActionPreference = 'Stop'

# v3.31 DEBUG
# Two UX fixes after the first 40/40 fully automatic pass:
# 1) replace the fixed QMessageBox test summary with a normal resizable QDialog
#    containing a QPlainTextEdit, so long results are vertically/horizontally
#    scrollable and the user can make the window wider/taller;
# 2) make a manual DOWN drag near the configured 1/2-row floor finish on the
#    exact calculated row geometry after mouse release. A very short temporary
#    same-row min/max pin gets Qt onto the exact splitter position, then ALL
#    maximums are immediately released, so the next manual drag stays native
#    and unrestricted. This removes the partially-visible next Scene row without
#    recreating the old persistent drag lock.
& ./build-v3.30-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.31 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.30.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.31.0-debug";' 'plugin version'

if (-not $s.Contains('#include <QPlainTextEdit>')) {
    if ($s.Contains('#include <QPushButton>')) {
        $s = $s.Replace('#include <QPushButton>', "#include <QPushButton>`n#include <QPlainTextEdit>")
    } else {
        throw 'v3.31 could not find include insertion point for QPlainTextEdit'
    }
}

# ---------------------------------------------------------------------------
# Resizable + scrollable final test-results dialog.
# ---------------------------------------------------------------------------
$restoreMarker = '    void RestoreAfterRestartTest()'
$restorePos = $s.IndexOf($restoreMarker)
if ($restorePos -lt 0) { throw 'v3.31 could not locate RestoreAfterRestartTest' }

$resultDialogHelper = @'
    void ShowScrollableTestResultDialog(const QString &title, const QString &summary)
    {
        auto *parent = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        auto *dialog = new QDialog(parent);
        dialog->setAttribute(Qt::WA_DeleteOnClose);
        dialog->setWindowTitle(title);
        dialog->setMinimumSize(560, 360);
        dialog->resize(980, 700);
        dialog->setSizeGripEnabled(true);

        auto *layout = new QVBoxLayout(dialog);
        auto *results = new QPlainTextEdit(dialog);
        results->setReadOnly(true);
        results->setLineWrapMode(QPlainTextEdit::NoWrap);
        results->setPlainText(summary);
        results->setMinimumSize(480, 260);
        layout->addWidget(results, 1);

        auto *buttons = new QDialogButtonBox(QDialogButtonBox::Close, dialog);
        QObject::connect(buttons, &QDialogButtonBox::rejected, dialog, &QDialog::close);
        QObject::connect(buttons, &QDialogButtonBox::accepted, dialog, &QDialog::close);
        layout->addWidget(buttons);

        dialog->show();
        dialog->raise();
        dialog->activateWindow();
    }

'@
$s = $s.Substring(0, $restorePos) + $resultDialogHelper.Replace("`r`n", "`n") + $s.Substring($restorePos)

# Replace only the final restart/complete-test QMessageBox inside
# RestoreAfterRestartTest; other warning/question boxes stay unchanged.
$restoreStart = $s.IndexOf($restoreMarker)
$restoreEnd = $s.IndexOf('    void ContinueRestartTestAfterStartup()', $restoreStart)
if ($restoreStart -lt 0 -or $restoreEnd -lt 0) { throw 'v3.31 could not isolate RestoreAfterRestartTest' }
$restoreBlock = $s.Substring($restoreStart, $restoreEnd - $restoreStart)
$msgStart = $restoreBlock.IndexOf('            QMessageBox::information(static_cast<QMainWindow *>(obs_frontend_get_main_window()),')
if ($msgStart -lt 0) { throw 'v3.31 final result QMessageBox not found' }
$msgEndNeedle = ' summary);'
$msgEnd = $restoreBlock.IndexOf($msgEndNeedle, $msgStart)
if ($msgEnd -lt 0) { throw 'v3.31 final result QMessageBox end not found' }
$msgEnd += $msgEndNeedle.Length
$newResultCall = @'
            ShowScrollableTestResultDialog(
                completeMode
                    ? QStringLiteral("OBS UI Scale Fully Automatic Combination-Matrix Test")
                    : QStringLiteral("OBS UI Scale Real Restart Test"),
                summary);
'@
$restoreBlock = $restoreBlock.Substring(0, $msgStart) +
                $newResultCall.TrimEnd() +
                $restoreBlock.Substring($msgEnd)
$s = $s.Substring(0, $restoreStart) + $restoreBlock + $s.Substring($restoreEnd)

# ---------------------------------------------------------------------------
# Perfect manual low-row snap after mouse release.
# ---------------------------------------------------------------------------
$eventMarker = '    bool eventFilter(QObject *watched, QEvent *event) override'
$eventPos = $s.IndexOf($eventMarker)
if ($eventPos -lt 0) { throw 'v3.31 could not locate eventFilter for helper insertion' }

$manualPerfectHelper = @'
    void PersistManualSceneDockHeightAfterPerfectSnap(int height)
    {
        QDockWidget *dock = ScenesDock();
        if (!dock || height <= 0)
            return;

        savedManualSceneDockHeight_ = height;
        lastImmediateManualSceneDockHeight_ = height;
        lastManualObservedHeight_ = height;
        CaptureStableDockTargets();

        if (settings_) {
            settings_->setValue(QStringLiteral("ui/manualSceneDockHeight"), height);
            settings_->sync();
        }

        DebugWrite(QStringLiteral(
            "MANUAL PERFECT ROW SNAP SAVED height=%1 rows=%2 fullyVisible=%3")
                       .arg(height)
                       .arg(sceneVisibleRows_)
                       .arg(CountFullyVisibleSceneRows()));
    }

    void SnapManualSceneDockToExactRows()
    {
        if (!sceneRowLockEnabled_ || sceneVisibleRows_ > 2)
            return;

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *dock = ScenesDock();
        if (!mainWindow || !dock)
            return;

        const int exactTarget = CalculateSceneDockHeightForRows();
        if (exactTarget <= 0)
            return;

        const int oldFloor = lockedSceneDockHeight_;
        const int oldMixerFloor = lockedMixerHeight_;

        // Lower the authoritative minimum back to the exact geometry target.
        // Physical-floor adoption may previously have rounded it a few pixels
        // upward; for a released manual drag we can safely do a one-shot exact
        // placement instead.
        if (oldFloor > 0 && exactTarget != oldFloor) {
            const int delta = exactTarget - oldFloor;
            lockedSceneDockHeight_ = exactTarget;
            lockedMixerHeight_ = qMax(1, oldMixerFloor + delta);
            mixerMinHeightTarget_ = lockedMixerHeight_;
        }

        RelaxBottomRowSiblingMinimums();
        RelaxSceneDockInternalMinimums();
        dock->setMinimumHeight(exactTarget);

        // Temporarily pin the whole live bottom row for one short settle window.
        // Unlike the old low-row latch this is NOT persistent and cannot lock
        // the next mouse drag.
        SetApplyBottomRowCeiling(exactTarget);

        restoringDockTargets_ = true;
        mainWindow->resizeDocks({dock}, {exactTarget}, Qt::Vertical);
        if (QLayout *layout = mainWindow->layout()) {
            layout->invalidate();
            layout->activate();
        }
        restoringDockTargets_ = false;

        DebugWrite(QStringLiteral(
            "MANUAL PERFECT ROW SNAP PINNED target=%1 live=%2 rows=%3")
                       .arg(exactTarget).arg(dock->height()).arg(sceneVisibleRows_));

        QTimer::singleShot(70, this, [this, exactTarget]() {
            auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
            QDockWidget *dock = ScenesDock();
            if (!mainWindow || !dock)
                return;

            ReleaseApplyBottomRowCeiling();

            // Reassert only the minimum, never a maximum, then place the splitter
            // at the same exact target once more after the temporary pin is gone.
            lockedSceneDockHeight_ = exactTarget;
            dock->setMinimumHeight(exactTarget);

            restoringDockTargets_ = true;
            mainWindow->resizeDocks({dock}, {exactTarget}, Qt::Vertical);
            restoringDockTargets_ = false;
            ReassertSceneRowLock();

            QTimer::singleShot(70, this, [this, exactTarget]() {
                QDockWidget *dock = ScenesDock();
                if (!dock)
                    return;

                const int finalHeight = dock->height();
                DebugWrite(QStringLiteral(
                    "MANUAL PERFECT ROW SNAP RELEASED target=%1 final=%2 rows=%3 fullyVisible=%4")
                               .arg(exactTarget)
                               .arg(finalHeight)
                               .arg(sceneVisibleRows_)
                               .arg(CountFullyVisibleSceneRows()));
                PersistManualSceneDockHeightAfterPerfectSnap(finalHeight);
            });
        });
    }

'@
$s = $s.Substring(0, $eventPos) + $manualPerfectHelper.Replace("`r`n", "`n") + $s.Substring($eventPos)

# v3.25/v3.26 already waits 90ms after the manual gesture. Replace its old
# low-row force with the new one-shot exact splitter placement and return from
# that settle callback so it does not also persist the pre-snap height.
$oldManualSettle = @'
                                    if (sceneRowLockEnabled_ && sceneVisibleRows_ <= 2) {
                                        const int pitchNow = qMax(1, CurrentSceneRowHeight());
                                        if (dock->height() > floor + 2 &&
                                            dock->height() <= floor + pitchNow) {
                                            ForceBottomRowHeightNow(
                                                floor,
                                                QStringLiteral("manual release low-row settle"),
                                                true);
                                        }
                                    }

                                    const int finalHeight = qMax(floor, dock->height());
'@
$newManualSettle = @'
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
Replace-Required $oldManualSettle $newManualSettle 'manual release exact-row snap'

$s = $s.Replace('OBS UI Scale v3.30 DEBUG', 'OBS UI Scale v3.31 DEBUG')
$s = $s.Replace('OBS UI Scale v3.30 DEBUG LOG', 'OBS UI Scale v3.31 DEBUG LOG')
$s = $s.Replace('v3.30 DEBUG', 'v3.31 DEBUG')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.30.0', '3.31.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.30.0', 'OBS-UI-Scale-Debug-Setup-3.31.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.31 DEBUG resizable result dialog + exact manual row snap.'

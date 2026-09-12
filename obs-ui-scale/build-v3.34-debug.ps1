$ErrorActionPreference = 'Stop'

# v3.34 DEBUG
# Low-row engine cleanup based on the v3.33 failure:
# - exact 1-row was reached repeatedly (70-76px) but "physical floor adoption"
#   later promoted it back to 86/91px, so UI/Text changes could turn 1 row into
#   2+ rows;
# - persistent max-height latching/polling caused the separator to feel locked;
# - recursive QSizePolicy/Layout mutation and full geometry snapshots caused
#   invisible/buggy dock text and unnecessary OBS/game lag.
#
# v3.34:
# 1) never adopts a higher "physical" floor; calculated row count stays exact;
# 2) uses only MINIMUM-height relaxation on descendants (no Ignored policies,
#    no SetNoConstraint, no descendant max caps);
# 3) uses a short 90ms dock max pin only to land the splitter, then releases it;
#    no persistent max latch and no idle polling;
# 4) if the dock is near its 1/2-row minimum when UI/Text scaling changes, Apply
#    follows the NEW calculated row floor instead of preserving the old pixels;
# 5) turns full geometry snapshots into a no-op. Test logs keep concise PASS/FAIL
#    and state lines without walking every OBS widget.
& ./build-v3.33-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$crlf = [string][char]13 + [string][char]10
$lf = [string][char]10
$s = $s.Replace($crlf, $lf)

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace($crlf, $lf)
    $new = $new.Replace($crlf, $lf)
    if (-not $script:s.Contains($old)) { throw "v3.34 patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}
function Replace-Block([string]$startMarker, [string]$endMarker, [string]$newBlock, [string]$label) {
    $start = $script:s.IndexOf($startMarker)
    if ($start -lt 0) { throw "v3.34 could not locate start of $label" }
    $end = $script:s.IndexOf($endMarker, $start)
    if ($end -lt 0) { throw "v3.34 could not locate end of $label" }
    $script:s = $script:s.Substring(0, $start) + $newBlock.Replace($crlf, $lf) + $script:s.Substring($end)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.33.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.34.0-debug";' 'plugin version'

# Scenes internal relaxation: minimums only. Do not change QSizePolicy or layout
# constraints; those were responsible for blank/invisible controls.
$sceneRelax = @'
    void RelaxSceneDockInternalMinimums()
    {
        if (!sceneRowLockEnabled_)
            return;

        QDockWidget *sceneDock = ScenesDock();
        QListWidget *list = ScenesList();
        if (!sceneDock || !list)
            return;

        for (QWidget *w = list; w && w != sceneDock; w = w->parentWidget()) {
            if (!w->property(PROP_SCENE_OLD_MIN_H).isValid())
                w->setProperty(PROP_SCENE_OLD_MIN_H, w->minimumHeight());
            w->setMinimumHeight(0);
            w->updateGeometry();
        }

        if (QWidget *viewport = list->viewport()) {
            if (!viewport->property(PROP_SCENE_OLD_MIN_H).isValid())
                viewport->setProperty(PROP_SCENE_OLD_MIN_H, viewport->minimumHeight());
            viewport->setMinimumHeight(0);
            viewport->updateGeometry();
        }
    }

'@
Replace-Block '    void RelaxSceneDockInternalMinimums()' '    void RestoreSceneDockInternalMinimums()' $sceneRelax 'minimum-only Scenes internal relaxation'

# Descendant relaxation: minimums only. Keep all text/control policies/layouts
# exactly as OBS owns them.
$cap = @'
    void ApplyLowRowWidgetCap(QWidget *widget, int targetHeight)
    {
        Q_UNUSED(targetHeight);
        if (!widget)
            return;

        if (!widget->property(PROP_LOWROW_CONTENT_OLD_MIN_H).isValid())
            widget->setProperty(PROP_LOWROW_CONTENT_OLD_MIN_H,
                                widget->minimumHeight());
        widget->setMinimumHeight(0);
        widget->updateGeometry();
    }

'@
Replace-Block '    void ApplyLowRowWidgetCap(QWidget *widget, int targetHeight)' '    void RestoreLowRowWidgetCap(QWidget *widget)' $cap 'minimum-only low-row descendant relaxation'

$restoreCap = @'
    void RestoreLowRowWidgetCap(QWidget *widget)
    {
        if (!widget)
            return;

        if (widget->property(PROP_LOWROW_CONTENT_OLD_MIN_H).isValid()) {
            widget->setMinimumHeight(
                qMax(0, widget->property(PROP_LOWROW_CONTENT_OLD_MIN_H).toInt()));
            widget->setProperty(PROP_LOWROW_CONTENT_OLD_MIN_H, QVariant());
        }

        // Cleanup compatibility with v3.23-v3.33 properties. In a fresh process
        // v3.34 never creates these, but restoring them makes the function safe
        // if called during an in-session diagnostic transition.
        if (widget->property(PROP_LOWROW_CONTENT_OLD_MAX_H).isValid()) {
            const int oldMax =
                widget->property(PROP_LOWROW_CONTENT_OLD_MAX_H).toInt();
            widget->setMaximumHeight(oldMax > 0 ? oldMax : QWIDGETSIZE_MAX);
            widget->setProperty(PROP_LOWROW_CONTENT_OLD_MAX_H, QVariant());
        }
        if (widget->property(PROP_LOWROW_CONTENT_OLD_VPOLICY).isValid()) {
            QSizePolicy policy = widget->sizePolicy();
            policy.setVerticalPolicy(static_cast<QSizePolicy::Policy>(
                widget->property(PROP_LOWROW_CONTENT_OLD_VPOLICY).toInt()));
            widget->setSizePolicy(policy);
            widget->setProperty(PROP_LOWROW_CONTENT_OLD_VPOLICY, QVariant());
        }
        if (QLayout *layout = widget->layout()) {
            if (widget->property(PROP_LOWROW_LAYOUT_OLD_CONSTRAINT).isValid()) {
                layout->setSizeConstraint(static_cast<QLayout::SizeConstraint>(
                    widget->property(PROP_LOWROW_LAYOUT_OLD_CONSTRAINT).toInt()));
                widget->setProperty(PROP_LOWROW_LAYOUT_OLD_CONSTRAINT, QVariant());
            }
            layout->invalidate();
        }
        widget->updateGeometry();
    }

'@
Replace-Block '    void RestoreLowRowWidgetCap(QWidget *widget)' '    void RelaxLowRowDescendantsForManualDrag()' $restoreCap 'restore minimum-only low-row descendants'

# Restore relaxed state without a persistent maximum-height latch.
$release = @'
    void ReleaseLowRowFloorLatch()
    {
        if (!lowRowFloorLatchActive_)
            return;

        ++lowRowFloorLatchGeneration_;

        auto *mainWindow =
            static_cast<QMainWindow *>(obs_frontend_get_main_window());
        if (mainWindow) {
            const auto docks =
                mainWindow->findChildren<QDockWidget *>(
                    QString(), Qt::FindDirectChildrenOnly);
            for (QDockWidget *dock : docks) {
                if (!dock)
                    continue;

                if (QWidget *content = dock->widget()) {
                    const auto descendants =
                        content->findChildren<QWidget *>(
                            QString(), Qt::FindChildrenRecursively);
                    for (QWidget *child : descendants)
                        RestoreLowRowWidgetCap(child);
                    RestoreLowRowWidgetCap(content);
                }

                if (dock->property(PROP_LOWROW_OLD_MAX_H).isValid()) {
                    const int oldMax =
                        dock->property(PROP_LOWROW_OLD_MAX_H).toInt();
                    dock->setMaximumHeight(oldMax > 0 ? oldMax : QWIDGETSIZE_MAX);
                    dock->setProperty(PROP_LOWROW_OLD_MAX_H, QVariant());
                }
                if (dock->property(PROP_LOWROW_OLD_VPOLICY).isValid()) {
                    QSizePolicy policy = dock->sizePolicy();
                    policy.setVerticalPolicy(static_cast<QSizePolicy::Policy>(
                        dock->property(PROP_LOWROW_OLD_VPOLICY).toInt()));
                    dock->setSizePolicy(policy);
                    dock->setProperty(PROP_LOWROW_OLD_VPOLICY, QVariant());
                }
                dock->updateGeometry();
            }
        }

        RestoreBottomRowSiblingMinimums();
        RestoreSceneDockInternalMinimums();

        lowRowFloorLatchActive_ = false;
        lowRowFloorLatchHeight_ = -1;
        lowRowLatchSeenRelease_ = false;
        lastManualObservedHeight_ =
            ScenesDock() ? ScenesDock()->height() : -1;

        if (sceneRowLockEnabled_ && lockedSceneDockHeight_ > 0) {
            if (QDockWidget *dock = ScenesDock())
                dock->setMinimumHeight(lockedSceneDockHeight_);
        }

        DebugWrite(QStringLiteral("LOW ROW RELAXATION RELEASED"));
    }

'@
Replace-Block '    void ReleaseLowRowFloorLatch()' '    void PollLowRowFloorLatchForUnlock(int generation)' $release 'release lightweight low-row relaxation'

$poll = @'
    void PollLowRowFloorLatchForUnlock(int generation)
    {
        Q_UNUSED(generation);
        // v3.34 has no idle polling. The temporary dock max is released by a
        // one-shot timer, and manual Resize events manage relaxation directly.
    }

'@
Replace-Block '    void PollLowRowFloorLatchForUnlock(int generation)' '    bool AdoptEquivalentLowRowPhysicalHeight' $poll 'remove idle low-row polling'

# Never turn a higher pixel value into the new floor. This was the direct cause
# of exact 70-76px one-row results becoming 86/91px later in v3.33.
$adopt = @'
    bool AdoptEquivalentLowRowPhysicalHeight(int requestedTarget,
                                             const QString &reason)
    {
        Q_UNUSED(reason);
        QDockWidget *dock = ScenesDock();
        if (!dock || requestedTarget <= 0)
            return false;

        return qAbs(dock->height() - requestedTarget) <= 3 &&
               (!sceneRowLockEnabled_ ||
                CountFullyVisibleSceneRows() == sceneVisibleRows_);
    }

'@
Replace-Block '    bool AdoptEquivalentLowRowPhysicalHeight' '    bool ForceBottomRowHeightNow' $adopt 'disable upward physical-floor adoption'

# Short-lived exact pin. Descendant minimums remain relaxed until the user grows
# away from the low-row area, but every dock maximum is released after 90ms.
$force = @'
    bool ForceBottomRowHeightNow(int targetHeight, const QString &reason,
                                 bool latch)
    {
        if (targetHeight <= 0 || lowRowForceActive_)
            return false;

        if (lowRowFloorLatchActive_ &&
            lowRowFloorLatchHeight_ > 0 &&
            qAbs(lowRowFloorLatchHeight_ - targetHeight) > 3)
            ReleaseLowRowFloorLatch();

        auto *mainWindow =
            static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        if (!mainWindow || !sceneDock || !sceneDock->isVisible() ||
            sceneDock->isFloating())
            return false;
        if (mainWindow->dockWidgetArea(sceneDock) !=
            Qt::BottomDockWidgetArea)
            return false;

        lowRowForceActive_ = true;
        RelaxBottomRowSiblingMinimums();
        RelaxSceneDockInternalMinimums();

        QList<QDockWidget *> rowDocks;
        QList<int> heights;
        const int rowY = sceneDock->y();
        const auto docks =
            mainWindow->findChildren<QDockWidget *>(
                QString(), Qt::FindDirectChildrenOnly);

        for (QDockWidget *dock : docks) {
            if (!dock || !dock->isVisible() || dock->isFloating())
                continue;
            if (mainWindow->dockWidgetArea(dock) !=
                Qt::BottomDockWidgetArea)
                continue;
            if (qAbs(dock->y() - rowY) > 4)
                continue;

            if (!dock->property(PROP_LOWROW_OLD_MAX_H).isValid()) {
                const int oldMax =
                    dock->property(PROP_APPLY_OLD_MAX_H).isValid()
                        ? dock->property(PROP_APPLY_OLD_MAX_H).toInt()
                        : dock->maximumHeight();
                dock->setProperty(PROP_LOWROW_OLD_MAX_H, oldMax);
            }

            dock->setMinimumHeight(dock == sceneDock ? targetHeight : 0);
            dock->setMaximumHeight(targetHeight);

            if (QWidget *content = dock->widget()) {
                ApplyLowRowWidgetCap(content, targetHeight);
                const auto descendants =
                    content->findChildren<QWidget *>(
                        QString(), Qt::FindChildrenRecursively);
                for (QWidget *child : descendants)
                    ApplyLowRowWidgetCap(child, targetHeight);
            }

            dock->updateGeometry();
            rowDocks.push_back(dock);
            heights.push_back(targetHeight);
        }

        restoringDockTargets_ = true;
        if (!rowDocks.isEmpty())
            mainWindow->resizeDocks(rowDocks, heights, Qt::Vertical);
        mainWindow->resizeDocks({sceneDock}, {targetHeight}, Qt::Vertical);
        restoringDockTargets_ = false;

        const int actual = sceneDock->height();
        const bool reached = qAbs(actual - targetHeight) <= 3;

        if (latch) {
            lowRowFloorLatchActive_ = true;
            lowRowFloorLatchHeight_ = targetHeight;
        }

        const int pinGeneration = ++lowRowFloorLatchGeneration_;
        QTimer::singleShot(90, this, [this, pinGeneration]() {
            if (pinGeneration != lowRowFloorLatchGeneration_)
                return;

            auto *mainWindow =
                static_cast<QMainWindow *>(obs_frontend_get_main_window());
            if (!mainWindow)
                return;

            const auto docks =
                mainWindow->findChildren<QDockWidget *>(
                    QString(), Qt::FindDirectChildrenOnly);
            for (QDockWidget *dock : docks) {
                if (!dock ||
                    !dock->property(PROP_LOWROW_OLD_MAX_H).isValid())
                    continue;

                const int oldMax =
                    dock->property(PROP_LOWROW_OLD_MAX_H).toInt();
                dock->setMaximumHeight(
                    oldMax > 0 ? oldMax : QWIDGETSIZE_MAX);
                dock->setProperty(PROP_LOWROW_OLD_MAX_H, QVariant());
                dock->updateGeometry();
            }

            DebugWrite(QStringLiteral(
                "LOW ROW TEMPORARY MAX RELEASED target=%1 live=%2")
                           .arg(lowRowFloorLatchHeight_)
                           .arg(ScenesDock() ? ScenesDock()->height() : -1));
        });

        if (reached && lowRowScaleSyncPending_) {
            savedManualSceneDockHeight_ = targetHeight;
            lastImmediateManualSceneDockHeight_ = targetHeight;
            applyPreservedSceneDockHeight_ = targetHeight;
            pendingCalibrationSceneDockHeight_ = targetHeight;
            lastManualObservedHeight_ = targetHeight;
            if (settings_)
                settings_->setValue(
                    QStringLiteral("ui/manualSceneDockHeight"),
                    targetHeight);
            lowRowScaleSyncPending_ = false;

            DebugWrite(QStringLiteral(
                "LOW ROW SCALE-SYNC COMMITTED exact=%1 rows=%2")
                           .arg(targetHeight)
                           .arg(sceneVisibleRows_));
        }

        lowRowForceActive_ = false;

        DebugWrite(QStringLiteral(
            "LOW ROW FORCE reason='%1' target=%2 actual=%3 reached=%4")
                       .arg(reason)
                       .arg(targetHeight)
                       .arg(actual)
                       .arg(reached ? 1 : 0));

        return reached;
    }

'@
Replace-Block '    bool ForceBottomRowHeightNow' '    void ReassertSceneRowLock()' $force 'temporary exact low-row pin'

# When manual dragging grows away from the configured minimum, immediately
# restore normal minimum hints/text layout. Shrinking re-applies only minimum
# relaxation through the existing v3.33 helper.
Replace-Required @'
                        if (sceneRowLockEnabled_ && sceneVisibleRows_ <= 2 && shrinking)
                            RelaxLowRowDescendantsForManualDrag();
                        Q_UNUSED(shrinking);
'@ @'
                        if (sceneRowLockEnabled_ && sceneVisibleRows_ <= 2) {
                            if (shrinking) {
                                RelaxLowRowDescendantsForManualDrag();
                                lowRowFloorLatchActive_ = true;
                                lowRowFloorLatchHeight_ = floorHeight;
                            } else if (lowRowFloorLatchActive_ &&
                                       manualHeight > floorHeight + pitch) {
                                ReleaseLowRowFloorLatch();
                            }
                        }
                        Q_UNUSED(shrinking);
'@ 'event-driven manual low-row relaxation'

# UI/Text scale synchronization. If the user is resting near the configured
# 1/2-row minimum, Apply follows the new row geometry rather than preserving the
# old pixel height.
$prepareStart = $s.IndexOf('    void PrepareForRealApplyButton()')
$prepareEnd = $s.IndexOf('    void ApplyScale(double requestedUiPercent', $prepareStart)
if ($prepareStart -lt 0 -or $prepareEnd -lt 0) {
    throw 'v3.34 could not isolate PrepareForRealApplyButton'
}
$prepare = $s.Substring($prepareStart, $prepareEnd - $prepareStart)

$floorMarker = '        const int floor = (sceneRowLockEnabled_ && lockedSceneDockHeight_ > 0)'
$floorPos = $prepare.IndexOf($floorMarker)
if ($floorPos -lt 0) {
    throw 'v3.34 Prepare floor marker missing'
}
$prepareInsert = @'
        const int rowsBeforeApply = CountFullyVisibleSceneRows();
        const int pitchBeforeApply = qMax(1, CurrentSceneRowHeight());
        const bool nearLowRowFloor =
            sceneRowLockEnabled_ && sceneVisibleRows_ <= 2 &&
            (rowsBeforeApply <= sceneVisibleRows_ ||
             (lockedSceneDockHeight_ > 0 &&
              sceneDock->height() <=
                  lockedSceneDockHeight_ + (pitchBeforeApply * 2)));
        lowRowScaleSyncPending_ = nearLowRowFloor;

        if (lowRowScaleSyncPending_) {
            DebugWrite(QStringLiteral(
                "LOW ROW SCALE-SYNC ARMED rows=%1 visibleBefore=%2 live=%3 oldFloor=%4 pitch=%5")
                           .arg(sceneVisibleRows_)
                           .arg(rowsBeforeApply)
                           .arg(sceneDock->height())
                           .arg(lockedSceneDockHeight_)
                           .arg(pitchBeforeApply));
        }

'@
$prepare = $prepare.Substring(0, $floorPos) +
           $prepareInsert +
           $prepare.Substring($floorPos)

$prepare = $prepare.Replace(
    '        if (newerManualDrag) {',
    '        if (newerManualDrag && !lowRowScaleSyncPending_) {')

$serialMarker = '        lastRealApplyManualSerial_ = manualResizeSerial_;'
if (-not $prepare.Contains($serialMarker)) {
    throw 'v3.34 Prepare serial marker missing'
}
$prepare = $prepare.Replace($serialMarker, @'
        lastRealApplyManualSerial_ = manualResizeSerial_;

        if (lowRowScaleSyncPending_) {
            ++realApplySmoothGuardGeneration_;
            realApplySmoothGuardActive_ = false;
            realApplySmoothExpectedHeight_ = -1;
            lastRealApplySmoothExcursions_ = 0;
            return;
        }
'@.TrimEnd())

$s = $s.Substring(0, $prepareStart) + $prepare + $s.Substring($prepareEnd)

# Don't carry the OLD pixel height through an Apply that is row-syncing.
Replace-Required @'
        pendingCalibrationSceneDockHeight_ = applyPreservedSceneDockHeight_;
'@ @'
        if (lowRowScaleSyncPending_) {
            DebugWrite(QStringLiteral(
                "LOW ROW SCALE-SYNC DROPPED OLD APPLY PIXEL TARGET old=%1")
                           .arg(applyPreservedSceneDockHeight_));
            applyPreservedSceneDockHeight_ = -1;
        }
        pendingCalibrationSceneDockHeight_ = applyPreservedSceneDockHeight_;
'@ 'drop old Apply height when row-syncing'

# Full geometry snapshots were useful during diagnosis but are too expensive for
# normal use and the game-lag goal. Keep all concise DebugWrite PASS/FAIL/state
# lines; make snapshots free.
$debugSnapshot = @'
    void DebugSnapshot(const QString &label)
    {
        Q_UNUSED(label);
    }

'@
Replace-Block '    void DebugSnapshot(const QString &label)' '    QString DebugEventName' $debugSnapshot 'disable expensive full geometry snapshots'

Replace-Required @'
    bool completeTestForceLogging_ = false;
'@ @'
    bool completeTestForceLogging_ = false;
    bool lowRowScaleSyncPending_ = false;
'@ 'low-row scale-sync member'

$s = $s.Replace('OBS UI Scale v3.33 DEBUG', 'OBS UI Scale v3.34 DEBUG')
$s = $s.Replace('OBS UI Scale v3.33 DEBUG LOG', 'OBS UI Scale v3.34 DEBUG LOG')
$s = $s.Replace('v3.33 DEBUG', 'v3.34 DEBUG')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.33.0', '3.34.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.33.0',
                    'OBS-UI-Scale-Debug-Setup-3.34.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.34 DEBUG low-row engine cleanup/performance rewrite.'

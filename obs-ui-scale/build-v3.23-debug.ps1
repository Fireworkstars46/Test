$ErrorActionPreference = 'Stop'

# v3.23 DEBUG:
# - make normal separator dragging as close to vanilla OBS as possible by keeping
#   the hot drag path in memory only and settling/persisting once after the drag;
# - stop scene-row reassert/recalculation work while a genuine separator drag is
#   in progress;
# - remove per-resize DEBUG file writes;
# - make 1/2-row mode authoritative: recursively relax/cap every widget inside
#   every dock on the live bottom row, force the exact calculated row floor, and
#   latch it until the user's next separator drag.
& ./build-v3.22-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.23 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}
function Replace-Block([string]$startMarker, [string]$endMarker, [string]$newBlock, [string]$label) {
    $start = $script:s.IndexOf($startMarker)
    if ($start -lt 0) { throw "v3.23 could not locate start of $label" }
    $end = $script:s.IndexOf($endMarker, $start)
    if ($end -lt 0) { throw "v3.23 could not locate end of $label" }
    $script:s = $script:s.Substring(0, $start) + $newBlock.Replace("`r`n", "`n") + $script:s.Substring($end)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.22.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.23.0-debug";' 'plugin version'

Replace-Required @'
static constexpr const char *PROP_LOWROW_CONTENT_OLD_VPOLICY = "obsUiScaleLowRowContentOldVPolicy";
'@ @'
static constexpr const char *PROP_LOWROW_CONTENT_OLD_VPOLICY = "obsUiScaleLowRowContentOldVPolicy";
static constexpr const char *PROP_LOWROW_LAYOUT_OLD_CONSTRAINT = "obsUiScaleLowRowLayoutOldConstraint";
'@ 'recursive low-row layout property'

# Replace the v3.22 low-row helper with a recursive version. v3.22 capped only
# each QDockWidget and its immediate content widget; grandchildren could still
# contribute a large minimumSizeHint and keep QMainWindow around 3 rows.
$lowRow = @'
    void ApplyLowRowWidgetCap(QWidget *widget, int targetHeight)
    {
        if (!widget || targetHeight <= 0)
            return;

        if (!widget->property(PROP_LOWROW_CONTENT_OLD_MIN_H).isValid())
            widget->setProperty(PROP_LOWROW_CONTENT_OLD_MIN_H, widget->minimumHeight());
        if (!widget->property(PROP_LOWROW_CONTENT_OLD_MAX_H).isValid())
            widget->setProperty(PROP_LOWROW_CONTENT_OLD_MAX_H, widget->maximumHeight());
        if (!widget->property(PROP_LOWROW_CONTENT_OLD_VPOLICY).isValid())
            widget->setProperty(PROP_LOWROW_CONTENT_OLD_VPOLICY,
                                static_cast<int>(widget->sizePolicy().verticalPolicy()));

        widget->setMinimumHeight(0);
        widget->setMaximumHeight(targetHeight);
        QSizePolicy policy = widget->sizePolicy();
        policy.setVerticalPolicy(QSizePolicy::Ignored);
        widget->setSizePolicy(policy);

        if (QLayout *layout = widget->layout()) {
            if (!widget->property(PROP_LOWROW_LAYOUT_OLD_CONSTRAINT).isValid())
                widget->setProperty(PROP_LOWROW_LAYOUT_OLD_CONSTRAINT,
                                    static_cast<int>(layout->sizeConstraint()));
            layout->setSizeConstraint(QLayout::SetNoConstraint);
            layout->invalidate();
        }
        widget->updateGeometry();
    }

    void RestoreLowRowWidgetCap(QWidget *widget)
    {
        if (!widget)
            return;

        if (widget->property(PROP_LOWROW_CONTENT_OLD_MIN_H).isValid()) {
            widget->setMinimumHeight(qMax(0, widget->property(PROP_LOWROW_CONTENT_OLD_MIN_H).toInt()));
            widget->setProperty(PROP_LOWROW_CONTENT_OLD_MIN_H, QVariant());
        }
        if (widget->property(PROP_LOWROW_CONTENT_OLD_MAX_H).isValid()) {
            const int oldMax = widget->property(PROP_LOWROW_CONTENT_OLD_MAX_H).toInt();
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

    void ReleaseLowRowFloorLatch()
    {
        if (!lowRowFloorLatchActive_)
            return;

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        if (mainWindow) {
            const auto docks = mainWindow->findChildren<QDockWidget *>(QString(), Qt::FindDirectChildrenOnly);
            for (QDockWidget *dock : docks) {
                if (!dock)
                    continue;

                const auto descendants = dock->findChildren<QWidget *>(QString(), Qt::FindChildrenRecursively);
                for (QWidget *child : descendants)
                    RestoreLowRowWidgetCap(child);

                if (dock->property(PROP_LOWROW_OLD_MAX_H).isValid()) {
                    const int oldMax = dock->property(PROP_LOWROW_OLD_MAX_H).toInt();
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

        lowRowFloorLatchActive_ = false;
        lowRowFloorLatchHeight_ = -1;
        lowRowLatchSeenRelease_ = false;
        ++lowRowFloorLatchGeneration_;
        lastManualObservedHeight_ = ScenesDock() ? ScenesDock()->height() : -1;
        ReassertSceneRowLock();
        DebugWrite(QStringLiteral("LOW ROW FLOOR LATCH RELEASED"));
    }

    void PollLowRowFloorLatchForUnlock(int generation)
    {
        if (!lowRowFloorLatchActive_ || generation != lowRowFloorLatchGeneration_)
            return;

        if (!(QApplication::mouseButtons() & Qt::LeftButton)) {
            lowRowLatchSeenRelease_ = true;
        } else if (lowRowLatchSeenRelease_ && IsManualBottomRowResizeGesture()) {
            ReleaseLowRowFloorLatch();
            return;
        }

        // This timer is intentionally relaxed; while latched the row is static.
        // A 32ms check is still effectively immediate on the next user drag but
        // produces half as many idle wakeups as v3.22.
        QTimer::singleShot(32, this, [this, generation]() {
            PollLowRowFloorLatchForUnlock(generation);
        });
    }

    bool ForceBottomRowHeightNow(int targetHeight, const QString &reason, bool latch)
    {
        if (targetHeight <= 0 || lowRowForceActive_)
            return false;

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        if (!mainWindow || !sceneDock || !sceneDock->isVisible() || sceneDock->isFloating())
            return false;
        if (mainWindow->dockWidgetArea(sceneDock) != Qt::BottomDockWidgetArea)
            return false;

        lowRowForceActive_ = true;
        RelaxBottomRowSiblingMinimums();
        RelaxSceneDockInternalMinimums();

        QList<QDockWidget *> rowDocks;
        QList<int> targetHeights;
        const int rowY = sceneDock->y();
        const auto docks = mainWindow->findChildren<QDockWidget *>(QString(), Qt::FindDirectChildrenOnly);

        for (QDockWidget *dock : docks) {
            if (!dock || !dock->isVisible() || dock->isFloating())
                continue;
            if (mainWindow->dockWidgetArea(dock) != Qt::BottomDockWidgetArea)
                continue;
            if (qAbs(dock->y() - rowY) > 4)
                continue;

            if (!dock->property(PROP_LOWROW_OLD_MAX_H).isValid()) {
                // If Apply currently owns a temporary ceiling, preserve the
                // original maximum behind that ceiling rather than saving the
                // temporary value as the post-latch maximum.
                const int oldMax = dock->property(PROP_APPLY_OLD_MAX_H).isValid()
                                     ? dock->property(PROP_APPLY_OLD_MAX_H).toInt()
                                     : dock->maximumHeight();
                dock->setProperty(PROP_LOWROW_OLD_MAX_H, oldMax);
            }
            if (!dock->property(PROP_LOWROW_OLD_VPOLICY).isValid())
                dock->setProperty(PROP_LOWROW_OLD_VPOLICY,
                                  static_cast<int>(dock->sizePolicy().verticalPolicy()));

            dock->setMinimumHeight(dock == sceneDock ? targetHeight : 0);
            dock->setMaximumHeight(targetHeight);
            QSizePolicy dockPolicy = dock->sizePolicy();
            dockPolicy.setVerticalPolicy(QSizePolicy::Ignored);
            dock->setSizePolicy(dockPolicy);

            if (QWidget *content = dock->widget()) {
                ApplyLowRowWidgetCap(content, targetHeight);
                const auto descendants = content->findChildren<QWidget *>(
                    QString(), Qt::FindChildrenRecursively);
                for (QWidget *child : descendants)
                    ApplyLowRowWidgetCap(child, targetHeight);
            }

            dock->updateGeometry();
            rowDocks.push_back(dock);
            targetHeights.push_back(targetHeight);
        }

        restoringDockTargets_ = true;
        if (QLayout *layout = mainWindow->layout())
            layout->invalidate();

        if (!rowDocks.isEmpty())
            mainWindow->resizeDocks(rowDocks, targetHeights, Qt::Vertical);
        mainWindow->resizeDocks({sceneDock}, {targetHeight}, Qt::Vertical);

        if (QLayout *layout = mainWindow->layout())
            layout->activate();

        mainWindow->resizeDocks({sceneDock}, {targetHeight}, Qt::Vertical);
        restoringDockTargets_ = false;

        const int actual = sceneDock->height();
        const bool reached = qAbs(actual - targetHeight) <= 3;
        lowRowForceActive_ = false;

        DebugWrite(QStringLiteral(
            "RECURSIVE LOW ROW FORCE reason='%1' target=%2 actual=%3 reached=%4 rowDocks=%5")
                       .arg(reason).arg(targetHeight).arg(actual)
                       .arg(reached ? 1 : 0).arg(rowDocks.size()));

        if (latch) {
            // Keep the caps even if Qt reports a few pixels high; the next
            // settled capture gets another force pass and cannot bounce back to
            // the old 3-row size-hint floor in the meantime.
            lowRowFloorLatchActive_ = true;
            lowRowFloorLatchHeight_ = targetHeight;
            lowRowLatchSeenRelease_ = false;
            const int generation = ++lowRowFloorLatchGeneration_;
            PollLowRowFloorLatchForUnlock(generation);
        } else if (!reached) {
            lowRowFloorLatchActive_ = true;
            ReleaseLowRowFloorLatch();
        }

        return reached;
    }

'@
Replace-Block '    void ApplyLowRowWidgetCap(QWidget *widget, int targetHeight)' '    void ReassertSceneRowLock()' $lowRow 'recursive low-row force helpers'

# v3.22's generated source does not yet have ApplyLowRowWidgetCap at the start
# marker because that helper was new here. Fall back to replacing the original
# v3.22 low-row block when chaining directly from v3.22.
if (-not $s.Contains('    void ApplyLowRowWidgetCap(QWidget *widget, int targetHeight)')) {
    Replace-Block '    void ReleaseLowRowFloorLatch()' '    void ReassertSceneRowLock()' $lowRow 'recursive low-row force helpers fallback'
}

# Make row=1/2 immediately authoritative when its floor is captured. The user no
# longer has to somehow drag through Qt's hidden 3-row stop before the special
# path becomes active. A second quiet pass defeats a queued QMainWindow relayout.
Replace-Required @'
        LogSceneRowMinimumChain(QStringLiteral("POST-CAPTURE"));
        DebugWrite(QStringLiteral("SCENE ROW MINIMUM rows=%1 visualPitch=%2 sceneDockMinH=%3 mixerMinH=%4")
'@ @'
        if (sceneVisibleRows_ <= 2 && lockedSceneDockHeight_ > 0) {
            ForceBottomRowHeightNow(lockedSceneDockHeight_,
                                    QStringLiteral("row capture immediate"), true);
            const int expectedLowRow = lockedSceneDockHeight_;
            QTimer::singleShot(80, this, [this, expectedLowRow]() {
                if (!sceneRowLockEnabled_ || sceneVisibleRows_ > 2 ||
                    lockedSceneDockHeight_ != expectedLowRow)
                    return;
                QDockWidget *dock = ScenesDock();
                if (dock && qAbs(dock->height() - expectedLowRow) > 3)
                    ForceBottomRowHeightNow(expectedLowRow,
                                            QStringLiteral("row capture settled"), true);
            });
        }

        LogSceneRowMinimumChain(QStringLiteral("POST-CAPTURE"));
        DebugWrite(QStringLiteral("SCENE ROW MINIMUM rows=%1 visualPitch=%2 sceneDockMinH=%3 mixerMinH=%4")
'@ 'force exact 1/2 row floor as soon as captured'

# During a real mouse drag, do not run the row-lock reassert/refresh machinery on
# every Resize. Qt gets the native OBS drag path. The only exception is the
# explicit low-row snap in the manual block below.
Replace-Required @'
        if (sceneRowLockEnabled_ && !sceneRowLockApplying_ && event &&
            (event->type() == QEvent::Resize || event->type() == QEvent::LayoutRequest ||
             event->type() == QEvent::Show)) {
            if (watched == ScenesDock() || watched == StackedMixerArea()) {
                ReassertSceneRowLock();
                if (!suppressManualDockCapture_ && !restoringDockTargets_ &&
                    applyPreservedSceneDockHeight_ <= 0)
                    ScheduleSceneRowMinimumRefresh();
            }
        }
'@ @'
        if (sceneRowLockEnabled_ && !sceneRowLockApplying_ && event &&
            (event->type() == QEvent::Resize || event->type() == QEvent::LayoutRequest ||
             event->type() == QEvent::Show)) {
            if (watched == ScenesDock() || watched == StackedMixerArea()) {
                const bool realSeparatorDrag =
                    event->type() == QEvent::Resize && IsManualBottomRowResizeGesture();
                if (!realSeparatorDrag && !lowRowForceActive_)
                    ReassertSceneRowLock();
                if (!realSeparatorDrag && !lowRowForceActive_ &&
                    !suppressManualDockCapture_ && !restoringDockTargets_ &&
                    applyPreservedSceneDockHeight_ <= 0)
                    ScheduleSceneRowMinimumRefresh();
            }
        }
'@ 'keep row-lock machinery out of native manual drag hot path'

# Replace v3.22's hot drag block. All per-pixel work is in-memory only. Stable
# target capture + QSettings write/sync happen once after 90ms of quiet time.
$eventFilterPos = $s.IndexOf('    bool eventFilter(QObject *watched, QEvent *event) override')
if ($eventFilterPos -lt 0) { throw 'v3.23 could not locate eventFilter' }
$gesturePos = $s.IndexOf('            IsManualBottomRowResizeGesture() &&', $eventFilterPos)
if ($gesturePos -lt 0) { throw 'v3.23 could not locate manual gesture block' }
$manualStart = $s.LastIndexOf('        if (event && event->type() == QEvent::Resize', $gesturePos)
$manualEnd = $s.IndexOf('        return QObject::eventFilter(watched, event);', $gesturePos)
if ($manualStart -lt 0 -or $manualEnd -lt 0) { throw 'v3.23 could not bound manual gesture block' }

$manualBlock = @'
        if (event && event->type() == QEvent::Resize &&
            !restoringDockTargets_ && !suppressManualDockCapture_ && !lowRowForceActive_ &&
            IsManualBottomRowResizeGesture() &&
            proportionalMode_ && currentUiPercent_ < 99.999) {
            if (auto *dock = qobject_cast<QDockWidget *>(watched)) {
                if (dock->property(PROP_DOCK_STABLE_H).isValid()) {
                    ++manualDockCaptureGeneration_;
                    ++manualResizeSerial_;

                    if (QDockWidget *sceneDock = ScenesDock()) {
                        int manualHeight = sceneDock->height();
                        const int floorHeight = sceneRowLockEnabled_ ? qMax(1, lockedSceneDockHeight_) : 1;
                        const int pitch = qMax(1, CurrentSceneRowHeight());
                        const bool shrinking = lastManualObservedHeight_ <= 0 ||
                                               manualHeight < lastManualObservedHeight_ - 1;
                        lastManualObservedHeight_ = manualHeight;

                        if (sceneRowLockEnabled_ && sceneVisibleRows_ <= 2 && shrinking &&
                            manualHeight > floorHeight + 2 &&
                            manualHeight <= floorHeight + (pitch * 4)) {
                            ForceBottomRowHeightNow(
                                floorHeight, QStringLiteral("manual low-row snap"), true);
                            manualHeight = sceneDock->height();
                            lastManualObservedHeight_ = manualHeight;
                        }

                        if (manualHeight >= floorHeight && manualHeight > 0) {
                            // Immediate in-memory authority keeps DOWN->Scene and
                            // DOWN->Apply race protection without any disk I/O or
                            // whole-dock scans while the mouse is moving.
                            savedManualSceneDockHeight_ = manualHeight;
                            lastImmediateManualSceneDockHeight_ = manualHeight;

                            const int settledHeight = manualHeight;
                            const int settleGeneration = ++manualDragSettleGeneration_;
                            QTimer::singleShot(90, this,
                                [this, settleGeneration, settledHeight]() {
                                    if (settleGeneration != manualDragSettleGeneration_)
                                        return;

                                    QDockWidget *dock = ScenesDock();
                                    if (!dock)
                                        return;

                                    const int floor = sceneRowLockEnabled_
                                                        ? qMax(1, lockedSceneDockHeight_) : 1;
                                    const int finalHeight = qMax(floor, dock->height());
                                    savedManualSceneDockHeight_ = finalHeight;
                                    lastImmediateManualSceneDockHeight_ = finalHeight;
                                    CaptureStableDockTargets();

                                    if (settings_) {
                                        settings_->setValue(
                                            QStringLiteral("ui/manualSceneDockHeight"),
                                            savedManualSceneDockHeight_);
                                        settings_->sync();
                                    }
                                    DebugWrite(QStringLiteral(
                                        "MANUAL DRAG SETTLED height=%1 serial=%2 initialQuietTarget=%3")
                                                   .arg(finalHeight)
                                                   .arg(manualResizeSerial_)
                                                   .arg(settledHeight));
                                });
                        }
                    }
                }
            }
        }

'@
$s = $s.Substring(0, $manualStart) + $manualBlock.Replace("`r`n", "`n") + $s.Substring($manualEnd)

# No DEBUG file write for every Resize. Major Apply/Scene/test events still log,
# so diagnostics remain useful without changing interaction latency.
$debugWidget = @'
    void DebugWidgetEvent(QWidget *widget, QEvent::Type type)
    {
        Q_UNUSED(widget);
        Q_UNUSED(type);
    }

'@
Replace-Block '    void DebugWidgetEvent(QWidget *widget, QEvent::Type type)' '    QString DebugFrontendEventName' $debugWidget 'remove per-resize debug I/O'

# One delayed geometry snapshot is enough for DEBUG. This affects diagnostics
# only; correctness guards/tests still have their own timers.
$s = $s.Replace('const int delays[] = {0, 120, 500, 1200};',
                'const int delays[] = {300};')

Replace-Required '    int manualSettingsSyncGeneration_ = 0;' '    int manualDragSettleGeneration_ = 0;' 'replace per-pixel settings sync generation'

$s = $s.Replace('OBS UI Scale v3.22 DEBUG', 'OBS UI Scale v3.23 DEBUG')
$s = $s.Replace('OBS UI Scale v3.22 DEBUG LOG', 'OBS UI Scale v3.23 DEBUG LOG')
$s = $s.Replace('v3.22 DEBUG', 'v3.23 DEBUG')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.22.0', '3.23.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.22.0', 'OBS-UI-Scale-Debug-Setup-3.23.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.23 DEBUG vanilla-smooth drag path + recursive exact 1-row force.'

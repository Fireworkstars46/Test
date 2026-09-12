$ErrorActionPreference = 'Stop'
& ./build-v3.21-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.22 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}
function Replace-Block([string]$startMarker, [string]$endMarker, [string]$newBlock, [string]$label) {
    $start = $script:s.IndexOf($startMarker)
    if ($start -lt 0) { throw "v3.22 could not locate start of $label" }
    $end = $script:s.IndexOf($endMarker, $start)
    if ($end -lt 0) { throw "v3.22 could not locate end of $label" }
    $script:s = $script:s.Substring(0, $start) + $newBlock.Replace("`r`n", "`n") + $script:s.Substring($end)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.21.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.22.0-debug";' 'plugin version'

Replace-Required @'
static constexpr const char *PROP_SCENE_OLD_LAYOUT_CONSTRAINT = "obsUiScaleSceneOldLayoutConstraint";
'@ @'
static constexpr const char *PROP_SCENE_OLD_LAYOUT_CONSTRAINT = "obsUiScaleSceneOldLayoutConstraint";
static constexpr const char *PROP_LOWROW_OLD_MAX_H = "obsUiScaleLowRowOldMaxH";
static constexpr const char *PROP_LOWROW_OLD_VPOLICY = "obsUiScaleLowRowOldVPolicy";
static constexpr const char *PROP_LOWROW_CONTENT_OLD_MIN_H = "obsUiScaleLowRowContentOldMinH";
static constexpr const char *PROP_LOWROW_CONTENT_OLD_MAX_H = "obsUiScaleLowRowContentOldMaxH";
static constexpr const char *PROP_LOWROW_CONTENT_OLD_VPOLICY = "obsUiScaleLowRowContentOldVPolicy";
'@ 'low-row latch properties'

$relaxSiblings = @'
    void RelaxBottomRowSiblingMinimums()
    {
        if (!sceneRowLockEnabled_)
            return;

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        if (!mainWindow || !sceneDock || !sceneDock->isVisible() || sceneDock->isFloating())
            return;
        if (mainWindow->dockWidgetArea(sceneDock) != Qt::BottomDockWidgetArea)
            return;

        const int rowY = sceneDock->y();
        const auto docks = mainWindow->findChildren<QDockWidget *>(QString(), Qt::FindDirectChildrenOnly);
        for (QDockWidget *dock : docks) {
            if (!dock || dock == sceneDock || !dock->isVisible() || dock->isFloating())
                continue;
            if (mainWindow->dockWidgetArea(dock) != Qt::BottomDockWidgetArea)
                continue;
            if (qAbs(dock->y() - rowY) > 4)
                continue;

            if (!dock->property(PROP_ROW_OLD_MIN_H).isValid())
                dock->setProperty(PROP_ROW_OLD_MIN_H, dock->minimumHeight());

            // Do NOT permanently set QSizePolicy::Ignored. That was the v3.21
            // toolbar/button layout regression. Only clear the explicit floor.
            dock->setMinimumHeight(0);
            dock->updateGeometry();
        }
    }

'@
Replace-Block '    void RelaxBottomRowSiblingMinimums()' '    void RestoreBottomRowSiblingMinimums()' $relaxSiblings 'normal sibling relaxation'

$relaxScene = @'
    void RelaxSceneDockInternalMinimums()
    {
        if (!sceneRowLockEnabled_)
            return;

        QDockWidget *sceneDock = ScenesDock();
        QAbstractItemView *list = ScenesListView();
        if (!sceneDock || !list)
            return;

        for (QWidget *w = list; w && w != sceneDock; w = w->parentWidget()) {
            if (!w->property(PROP_SCENE_OLD_MIN_H).isValid())
                w->setProperty(PROP_SCENE_OLD_MIN_H, w->minimumHeight());

            w->setMinimumHeight(0);

            if (QLayout *layout = w->layout()) {
                if (!w->property(PROP_SCENE_OLD_LAYOUT_CONSTRAINT).isValid())
                    w->setProperty(PROP_SCENE_OLD_LAYOUT_CONSTRAINT,
                                   static_cast<int>(layout->sizeConstraint()));
                layout->setSizeConstraint(QLayout::SetNoConstraint);
                layout->invalidate();
            }
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
Replace-Block '    void RelaxSceneDockInternalMinimums()' '    void RestoreSceneDockInternalMinimums()' $relaxScene 'Scenes internal relaxation'

$refresh = @'
    void RefreshWidgets()
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        if (!mainWindow)
            return;

        if (QLayout *layout = mainWindow->layout())
            layout->invalidate();
        mainWindow->updateGeometry();
        mainWindow->update();

        const auto docks = mainWindow->findChildren<QDockWidget *>(QString(), Qt::FindDirectChildrenOnly);
        for (QDockWidget *dock : docks) {
            if (!dock || !dock->isVisible())
                continue;
            dock->updateGeometry();
            dock->update();
        }

        if (QDockWidget *sceneDock = ScenesDock()) {
            sceneDock->updateGeometry();
            sceneDock->update();
        }
        if (QStackedWidget *mixer = StackedMixerArea()) {
            mixer->updateGeometry();
            mixer->update();
        }
    }

'@
Replace-Block '    void RefreshWidgets()' '    void ApplyScale(double requestedUiPercent' $refresh 'targeted RefreshWidgets'

$debugWidget = @'
    void DebugWidgetEvent(QWidget *widget, QEvent::Type type)
    {
        if (!debugLoggingEnabled_ || type != QEvent::Resize || !widget)
            return;

        QWidget *sceneDock = ScenesDock();
        QWidget *mixer = StackedMixerArea();
        if (widget != sceneDock && widget != mixer)
            return;

        DebugWrite(QStringLiteral("QT RESIZE: %1").arg(DebugWidgetSummary(widget)));
    }

'@
Replace-Block '    void DebugWidgetEvent(QWidget *widget, QEvent::Type type)' '    QString DebugFrontendEventName' $debugWidget 'lightweight geometry event logging'

$s = $s.Replace('const int delays[] = {0, 5, 15, 30, 60, 100, 180, 300, 500, 800, 1200};',
                'const int delays[] = {0, 120, 500, 1200};')
$s = $s.Replace('const int delays[] = {0, 5, 15, 35, 70, 100, 150, 220, 350, 500, 800, 1200};',
                'const int delays[] = {0, 120, 500, 1200};')
$s = $s.Replace('const int delays[] = {20, 60, 120, 220, 350, 550, 800, 1100, 1350};',
                'const int delays[] = {30, 150, 500, 1000, 1350};')

$insertMarker = '    void ReassertSceneRowLock()'
$insertPos = $s.IndexOf($insertMarker)
if ($insertPos -lt 0) { throw 'v3.22 could not locate ReassertSceneRowLock insertion point' }
$lowRowHelper = @'
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

                if (QWidget *content = dock->widget()) {
                    if (content->property(PROP_LOWROW_CONTENT_OLD_MIN_H).isValid()) {
                        content->setMinimumHeight(content->property(PROP_LOWROW_CONTENT_OLD_MIN_H).toInt());
                        content->setProperty(PROP_LOWROW_CONTENT_OLD_MIN_H, QVariant());
                    }
                    if (content->property(PROP_LOWROW_CONTENT_OLD_MAX_H).isValid()) {
                        const int oldMax = content->property(PROP_LOWROW_CONTENT_OLD_MAX_H).toInt();
                        content->setMaximumHeight(oldMax > 0 ? oldMax : QWIDGETSIZE_MAX);
                        content->setProperty(PROP_LOWROW_CONTENT_OLD_MAX_H, QVariant());
                    }
                    if (content->property(PROP_LOWROW_CONTENT_OLD_VPOLICY).isValid()) {
                        QSizePolicy policy = content->sizePolicy();
                        policy.setVerticalPolicy(static_cast<QSizePolicy::Policy>(
                            content->property(PROP_LOWROW_CONTENT_OLD_VPOLICY).toInt()));
                        content->setSizePolicy(policy);
                        content->setProperty(PROP_LOWROW_CONTENT_OLD_VPOLICY, QVariant());
                    }
                    content->updateGeometry();
                }
                dock->updateGeometry();
            }
        }

        lowRowFloorLatchActive_ = false;
        lowRowFloorLatchHeight_ = -1;
        lowRowLatchSeenRelease_ = false;
        ++lowRowFloorLatchGeneration_;
        lastManualObservedHeight_ = ScenesDock() ? ScenesDock()->height() : -1;
        DebugWrite(QStringLiteral("LOW ROW FLOOR LATCH RELEASED"));
        ReassertSceneRowLock();
    }

    void PollLowRowFloorLatchForUnlock(int generation)
    {
        if (!lowRowFloorLatchActive_ || generation != lowRowFloorLatchGeneration_)
            return;

        if (!(QApplication::mouseButtons() & Qt::LeftButton)) {
            lowRowLatchSeenRelease_ = true;
        } else if (lowRowLatchSeenRelease_ && IsManualBottomRowResizeGesture()) {
            DebugWrite(QStringLiteral("LOW ROW FLOOR LATCH UNLOCKED BY NEXT SEPARATOR DRAG"));
            ReleaseLowRowFloorLatch();
            return;
        }

        QTimer::singleShot(16, this, [this, generation]() {
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

            if (!dock->property(PROP_LOWROW_OLD_MAX_H).isValid())
                dock->setProperty(PROP_LOWROW_OLD_MAX_H, dock->maximumHeight());
            if (!dock->property(PROP_LOWROW_OLD_VPOLICY).isValid())
                dock->setProperty(PROP_LOWROW_OLD_VPOLICY,
                                  static_cast<int>(dock->sizePolicy().verticalPolicy()));

            dock->setMinimumHeight(dock == sceneDock ? targetHeight : 0);
            dock->setMaximumHeight(targetHeight);
            QSizePolicy dockPolicy = dock->sizePolicy();
            dockPolicy.setVerticalPolicy(QSizePolicy::Ignored);
            dock->setSizePolicy(dockPolicy);

            if (QWidget *content = dock->widget()) {
                if (!content->property(PROP_LOWROW_CONTENT_OLD_MIN_H).isValid())
                    content->setProperty(PROP_LOWROW_CONTENT_OLD_MIN_H, content->minimumHeight());
                if (!content->property(PROP_LOWROW_CONTENT_OLD_MAX_H).isValid())
                    content->setProperty(PROP_LOWROW_CONTENT_OLD_MAX_H, content->maximumHeight());
                if (!content->property(PROP_LOWROW_CONTENT_OLD_VPOLICY).isValid())
                    content->setProperty(PROP_LOWROW_CONTENT_OLD_VPOLICY,
                                         static_cast<int>(content->sizePolicy().verticalPolicy()));

                content->setMinimumHeight(0);
                content->setMaximumHeight(targetHeight);
                QSizePolicy contentPolicy = content->sizePolicy();
                contentPolicy.setVerticalPolicy(QSizePolicy::Ignored);
                content->setSizePolicy(contentPolicy);
                content->updateGeometry();
            }

            dock->updateGeometry();
            rowDocks.push_back(dock);
            targetHeights.push_back(targetHeight);
        }

        restoringDockTargets_ = true;
        if (!rowDocks.isEmpty())
            mainWindow->resizeDocks(rowDocks, targetHeights, Qt::Vertical);
        else
            mainWindow->resizeDocks({sceneDock}, {targetHeight}, Qt::Vertical);
        if (QLayout *layout = mainWindow->layout()) {
            layout->invalidate();
            layout->activate();
        }
        mainWindow->resizeDocks({sceneDock}, {targetHeight}, Qt::Vertical);
        restoringDockTargets_ = false;

        const int actual = sceneDock->height();
        const bool reached = qAbs(actual - targetHeight) <= 3;
        DebugWrite(QStringLiteral(
            "FORCE BOTTOM ROW reason='%1' target=%2 actual=%3 reached=%4 rowDocks=%5")
                       .arg(reason).arg(targetHeight).arg(actual).arg(reached ? 1 : 0).arg(rowDocks.size()));

        lowRowForceActive_ = false;

        if (latch && reached) {
            lowRowFloorLatchActive_ = true;
            lowRowFloorLatchHeight_ = targetHeight;
            lowRowLatchSeenRelease_ = false;
            const int generation = ++lowRowFloorLatchGeneration_;
            PollLowRowFloorLatchForUnlock(generation);
        } else {
            lowRowFloorLatchActive_ = true;
            ReleaseLowRowFloorLatch();
        }

        return reached;
    }

'@
$s = $s.Substring(0, $insertPos) + $lowRowHelper.Replace("`r`n", "`n") + $s.Substring($insertPos)

Replace-Required @'
        const int delta = targetDockHeight - currentDockHeight;
        lockedSceneDockHeight_ = targetDockHeight;
'@ @'
        if (lowRowFloorLatchActive_ && lowRowFloorLatchHeight_ != targetDockHeight)
            ReleaseLowRowFloorLatch();

        const int delta = targetDockHeight - currentDockHeight;
        lockedSceneDockHeight_ = targetDockHeight;
'@ 'release stale latch when row setting changes'

$gesturePos = $s.IndexOf('            IsManualBottomRowResizeGesture() &&')
if ($gesturePos -lt 0) { throw 'v3.22 could not locate manual gesture block' }
$manualStart = $s.LastIndexOf('        if (event && event->type() == QEvent::Resize', $gesturePos)
$manualEnd = $s.IndexOf('        return QObject::eventFilter(watched, event);', $gesturePos)
if ($manualStart -lt 0 -or $manualEnd -lt 0) { throw 'v3.22 could not bound manual gesture block' }

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
                            manualHeight <= floorHeight + (pitch * 3)) {
                            if (ForceBottomRowHeightNow(
                                    floorHeight, QStringLiteral("manual low-row snap"), true)) {
                                manualHeight = sceneDock->height();
                                lastManualObservedHeight_ = manualHeight;
                            }
                        }

                        if (manualHeight >= floorHeight && manualHeight > 0) {
                            savedManualSceneDockHeight_ = manualHeight;
                            lastImmediateManualSceneDockHeight_ = manualHeight;
                            CaptureStableDockTargets();

                            if (settings_) {
                                settings_->setValue(QStringLiteral("ui/manualSceneDockHeight"),
                                                    savedManualSceneDockHeight_);
                                const int syncGeneration = ++manualSettingsSyncGeneration_;
                                QTimer::singleShot(120, this, [this, syncGeneration]() {
                                    if (syncGeneration != manualSettingsSyncGeneration_ || !settings_)
                                        return;
                                    settings_->sync();
                                    DebugWrite(QStringLiteral(
                                        "MANUAL HEIGHT DEBOUNCED DISK SYNC height=%1 serial=%2")
                                                   .arg(savedManualSceneDockHeight_)
                                                   .arg(manualResizeSerial_));
                                });
                            }

                            DebugWrite(QStringLiteral(
                                "MANUAL SCENE DOCK HEIGHT UPDATED height=%1 serial=%2")
                                           .arg(savedManualSceneDockHeight_)
                                           .arg(manualResizeSerial_));
                        }
                    }
                }
            }
        }

'@
$s = $s.Substring(0, $manualStart) + $manualBlock.Replace("`r`n", "`n") + $s.Substring($manualEnd)

Replace-Required @'
    bool realApplySmoothGuardActive_ = false;
'@ @'
    bool realApplySmoothGuardActive_ = false;
    int manualSettingsSyncGeneration_ = 0;
    int lastManualObservedHeight_ = -1;
    bool lowRowForceActive_ = false;
    bool lowRowFloorLatchActive_ = false;
    bool lowRowLatchSeenRelease_ = false;
    int lowRowFloorLatchHeight_ = -1;
    int lowRowFloorLatchGeneration_ = 0;
'@ 'v3.22 low-row/performance members'

$s = $s.Replace('OBS UI Scale v3.21 DEBUG', 'OBS UI Scale v3.22 DEBUG')
$s = $s.Replace('OBS UI Scale v3.21 DEBUG LOG', 'OBS UI Scale v3.22 DEBUG LOG')
$s = $s.Replace('v3.21 DEBUG', 'v3.22 DEBUG')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.21.0', '3.22.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.21.0', 'OBS-UI-Scale-Debug-Setup-3.22.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.22 DEBUG button-layout, low-lag drag, and physical 1-row latch fix.'

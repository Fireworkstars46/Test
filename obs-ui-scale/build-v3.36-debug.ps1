$ErrorActionPreference = 'Stop'

# v3.36 DEBUG
# v3.35 log/video findings:
# - exact row target 67px was reached, but ~150ms later Qt expanded it to 86px;
# - repeated global MouseButtonPress handling produced duplicate unlock work;
# - the global application event filter touches every Qt event and is not
#   acceptable for the "vanilla-smooth / no game lag" goal;
# - Source Clone's Sources-list icon is still visually wrong. The remaining
#   global QAbstractItemView runtime style + transformed icon-related theme
#   metrics can affect OBS/plugin item delegates even though button icon scaling
#   was removed.
#
# v3.36 removes persistent dock maximums entirely. Exact low-row mode instead
# uses Qt's vertical Ignore policy on the QDockWidget itself + ONLY the root dock
# content container. The splitter therefore remains fully draggable with no max
# lock. Row geometry is placed with resizeDocks and held by relaxed minimum-size
# hints, not by polling or a permanent maximum.
#
# Scene protection is also event-driven: one guard expiry timer is armed on a
# scene change, and actual Scenes-dock Resize events are repaired only if OBS
# really moved the splitter.
& ./build-v3.35-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$crlf = [string][char]13 + [string][char]10
$lf = [string][char]10
$s = $s.Replace($crlf, $lf)

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace($crlf, $lf)
    $new = $new.Replace($crlf, $lf)
    if (-not $script:s.Contains($old)) { throw "v3.36 patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}
function Replace-Block([string]$startMarker, [string]$endMarker, [string]$newBlock, [string]$label) {
    $start = $script:s.IndexOf($startMarker)
    if ($start -lt 0) { throw "v3.36 could not locate start of $label" }
    $end = $script:s.IndexOf($endMarker, $start)
    if ($end -lt 0) { throw "v3.36 could not locate end of $label" }
    $script:s = $script:s.Substring(0, $start) + $newBlock.Replace($crlf, $lf) + $script:s.Substring($end)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.35.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.36.0-debug";' 'plugin version'

# ---------------------------------------------------------------------------
# Protect OBS/plugin source-tree icon delegates.
# ---------------------------------------------------------------------------
Replace-Required @'
            const bool isFontValue = propertyText.contains(QStringLiteral("font"));
            const double percent = isFontValue ? textPercent : uiPercent;
'@ @'
            const bool isFontValue =
                propertyText.contains(QStringLiteral("font"));
            const bool isIconValue =
                propertyText.contains(QStringLiteral("icon"));
            const double percent =
                isIconValue ? 100.0
                            : (isFontValue ? textPercent : uiPercent);
'@ 'do not transform theme icon pixel metrics'

if ($s.Contains('QAbstractItemView::item, QHeaderView::section')) {
    $s = $s.Replace('QAbstractItemView::item, QHeaderView::section',
                    'QHeaderView::section')
} elseif ($s.Contains('QAbstractItemView::item')) {
    $s = $s.Replace('QAbstractItemView::item, ', '')
}

# ---------------------------------------------------------------------------
# No global qApp event filter. It was invoked for every Qt event.
# Existing dock/widget event filters are enough for resize-based logic.
# ---------------------------------------------------------------------------
Replace-Required @'
        obs_frontend_add_event_callback(&ObsUiScaleController::FrontendEvent, this);
        if (qApp)
            qApp->installEventFilter(this);
'@ @'
        obs_frontend_add_event_callback(&ObsUiScaleController::FrontendEvent, this);
'@ 'remove global application event filter install'

Replace-Required @'
        if (qApp)
            qApp->removeEventFilter(this);
        obs_frontend_remove_event_callback(&ObsUiScaleController::FrontendEvent, this);
'@ @'
        obs_frontend_remove_event_callback(&ObsUiScaleController::FrontendEvent, this);
'@ 'remove global application event filter removal'

$mousePressBlock = @'
        if (event && event->type() == QEvent::MouseButtonPress &&
            lowRowFloorLatchActive_) {
            auto *mouseEvent = static_cast<QMouseEvent *>(event);
            if (mouseEvent && mouseEvent->button() == Qt::LeftButton) {
                auto *mainWindow =
                    static_cast<QMainWindow *>(
                        obs_frontend_get_main_window());
                QDockWidget *sceneDock = ScenesDock();
                if (mainWindow && sceneDock) {
                    const QPoint cursor = QCursor::pos();
                    const QPoint sceneTop =
                        sceneDock->mapToGlobal(QPoint(0, 0));
                    const QPoint mainTop =
                        mainWindow->mapToGlobal(QPoint(0, 0));
                    const int splitterY = sceneTop.y();
                    const int left = mainTop.x();
                    const int right = left + mainWindow->width();

                    if (cursor.x() >= left &&
                        cursor.x() <= right &&
                        qAbs(cursor.y() - splitterY) <= 16) {
                        ReleaseLowRowDockMaximumsOnly();
                    }
                }
            }
        }

'@
Replace-Required $mousePressBlock '' 'remove global splitter mouse handler'

# ---------------------------------------------------------------------------
# Low row = relaxed size hints, never a max-height lock.
# ---------------------------------------------------------------------------
$manualRelax = @'
    void RelaxLowRowDescendantsForManualDrag()
    {
        if (!sceneRowLockEnabled_ || sceneVisibleRows_ > 2)
            return;

        auto *mainWindow =
            static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        if (!mainWindow || !sceneDock)
            return;

        RelaxBottomRowSiblingMinimums();
        RelaxSceneDockInternalMinimums();

        static constexpr const char *PROP_SCENE_DOCK_OLD_VPOLICY =
            "obsUiScaleLowRowSceneDockOldVPolicy";

        if (!sceneDock->property(PROP_SCENE_DOCK_OLD_VPOLICY).isValid()) {
            sceneDock->setProperty(
                PROP_SCENE_DOCK_OLD_VPOLICY,
                static_cast<int>(
                    sceneDock->sizePolicy().verticalPolicy()));
        }
        QSizePolicy sceneDockPolicy = sceneDock->sizePolicy();
        sceneDockPolicy.setVerticalPolicy(QSizePolicy::Ignored);
        sceneDock->setSizePolicy(sceneDockPolicy);

        const int rowY = sceneDock->y();
        const int floor = qMax(1, lockedSceneDockHeight_);
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

            dock->setMinimumHeight(dock == sceneDock ? floor : 0);

            // Only root content is relaxed. Child source/scene item widgets,
            // custom plugin icons and button layouts stay untouched.
            if (QWidget *content = dock->widget())
                ApplyLowRowWidgetCap(content, floor);

            dock->updateGeometry();
        }

        if (QLayout *layout = mainWindow->layout())
            layout->invalidate();
    }

'@
Replace-Block '    void RelaxLowRowDescendantsForManualDrag()' '    void RestoreLowRowDescendantVisualState()' $manualRelax 'dock+root low-row relaxation'

$restoreVisual = @'
    void RestoreLowRowDescendantVisualState()
    {
        auto *mainWindow =
            static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        if (!mainWindow || !sceneDock)
            return;

        static constexpr const char *PROP_SCENE_DOCK_OLD_VPOLICY =
            "obsUiScaleLowRowSceneDockOldVPolicy";

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

            if (QWidget *content = dock->widget())
                RestoreLowRowWidgetCap(content);
            dock->updateGeometry();
        }

        if (sceneDock->property(PROP_SCENE_DOCK_OLD_VPOLICY).isValid()) {
            QSizePolicy policy = sceneDock->sizePolicy();
            policy.setVerticalPolicy(static_cast<QSizePolicy::Policy>(
                sceneDock->property(
                    PROP_SCENE_DOCK_OLD_VPOLICY).toInt()));
            sceneDock->setSizePolicy(policy);
            sceneDock->setProperty(
                PROP_SCENE_DOCK_OLD_VPOLICY, QVariant());
        }

        RestoreBottomRowSiblingMinimums();
        RestoreSceneDockInternalMinimums();

        if (sceneRowLockEnabled_ && lockedSceneDockHeight_ > 0)
            sceneDock->setMinimumHeight(lockedSceneDockHeight_);

        if (QLayout *layout = mainWindow->layout()) {
            layout->invalidate();
            layout->activate();
        }

        lowRowFloorLatchActive_ = false;
        lowRowFloorLatchHeight_ = -1;
        ++lowRowFloorLatchGeneration_;

        DebugWrite(QStringLiteral(
            "LOW ROW ROOT/Dock POLICIES RESTORED live=%1")
                       .arg(sceneDock->height()));
    }

'@
Replace-Block '    void RestoreLowRowDescendantVisualState()' '    void ReleaseLowRowDockMaximumsOnly()' $restoreVisual 'restore dock+root policies'

$release = @'
    void ReleaseLowRowDockMaximumsOnly()
    {
        // v3.36 never leaves a low-row maximum installed.
    }

    void ReleaseLowRowFloorLatch()
    {
        if (!lowRowFloorLatchActive_)
            return;
        RestoreLowRowDescendantVisualState();
    }

    void PollLowRowFloorLatchForUnlock(int generation)
    {
        Q_UNUSED(generation);
    }

'@
Replace-Block '    void ReleaseLowRowDockMaximumsOnly()' '    bool AdoptEquivalentLowRowPhysicalHeight' $release 'remove all persistent maximum-height locking'

$force = @'
    bool ForceBottomRowHeightNow(int targetHeight, const QString &reason,
                                 bool latch)
    {
        if (targetHeight <= 0 || lowRowForceActive_)
            return false;

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
        RelaxLowRowDescendantsForManualDrag();

        QList<QDockWidget *> rowDocks;
        QList<int> heights;
        const int rowY = sceneDock->y();
        const auto docks =
            mainWindow->findChildren<QDockWidget *>(
                QString(), Qt::FindDirectChildrenOnly);

        struct OldMax {
            QDockWidget *dock = nullptr;
            int maxHeight = QWIDGETSIZE_MAX;
        };
        QList<OldMax> temporaryMax;

        for (QDockWidget *dock : docks) {
            if (!dock || !dock->isVisible() || dock->isFloating())
                continue;
            if (mainWindow->dockWidgetArea(dock) !=
                Qt::BottomDockWidgetArea)
                continue;
            if (qAbs(dock->y() - rowY) > 4)
                continue;

            dock->setMinimumHeight(dock == sceneDock ? targetHeight : 0);

            // Max is used only during this synchronous geometry transaction.
            // It is restored before this function returns, so there is never a
            // locked splitter waiting on a timer or mouse hook.
            temporaryMax.push_back({dock, dock->maximumHeight()});
            dock->setMaximumHeight(targetHeight);

            if (QWidget *content = dock->widget())
                ApplyLowRowWidgetCap(content, targetHeight);

            dock->updateGeometry();
            rowDocks.push_back(dock);
            heights.push_back(targetHeight);
        }

        restoringDockTargets_ = true;
        if (!rowDocks.isEmpty())
            mainWindow->resizeDocks(rowDocks, heights, Qt::Vertical);
        if (QLayout *layout = mainWindow->layout()) {
            layout->invalidate();
            layout->activate();
        }
        mainWindow->resizeDocks({sceneDock}, {targetHeight}, Qt::Vertical);
        restoringDockTargets_ = false;

        for (const OldMax &item : temporaryMax) {
            if (item.dock) {
                item.dock->setMaximumHeight(item.maxHeight);
                item.dock->updateGeometry();
            }
        }

        // With dock/root vertical policies Ignored, releasing the temporary max
        // does not recreate the old sizeHint floor.
        if (QLayout *layout = mainWindow->layout()) {
            layout->invalidate();
            layout->activate();
        }

        const int actual = sceneDock->height();
        const bool reached = qAbs(actual - targetHeight) <= 3;

        if (latch && reached) {
            lowRowFloorLatchActive_ = true;
            lowRowFloorLatchHeight_ = targetHeight;
            ++lowRowFloorLatchGeneration_;
        } else if (!latch) {
            lowRowFloorLatchActive_ = false;
            lowRowFloorLatchHeight_ = -1;
        }

        if (reached && lowRowScaleSyncPending_) {
            savedManualSceneDockHeight_ = targetHeight;
            lastImmediateManualSceneDockHeight_ = targetHeight;
            applyPreservedSceneDockHeight_ = targetHeight;
            pendingCalibrationSceneDockHeight_ = targetHeight;
            lastManualObservedHeight_ = targetHeight;
            if (settings_) {
                settings_->setValue(
                    QStringLiteral("ui/manualSceneDockHeight"),
                    targetHeight);
                settings_->sync();
            }
            lowRowScaleSyncPending_ = false;
        }

        lowRowForceActive_ = false;

        DebugWrite(QStringLiteral(
            "LOW ROW UNLOCKED FORCE reason='%1' target=%2 actual=%3 reached=%4 rows=%5")
                       .arg(reason)
                       .arg(targetHeight)
                       .arg(actual)
                       .arg(reached ? 1 : 0)
                       .arg(CountFullyVisibleSceneRows()));
        return reached;
    }

'@
Replace-Block '    bool ForceBottomRowHeightNow' '    void ReassertSceneRowLock()' $force 'no-lock exact low-row force'

# While exact low-row relaxation is active, Reassert must keep the dock/root
# Ignore policies but must never impose a maximum.
$reassertStart = $s.IndexOf('    void ReassertSceneRowLock()')
$reassertEnd = $s.IndexOf('    void CaptureAndApplySceneRowLock()', $reassertStart)
if ($reassertStart -lt 0 -or $reassertEnd -lt 0) {
    throw 'v3.36 could not isolate ReassertSceneRowLock'
}
$reassert = $s.Substring($reassertStart, $reassertEnd - $reassertStart)
$reassertNeedle = '        sceneRowLockApplying_ = true;'
if (-not $reassert.Contains($reassertNeedle)) {
    throw 'v3.36 Reassert apply marker missing'
}
$reassert = $reassert.Replace(
    $reassertNeedle,
    $reassertNeedle + $lf +
    '        if (lowRowFloorLatchActive_)' + $lf +
    '            RelaxLowRowDescendantsForManualDrag();')
$s = $s.Substring(0, $reassertStart) +
     $reassert +
     $s.Substring($reassertEnd)

# ---------------------------------------------------------------------------
# Scene changes: event-driven repair only. No repeated guard timers.
# ---------------------------------------------------------------------------
$sceneGuard = @'
    void RestoreAuthoritativeSceneDockTarget()
    {
        if (lowRowFloorLatchActive_)
            return;
        if (IsManualBottomRowResizeGesture())
            return;
        if (restoringDockTargets_ || !proportionalMode_ ||
            currentUiPercent_ >= 99.999)
            return;

        auto *mainWindow =
            static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        if (!mainWindow || !sceneDock || !sceneDock->isVisible() ||
            sceneDock->isFloating())
            return;

        const int floorHeight =
            (sceneRowLockEnabled_ && lockedSceneDockHeight_ > 0)
                ? qMax(1, lockedSceneDockHeight_)
                : 1;
        int targetHeight = -1;

        if (sceneDockGuardActive_ && sceneGuardTargetHeight_ > 0)
            targetHeight =
                qMax(floorHeight, sceneGuardTargetHeight_);
        else if (savedManualSceneDockHeight_ > 0)
            targetHeight =
                qMax(floorHeight, savedManualSceneDockHeight_);

        if (targetHeight <= 0 ||
            qAbs(sceneDock->height() - targetHeight) <= 2)
            return;

        restoringDockTargets_ = true;
        mainWindow->resizeDocks(
            {sceneDock}, {targetHeight}, Qt::Vertical);
        restoringDockTargets_ = false;

        DebugWrite(QStringLiteral(
            "SCENE RESIZE EVENT REPAIRED target=%1 live=%2")
                       .arg(targetHeight)
                       .arg(sceneDock->height()));
    }

    void ArmSceneDockGuard()
    {
        if (lowRowFloorLatchActive_)
            return;
        if (IsManualBottomRowResizeGesture())
            return;
        if (!proportionalMode_ || currentUiPercent_ >= 99.999)
            return;

        QDockWidget *sceneDock = ScenesDock();
        const int floorHeight =
            (sceneRowLockEnabled_ && lockedSceneDockHeight_ > 0)
                ? qMax(1, lockedSceneDockHeight_)
                : 1;

        if (!sceneDockGuardActive_) {
            if (sceneDock && sceneDock->height() > 0)
                sceneGuardTargetHeight_ =
                    qMax(floorHeight, sceneDock->height());
            else if (savedManualSceneDockHeight_ > 0)
                sceneGuardTargetHeight_ =
                    qMax(floorHeight,
                         savedManualSceneDockHeight_);

            if (sceneGuardTargetHeight_ > 0 &&
                manualResizeSerial_ >
                    lastSceneGuardManualSerial_) {
                savedManualSceneDockHeight_ =
                    sceneGuardTargetHeight_;
                lastImmediateManualSceneDockHeight_ =
                    sceneGuardTargetHeight_;
                if (settings_) {
                    settings_->setValue(
                        QStringLiteral(
                            "ui/manualSceneDockHeight"),
                        savedManualSceneDockHeight_);
                }
            }
            lastSceneGuardManualSerial_ =
                manualResizeSerial_;
        }

        ++manualDockCaptureGeneration_;
        sceneDockGuardActive_ = true;
        const int generation = ++sceneDockGuardGeneration_;

        // Resize events themselves perform repairs. This timer only expires
        // the target after OBS's scene-layout settle window.
        QTimer::singleShot(1200, this,
                           [this, generation]() {
            if (generation != sceneDockGuardGeneration_)
                return;
            sceneDockGuardActive_ = false;
            sceneGuardTargetHeight_ = -1;
        });
    }

'@
Replace-Block '    void RestoreAuthoritativeSceneDockTarget()' '    bool IsManualBottomRowResizeGesture() const' $sceneGuard 'event-driven scene guard'

$eventMarker = @'
    bool eventFilter(QObject *watched, QEvent *event) override
    {
'@
Replace-Required $eventMarker @'
    bool eventFilter(QObject *watched, QEvent *event) override
    {
        if (event && event->type() == QEvent::Resize &&
            watched == ScenesDock() &&
            sceneDockGuardActive_ &&
            !restoringDockTargets_ &&
            !suppressManualDockCapture_ &&
            !lowRowFloorLatchActive_ &&
            !IsManualBottomRowResizeGesture()) {
            RestoreAuthoritativeSceneDockTarget();
        }

'@ 'repair scene guard only on real dock resize event'

# Remove a noisy "armed" debug line if the older handler still contains it.
$s = $s.Replace(
    '            DebugWrite(QStringLiteral("PREVIEW SCENE REPAIR ARMED"));' + $lf,
    '')

# Update the stale description shown at the top of the settings dialog.
$oldDescription =
    'v3.15 DEBUG keeps the passing v3.12 Full Self-Test and adds a real end-to-end restart test: actual dialog controls + Apply, live row/mixer floor, genuine mouse separator drag, automatic OBS close/reopen, startup persistence verification, post-restart Apply, and automatic restoration of your original settings. Debug logging remains optional. After reproducing it once, send the OBS-UI-Scale-Debug.txt file from your Desktop.'
if ($s.Contains($oldDescription)) {
    $s = $s.Replace(
        $oldDescription,
        'v3.36 DEBUG uses an unlocked event-driven 1-row floor, protects native OBS/plugin source-list icon styling, removes global Qt event polling, and keeps the fully automatic restart/combination test. Debug logging remains optional.')
}

$s = $s.Replace('OBS UI Scale v3.35 DEBUG', 'OBS UI Scale v3.36 DEBUG')
$s = $s.Replace('OBS UI Scale v3.35 DEBUG LOG', 'OBS UI Scale v3.36 DEBUG LOG')
$s = $s.Replace('v3.35 DEBUG', 'v3.36 DEBUG')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.35.0', '3.36.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.35.0',
                    'OBS-UI-Scale-Debug-Setup-3.36.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.36 DEBUG no-lock low-row + native item/icon styling + event-driven scene guard.'

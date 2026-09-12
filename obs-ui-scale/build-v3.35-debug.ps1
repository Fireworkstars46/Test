$ErrorActionPreference = 'Stop'

# v3.35 DEBUG
# Consolidates the low-row engine around the actual failure seen in v3.34:
# - Apply smooth guard expected stale savedManual=86 while live was 165, causing
#   54 synchronous repairs in ~4 seconds (major UI/game stutter);
# - row=1 target was correctly calculated at 67-69px but never reached because
#   descendant minimum-size hints still blocked QMainWindow at 109-165px;
# - Scene guards scheduled many no-op repairs for every preview/scene change;
# - global button icon scaling can distort third-party plugin icons (Source Clone).
#
# v3.35:
# 1) real Apply uses the EXACT live dock height as its smooth target unless the
#    row is already latched at 1/2-row minimum and must follow a new scale floor;
# 2) exact low-row mode uses ONE root-content vertical Ignored/NoConstraint per
#    same-row dock plus a persistent dock max latch. No descendant policies are
#    changed. This is enough to bypass sizeHint blockers without corrupting child
#    text/icons/layout;
# 3) a global Qt event filter releases ONLY the dock max caps before the next
#    splitter drag. Root relaxation remains until the row grows, preventing the
#    splitter from re-locking at the old sizeHint floor;
# 4) no idle latch polling;
# 5) Scene guard becomes event-light: at most 3 checks and no resize/log when the
#    current height is already correct;
# 6) stop resizing QAbstractButton icons globally. Restore each captured native
#    icon size instead, protecting Source Clone and other third-party icons.
& ./build-v3.34-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$crlf = [string][char]13 + [string][char]10
$lf = [string][char]10
$s = $s.Replace($crlf, $lf)

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace($crlf, $lf)
    $new = $new.Replace($crlf, $lf)
    if (-not $script:s.Contains($old)) { throw "v3.35 patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}
function Replace-Block([string]$startMarker, [string]$endMarker, [string]$newBlock, [string]$label) {
    $start = $script:s.IndexOf($startMarker)
    if ($start -lt 0) { throw "v3.35 could not locate start of $label" }
    $end = $script:s.IndexOf($endMarker, $start)
    if ($end -lt 0) { throw "v3.35 could not locate end of $label" }
    $script:s = $script:s.Substring(0, $start) + $newBlock.Replace($crlf, $lf) + $script:s.Substring($end)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.34.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.35.0-debug";' 'plugin version'

Replace-Required @'
                    if (baseIconW > 0 && baseIconH > 0)
                        button->setIconSize(QSize(qMax(1, ScaledLength(baseIconW, uiPercent)),
                                                  qMax(1, ScaledLength(baseIconH, uiPercent))));
'@ @'
                    if (baseIconW > 0 && baseIconH > 0)
                        button->setIconSize(QSize(baseIconW, baseIconH));
'@ 'restore native button icon size instead of globally scaling icons'

$cap = @'
    void ApplyLowRowWidgetCap(QWidget *widget, int targetHeight)
    {
        Q_UNUSED(targetHeight);
        if (!widget)
            return;

        if (!widget->property(PROP_LOWROW_CONTENT_OLD_MIN_H).isValid())
            widget->setProperty(PROP_LOWROW_CONTENT_OLD_MIN_H,
                                widget->minimumHeight());
        if (!widget->property(PROP_LOWROW_CONTENT_OLD_VPOLICY).isValid())
            widget->setProperty(PROP_LOWROW_CONTENT_OLD_VPOLICY,
                                static_cast<int>(
                                    widget->sizePolicy().verticalPolicy()));

        widget->setMinimumHeight(0);

        QSizePolicy policy = widget->sizePolicy();
        policy.setVerticalPolicy(QSizePolicy::Ignored);
        widget->setSizePolicy(policy);

        if (QLayout *layout = widget->layout()) {
            if (!widget->property(PROP_LOWROW_LAYOUT_OLD_CONSTRAINT).isValid())
                widget->setProperty(
                    PROP_LOWROW_LAYOUT_OLD_CONSTRAINT,
                    static_cast<int>(layout->sizeConstraint()));
            layout->setSizeConstraint(QLayout::SetNoConstraint);
            layout->invalidate();
        }

        widget->updateGeometry();
    }

'@
Replace-Block '    void ApplyLowRowWidgetCap(QWidget *widget, int targetHeight)' '    void RestoreLowRowWidgetCap(QWidget *widget)' $cap 'root low-row content relaxation'

$restoreCap = @'
    void RestoreLowRowWidgetCap(QWidget *widget)
    {
        if (!widget)
            return;

        if (widget->property(PROP_LOWROW_CONTENT_OLD_MIN_H).isValid()) {
            widget->setMinimumHeight(
                qMax(0,
                     widget->property(PROP_LOWROW_CONTENT_OLD_MIN_H).toInt()));
            widget->setProperty(PROP_LOWROW_CONTENT_OLD_MIN_H, QVariant());
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
                    widget->property(
                        PROP_LOWROW_LAYOUT_OLD_CONSTRAINT).toInt()));
                widget->setProperty(PROP_LOWROW_LAYOUT_OLD_CONSTRAINT,
                                    QVariant());
            }
            layout->invalidate();
        }

        if (widget->property(PROP_LOWROW_CONTENT_OLD_MAX_H).isValid()) {
            const int oldMax =
                widget->property(PROP_LOWROW_CONTENT_OLD_MAX_H).toInt();
            widget->setMaximumHeight(
                oldMax > 0 ? oldMax : QWIDGETSIZE_MAX);
            widget->setProperty(PROP_LOWROW_CONTENT_OLD_MAX_H, QVariant());
        }

        widget->updateGeometry();
    }

'@
Replace-Block '    void RestoreLowRowWidgetCap(QWidget *widget)' '    void RelaxLowRowDescendantsForManualDrag()' $restoreCap 'restore root low-row content state'

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
            if (QWidget *content = dock->widget())
                ApplyLowRowWidgetCap(content, floor);
            dock->updateGeometry();
        }

        if (QListWidget *list = ScenesList()) {
            list->setMinimumHeight(0);
            if (QWidget *viewport = list->viewport())
                viewport->setMinimumHeight(0);
        }

        if (QLayout *layout = mainWindow->layout())
            layout->invalidate();
    }

'@
Replace-Block '    void RelaxLowRowDescendantsForManualDrag()' '    void RestoreLowRowDescendantVisualState()' $manualRelax 'manual root-only low-row relaxation'

$release = @'
    void ReleaseLowRowDockMaximumsOnly()
    {
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

        ++lowRowFloorLatchGeneration_;
        DebugWrite(QStringLiteral(
            "LOW ROW DOCK MAXIMUMS RELEASED FOR MANUAL DRAG target=%1")
                       .arg(lowRowFloorLatchHeight_));
    }

    void ReleaseLowRowFloorLatch()
    {
        if (!lowRowFloorLatchActive_)
            return;

        ReleaseLowRowDockMaximumsOnly();

        auto *mainWindow =
            static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        if (mainWindow && sceneDock) {
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

            if (QLayout *layout = mainWindow->layout()) {
                layout->invalidate();
                layout->activate();
            }
        }

        lowRowFloorLatchActive_ = false;
        lowRowFloorLatchHeight_ = -1;
        lowRowLatchSeenRelease_ = false;

        if (sceneRowLockEnabled_ && lockedSceneDockHeight_ > 0) {
            if (QDockWidget *dock = ScenesDock())
                dock->setMinimumHeight(lockedSceneDockHeight_);
        }

        DebugWrite(QStringLiteral("LOW ROW ROOT RELAXATION RELEASED"));
    }

    void PollLowRowFloorLatchForUnlock(int generation)
    {
        Q_UNUSED(generation);
    }

'@
Replace-Block '    void ReleaseLowRowFloorLatch()' '    bool AdoptEquivalentLowRowPhysicalHeight' $release 'event-driven low-row release helpers'

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
Replace-Block '    bool AdoptEquivalentLowRowPhysicalHeight' '    bool ForceBottomRowHeightNow' $adopt 'never promote a higher physical floor'

$force = @'
    bool ForceBottomRowHeightNow(int targetHeight, const QString &reason,
                                 bool latch)
    {
        if (targetHeight <= 0 || lowRowForceActive_)
            return false;

        if (lowRowFloorLatchActive_ &&
            lowRowFloorLatchHeight_ > 0 &&
            qAbs(lowRowFloorLatchHeight_ - targetHeight) > 2)
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

            if (QWidget *content = dock->widget())
                ApplyLowRowWidgetCap(content, targetHeight);

            dock->updateGeometry();
            rowDocks.push_back(dock);
            heights.push_back(targetHeight);
        }

        if (QListWidget *list = ScenesList()) {
            list->setMinimumHeight(0);
            if (QWidget *viewport = list->viewport())
                viewport->setMinimumHeight(0);
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

        const int actual = sceneDock->height();
        const bool reached = qAbs(actual - targetHeight) <= 3;

        if (latch) {
            lowRowFloorLatchActive_ = true;
            lowRowFloorLatchHeight_ = targetHeight;
            ++lowRowFloorLatchGeneration_;
        } else {
            ReleaseLowRowDockMaximumsOnly();
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
            "LOW ROW ROOT FORCE reason='%1' target=%2 actual=%3 reached=%4 rows=%5")
                       .arg(reason)
                       .arg(targetHeight)
                       .arg(actual)
                       .arg(reached ? 1 : 0)
                       .arg(CountFullyVisibleSceneRows()));
        return reached;
    }

'@
Replace-Block '    bool ForceBottomRowHeightNow' '    void ReassertSceneRowLock()' $force 'persistent exact root-only low-row force'

$prepare = @'
    void PrepareForRealApplyButton()
    {
        QDockWidget *sceneDock = ScenesDock();
        if (!sceneDock || !sceneDock->isVisible())
            return;

        const int floor =
            (sceneRowLockEnabled_ && lockedSceneDockHeight_ > 0)
                ? qMax(1, lockedSceneDockHeight_)
                : 1;
        const int pitch = qMax(1, CurrentSceneRowHeight());

        const bool exactLowRowState =
            sceneRowLockEnabled_ && sceneVisibleRows_ <= 2 &&
            (lowRowFloorLatchActive_ ||
             (savedManualSceneDockHeight_ > 0 &&
              savedManualSceneDockHeight_ <= floor + 3 &&
              sceneDock->height() <= floor + pitch));

        lowRowScaleSyncPending_ = exactLowRowState;
        lastRealApplyManualSerial_ = manualResizeSerial_;

        if (lowRowScaleSyncPending_) {
            if (lowRowFloorLatchActive_)
                ReleaseLowRowFloorLatch();

            ++realApplySmoothGuardGeneration_;
            realApplySmoothGuardActive_ = false;
            realApplySmoothExpectedHeight_ = -1;
            lastRealApplySmoothExcursions_ = 0;

            DebugWrite(QStringLiteral(
                "LOW ROW SCALE-SYNC ARMED live=%1 oldFloor=%2 pitch=%3")
                           .arg(sceneDock->height())
                           .arg(floor)
                           .arg(pitch));
            return;
        }

        const int exactLive = qMax(floor, sceneDock->height());
        savedManualSceneDockHeight_ = exactLive;
        lastImmediateManualSceneDockHeight_ = exactLive;
        if (settings_) {
            settings_->setValue(QStringLiteral("ui/manualSceneDockHeight"),
                                exactLive);
            settings_->sync();
        }

        realApplySmoothExpectedHeight_ = exactLive;
        lastRealApplySmoothExcursions_ = 0;
        realApplySmoothGuardActive_ = true;
        const int generation = ++realApplySmoothGuardGeneration_;

        DebugWrite(QStringLiteral(
            "REAL APPLY SMOOTH GUARD ARMED expected=%1 live=%2")
                       .arg(exactLive)
                       .arg(sceneDock->height()));

        QTimer::singleShot(3600, this, [this, generation]() {
            if (generation != realApplySmoothGuardGeneration_)
                return;
            QDockWidget *dock = ScenesDock();
            DebugWrite(QStringLiteral(
                "REAL APPLY SMOOTH GUARD COMPLETE expected=%1 live=%2 excursions=%3")
                           .arg(realApplySmoothExpectedHeight_)
                           .arg(dock ? dock->height() : -1)
                           .arg(lastRealApplySmoothExcursions_));
            realApplySmoothGuardActive_ = false;
            realApplySmoothExpectedHeight_ = -1;
        });
    }

'@
Replace-Block '    void PrepareForRealApplyButton()' '    void ApplyScale(double requestedUiPercent' $prepare 'live-authoritative Apply target'

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
        if (mainWindow->dockWidgetArea(sceneDock) !=
            Qt::BottomDockWidgetArea)
            return;

        const int floorHeight =
            (sceneRowLockEnabled_ && lockedSceneDockHeight_ > 0)
                ? qMax(1, lockedSceneDockHeight_)
                : 1;

        int targetHeight = -1;
        if (sceneDockGuardActive_ && sceneGuardTargetHeight_ > 0)
            targetHeight = qMax(floorHeight, sceneGuardTargetHeight_);
        else if (savedManualSceneDockHeight_ > 0)
            targetHeight = qMax(floorHeight, savedManualSceneDockHeight_);

        if (targetHeight <= 0)
            return;
        if (qAbs(sceneDock->height() - targetHeight) <= 2)
            return;

        restoringDockTargets_ = true;
        mainWindow->resizeDocks({sceneDock}, {targetHeight}, Qt::Vertical);
        restoringDockTargets_ = false;

        if (qAbs(sceneDock->height() - targetHeight) <= 2)
            CaptureStableDockTargets();

        DebugWrite(QStringLiteral(
            "SCENE TARGET REPAIRED target=%1 live=%2 saved=%3")
                       .arg(targetHeight)
                       .arg(sceneDock->height())
                       .arg(savedManualSceneDockHeight_));
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
                    qMax(floorHeight, savedManualSceneDockHeight_);

            if (sceneGuardTargetHeight_ > 0 &&
                manualResizeSerial_ > lastSceneGuardManualSerial_) {
                savedManualSceneDockHeight_ = sceneGuardTargetHeight_;
                lastImmediateManualSceneDockHeight_ =
                    sceneGuardTargetHeight_;
                if (settings_) {
                    settings_->setValue(
                        QStringLiteral("ui/manualSceneDockHeight"),
                        savedManualSceneDockHeight_);
                }
            }
            lastSceneGuardManualSerial_ = manualResizeSerial_;
        }

        ++manualDockCaptureGeneration_;
        sceneDockGuardActive_ = true;
        const int generation = ++sceneDockGuardGeneration_;

        RestoreAuthoritativeSceneDockTarget();

        const int delays[] = {90, 260};
        for (int delay : delays) {
            QTimer::singleShot(delay, this, [this, generation]() {
                if (generation != sceneDockGuardGeneration_ ||
                    !sceneDockGuardActive_)
                    return;
                RestoreAuthoritativeSceneDockTarget();
            });
        }

        QTimer::singleShot(420, this, [this, generation]() {
            if (generation != sceneDockGuardGeneration_)
                return;
            RestoreAuthoritativeSceneDockTarget();
            sceneDockGuardActive_ = false;
            sceneGuardTargetHeight_ = -1;
        });
    }

'@
Replace-Block '    void RestoreAuthoritativeSceneDockTarget()' '    bool IsManualBottomRowResizeGesture() const' $sceneGuard 'lightweight scene guard'

if (-not $s.Contains('#include <QMouseEvent>')) {
    if ($s.Contains('#include <QMainWindow>'))
        $s = $s.Replace('#include <QMainWindow>', '#include <QMainWindow>' + $lf + '#include <QMouseEvent>')
    else
        throw 'v3.35 QMouseEvent include insertion point missing'
}

Replace-Required @'
        obs_frontend_add_event_callback(&ObsUiScaleController::FrontendEvent, this);
'@ @'
        obs_frontend_add_event_callback(&ObsUiScaleController::FrontendEvent, this);
        if (qApp)
            qApp->installEventFilter(this);
'@ 'install global splitter-press event filter'

Replace-Required @'
        obs_frontend_remove_event_callback(&ObsUiScaleController::FrontendEvent, this);
'@ @'
        if (qApp)
            qApp->removeEventFilter(this);
        obs_frontend_remove_event_callback(&ObsUiScaleController::FrontendEvent, this);
'@ 'remove global splitter-press event filter'

$eventMarker = @'
    bool eventFilter(QObject *watched, QEvent *event) override
    {
'@
Replace-Required $eventMarker @'
    bool eventFilter(QObject *watched, QEvent *event) override
    {
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

'@ 'event-driven exact-row max release before splitter drag'

Replace-Required @'
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
'@ @'
                        if (sceneRowLockEnabled_ && sceneVisibleRows_ <= 2) {
                            if (shrinking) {
                                RelaxLowRowDescendantsForManualDrag();
                            } else if (lowRowFloorLatchActive_ &&
                                       manualHeight > floorHeight + pitch) {
                                ReleaseLowRowFloorLatch();
                            }
                        }
                        Q_UNUSED(shrinking);
'@ 'manual drag uses relaxation without premature exact latch'

$s = $s.Replace('OBS UI Scale v3.34 DEBUG', 'OBS UI Scale v3.35 DEBUG')
$s = $s.Replace('OBS UI Scale v3.34 DEBUG LOG', 'OBS UI Scale v3.35 DEBUG LOG')
$s = $s.Replace('v3.34 DEBUG', 'v3.35 DEBUG')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.34.0', '3.35.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.34.0',
                    'OBS-UI-Scale-Debug-Setup-3.35.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.35 DEBUG live Apply target + root-only exact row + icon protection.'

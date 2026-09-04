$ErrorActionPreference = 'Stop'

# v3.6 fixes the scene-row floor being one visible row too tall at some scales.
# v3.5 used QListWidget::sizeHintForRow(), which can disagree with the actual
# on-screen item pitch after OBS UI scaling. At 78% the debug trace reported a
# 22px row hint while the 208px minimum visibly fit 8 rows even though the user
# selected 7.
#
# Measure the REAL laid-out QListWidget item rectangles instead, and calculate
# the dock floor from the viewport span occupied by exactly N rows. The formula
# uses the live dock/viewport chrome, so it adapts to OBS window width/height and
# scrollbar/layout changes instead of relying on hard-coded pixels.
#
# Recalculate the floor during dock Resize/Layout events without collapsing a
# manually taller dock. Also migrate a saved manual height that exactly matches
# v3.5's legacy incorrect floor so existing 7-row users do not stay stuck at the
# old 8-row height after upgrading.
& ./build-v3.5-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.6 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

function Replace-Block([string]$startMarker, [string]$endMarker, [string]$newBlock, [string]$label) {
    $start = $script:s.IndexOf($startMarker)
    if ($start -lt 0) { throw "v3.6 could not locate start of $label" }
    $end = $script:s.IndexOf($endMarker, $start)
    if ($end -lt 0) { throw "v3.6 could not locate end of $label" }
    $script:s = $script:s.Substring(0, $start) + $newBlock.Replace("`r`n", "`n") + $script:s.Substring($end)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.5.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.6.0-debug";' 'plugin version'

# Replace the old sizeHint-based row measurement with live visual geometry.
# Keep a legacy calculator only for one-time migration of v3.5 saved heights.
$rowGeometryBlock = @'
    int LegacySceneRowHeight() const
    {
        QListWidget *scenes = ScenesList();
        if (!scenes)
            return 0;

        for (int row = 0; row < scenes->count(); ++row) {
            const int h = scenes->sizeHintForRow(row);
            if (h > 0)
                return h;
        }

        return qMax(1, scenes->fontMetrics().height() + 4);
    }

    int CurrentSceneRowHeight() const
    {
        QListWidget *scenes = ScenesList();
        if (!scenes)
            return 0;

        // visualItemRect() reflects the ACTUAL laid-out/scaled geometry, unlike
        // sizeHintForRow() which can remain larger than the painted row pitch.
        int previousTop = 0;
        int fallbackHeight = 0;
        bool havePrevious = false;
        const int inspectCount = qMin(scenes->count(), 16);
        for (int row = 0; row < inspectCount; ++row) {
            QListWidgetItem *item = scenes->item(row);
            if (!item || item->isHidden())
                continue;

            const QRect rect = scenes->visualItemRect(item);
            if (!rect.isValid() || rect.height() <= 0)
                continue;

            fallbackHeight = qMax(fallbackHeight, rect.height());
            if (havePrevious) {
                const int pitch = qAbs(rect.top() - previousTop);
                if (pitch > 0)
                    return pitch;
            }

            previousTop = rect.top();
            havePrevious = true;
        }

        if (fallbackHeight > 0)
            return fallbackHeight;

        return LegacySceneRowHeight();
    }

    int LegacySceneDockHeightForRows() const
    {
        QDockWidget *dock = ScenesDock();
        QListWidget *scenes = ScenesList();
        if (!dock || !scenes || sceneVisibleRows_ <= 0)
            return 0;

        const int rowHeight = LegacySceneRowHeight();
        if (rowHeight <= 0)
            return 0;

        const int outsideList = qMax(0, dock->height() - scenes->height());
        const int listChrome = scenes->viewport() ? qMax(0, scenes->height() - scenes->viewport()->height()) : 0;
        int target = outsideList + listChrome + rowHeight * sceneVisibleRows_;
        target = qMax(target, dock->minimumSizeHint().height());
        return qMax(1, target);
    }

    int CalculateSceneDockHeightForRows() const
    {
        QDockWidget *dock = ScenesDock();
        QListWidget *scenes = ScenesList();
        QWidget *viewport = scenes ? scenes->viewport() : nullptr;
        if (!dock || !scenes || !viewport || sceneVisibleRows_ <= 0)
            return 0;

        int targetViewportHeight = 0;

        // If enough real scene items exist, use the exact visual span occupied
        // by N laid-out rows. The subtraction cancels any current scroll offset.
        QListWidgetItem *firstItem = nullptr;
        QListWidgetItem *lastItem = nullptr;
        int visibleOrdinal = 0;
        for (int row = 0; row < scenes->count(); ++row) {
            QListWidgetItem *item = scenes->item(row);
            if (!item || item->isHidden())
                continue;

            if (!firstItem)
                firstItem = item;
            ++visibleOrdinal;
            if (visibleOrdinal == sceneVisibleRows_) {
                lastItem = item;
                break;
            }
        }

        if (firstItem && lastItem) {
            const QRect firstRect = scenes->visualItemRect(firstItem);
            const QRect lastRect = scenes->visualItemRect(lastItem);
            if (firstRect.isValid() && lastRect.isValid() &&
                firstRect.height() > 0 && lastRect.height() > 0) {
                targetViewportHeight = lastRect.bottom() - firstRect.top() + 1;
            }
        }

        // When the collection currently has fewer than N scenes, extrapolate
        // from the live visual pitch so the minimum is still correct when more
        // scenes are later added.
        if (targetViewportHeight <= 0) {
            const int pitch = CurrentSceneRowHeight();
            if (pitch <= 0)
                return 0;
            targetViewportHeight = pitch * sceneVisibleRows_;
        }

        // Everything outside the scrolling viewport is real live chrome: dock
        // title, toolbar, frame, margins and (when present) a horizontal scroll
        // bar. Because this is measured from the current OBS layout, the same N
        // rows remain correct at narrow, wide, short and tall window sizes.
        const int outsideViewport = qMax(0, dock->height() - viewport->height());
        int target = outsideViewport + targetViewportHeight;
        target = qMax(target, dock->minimumSizeHint().height());
        return qMax(1, target);
    }

    void MaybeMigrateLegacySceneFloor(int newFloor)
    {
        if (newFloor <= 0 || savedManualSceneDockHeight_ <= 0)
            return;

        const int legacyFloor = LegacySceneDockHeightForRows();
        if (legacyFloor <= 0 || qAbs(legacyFloor - newFloor) <= 1)
            return;

        // v3.5 could save its incorrect row floor as the "manual" restart
        // target. If the saved value is exactly that old floor, move it to the
        // corrected floor. A genuinely taller user position remains untouched.
        if (qAbs(savedManualSceneDockHeight_ - legacyFloor) <= 2) {
            const int oldSaved = savedManualSceneDockHeight_;
            savedManualSceneDockHeight_ = newFloor;
            if (settings_) {
                settings_->setValue(QStringLiteral("ui/manualSceneDockHeight"),
                                    savedManualSceneDockHeight_);
                settings_->sync();
            }

            if (applyPreservedSceneDockHeight_ > 0 &&
                qAbs(applyPreservedSceneDockHeight_ - oldSaved) <= 2)
                applyPreservedSceneDockHeight_ = newFloor;

            DebugWrite(QStringLiteral("LEGACY SCENE ROW FLOOR MIGRATED old=%1 new=%2")
                           .arg(oldSaved)
                           .arg(newFloor));
        }
    }

'@
Replace-Block '    int CurrentSceneRowHeight() const' '    void ReleaseSceneRowLockConstraints()' $rowGeometryBlock 'scene row geometry helpers'

# Keep the floor live when OBS itself is resized. This updates ONLY the minimum;
# a manually taller row is not pulled down. Mixer minimum changes by the same
# delta so its containment logic remains aligned with the scene-row floor.
$reassert = @'
    void ReassertSceneRowLock()
    {
        if (!sceneRowLockEnabled_ || lockedSceneDockHeight_ <= 0 || lockedMixerHeight_ <= 0 ||
            sceneRowLockApplying_)
            return;

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        QStackedWidget *mixer = StackedMixerArea();
        if (!mainWindow || !sceneDock || !mixer)
            return;

        const int refreshedFloor = CalculateSceneDockHeightForRows();
        if (refreshedFloor > 0 && qAbs(refreshedFloor - lockedSceneDockHeight_) > 1) {
            const int delta = refreshedFloor - lockedSceneDockHeight_;
            lockedSceneDockHeight_ = refreshedFloor;
            lockedMixerHeight_ = qMax(1, lockedMixerHeight_ + delta);
            mixerMinHeightTarget_ = lockedMixerHeight_;
            DebugWrite(QStringLiteral("SCENE ROW MINIMUM REFRESH rows=%1 pitch=%2 sceneDockMinH=%3 mixerMinH=%4")
                           .arg(sceneVisibleRows_)
                           .arg(CurrentSceneRowHeight())
                           .arg(lockedSceneDockHeight_)
                           .arg(lockedMixerHeight_));
        }

        sceneRowLockApplying_ = true;

        // The selected row count remains a minimum only. During Apply, however,
        // temporarily cap the whole current bottom row at the user's preserved
        // position so there is no one-frame/timed expansion before restoration.
        // The ceiling is removed at the end of Apply, so manual upward dragging
        // remains unrestricted during normal use.
        const int applyCeiling = (suppressManualDockCapture_ && applyPreservedSceneDockHeight_ > 0)
                                     ? qMax(lockedSceneDockHeight_, applyPreservedSceneDockHeight_)
                                     : QWIDGETSIZE_MAX;
        if (applyCeiling != QWIDGETSIZE_MAX)
            SetApplyBottomRowCeiling(applyCeiling);
        sceneDock->setMaximumHeight(applyCeiling);
        sceneDock->setMinimumHeight(lockedSceneDockHeight_);

        // stackedMixerArea must never be taller than the space represented by
        // the current dock row. If the row is manually enlarged, this ceiling
        // enlarges by the same amount, so upward dragging stays unrestricted.
        const int extraRowHeight = qMax(0, sceneDock->height() - lockedSceneDockHeight_);
        const int expectedMixerHeight = qMax(1, lockedMixerHeight_ + extraRowHeight);
        mixer->setMinimumHeight(lockedMixerHeight_);
        mixer->setMaximumHeight(expectedMixerHeight);

        if (mixer->height() > expectedMixerHeight)
            mixer->resize(mixer->width(), expectedMixerHeight);

        // Only intervene if something actually tries to shrink below the chosen
        // minimum. Never pull a manually enlarged dock back down.
        if (sceneDock->height() < lockedSceneDockHeight_)
            mainWindow->resizeDocks({sceneDock}, {lockedSceneDockHeight_}, Qt::Vertical);

        if (mixer->parentWidget() && mixer->parentWidget()->layout()) {
            mixer->parentWidget()->layout()->invalidate();
            mixer->parentWidget()->layout()->activate();
        }
        mixer->updateGeometry();

        sceneRowLockApplying_ = false;
    }

'@
Replace-Block '    void ReassertSceneRowLock()' '    void CaptureAndApplySceneRowLock()' $reassert 'dynamic ReassertSceneRowLock'

# Migrate the stale v3.5 floor before CaptureAndApply uses the preserved startup
# height, then identify the debug number as the real visual pitch.
Replace-Required @'
        const int targetDockHeight = CalculateSceneDockHeightForRows();
        if (currentDockHeight <= 0 || currentMixerHeight <= 0 || targetDockHeight <= 0)
            return;

        const int delta = targetDockHeight - currentDockHeight;
'@ @'
        const int targetDockHeight = CalculateSceneDockHeightForRows();
        if (currentDockHeight <= 0 || currentMixerHeight <= 0 || targetDockHeight <= 0)
            return;

        MaybeMigrateLegacySceneFloor(targetDockHeight);

        const int delta = targetDockHeight - currentDockHeight;
'@ 'migrate old incorrect saved floor during capture'

$s = $s.Replace('SCENE ROW MINIMUM rows=%1 rowH=%2 sceneDockMinH=%3 mixerMinH=%4',
                'SCENE ROW MINIMUM rows=%1 visualPitch=%2 sceneDockMinH=%3 mixerMinH=%4')

$s = $s.Replace('OBS UI Scale v3.5 DEBUG', 'OBS UI Scale v3.6 DEBUG')
$s = $s.Replace('OBS UI Scale v3.5 DEBUG LOG', 'OBS UI Scale v3.6 DEBUG LOG')
$s = $s.Replace('v3.5 DEBUG waits for OBS to restore the real Bottom dock layout before startup Apply, preventing placeholder startup geometry from corrupting the scene-row minimum while preserving the saved manual dock height. Debug logging remains optional.',
                'v3.6 DEBUG keeps the v3.5 startup/restart fixes and measures actual laid-out scene-row geometry, so the selected minimum is the exact visible row count and stays correct as the OBS window is resized. Debug logging remains optional.')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.5.0', '3.6.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.5.0', 'OBS-UI-Scale-Debug-Setup-3.6.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.6 DEBUG exact dynamic scene-row minimum.'

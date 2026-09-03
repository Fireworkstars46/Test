$ErrorActionPreference = 'Stop'

# Start from v1.3, not v1.5. v1.5's hard maximumHeight constraint can starve
# custom dock contents (as seen with Win Capture Audio Health) and can lock the
# wrong height because it derives the target from the old 100% baseline.
#
# v1.6 instead remembers the ACTUAL compact dock-row height after the scale has
# settled, then temporarily guards that exact height while OBS is switching
# scenes. No permanent maximumHeight is applied and no whole-widget-tree rescan
# is done on scene clicks.
& ./build-v1.3.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v1.6 patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "1.3.0";' 'static constexpr const char *PLUGIN_VERSION = "1.6.0";' 'plugin version'

Replace-Required @'
static constexpr const char *PROP_LAYOUT_SPACING = "obsUiScaleLayoutSpacing";
'@ @'
static constexpr const char *PROP_LAYOUT_SPACING = "obsUiScaleLayoutSpacing";
static constexpr const char *PROP_DOCK_STABLE_H = "obsUiScaleStableDockHeight";
static constexpr const char *PROP_DOCK_GUARD_WATCHED = "obsUiScaleDockGuardWatched";
'@ 'stable dock properties'

if (-not $s.Contains('#include <QEvent>')) {
    Replace-Required '#include <QDoubleSpinBox>' "#include <QDoubleSpinBox>`n#include <QEvent>" 'QEvent include'
}

# Insert the stable-row helper and a very small resize watcher. The watcher is
# armed only briefly after a scene change, so the user can still manually resize
# the dock row normally at all other times.
$insertMarker = '    void ScaleLateCreatedWidgetsAndDock(double uiPercent)'
$insertPos = $s.IndexOf($insertMarker)
if ($insertPos -lt 0) { throw 'v1.6 could not locate late-widget helper insertion point' }

$helper = @'
    void ClearStableDockTargets()
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        if (!mainWindow)
            return;

        const auto docks = mainWindow->findChildren<QDockWidget *>(QString(), Qt::FindDirectChildrenOnly);
        for (QDockWidget *dock : docks) {
            if (!dock)
                continue;
            dock->setProperty(PROP_DOCK_STABLE_H, QVariant());
        }

        sceneDockGuardActive_ = false;
        ++sceneDockGuardGeneration_;
    }

    void CaptureStableDockTargets()
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        if (!mainWindow)
            return;

        if (!proportionalMode_ || currentUiPercent_ >= 99.999) {
            ClearStableDockTargets();
            return;
        }

        const auto docks = mainWindow->findChildren<QDockWidget *>(QString(), Qt::FindDirectChildrenOnly);
        for (QDockWidget *dock : docks) {
            if (!dock || !dock->isVisible() || dock->isFloating())
                continue;

            const Qt::DockWidgetArea area = mainWindow->dockWidgetArea(dock);
            if (area != Qt::BottomDockWidgetArea && area != Qt::TopDockWidgetArea)
                continue;

            // This is intentionally the current post-scale height, not
            // ScaledLength(baseHeight). It preserves exactly the compact row the
            // user sees immediately after pressing Apply.
            const int stableHeight = dock->height();
            if (stableHeight > 0)
                dock->setProperty(PROP_DOCK_STABLE_H, stableHeight);

            if (!dock->property(PROP_DOCK_GUARD_WATCHED).toBool()) {
                dock->installEventFilter(this);
                dock->setProperty(PROP_DOCK_GUARD_WATCHED, true);
            }
        }
    }

    void RestoreStableDockTargets()
    {
        if (restoringDockTargets_ || !proportionalMode_ || currentUiPercent_ >= 99.999)
            return;

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        if (!mainWindow)
            return;

        QList<QDockWidget *> docksToResize;
        QList<int> targetHeights;
        const auto docks = mainWindow->findChildren<QDockWidget *>(QString(), Qt::FindDirectChildrenOnly);
        for (QDockWidget *dock : docks) {
            if (!dock || !dock->isVisible() || dock->isFloating() ||
                !dock->property(PROP_DOCK_STABLE_H).isValid())
                continue;

            const Qt::DockWidgetArea area = mainWindow->dockWidgetArea(dock);
            if (area != Qt::BottomDockWidgetArea && area != Qt::TopDockWidgetArea)
                continue;

            const int stableHeight = dock->property(PROP_DOCK_STABLE_H).toInt();
            if (stableHeight <= 0)
                continue;

            docksToResize.push_back(dock);
            targetHeights.push_back(stableHeight);
        }

        if (docksToResize.isEmpty())
            return;

        restoringDockTargets_ = true;
        mainWindow->resizeDocks(docksToResize, targetHeights, Qt::Vertical);
        restoringDockTargets_ = false;
    }

    void ArmSceneDockGuard()
    {
        if (!proportionalMode_ || currentUiPercent_ >= 99.999)
            return;

        sceneDockGuardActive_ = true;
        const int generation = ++sceneDockGuardGeneration_;

        // Restore once immediately and again at several quiet points. The resize
        // watcher below catches an OBS relayout that lands between these points.
        RestoreStableDockTargets();
        const int delays[] = {50, 150, 350, 700, 1100};
        for (int delay : delays) {
            QTimer::singleShot(delay, this, [this, generation]() {
                if (generation == sceneDockGuardGeneration_ && sceneDockGuardActive_)
                    RestoreStableDockTargets();
            });
        }

        QTimer::singleShot(1400, this, [this, generation]() {
            if (generation == sceneDockGuardGeneration_)
                sceneDockGuardActive_ = false;
        });
    }

    bool eventFilter(QObject *watched, QEvent *event) override
    {
        if (event && sceneDockGuardActive_ && !restoringDockTargets_ &&
            event->type() == QEvent::Resize) {
            auto *dock = qobject_cast<QDockWidget *>(watched);
            if (dock && dock->property(PROP_DOCK_STABLE_H).isValid()) {
                const int stableHeight = dock->property(PROP_DOCK_STABLE_H).toInt();
                if (stableHeight > 0 && qAbs(dock->height() - stableHeight) > 1 && !dockRestoreQueued_) {
                    dockRestoreQueued_ = true;
                    QTimer::singleShot(0, this, [this]() {
                        dockRestoreQueued_ = false;
                        RestoreStableDockTargets();
                    });
                }
            }
        }

        return QObject::eventFilter(watched, event);
    }

'@
$s = $s.Substring(0, $insertPos) + $helper + $s.Substring($insertPos)

# v1.3 rescans/scales the whole widget tree on each scene change. That can touch
# custom docks and the Source Dock Hide counter. Replace it with the short-lived
# exact-height guard captured after Apply.
Replace-Required @'
            // Scene changes can create fresh Audio Mixer/source widgets with
            // their stock (100%) explicit minimum sizes. Scale those new widgets
            // before reasserting the proportional dock geometry.
            const double ui = self->currentUiPercent_;
            self->ScheduleLateSceneWidgetScale(ui);
'@ @'
            // Preserve the exact compact dock-row height captured after Apply.
            // Do not rescan/repaint the whole OBS widget tree on a scene click.
            self->ArmSceneDockGuard();
'@ 'scene change exact dock-row guard'

# Capture the actual settled dock-row height after each explicit/startup scale.
Replace-Required @'
        QTimer::singleShot(24, this, [this, uiPercent]() {
            RefreshWidgets();
            ApplyProportionalDockGeometry(uiPercent);
        });

'@ @'
        QTimer::singleShot(24, this, [this, uiPercent]() {
            RefreshWidgets();
            ApplyProportionalDockGeometry(uiPercent);
        });
        QTimer::singleShot(120, this, [this, uiPercent]() {
            if (qAbs(currentUiPercent_ - uiPercent) < 0.01)
                CaptureStableDockTargets();
        });

'@ 'capture settled compact dock row after apply'

# Applying a new scale invalidates any old scene guard before the new row target
# is captured.
Replace-Required @'
        currentUiPercent_ = uiPercent;
        currentTextPercent_ = textPercent;

        FitSourceDockHideCounter(uiPercent);
'@ @'
        sceneDockGuardActive_ = false;
        ++sceneDockGuardGeneration_;
        currentUiPercent_ = uiPercent;
        currentTextPercent_ = textPercent;

        FitSourceDockHideCounter(uiPercent);
'@ 'invalidate old guard on scale apply'

# 100% must stop the temporary guard and discard scaled targets.
Replace-Required @'
        currentUiPercent_ = 100.0;
        currentTextPercent_ = 100.0;

        FitSourceDockHideCounter(100.0);
'@ @'
        currentUiPercent_ = 100.0;
        currentTextPercent_ = 100.0;
        ClearStableDockTargets();

        FitSourceDockHideCounter(100.0);
'@ 'clear stable row target at 100 percent'

Replace-Required 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v1.3"));' 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v1.6"));' 'dialog title'

Replace-Required @'
    bool proportionalMode_ = true;
    bool startupApplyDone_ = false;
'@ @'
    bool proportionalMode_ = true;
    bool startupApplyDone_ = false;
    bool restoringDockTargets_ = false;
    bool dockRestoreQueued_ = false;
    bool sceneDockGuardActive_ = false;
    int sceneDockGuardGeneration_ = 0;
'@ 'stable dock guard members'

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('1.3.0', '1.6.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v1.6 captured compact dock-row guard (no hard max-height caps).'

$ErrorActionPreference = 'Stop'

# Start from v1.9, but remove its permanent maximum-height lock. The user's latest
# test shows that permanent cap blocks manual dock dragging and can clip dock
# contents. v2.0 keeps the exact post-Apply row height only as a target.
#
# On a scene change we temporarily cap the stock Scenes dock just long enough for
# OBS's scene relayout to finish, then immediately release the cap again. Outside
# that short guard window, manual dock resizing is fully available and becomes the
# new saved target automatically.
& ./build-v1.9.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v2.0 patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "1.9.0";' 'static constexpr const char *PLUGIN_VERSION = "2.0.0";' 'plugin version'

# Replace v1.9's permanent row-anchor implementation with a transient guard.
$helperStart = $s.IndexOf('    QDockWidget *DockRowAnchor() const')
$helperEnd = $s.IndexOf('    bool IsInsideContextContainer(QWidget *widget) const', $helperStart)
if ($helperStart -lt 0 -or $helperEnd -lt 0) { throw 'v2.0 could not locate v1.9 dock-row helper block' }

$newHelper = @'
    QDockWidget *DockRowAnchor() const
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        if (!mainWindow)
            return nullptr;

        auto *anchor = mainWindow->findChild<QDockWidget *>(QStringLiteral("scenesDock"),
                                                            Qt::FindChildrenRecursively);
        if (!anchor || !anchor->isVisible() || anchor->isFloating()) {
            anchor = mainWindow->findChild<QDockWidget *>(QStringLiteral("sourcesDock"),
                                                          Qt::FindChildrenRecursively);
        }
        return anchor;
    }

    void ReleaseDockRowAnchor()
    {
        ++dockRowGuardGeneration_;
        dockRowGuardActive_ = false;
        if (QDockWidget *anchor = DockRowAnchor()) {
            anchor->setMaximumHeight(QWIDGETSIZE_MAX);
            anchor->updateGeometry();
        }
        dockRowAnchorHeight_ = -1;
    }

    void CaptureDockRowTarget(double uiPercent)
    {
        if (!proportionalMode_ || uiPercent >= 99.999) {
            ReleaseDockRowAnchor();
            return;
        }

        QDockWidget *anchor = DockRowAnchor();
        if (!anchor)
            return;

        // Never leave a permanent cap behind. We only remember the exact height
        // that Apply/manual dragging produced.
        anchor->setMaximumHeight(QWIDGETSIZE_MAX);
        const int h = anchor->height();
        if (h > 0)
            dockRowAnchorHeight_ = h;
    }

    void ScheduleDockRowAnchor(double uiPercent)
    {
        // Capture the real settled height after Apply, but do not constrain it.
        QTimer::singleShot(90, this, [this, uiPercent]() {
            if (qAbs(currentUiPercent_ - uiPercent) < 0.01)
                CaptureDockRowTarget(uiPercent);
        });
        QTimer::singleShot(240, this, [this, uiPercent]() {
            if (qAbs(currentUiPercent_ - uiPercent) < 0.01)
                CaptureDockRowTarget(uiPercent);
        });
    }

    void RestoreDockRowTargetOnce()
    {
        if (dockRowAnchorHeight_ <= 0)
            return;

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *anchor = DockRowAnchor();
        if (!mainWindow || !anchor)
            return;

        anchor->setMaximumHeight(dockRowAnchorHeight_);
        mainWindow->resizeDocks(QList<QDockWidget *>{anchor},
                                QList<int>{dockRowAnchorHeight_}, Qt::Vertical);
        anchor->updateGeometry();
    }

    void ArmDockRowGuard()
    {
        if (!proportionalMode_ || currentUiPercent_ >= 99.999 || dockRowAnchorHeight_ <= 0)
            return;

        dockRowGuardActive_ = true;
        const int generation = ++dockRowGuardGeneration_;

        // Cap immediately, before OBS's queued scene relayout, then reinforce at
        // a few quiet points. The cap is always removed after the relayout.
        RestoreDockRowTargetOnce();
        const int delays[] = {0, 40, 100, 220, 420, 700};
        for (int delay : delays) {
            QTimer::singleShot(delay, this, [this, generation]() {
                if (generation == dockRowGuardGeneration_ && dockRowGuardActive_)
                    RestoreDockRowTargetOnce();
            });
        }

        QTimer::singleShot(850, this, [this, generation]() {
            if (generation != dockRowGuardGeneration_)
                return;
            dockRowGuardActive_ = false;
            if (QDockWidget *anchor = DockRowAnchor()) {
                anchor->setMaximumHeight(QWIDGETSIZE_MAX);
                anchor->updateGeometry();
            }
        });
    }

'@
$s = $s.Substring(0, $helperStart) + $newHelper + $s.Substring($helperEnd)

# Scene changes: keep the targeted context scaling from v1.8 and additionally
# protect the user's exact dock-row height only during OBS's relayout window.
Replace-Required @'
            self->ScheduleContextBarRescale(self->currentUiPercent_);
'@ @'
            self->ScheduleContextBarRescale(self->currentUiPercent_);
            self->ArmDockRowGuard();
'@ 'arm transient row guard on scene change'

# Track manual dock dragging. A resize outside the short scene-change guard is a
# user/layout choice, so remember it as the next target instead of fighting it.
Replace-Required @'
    bool eventFilter(QObject *watched, QEvent *event) override
    {
        if (event && (event->type() == QEvent::Polish || event->type() == QEvent::Show)) {
'@ @'
    bool eventFilter(QObject *watched, QEvent *event) override
    {
        if (event && event->type() == QEvent::Resize && !dockRowGuardActive_ &&
            proportionalMode_ && currentUiPercent_ < 99.999) {
            if (auto *dock = qobject_cast<QDockWidget *>(watched)) {
                if (dock == DockRowAnchor() && dock->isVisible() && !dock->isFloating()) {
                    const int h = dock->height();
                    if (h > 0)
                        dockRowAnchorHeight_ = h;
                }
            }
        }

        if (event && (event->type() == QEvent::Polish || event->type() == QEvent::Show)) {
'@ 'remember manual dock-row resizing'

Replace-Required 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v1.9"));' 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v2.0"));' 'dialog title'
Replace-Required @'
            QStringLiteral("v1.9 keeps the applied dock row at the exact height produced by Apply. "
                           "Scene changes can no longer make the bottom OBS docks jump upward, while custom dock contents remain unconstrained."),
'@ @'
            QStringLiteral("v2.0 preserves the applied/manual dock-row height during scene changes without permanently locking it. "
                           "The temporary guard releases automatically, so the dock separator remains draggable and custom dock contents are not permanently clipped."),
'@ 'dialog intro'

Replace-Required @'
    int dockRowAnchorHeight_ = -1;
'@ @'
    int dockRowAnchorHeight_ = -1;
    bool dockRowGuardActive_ = false;
    int dockRowGuardGeneration_ = 0;
'@ 'transient guard members'

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('1.9.0', '2.0.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v2.0 transient scene dock-row guard + manual resize tracking.'

$ErrorActionPreference = 'Stop'

# Start from v2.0, but remove all height caps/resizeDocks guarding. The user's
# latest video shows the separator still returns to OBS's taller layout and the
# temporary max-height method can still interfere with dragging/content.
#
# v2.1 instead treats QMainWindow's own dock layout state as the source of truth:
# after Apply (or after the user manually drags a dock separator) we snapshot
# QMainWindow::saveState(). On a scene change, while OBS rebuilds its scene UI,
# we restore that exact state a few times. No dock gets a min/max height lock, so
# manual dragging stays fully native and custom docks are never clipped.
& ./build-v2.0.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v2.1 patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "2.0.0";' 'static constexpr const char *PLUGIN_VERSION = "2.1.0";' 'plugin version'

# Replace v2.0's transient height-cap helper with exact QMainWindow dock-state
# snapshot/restore. This keeps splitter positions, row heights and custom-dock
# placement together instead of trying to infer one row height from one dock.
$helperStart = $s.IndexOf('    QDockWidget *DockRowAnchor() const')
$helperEnd = $s.IndexOf('    bool IsInsideContextContainer(QWidget *widget) const', $helperStart)
if ($helperStart -lt 0 -or $helperEnd -lt 0) { throw 'v2.1 could not locate v2.0 dock helper block' }

$newHelper = @'
    QMainWindow *ObsMainWindow() const
    {
        return static_cast<QMainWindow *>(obs_frontend_get_main_window());
    }

    void CancelDockLayoutGuard(bool clearSavedState = false)
    {
        dockLayoutGuardActive_ = false;
        ++dockLayoutGuardGeneration_;
        dockLayoutRestoreQueued_ = false;
        if (clearSavedState)
            dockLayoutState_.clear();
    }

    void CaptureDockLayoutState()
    {
        if (!proportionalMode_ || currentUiPercent_ >= 99.999 || dockLayoutGuardActive_)
            return;

        QMainWindow *mainWindow = ObsMainWindow();
        if (!mainWindow)
            return;

        const QByteArray state = mainWindow->saveState();
        if (!state.isEmpty())
            dockLayoutState_ = state;
    }

    void ScheduleDockLayoutCapture(int delay = 180)
    {
        const int generation = ++dockLayoutCaptureGeneration_;
        QTimer::singleShot(delay, this, [this, generation]() {
            if (generation != dockLayoutCaptureGeneration_ || dockLayoutGuardActive_)
                return;
            CaptureDockLayoutState();
        });
    }

    void RestoreDockLayoutStateOnce()
    {
        if (dockLayoutState_.isEmpty())
            return;

        QMainWindow *mainWindow = ObsMainWindow();
        if (!mainWindow)
            return;

        restoringDockLayoutState_ = true;
        mainWindow->restoreState(dockLayoutState_);
        if (QLayout *layout = mainWindow->layout()) {
            layout->invalidate();
            layout->activate();
        }
        mainWindow->updateGeometry();
        restoringDockLayoutState_ = false;
    }

    void BeginSceneDockLayoutGuard()
    {
        if (!proportionalMode_ || currentUiPercent_ >= 99.999 || dockLayoutState_.isEmpty())
            return;

        dockLayoutGuardActive_ = true;
        const int generation = ++dockLayoutGuardGeneration_;
        ++dockLayoutCaptureGeneration_; // ignore resize events caused by this scene

        // Restore immediately and after OBS's queued scene/source refreshes. This
        // uses Qt's own saved splitter/dock state, so there is no permanent cap
        // and no guessed pixel height. The user can drag again as soon as this
        // short scene update finishes.
        RestoreDockLayoutStateOnce();
        const int delays[] = {0, 25, 70, 150, 280, 480};
        for (int delay : delays) {
            QTimer::singleShot(delay, this, [this, generation]() {
                if (generation == dockLayoutGuardGeneration_ && dockLayoutGuardActive_)
                    RestoreDockLayoutStateOnce();
            });
        }

        QTimer::singleShot(620, this, [this, generation]() {
            if (generation != dockLayoutGuardGeneration_)
                return;
            RestoreDockLayoutStateOnce();
            dockLayoutGuardActive_ = false;
            // Keep the same state as the target; do NOT recapture the temporary
            // bad geometry OBS tried to apply during the scene switch.
        });
    }

    void ScheduleDockRowAnchor(double uiPercent)
    {
        Q_UNUSED(uiPercent);
        // ApplyScale finishes with queued style/layout work. Capture only after
        // those passes settle, then again once more to get the exact visible
        // post-Apply layout the user wants to preserve.
        const int generation = ++dockLayoutCaptureGeneration_;
        QTimer::singleShot(220, this, [this, generation]() {
            if (generation == dockLayoutCaptureGeneration_ && !dockLayoutGuardActive_)
                CaptureDockLayoutState();
        });
        QTimer::singleShot(500, this, [this, generation]() {
            if (generation == dockLayoutCaptureGeneration_ && !dockLayoutGuardActive_)
                CaptureDockLayoutState();
        });
    }

    void ReleaseDockRowAnchor()
    {
        // Compatibility name retained for ApplyScale/Restore100 call sites from
        // earlier builds. There is no physical dock constraint in v2.1.
        CancelDockLayoutGuard(true);
    }

'@
$s = $s.Substring(0, $helperStart) + $newHelper + $s.Substring($helperEnd)

# Scene changes now restore the complete dock state rather than applying a
# maximumHeight/resizeDocks guard.
Replace-Required @'
            self->ScheduleContextBarRescale(self->currentUiPercent_);
            self->ArmDockRowGuard();
'@ @'
            self->ScheduleContextBarRescale(self->currentUiPercent_);
            self->BeginSceneDockLayoutGuard();
'@ 'restore exact dock state on scene change'

# Replace v2.0's anchor-only resize tracking. Any dock resize/move/show/hide that
# happens outside a scene restore is treated as a real user layout change and is
# debounced into a new saveState snapshot. This is what makes manual dragging
# actually "save" for the next scene click.
Replace-Required @'
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

'@ @'
        if (event && !dockLayoutGuardActive_ && !restoringDockLayoutState_ &&
            proportionalMode_ && currentUiPercent_ < 99.999) {
            const QEvent::Type type = event->type();
            if (type == QEvent::Resize || type == QEvent::Move ||
                type == QEvent::Show || type == QEvent::Hide) {
                if (qobject_cast<QDockWidget *>(watched))
                    ScheduleDockLayoutCapture(220);
            }
        }

'@ 'save manual dock layout changes'

Replace-Required 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v2.0"));' 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v2.1"));' 'dialog title'
Replace-Required @'
            QStringLiteral("v2.0 preserves the applied/manual dock-row height during scene changes without permanently locking it. "
                           "The temporary guard releases automatically, so the dock separator remains draggable and custom dock contents are not permanently clipped."),
'@ @'
            QStringLiteral("v2.1 preserves the exact Qt dock layout produced by Apply or manual dragging. "
                           "Scene changes restore that saved splitter/dock state without min/max-height locks, so the separator stays draggable and custom docks stay unclipped."),
'@ 'dialog intro'

Replace-Required @'
    int dockRowAnchorHeight_ = -1;
    bool dockRowGuardActive_ = false;
    int dockRowGuardGeneration_ = 0;
'@ @'
    QByteArray dockLayoutState_;
    bool dockLayoutGuardActive_ = false;
    bool restoringDockLayoutState_ = false;
    bool dockLayoutRestoreQueued_ = false;
    int dockLayoutGuardGeneration_ = 0;
    int dockLayoutCaptureGeneration_ = 0;
'@ 'dock layout state members'

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('2.0.0', '2.1.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v2.1 exact QMainWindow dock-state preservation.'

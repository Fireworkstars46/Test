$ErrorActionPreference = 'Stop'

# v3.8 fixes the remaining minimum-scene-row blocker shown by the v3.7 trace.
# v3.7 calculates the 7-row Scenes floor correctly (about 199px at 78%), but
# the Audio Mixer child is captured during Apply at an artificially tall minimum
# (198px). That makes mixerDock report a ~241px minimum and Qt expands the whole
# tabbed bottom row to ~265px, so dragging toward the 7-row floor cannot move.
#
# The fix keeps every v3.7 startup/Apply/manual-position behavior, but after the
# Apply ceiling is fully released and the dock row has been quiet, it calibrates
# the Audio Mixer minimum against the REAL settled row excess. Example from the
# failing trace: row=265, scene floor=199, mixer min=198 -> corrected mixer min
# 132. This is the same scale-aware relationship that the older compact builds
# used, but learned only from settled geometry so temporary Apply geometry cannot
# poison it. Only OBS's Audio Mixer stack/dock are touched; custom sibling docks
# such as Win Capture Audio Health and Percent Mixer remain unrestricted.
& ./build-v3.7-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.8 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

function Replace-Block([string]$startMarker, [string]$endMarker, [string]$newBlock, [string]$label) {
    $start = $script:s.IndexOf($startMarker)
    if ($start -lt 0) { throw "v3.8 could not locate start of $label" }
    $end = $script:s.IndexOf($endMarker, $start)
    if ($end -lt 0) { throw "v3.8 could not locate end of $label" }
    $script:s = $script:s.Substring(0, $start) + $newBlock.Replace("`r`n", "`n") + $script:s.Substring($end)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.7.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.8.0-debug";' 'plugin version'

# Add a direct helper for the real OBS Audio Mixer dock, then a quiet calibration
# pass. The calibration is intentionally one-way: it may LOWER a bad mixer floor
# that is blocking the configured scene-row floor, but it never raises it based
# on a manually taller dock.
$insertMarker = '    void ScheduleSceneRowMinimumRefresh()'
$insertPos = $s.IndexOf($insertMarker)
if ($insertPos -lt 0) { throw 'v3.8 could not locate scene-row refresh insertion point' }
$helper = @'
    QDockWidget *AudioMixerDock() const
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        return mainWindow ? mainWindow->findChild<QDockWidget *>(QStringLiteral("mixerDock"),
                                                                  Qt::FindChildrenRecursively)
                          : nullptr;
    }

    void CalibrateMixerFloorToSceneMinimum()
    {
        if (!sceneRowLockEnabled_ || lockedSceneDockHeight_ <= 0 || lockedMixerHeight_ <= 0 ||
            sceneRowLockApplying_ || suppressManualDockCapture_ || restoringDockTargets_ ||
            applyPreservedSceneDockHeight_ > 0)
            return;

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        QStackedWidget *mixer = StackedMixerArea();
        QDockWidget *mixerDock = AudioMixerDock();
        if (!mainWindow || !sceneDock || !mixer || sceneDock->isFloating())
            return;
        if (mainWindow->dockWidgetArea(sceneDock) != Qt::BottomDockWidgetArea ||
            !sceneDock->isVisible() || sceneDock->height() <= 30)
            return;

        const int rowHeight = sceneDock->height();
        const int sceneFloor = lockedSceneDockHeight_;
        const int rowExcess = rowHeight - sceneFloor;
        const int currentMixerMin = mixer->minimumHeight();

        // Nothing is blocking the floor if the row is already at it. More
        // importantly, never reinterpret a deliberately taller manual row as a
        // reason to lower the Audio Mixer. This routine is scheduled only after
        // Apply-owned movement, where a positive excess is the exact failure
        // mode seen in the user's trace.
        if (rowExcess <= 1 || currentMixerMin <= 1)
            return;

        const int correctedMixerMin = qMax(1, currentMixerMin - rowExcess);
        if (correctedMixerMin >= lockedMixerHeight_)
            return;

        const int oldLockedMixer = lockedMixerHeight_;
        const int oldMixerDockMin = mixerDock ? mixerDock->minimumHeight() : -1;

        sceneRowLockApplying_ = true;

        // mixerDock can inherit an explicit minimum from the mixer child. Clear
        // only its vertical explicit floor while the scene-row feature is active;
        // the Scenes dock remains the authoritative row minimum.
        if (mixerDock)
            mixerDock->setMinimumHeight(0);

        lockedMixerHeight_ = correctedMixerMin;
        mixerMinHeightTarget_ = correctedMixerMin;
        mixer->setMinimumHeight(correctedMixerMin);
        mixer->updateGeometry();
        if (mixer->parentWidget() && mixer->parentWidget()->layout()) {
            mixer->parentWidget()->layout()->invalidate();
            mixer->parentWidget()->layout()->activate();
        }
        if (mixerDock && mixerDock->layout()) {
            mixerDock->layout()->invalidate();
            mixerDock->layout()->activate();
            mixerDock->updateGeometry();
        }

        sceneRowLockApplying_ = false;

        // Preserve a genuine manually taller position while removing the hidden
        // mixer blocker underneath it. If there is no saved manual target, use
        // the configured scene-row floor itself.
        int desiredHeight = sceneFloor;
        if (savedManualSceneDockHeight_ > 0)
            desiredHeight = qMax(sceneFloor, savedManualSceneDockHeight_);

        restoringDockTargets_ = true;
        mainWindow->resizeDocks({sceneDock}, {desiredHeight}, Qt::Vertical);
        restoringDockTargets_ = false;
        ReassertSceneRowLock();
        CaptureStableDockTargets();

        DebugWrite(QStringLiteral("MIXER ROW FLOOR CALIBRATED rowH=%1 sceneFloor=%2 excess=%3 oldMixerMin=%4 newMixerMin=%5 oldMixerDockMin=%6 desiredH=%7 actualH=%8")
                       .arg(rowHeight)
                       .arg(sceneFloor)
                       .arg(rowExcess)
                       .arg(oldLockedMixer)
                       .arg(lockedMixerHeight_)
                       .arg(oldMixerDockMin)
                       .arg(desiredHeight)
                       .arg(sceneDock->height()));
    }

    void ScheduleMixerFloorCalibration()
    {
        const int generation = ++mixerFloorCalibrationGeneration_;
        QTimer::singleShot(350, this, [this, generation]() {
            if (generation != mixerFloorCalibrationGeneration_)
                return;
            CalibrateMixerFloorToSceneMinimum();
        });
    }

'@
$s = $s.Substring(0, $insertPos) + $helper + $s.Substring($insertPos)

# Reassert must also keep the Audio Mixer dock itself from retaining a stale
# explicit vertical minimum after its child minimum has been corrected. Do not
# touch any other bottom-row dock.
$reassert = @'
    void ReassertSceneRowLock()
    {
        if (!sceneRowLockEnabled_ || lockedSceneDockHeight_ <= 0 || lockedMixerHeight_ <= 0 ||
            sceneRowLockApplying_)
            return;

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        QStackedWidget *mixer = StackedMixerArea();
        QDockWidget *mixerDock = AudioMixerDock();
        if (!mainWindow || !sceneDock || !mixer)
            return;

        sceneRowLockApplying_ = true;

        // Scenes is the row floor. OBS's Audio Mixer must not impose a larger
        // hidden sibling minimum, especially when it is tabified with another
        // dock such as Percent Mixer.
        if (mixerDock)
            mixerDock->setMinimumHeight(0);

        const int applyCeiling = (suppressManualDockCapture_ && applyPreservedSceneDockHeight_ > 0)
                                     ? qMax(lockedSceneDockHeight_, applyPreservedSceneDockHeight_)
                                     : QWIDGETSIZE_MAX;
        if (applyCeiling != QWIDGETSIZE_MAX)
            SetApplyBottomRowCeiling(applyCeiling);
        sceneDock->setMaximumHeight(applyCeiling);
        sceneDock->setMinimumHeight(lockedSceneDockHeight_);

        const int extraRowHeight = qMax(0, sceneDock->height() - lockedSceneDockHeight_);
        const int expectedMixerHeight = qMax(1, lockedMixerHeight_ + extraRowHeight);
        mixer->setMinimumHeight(lockedMixerHeight_);
        mixer->setMaximumHeight(expectedMixerHeight);

        if (mixer->height() > expectedMixerHeight)
            mixer->resize(mixer->width(), expectedMixerHeight);

        if (sceneDock->height() < lockedSceneDockHeight_)
            mainWindow->resizeDocks({sceneDock}, {lockedSceneDockHeight_}, Qt::Vertical);

        if (mixer->parentWidget() && mixer->parentWidget()->layout()) {
            mixer->parentWidget()->layout()->invalidate();
            mixer->parentWidget()->layout()->activate();
        }
        if (mixerDock && mixerDock->layout()) {
            mixerDock->layout()->invalidate();
            mixerDock->layout()->activate();
            mixerDock->updateGeometry();
        }
        mixer->updateGeometry();

        sceneRowLockApplying_ = false;
    }

'@
Replace-Block '    void ReassertSceneRowLock()' '    void CaptureAndApplySceneRowLock()' $reassert 'ReassertSceneRowLock mixer sibling fix'

# During each row-floor capture, clear only the Audio Mixer dock's explicit
# vertical minimum before Qt is asked to honor the Scenes floor. The existing
# calculation remains as the provisional mixer value until the late settled
# calibration replaces it with the correct value.
Replace-Required @'
        sceneDock->setMaximumHeight(QWIDGETSIZE_MAX);
        sceneDock->setMinimumHeight(0);
        mixer->setMaximumHeight(QWIDGETSIZE_MAX);
        mixer->setMinimumHeight(0);
        sceneRowLockApplying_ = false;
'@ @'
        sceneDock->setMaximumHeight(QWIDGETSIZE_MAX);
        sceneDock->setMinimumHeight(0);
        mixer->setMaximumHeight(QWIDGETSIZE_MAX);
        mixer->setMinimumHeight(0);
        if (QDockWidget *mixerDock = AudioMixerDock())
            mixerDock->setMinimumHeight(0);
        sceneRowLockApplying_ = false;
'@ 'clear Audio Mixer dock floor during row capture'

# The v3.2 Apply window keeps manual capture suppressed for 400ms after its
# ceiling is released. Start the calibration only once that quiet period ends;
# by then the exact v3.7 failure has settled (214 -> 265 in about 140ms).
Replace-Required @'
            QTimer::singleShot(400, this, [this, manualSuppressGeneration]() {
                if (manualSuppressGeneration == manualDockSuppressGeneration_)
                    suppressManualDockCapture_ = false;
            });
'@ @'
            QTimer::singleShot(400, this, [this, manualSuppressGeneration]() {
                if (manualSuppressGeneration == manualDockSuppressGeneration_) {
                    suppressManualDockCapture_ = false;
                    ScheduleMixerFloorCalibration();
                }
            });
'@ 'calibrate mixer after Apply quiet period'

# One generation counter prevents overlapping Apply passes from calibrating stale
# geometry from an older run.
Replace-Required @'
    int sceneRowRefreshGeneration_ = 0;
'@ @'
    int sceneRowRefreshGeneration_ = 0;
    int mixerFloorCalibrationGeneration_ = 0;
'@ 'mixer floor calibration generation member'

$s = $s.Replace('OBS UI Scale v3.7 DEBUG', 'OBS UI Scale v3.8 DEBUG')
$s = $s.Replace('OBS UI Scale v3.7 DEBUG LOG', 'OBS UI Scale v3.8 DEBUG LOG')
$s = $s.Replace('v3.7 DEBUG keeps the v3.6 visual row measurement but refreshes the row minimum only after dock/window layout has settled, preventing Apply-time geometry from inflating the minimum while still adapting to OBS window-size changes. Debug logging remains optional.',
                'v3.8 DEBUG keeps the v3.7 settled row measurement and fixes the Audio Mixer/tabbed-dock minimum that could still force the whole bottom row above the selected scene-row floor. Debug logging remains optional.')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.7.0', '3.8.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.7.0', 'OBS-UI-Scale-Debug-Setup-3.8.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.8 DEBUG Audio Mixer sibling row-floor calibration.'

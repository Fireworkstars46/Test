$ErrorActionPreference = 'Stop'

# v2.9 changes v2.8's exact-height scene-row lock into a true minimum.
# The selected row count (default 6) is the smallest allowed Scenes dock size,
# but the user can still drag the dock taller. The minimum is scale-aware and
# configurable from 1 to 1000 rows. Existing v2.7 scene-change preservation and
# mixer-minimum repair remain active so a manually taller dock is preserved.
& ./build-v2.8-fixed.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Block([string]$startMarker, [string]$endMarker, [string]$newBlock, [string]$label) {
    $start = $script:s.IndexOf($startMarker)
    if ($start -lt 0) { throw "v2.9 could not locate start of $label" }
    $end = $script:s.IndexOf($endMarker, $start)
    if ($end -lt 0) { throw "v2.9 could not locate end of $label" }
    $script:s = $script:s.Substring(0, $start) + $newBlock.Replace("`r`n", "`n") + $script:s.Substring($end)
}

$s = $s.Replace('static constexpr const char *PLUGIN_VERSION = "2.8.0-debug";',
                'static constexpr const char *PLUGIN_VERSION = "2.9.0-debug";')
$s = $s.Replace('qBound(1, sceneVisibleRows_, 30)', 'qBound(1, sceneVisibleRows_, 1000)')
$s = $s.Replace('sceneRowsSpin->setRange(1, 30);', 'sceneRowsSpin->setRange(1, 1000);')

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

        sceneRowLockApplying_ = true;

        // This is a MINIMUM only. OBS may not raise the mixer minimum above the
        // scaled row-count target, but the user remains free to drag the whole
        // dock row taller than the minimum.
        mixer->setMaximumHeight(QWIDGETSIZE_MAX);
        mixer->setMinimumHeight(lockedMixerHeight_);
        sceneDock->setMaximumHeight(QWIDGETSIZE_MAX);
        sceneDock->setMinimumHeight(lockedSceneDockHeight_);

        // Only intervene if something actually tries to shrink below the chosen
        // minimum. Never pull a manually enlarged dock back down.
        if (sceneDock->height() < lockedSceneDockHeight_)
            mainWindow->resizeDocks({sceneDock}, {lockedSceneDockHeight_}, Qt::Vertical);

        sceneRowLockApplying_ = false;
    }

'@
Replace-Block '    void ReassertSceneRowLock()' '    void CaptureAndApplySceneRowLock()' $reassert 'ReassertSceneRowLock'

$capture = @'
    void CaptureAndApplySceneRowLock()
    {
        if (!sceneRowLockEnabled_) {
            ReleaseSceneRowLockConstraints();
            return;
        }

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        QStackedWidget *mixer = StackedMixerArea();
        if (!mainWindow || !sceneDock || !mixer)
            return;

        // Calculate the selected minimum from the current scaled row metrics,
        // without inheriting an older pixel constraint from another scale.
        sceneRowLockApplying_ = true;
        sceneDock->setMaximumHeight(QWIDGETSIZE_MAX);
        sceneDock->setMinimumHeight(0);
        mixer->setMaximumHeight(QWIDGETSIZE_MAX);
        mixer->setMinimumHeight(0);
        sceneRowLockApplying_ = false;

        const int currentDockHeight = sceneDock->height();
        const int currentMixerHeight = mixer->height();
        const int targetDockHeight = CalculateSceneDockHeightForRows();
        if (currentDockHeight <= 0 || currentMixerHeight <= 0 || targetDockHeight <= 0)
            return;

        const int delta = targetDockHeight - currentDockHeight;
        lockedSceneDockHeight_ = targetDockHeight;
        lockedMixerHeight_ = qMax(1, currentMixerHeight + delta);

        // Keep v2.7's mixer repair aligned with this scale-aware minimum.
        mixerMinHeightTarget_ = lockedMixerHeight_;

        sceneDock->installEventFilter(this);
        mixer->installEventFilter(this);
        ReassertSceneRowLock();

        // Applying/changing the setting starts the dock at the selected minimum.
        // After this one-time resize, normal upward dragging remains unrestricted.
        mainWindow->resizeDocks({sceneDock}, {lockedSceneDockHeight_}, Qt::Vertical);
        ReassertSceneRowLock();

        DebugWrite(QStringLiteral("SCENE ROW MINIMUM rows=%1 rowH=%2 sceneDockMinH=%3 mixerMinH=%4")
                       .arg(sceneVisibleRows_)
                       .arg(CurrentSceneRowHeight())
                       .arg(lockedSceneDockHeight_)
                       .arg(lockedMixerHeight_));
    }

'@
Replace-Block '    void CaptureAndApplySceneRowLock()' '    void ScheduleSceneRowLockCapture(double uiPercent)' $capture 'CaptureAndApplySceneRowLock'

# UI wording: the number is the floor, not a fixed exact height.
$s = $s.Replace('Lock bottom dock height to scene rows', 'Set minimum visible scene rows')
$s = $s.Replace('Visible scene rows:', 'Minimum scene rows:')
$s = $s.Replace('Keeps the bottom dock boundary fixed and prevents scene changes from making it jump. ',
                'Prevents the bottom docks from being dragged below the selected number of scene rows. ')
$s = $s.Replace('The Scenes list shows exactly the selected number of full rows before scrolling.',
                'You can still drag the dock taller; this setting only controls the minimum.')
$s = $s.Replace('OBS UI Scale v2.8 DEBUG', 'OBS UI Scale v2.9 DEBUG')
$s = $s.Replace('OBS UI Scale v2.8 DEBUG LOG', 'OBS UI Scale v2.9 DEBUG LOG')
$s = $s.Replace('v2.8 DEBUG adds a persistent visible-scene-row lock (6 rows by default) so the bottom dock boundary cannot briefly jump during scene changes. Debug logging remains optional.',
                'v2.9 DEBUG uses an adjustable minimum scene-row count (6 by default). You can drag the dock taller, but not below that many rows. Debug logging remains optional.')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('2.8.0', '2.9.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-2.8.0', 'OBS-UI-Scale-Debug-Setup-2.9.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v2.9 DEBUG adjustable minimum scene rows with free upward dragging.'

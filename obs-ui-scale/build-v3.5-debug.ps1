$ErrorActionPreference = 'Stop'

# v3.5 fixes the startup-only geometry failure shown by the v3.4 trace. OBS can
# report the main window as visible before its dock layout has actually been
# restored. In that state scenesDock is still the 100x30 placeholder in the Left
# area and hidden; running the scale/scene-row calculation there makes the
# minimum grow from bogus geometry (167 -> 304 -> 441 in the trace).
#
# Wait for OBS to restore a real Bottom-area dock layout before automatic startup
# Apply. Once that layout is real, v3.4's saved manual height enters the normal
# Apply-preservation path instead of being skipped against placeholder geometry.
& ./build-v3.4-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.5 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.4.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.5.0-debug";' 'plugin version'

$frontendMarker = '    static void FrontendEvent(enum obs_frontend_event event, void *privateData)'
$frontendPos = $s.IndexOf($frontendMarker)
if ($frontendPos -lt 0) { throw 'v3.5 could not locate FrontendEvent insertion point' }
$startupHelper = @'
    bool StartupDockLayoutReady() const
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        if (!mainWindow || !sceneDock || !mainWindow->isVisible() || sceneDock->isFloating())
            return false;

        if (mainWindow->dockWidgetArea(sceneDock) != Qt::BottomDockWidgetArea)
            return false;

        // 100x30 is Qt's startup placeholder geometry from the failing trace.
        // A hidden Scenes dock is still considered ready if OBS has restored its
        // real Bottom-area geometry, so intentional dock hiding does not block
        // UI scaling.
        if (sceneDock->width() <= 100 && sceneDock->height() <= 30)
            return false;

        return true;
    }

    void TryStartupAutoApply(int generation, int attempt)
    {
        if (generation != startupAutoApplyGeneration_ || startupAutoApplyDone_ || !autoApply_)
            return;

        CaptureBaselineIfNeeded();
        EnsureEmergencyShortcut();

        if (StartupDockLayoutReady()) {
            startupAutoApplyDone_ = true;
            QDockWidget *sceneDock = ScenesDock();
            DebugWrite(QStringLiteral("STARTUP DOCK LAYOUT READY attempt=%1 visible=%2 area=Bottom size=%3x%4 savedManual=%5")
                           .arg(attempt)
                           .arg(sceneDock && sceneDock->isVisible() ? 1 : 0)
                           .arg(sceneDock ? sceneDock->width() : -1)
                           .arg(sceneDock ? sceneDock->height() : -1)
                           .arg(savedManualSceneDockHeight_));
            ApplyScale(uiPercent_, textPercent_);
            return;
        }

        if (attempt == 0 || attempt == 10 || attempt == 30 || attempt == 60)
            DebugWrite(QStringLiteral("STARTUP APPLY WAITING FOR REAL DOCK LAYOUT attempt=%1").arg(attempt));

        // Keep waiting rather than ever scaling the 100x30 placeholder. The
        // user's normal layout should become ready within a fraction of this.
        // After 15 seconds, stop the automatic attempt instead of risking the
        // corrupt scene-row calculation seen in v3.4; manual Apply remains
        // available for unusual intentionally dockless layouts.
        if (attempt >= 150) {
            startupAutoApplyDone_ = true;
            DebugWrite(QStringLiteral("STARTUP DOCK LAYOUT WAIT TIMEOUT - automatic Apply skipped"));
            return;
        }

        QTimer::singleShot(100, this, [this, generation, attempt]() {
            TryStartupAutoApply(generation, attempt + 1);
        });
    }

    void ScheduleStartupAutoApply()
    {
        const int generation = ++startupAutoApplyGeneration_;
        QTimer::singleShot(0, this, [this, generation]() {
            TryStartupAutoApply(generation, 0);
        });
    }

'@
$s = $s.Substring(0, $frontendPos) + $startupHelper + $s.Substring($frontendPos)

# Earlier builds changed the startup timer details, so patch only the actual
# constructor Apply call rather than depending on a specific delay value.
$ctorStart = $s.IndexOf('    ObsUiScaleController()')
$ctorEnd = $s.IndexOf('    ~ObsUiScaleController()', $ctorStart)
if ($ctorStart -lt 0 -or $ctorEnd -lt 0) { throw 'v3.5 could not locate constructor block' }
$ctorBlock = $s.Substring($ctorStart, $ctorEnd - $ctorStart)
$ctorApply = 'ApplyScale(uiPercent_, textPercent_);'
if (-not $ctorBlock.Contains($ctorApply)) { throw 'v3.5 constructor ApplyScale call not found' }
$ctorBlock = $ctorBlock.Replace($ctorApply, 'ScheduleStartupAutoApply();')
$s = $s.Substring(0, $ctorStart) + $ctorBlock + $s.Substring($ctorEnd)

# Also delay the FINISHED_LOADING automatic Apply. The generation counter makes
# the constructor and frontend-event startup attempts collapse into one.
$frontendStart = $s.IndexOf($frontendMarker)
$scaledMarker = '    static int ScaledLength(int value, double percent)'
$frontendEnd = $s.IndexOf($scaledMarker, $frontendStart)
if ($frontendStart -lt 0 -or $frontendEnd -lt 0) { throw 'v3.5 could not isolate FrontendEvent block' }
$frontendBlock = $s.Substring($frontendStart, $frontendEnd - $frontendStart)
$frontendApply = 'self->ApplyScale(self->uiPercent_, self->textPercent_);'
if (-not $frontendBlock.Contains($frontendApply)) { throw 'v3.5 finished-loading ApplyScale call not found' }
$frontendBlock = $frontendBlock.Replace($frontendApply, 'self->ScheduleStartupAutoApply();')
$s = $s.Substring(0, $frontendStart) + $frontendBlock + $s.Substring($frontendEnd)

Replace-Required @'
    int savedManualSceneDockHeight_ = -1;
'@ @'
    int savedManualSceneDockHeight_ = -1;
    int startupAutoApplyGeneration_ = 0;
    bool startupAutoApplyDone_ = false;
'@ 'startup wait members'

$s = $s.Replace('OBS UI Scale v3.4 DEBUG', 'OBS UI Scale v3.5 DEBUG')
$s = $s.Replace('OBS UI Scale v3.4 DEBUG LOG', 'OBS UI Scale v3.5 DEBUG LOG')
$s = $s.Replace('v3.4 DEBUG keeps the v3.2 stability fixes and makes the persisted manual bottom-dock height authoritative across repeated startup Apply passes, so restart restoration cannot be overwritten. Debug logging remains optional.',
                'v3.5 DEBUG waits for OBS to restore the real Bottom dock layout before startup Apply, preventing placeholder startup geometry from corrupting the scene-row minimum while preserving the saved manual dock height. Debug logging remains optional.')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.4.0', '3.5.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.4.0', 'OBS-UI-Scale-Debug-Setup-3.5.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.5 DEBUG startup dock-layout readiness fix.'

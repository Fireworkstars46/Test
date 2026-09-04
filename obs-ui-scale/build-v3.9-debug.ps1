$ErrorActionPreference = 'Stop'

# v3.9 keeps the working v3.8 scene-row/mixer fix and tightens manual dock
# persistence. The v3.8 trace showed a temporary OBS/window-layout expansion to
# 617px being mistaken for a user divider drag and briefly persisted. A real
# bottom-row resize is now learned only while the left mouse button is held and
# the pointer is actually on the horizontal separator at the top of the Scenes
# row. Main-window resizing, Apply/layout settling, tab changes, and other
# programmatic dock resizes can no longer overwrite the saved manual height.
& ./build-v3.8-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.9 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.8.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.9.0-debug";' 'plugin version'

if (-not $s.Contains('#include <QCursor>')) {
    $s = $s.Replace('#include <QCheckBox>', "#include <QCheckBox>`n#include <QCursor>")
}

# Determine whether a Scenes-row Resize event is actually coming from the user
# dragging QMainWindow's horizontal dock separator. Checking only for a mouse
# button is not enough because resizing the OBS window also holds the left button
# while docks resize. Require the pointer to be near the top boundary of the
# bottom dock row and away from the outer OBS window resize borders.
$insertMarker = '    bool eventFilter(QObject *watched, QEvent *event) override'
$insertPos = $s.IndexOf($insertMarker)
if ($insertPos -lt 0) { throw 'v3.9 could not locate eventFilter insertion point' }
$helper = @'
    bool IsManualBottomRowResizeGesture() const
    {
        if (!(QApplication::mouseButtons() & Qt::LeftButton))
            return false;

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        if (!mainWindow || !sceneDock || sceneDock->isFloating() || !sceneDock->isVisible())
            return false;

        const QPoint globalPos = QCursor::pos();
        const QPoint dockPos = sceneDock->mapFromGlobal(globalPos);
        const QPoint mainPos = mainWindow->mapFromGlobal(globalPos);

        // QMainWindow's horizontal dock separator sits on the top edge of the
        // bottom row. Allow a generous logical-pixel tolerance so this remains
        // reliable at different OBS/UI scales and Windows DPI settings.
        constexpr int separatorTolerance = 16;
        if (dockPos.y() < -separatorTolerance || dockPos.y() > separatorTolerance)
            return false;

        // Exclude the outer window resize frame. This prevents a side/corner
        // OBS-window resize from ever being learned as a manual dock position,
        // even if the pointer happens to line up with the dock separator Y.
        constexpr int windowEdgeGuard = 14;
        if (mainPos.x() <= windowEdgeGuard || mainPos.x() >= mainWindow->width() - windowEdgeGuard ||
            mainPos.y() <= windowEdgeGuard || mainPos.y() >= mainWindow->height() - windowEdgeGuard)
            return false;

        return true;
    }

'@
$s = $s.Substring(0, $insertPos) + $helper + $s.Substring($insertPos)

# Only the gesture-qualified Resize path is allowed to start the existing quiet
# 300ms manual-size capture. All later persistence logic remains unchanged.
Replace-Required @'
        if (event && event->type() == QEvent::Resize && !sceneDockGuardActive_ &&
            !restoringDockTargets_ && !suppressManualDockCapture_ &&
            proportionalMode_ && currentUiPercent_ < 99.999) {
'@ @'
        if (event && event->type() == QEvent::Resize && !sceneDockGuardActive_ &&
            !restoringDockTargets_ && !suppressManualDockCapture_ &&
            IsManualBottomRowResizeGesture() &&
            proportionalMode_ && currentUiPercent_ < 99.999) {
'@ 'require a real dock-separator drag before manual capture'

$s = $s.Replace('OBS UI Scale v3.8 DEBUG', 'OBS UI Scale v3.9 DEBUG')
$s = $s.Replace('OBS UI Scale v3.8 DEBUG LOG', 'OBS UI Scale v3.9 DEBUG LOG')
$s = $s.Replace('v3.8 DEBUG keeps the v3.7 settled row measurement and fixes the Audio Mixer/tabbed-dock minimum that could still force the whole bottom row above the selected scene-row floor. Debug logging remains optional.',
                'v3.9 DEBUG keeps the v3.8 scene-row/mixer fix and saves a manual dock height only from a real user drag of the bottom-row separator, so OBS/window layout changes cannot overwrite it. Debug logging remains optional.')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.8.0', '3.9.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.8.0', 'OBS-UI-Scale-Debug-Setup-3.9.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.9 DEBUG gesture-qualified manual dock persistence.'

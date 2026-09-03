$ErrorActionPreference = 'Stop'

# Start from v1.3 (the last normal build before diagnostics). The video shows OBS
# enlarging the entire bottom dock row a few hundred ms after a scene click. The
# previous retry-based fixes run too early and OBS's later QMainWindow relayout wins.
# v1.5 keeps the scaled dock height as a real maximum while proportional mode is
# active, so a later scene/source relayout cannot expand the row again.
& ./build-v1.3.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v1.5 patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "1.3.0";' 'static constexpr const char *PLUGIN_VERSION = "1.5.0";' 'plugin version'

Replace-Required @'
static constexpr const char *PROP_LAYOUT_SPACING = "obsUiScaleLayoutSpacing";
'@ @'
static constexpr const char *PROP_LAYOUT_SPACING = "obsUiScaleLayoutSpacing";
static constexpr const char *PROP_DOCK_ORIGINAL_MAX_H = "obsUiScaleOriginalDockMaxH";
static constexpr const char *PROP_DOCK_SCALE_CAP_H = "obsUiScaleDockScaleCapH";
'@ 'dock cap properties'

# Replace the v1.3 dock geometry method with one that persists the desired scaled
# row height as each top/bottom dock's maximumHeight. This prevents OBS from
# restoring a larger dock row after selection/scene UI work. The original max is
# saved and restored at 100% or when proportional mode is disabled.
$startMarker = '    void ApplyProportionalDockGeometry(double uiPercent)'
$endMarker = '    QFont ScaledFont(double textPercent) const'
$start = $s.IndexOf($startMarker)
$end = $s.IndexOf($endMarker, $start)
if ($start -lt 0 -or $end -lt 0) { throw 'v1.5 could not locate dock geometry method' }

$newDockMethod = @'
    void ReleaseProportionalDockHeightCaps()
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        if (!mainWindow)
            return;

        const auto docks = mainWindow->findChildren<QDockWidget *>(QString(), Qt::FindDirectChildrenOnly);
        for (QDockWidget *dock : docks) {
            if (!dock || !dock->property(PROP_DOCK_ORIGINAL_MAX_H).isValid())
                continue;
            dock->setMaximumHeight(dock->property(PROP_DOCK_ORIGINAL_MAX_H).toInt());
            dock->setProperty(PROP_DOCK_SCALE_CAP_H, QVariant());
            dock->updateGeometry();
        }
    }

    void ApplyProportionalDockGeometry(double uiPercent)
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        if (!mainWindow)
            return;

        if (!proportionalMode_) {
            ReleaseProportionalDockHeightCaps();
            return;
        }

        QList<QDockWidget *> verticalDocks;
        QList<int> verticalSizes;
        QList<QDockWidget *> horizontalDocks;
        QList<int> horizontalSizes;

        const auto docks = mainWindow->findChildren<QDockWidget *>(QString(), Qt::FindDirectChildrenOnly);
        for (QDockWidget *dock : docks) {
            if (!dock || !dock->isVisible() || dock->isFloating() || !dock->property(PROP_BASE_W).isValid())
                continue;

            const int baseW = dock->property(PROP_BASE_W).toInt();
            const int baseH = dock->property(PROP_BASE_H).toInt();
            const Qt::DockWidgetArea area = mainWindow->dockWidgetArea(dock);

            if (area == Qt::BottomDockWidgetArea || area == Qt::TopDockWidgetArea) {
                if (!dock->property(PROP_DOCK_ORIGINAL_MAX_H).isValid())
                    dock->setProperty(PROP_DOCK_ORIGINAL_MAX_H, dock->maximumHeight());

                const int targetH = qMax(dock->minimumHeight(), ScaledLength(baseH, uiPercent));

                if (uiPercent < 99.999) {
                    // This is the key v1.5 fix. resizeDocks() is only a request and
                    // OBS can override it later. A maximum height is a hard Qt
                    // layout constraint, so the row cannot jump back larger after
                    // clicking a scene/source. Keep the minimum sane if another
                    // widget temporarily raised it during the scene transition.
                    if (dock->minimumHeight() > targetH)
                        dock->setMinimumHeight(targetH);
                    dock->setMaximumHeight(targetH);
                    dock->setProperty(PROP_DOCK_SCALE_CAP_H, targetH);
                } else {
                    dock->setMaximumHeight(dock->property(PROP_DOCK_ORIGINAL_MAX_H).toInt());
                    dock->setProperty(PROP_DOCK_SCALE_CAP_H, QVariant());
                }

                verticalDocks.push_back(dock);
                verticalSizes.push_back(targetH);
            } else if (area == Qt::LeftDockWidgetArea || area == Qt::RightDockWidgetArea) {
                horizontalDocks.push_back(dock);
                horizontalSizes.push_back(qMax(dock->minimumWidth(), ScaledLength(baseW, uiPercent)));
            }
        }

        if (!verticalDocks.isEmpty())
            mainWindow->resizeDocks(verticalDocks, verticalSizes, Qt::Vertical);
        if (!horizontalDocks.isEmpty())
            mainWindow->resizeDocks(horizontalDocks, horizontalSizes, Qt::Horizontal);
    }

'@
$s = $s.Substring(0, $start) + $newDockMethod + $s.Substring($end)

# v1.3 rescanned and resized every widget twice after every scene change. Besides
# being unnecessary once the row is capped, that also touches Source Dock Hide's
# custom toolbar control and contributes to its flash. Keep scene-change handling
# geometry-only now; the persistent max-height constraint remains in force anyway.
Replace-Required @'
            // Scene changes can create fresh Audio Mixer/source widgets with
            // their stock (100%) explicit minimum sizes. Scale those new widgets
            // before reasserting the proportional dock geometry.
            const double ui = self->currentUiPercent_;
            self->ScheduleLateSceneWidgetScale(ui);
'@ @'
            // The dock row is now persistently constrained to the scaled height,
            // so do not walk/re-scale every QWidget on a scene click. Reasserting
            // geometry is enough and avoids flashing custom toolbar controls.
            const double ui = self->currentUiPercent_;
            self->ApplyProportionalDockGeometry(ui);
            QTimer::singleShot(120, self, [self, ui]() {
                if (qAbs(self->currentUiPercent_ - ui) < 0.01)
                    self->ApplyProportionalDockGeometry(ui);
            });
'@ 'scene change uses persistent dock cap only'

Replace-Required 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v1.3"));' 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v1.5"));' 'dialog title'

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('1.3.0', '1.5.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v1.5 persistent proportional dock-height lock.'

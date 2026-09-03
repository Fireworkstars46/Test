$ErrorActionPreference = 'Stop'

# Keep v1.6's compact dock-row guard, but stop UI Scale from being a second
# horizontal-size owner for Source Dock Hide's counter. The new recording shows
# the counter is full width while idle and gets squeezed when source-selection UI
# changes. Source Dock Hide v1.9 now owns that button width completely.
& ./build-v1.6.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v1.7 patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "1.6.0";' 'static constexpr const char *PLUGIN_VERSION = "1.7.0";' 'plugin version'

# Replace the old compatibility helper. It used to set minimum/maximum width on
# the Source Dock Hide button. That was useful for the original plain QToolButton,
# but it now fights the plugin's own full-text fixed-width button. UI Scale should
# only trigger a normal geometry pass and leave horizontal sizing untouched.
$fitStartMarker = '    void FitSourceDockHideCounter(double uiPercent)'
$fitEndMarker = '    void ScheduleLatePluginWidgetFixes(double uiPercent)'
$fitStart = $s.IndexOf($fitStartMarker)
$fitEnd = $s.IndexOf($fitEndMarker, $fitStart)
if ($fitStart -lt 0 -or $fitEnd -lt 0) { throw 'v1.7 could not locate Source Dock Hide compatibility helper' }

$newFit = @'
    void FitSourceDockHideCounter(double uiPercent)
    {
        Q_UNUSED(uiPercent);
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        if (!mainWindow)
            return;

        auto *button = mainWindow->findChild<QAbstractButton *>(QStringLiteral("sourceDockHiddenCountButton"),
                                                                 Qt::FindChildrenRecursively);
        if (!button)
            return;

        // Source Dock Hide owns horizontal min/max/fixed width. Do not write any
        // width constraint from UI Scale; font/style changes will make the custom
        // button recalculate its own width.
        button->updateGeometry();
        button->update();
    }

'@
$s = $s.Substring(0, $fitStart) + $newFit + $s.Substring($fitEnd)

# The dialog title had advanced through several builds while its intro paragraph
# still said v1.0. Keep the visible version/help text consistent with the build.
Replace-Required @'
            QStringLiteral("v1.0 keeps the smooth v0.9 scaling path and now also catches plugin controls that appear after startup. "
                           "The Source Dock Hide counter is fitted after scaling without doing expensive whole-OBS refresh loops."),
'@ @'
            QStringLiteral("v1.7 keeps the 78%-style proportional scaling and compact dock-row guard from v1.6. "
                           "Source Dock Hide now owns its counter width completely, so source selection cannot make UI Scale squeeze that button."),
'@ 'update dialog intro text'

Replace-Required 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v1.6"));' 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v1.7"));' 'dialog title'

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('1.6.0', '1.7.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v1.7 Source Dock Hide width-ownership cleanup.'

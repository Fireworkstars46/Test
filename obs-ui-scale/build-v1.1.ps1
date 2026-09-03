$ErrorActionPreference = 'Stop'

# Keep v1.0 behavior, but stop OBS UI Scale from constraining Source Dock Hide's
# counter width. Source Dock Hide owns that widget's horizontal sizing; UI Scale
# should only scale its height/font/theme and leave enough horizontal room.
& ./build-v1.0.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v1.1 patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "1.0.0";' 'static constexpr const char *PLUGIN_VERSION = "1.1.0";' 'plugin version'

# Never freeze the Source Dock Hide counter to a maximum width. The previous
# compatibility helper accidentally became the final width authority and could
# leave the text elided after the toolbar changed state.
Replace-Required @'
        const int padding = qMax(4, ScaledLength(12, uiPercent));
        const int wantedW = qMax(currentTextW, reserveTextW) + padding;

        button->setMinimumWidth(wantedW);
        button->setMaximumWidth(wantedW);
        button->updateGeometry();
'@ @'
        const int padding = qMax(16, ScaledLength(24, uiPercent));
        const int wantedW = qMax(currentTextW, reserveTextW) + padding;

        // Source Dock Hide owns horizontal sizing. Never cap it here; a max-width
        // can make QToolButton paint an elided label (for example "0...en").
        button->setMaximumWidth(QWIDGETSIZE_MAX);
        button->setMinimumWidth(wantedW);
        button->updateGeometry();
'@ 'remove source counter max-width cap'

# The general metric pass must not overwrite the counter's minimum width captured
# before/after plugin startup. Keep vertical scaling, but leave horizontal sizing
# entirely to Source Dock Hide + FitSourceDockHideCounter.
Replace-Required @'
        for (QWidget *widget : widgets) {
            if (!widget)
                continue;

            if (widget->property(PROP_MIN_W).isValid()) {
'@ @'
        for (QWidget *widget : widgets) {
            if (!widget)
                continue;

            const bool sourceDockCounter =
                widget->objectName() == QStringLiteral("sourceDockHiddenCountButton");

            if (widget->property(PROP_MIN_W).isValid()) {
'@ 'identify source counter in metric pass'

Replace-Required @'
                widget->setMinimumSize(targetW, targetH);
'@ @'
                if (sourceDockCounter)
                    widget->setMinimumHeight(targetH);
                else
                    widget->setMinimumSize(targetW, targetH);
'@ 'skip source counter horizontal baseline scaling'

Replace-Required 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v1.0"));' 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v1.1"));' 'dialog title'

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('1.0.0', '1.1.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v1.1 Source Dock Hide width-ownership fix.'

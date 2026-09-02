$ErrorActionPreference = 'Stop'

# Keep v1.0 behavior, then make the hidden counter keep enough minimum width
# even when OBS reveals extra source-toolbar buttons after a source is selected.
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

Replace-Required @'
        hiddenCountButton_->setText(QStringLiteral("%1 hidden").arg(hiddenCount));
        hiddenCountButton_->updateGeometry();
'@ @'
        hiddenCountButton_->setText(QStringLiteral("%1 hidden").arg(hiddenCount));

        // QToolBar can compress custom widgets when selection-specific source
        // controls appear. Keep a real minimum width based on the current font/text
        // so "0 hidden" / "1 hidden" never collapses to an ellipsis.
        const int textWidth = hiddenCountButton_->fontMetrics().horizontalAdvance(hiddenCountButton_->text());
        const int horizontalPadding = qMax(8, hiddenCountButton_->fontMetrics().horizontalAdvance(QStringLiteral("  ")));
        hiddenCountButton_->setMinimumWidth(textWidth + horizontalPadding);
        hiddenCountButton_->updateGeometry();
'@ 'persistent text-fit minimum width'

Set-Content $path $s -Encoding utf8

$issPath = 'installer/SourceDockHide.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('1.0.0', '1.1.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared Source Dock Hide v1.1 persistent hidden-counter width fix.'

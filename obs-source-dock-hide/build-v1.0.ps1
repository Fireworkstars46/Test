$ErrorActionPreference = 'Stop'

# Keep all v0.9 behavior, then make the bottom hidden-counter button cooperate
# with OBS/Qt scaling instead of forcing a hard-coded 72x28 minimum.
& ./build-v0.9.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v1.0 patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "0.9.0";' 'static constexpr const char *PLUGIN_VERSION = "1.0.0";' 'plugin version'
Replace-Required '#include <QSettings>' "#include <QSettings>`n#include <QSizePolicy>" 'QSizePolicy include'

Replace-Required @'
            hiddenCountButton_->setMinimumHeight(28);
            hiddenCountButton_->setMinimumWidth(72);
'@ @'
            // Let Qt calculate the correct size from the current OBS font/theme.
            // This keeps "0 hidden" readable when OBS UI Scale makes the interface
            // smaller or when text/UI are scaled independently.
            hiddenCountButton_->setSizePolicy(QSizePolicy::Minimum, QSizePolicy::Preferred);
            hiddenCountButton_->setMinimumSize(0, 0);
            hiddenCountButton_->setProperty("obsUiScaleCooperative", true);
'@ 'remove hard-coded hidden button size'

Replace-Required @'
        hiddenCountButton_->setText(QStringLiteral("%1 hidden").arg(hiddenCount));

        // QToolButton::click toggles its checked state itself; always make the
'@ @'
        hiddenCountButton_->setText(QStringLiteral("%1 hidden").arg(hiddenCount));
        hiddenCountButton_->updateGeometry();

        // QToolButton::click toggles its checked state itself; always make the
'@ 'refresh button geometry after text change'

Set-Content $path $s -Encoding utf8

$issPath = 'installer/SourceDockHide.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('0.9.0', '1.0.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared Source Dock Hide v1.0 scale-friendly hidden counter.'

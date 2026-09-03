$ErrorActionPreference = 'Stop'

# Keep v1.1 behavior, but make the hidden counter a truly fixed-width toolbar
# widget. QToolBar is allowed to squeeze QSizePolicy::Minimum widgets when other
# source controls appear; QSizePolicy::Fixed + setFixedWidth prevents the text
# from turning back into an ellipsis when a source is selected.
& ./build-v1.1.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v1.2 patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "1.1.0";' 'static constexpr const char *PLUGIN_VERSION = "1.2.0";' 'plugin version'

Replace-Required @'
            hiddenCountButton_->setSizePolicy(QSizePolicy::Minimum, QSizePolicy::Preferred);
'@ @'
            // Fixed horizontally: the toolbar must not compress this text button
            // when selection-specific source controls become visible.
            hiddenCountButton_->setSizePolicy(QSizePolicy::Fixed, QSizePolicy::Preferred);
'@ 'fixed horizontal size policy'

Replace-Required @'
        hiddenCountButton_->setMinimumWidth(textWidth + horizontalPadding);
        hiddenCountButton_->updateGeometry();
'@ @'
        hiddenCountButton_->setFixedWidth(textWidth + horizontalPadding);
        hiddenCountButton_->updateGeometry();
'@ 'fixed text-fit width'

Set-Content $path $s -Encoding utf8

$issPath = 'installer/SourceDockHide.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('1.1.0', '1.2.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared Source Dock Hide v1.2 fixed-width hidden counter.'

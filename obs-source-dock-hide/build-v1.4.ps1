$ErrorActionPreference = 'Stop'

# Keep v1.3 behavior, but replace the hidden counter's QToolButton with a flat
# QPushButton. QToolButton's style can elide toolbar text ("0...en") even when
# the widget itself has enough width; QPushButton renders the full label instead.
& ./build-v1.3.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v1.4 patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "1.3.0";' 'static constexpr const char *PLUGIN_VERSION = "1.4.0";' 'plugin version'

Replace-Required @'
            hiddenCountButton_ = new QToolButton(sourcesToolbar);
            hiddenCountButton_->setObjectName("sourceDockHiddenCountButton");
            hiddenCountButton_->setText("0 hidden");
            hiddenCountButton_->setToolButtonStyle(Qt::ToolButtonTextOnly);
            hiddenCountButton_->setAutoRaise(true);
'@ @'
            hiddenCountButton_ = new QPushButton(sourcesToolbar);
            hiddenCountButton_->setObjectName("sourceDockHiddenCountButton");
            hiddenCountButton_->setText("0 hidden");
            // A flat QPushButton visually fits the toolbar but, unlike QToolButton,
            // does not internally elide the text when OBS changes toolbar contents.
            hiddenCountButton_->setFlat(true);
'@ 'replace tool button with flat push button'

Replace-Required 'QObject::connect(hiddenCountButton_, &QToolButton::clicked, this, [this]() {' 'QObject::connect(hiddenCountButton_, &QPushButton::clicked, this, [this]() {' 'clicked signal type'
Replace-Required 'QPointer<QToolButton> hiddenCountButton_;' 'QPointer<QPushButton> hiddenCountButton_;' 'button pointer type'

Set-Content $path $s -Encoding utf8

$issPath = 'installer/SourceDockHide.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('1.3.0', '1.4.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared Source Dock Hide v1.4 non-eliding hidden counter.'

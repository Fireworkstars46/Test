$ErrorActionPreference = 'Stop'

# Keep v1.2 behavior, but stop freezing the counter at a stale pre-scale width.
# Recalculate from QToolButton's full style-aware sizeHint whenever font/style/size
# changes so OBS selection changes cannot turn "0 hidden" into an ellipsis.
& ./build-v1.2.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v1.3 patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "1.2.0";' 'static constexpr const char *PLUGIN_VERSION = "1.3.0";' 'plugin version'

Replace-Required @'
        hiddenCountButton_->setFixedWidth(textWidth + horizontalPadding);
        hiddenCountButton_->updateGeometry();
'@ @'
        // Do not lock the maximum width: OBS UI Scale may change the button font/theme
        // after this plugin creates the widget. QToolButton::sizeHint includes its
        // style margins, which raw fontMetrics alone did not account for.
        hiddenCountButton_->setMaximumWidth(QWIDGETSIZE_MAX);
        hiddenCountButton_->ensurePolished();
        const int naturalWidth = hiddenCountButton_->sizeHint().width();
        const int neededWidth = qMax(naturalWidth, textWidth + horizontalPadding);
        hiddenCountButton_->setMinimumWidth(neededWidth);
        hiddenCountButton_->updateGeometry();
'@ 'style-aware dynamic width'

Replace-Required @'
    bool eventFilter(QObject *watched, QEvent *event) override
    {
        if (event && event->type() == QEvent::Show) {
            if (auto *menu = qobject_cast<QMenu *>(watched))
                MaybeAddSourceContextAction(menu);
        }
        return QObject::eventFilter(watched, event);
    }
'@ @'
    bool eventFilter(QObject *watched, QEvent *event) override
    {
        if (event && hiddenCountButton_ && watched == hiddenCountButton_.data()) {
            const auto type = event->type();
            if (type == QEvent::FontChange || type == QEvent::StyleChange || type == QEvent::Resize) {
                // Recalculate after OBS/Qt finishes the current style/layout event.
                QTimer::singleShot(0, this, [this]() { UpdateHiddenCountButton(); });
            }
        }

        if (event && event->type() == QEvent::Show) {
            if (auto *menu = qobject_cast<QMenu *>(watched))
                MaybeAddSourceContextAction(menu);
        }
        return QObject::eventFilter(watched, event);
    }
'@ 'counter font/style/resize refresh'

Set-Content $path $s -Encoding utf8

$issPath = 'installer/SourceDockHide.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('1.2.0', '1.3.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared Source Dock Hide v1.3 dynamic style-aware hidden-counter width fix.'

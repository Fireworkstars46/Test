$ErrorActionPreference = 'Stop'

# Keep v1.5's native OBS-style full-text counter and all-source context menu,
# but stop redundant model/button updates that caused the hidden counter and
# Sources dock to flicker whenever OBS changed selection/model data.
& ./build-v1.5.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v1.6 patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "1.5.0";' 'static constexpr const char *PLUGIN_VERSION = "1.6.0";' 'plugin version'

Replace-Required @'
    void setDisplayText(const QString &text)
    {
        displayText_ = text;
        // Keep QToolButton's own label empty so its style cannot replace our
        // text with an ellipsis. The real QToolButton still paints the OBS
        // toolbar background, hover and checked states.
        QToolButton::setText(QString());
        label_->setText(text);
        label_->setFont(font());
        updateLabelGeometry();
        updateGeometry();
        update();
    }
'@ @'
    void setDisplayText(const QString &text)
    {
        // Model/data notifications can fire repeatedly for simple selection
        // changes. Do nothing when the visible label is already correct so the
        // native toolbar button does not repaint/flicker for no visual change.
        if (displayText_ == text && label_ && label_->text() == text)
            return;

        displayText_ = text;
        // Keep QToolButton's own label empty so its style cannot replace our
        // text with an ellipsis. The real QToolButton still paints the OBS
        // toolbar background, hover and checked states.
        QToolButton::setText(QString());
        label_->setText(text);
        label_->setFont(font());
        updateLabelGeometry();
        updateGeometry();
        update();
    }
'@ 'skip unchanged counter repaint'

Replace-Required @'
    void ApplyHiddenRows()
    {
        FindSourceTree();
        if (!sourceTree_ || !sourceTree_->model())
            return;
'@ @'
    void ApplyHiddenRows()
    {
        // FindSourceTree() also updates/repolishes the counter. Calling it for
        // every model notification caused two counter updates per click. Only
        // rediscover the Sources view when our cached view/model is unavailable.
        if (!sourceTree_ || !sourceTree_->model())
            FindSourceTree();
        if (!sourceTree_ || !sourceTree_->model())
            return;
'@ 'avoid duplicate counter refresh per apply'

Replace-Required @'
            const bool isMarkedHidden = !name.isEmpty() && hidden.contains(name);
            sourceTree_->setRowHidden(row, isMarkedHidden && !showHiddenRows_);
'@ @'
            const bool isMarkedHidden = !name.isEmpty() && hidden.contains(name);
            const bool shouldHide = isMarkedHidden && !showHiddenRows_;
            // setRowHidden triggers view geometry/repaint work even if callers
            // repeatedly ask for the same state. Skip unchanged rows so ordinary
            // source selection does not flash the dock/counter.
            if (sourceTree_->isRowHidden(row) != shouldHide)
                sourceTree_->setRowHidden(row, shouldHide);
'@ 'skip unchanged row-hidden work'

Replace-Required @'
        hiddenCountButton_->show();
'@ @'
        if (!hiddenCountButton_->isVisible())
            hiddenCountButton_->show();
'@ 'avoid redundant show repaint'

Set-Content $path $s -Encoding utf8

$issPath = 'installer/SourceDockHide.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('1.5.0', '1.6.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared Source Dock Hide v1.6 low-flicker update path.'

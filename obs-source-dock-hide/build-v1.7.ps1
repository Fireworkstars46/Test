$ErrorActionPreference = 'Stop'

# Keep v1.6's all-source hiding and native OBS-style counter, but remove the
# resize-event feedback loop that can make the hidden counter flash whenever the
# Sources/Scenes toolbars relayout. Also ignore model dataChanged notifications
# when source names did not actually change.
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

# v1.3 installed a Resize watcher that called UpdateHiddenCountButton() after
# every resize. Toolbar layout -> resize -> updateGeometry -> resize could form a
# visible feedback loop. FullTextToolButton already handles its own resize/font/
# style changes, so the controller no longer needs to watch the counter at all.
Replace-Required @'
        if (event && hiddenCountButton_ && watched == hiddenCountButton_.data()) {
            const auto type = event->type();
            if (type == QEvent::FontChange || type == QEvent::StyleChange || type == QEvent::Resize) {
                // Recalculate after OBS/Qt finishes the current style/layout event.
                QTimer::singleShot(0, this, [this]() { UpdateHiddenCountButton(); });
            }
        }

'@ '' 'remove counter resize feedback loop'

# dataChanged fires for ordinary selection/highlight changes in OBS. Only run the
# hide-row maintenance path when the actual list of source names changed (rename,
# replacement, etc.), not on every click.
Replace-Required @'
        observedModel_ = model;
        QObject::connect(model, &QAbstractItemModel::rowsInserted, this, [this]() { ScheduleApply(); });
        QObject::connect(model, &QAbstractItemModel::rowsRemoved, this, [this]() { ScheduleApply(); });
        QObject::connect(model, &QAbstractItemModel::modelReset, this, [this]() { ScheduleApply(); });
        QObject::connect(model, &QAbstractItemModel::layoutChanged, this, [this]() { ScheduleApply(); });
        QObject::connect(model, &QAbstractItemModel::dataChanged, this, [this]() { ScheduleApply(); });
'@ @'
        observedModel_ = model;
        lastModelNames_ = CurrentModelNames();
        QObject::connect(model, &QAbstractItemModel::rowsInserted, this, [this]() { ScheduleApply(); });
        QObject::connect(model, &QAbstractItemModel::rowsRemoved, this, [this]() { ScheduleApply(); });
        QObject::connect(model, &QAbstractItemModel::modelReset, this, [this]() { ScheduleApply(); });
        QObject::connect(model, &QAbstractItemModel::layoutChanged, this, [this]() { ScheduleApply(); });
        QObject::connect(model, &QAbstractItemModel::dataChanged, this, [this]() {
            const QSet<QString> now = CurrentModelNames();
            if (now == lastModelNames_)
                return;
            lastModelNames_ = now;
            ScheduleApply();
        });
'@ 'ignore selection-only dataChanged notifications'

# Keep the name snapshot current after actual hide/model maintenance.
Replace-Required @'
        // Remove stale names if a hidden source was actually deleted from the scene.
        QStringList cleanedHidden;
'@ @'
        lastModelNames_ = existingNames;

        // Remove stale names if a hidden source was actually deleted from the scene.
        QStringList cleanedHidden;
'@ 'refresh model-name snapshot'

# Avoid even calling the checked-state setter when no visual state changed.
Replace-Required @'
        hiddenCountButton_->setChecked(showHiddenRows_ && hiddenCount > 0);
'@ @'
        const bool wantedChecked = showHiddenRows_ && hiddenCount > 0;
        if (hiddenCountButton_->isChecked() != wantedChecked)
            hiddenCountButton_->setChecked(wantedChecked);
'@ 'skip unchanged checked repaint'

Replace-Required @'
    bool applyQueued_ = false;
    bool showHiddenRows_ = false;
'@ @'
    bool applyQueued_ = false;
    bool showHiddenRows_ = false;
    QSet<QString> lastModelNames_;
'@ 'model name snapshot member'

Set-Content $path $s -Encoding utf8

$issPath = 'installer/SourceDockHide.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('1.6.0', '1.7.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared Source Dock Hide v1.7 no-resize-loop + selection-noise suppression.'

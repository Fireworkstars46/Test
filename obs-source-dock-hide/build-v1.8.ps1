$ErrorActionPreference = 'Stop'

# Keep v1.7's all-source hiding and full-text OBS-style counter, but stop transient
# scene/source model notifications from making the counter repaint during simple
# clicks. The video shows the counter flashing while the Sources model is being
# relaid out even though the actual source-name list has not changed.
& ./build-v1.7.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v1.8 patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "1.7.0";' 'static constexpr const char *PLUGIN_VERSION = "1.8.0";' 'plugin version'

# layoutChanged is emitted for selection/visual relayouts too. Treat it like
# dataChanged: only run hidden-row maintenance if the actual list of source names
# changed. This removes another click-only path that still reached the counter.
Replace-Required @'
        QObject::connect(model, &QAbstractItemModel::layoutChanged, this, [this]() { ScheduleApply(); });
        QObject::connect(model, &QAbstractItemModel::dataChanged, this, [this]() {
            const QSet<QString> now = CurrentModelNames();
            if (now == lastModelNames_)
                return;
            lastModelNames_ = now;
            ScheduleApply();
        });
'@ @'
        QObject::connect(model, &QAbstractItemModel::layoutChanged, this, [this]() {
            const QSet<QString> now = CurrentModelNames();
            if (now == lastModelNames_)
                return;
            lastModelNames_ = now;
            ScheduleApply();
        });
        QObject::connect(model, &QAbstractItemModel::dataChanged, this, [this]() {
            const QSet<QString> now = CurrentModelNames();
            if (now == lastModelNames_)
                return;
            lastModelNames_ = now;
            ScheduleApply();
        });
'@ 'ignore selection-only layoutChanged notifications'

# FindSourceTree is called during every scene transition. Do not immediately paint
# the counter from a half-transitioned model; ScheduleApply() below will update it
# once the model has settled.
Replace-Required @'
        AttachModelSignals();
        EnsureHiddenCountButton();
        UpdateHiddenCountButton();
'@ @'
        AttachModelSignals();
        EnsureHiddenCountButton();
'@ 'defer counter update until stable apply'

# Coalesce bursts of model/reset/layout signals for a few milliseconds. A single
# delayed pass sees the final scene model instead of showing 0 hidden then the real
# count during the transition. The delay is short enough to feel immediate when a
# user explicitly hides/unhides a source.
Replace-Required @'
    void ScheduleApply()
    {
        if (applyQueued_)
            return;
        applyQueued_ = true;
        QTimer::singleShot(0, this, [this]() {
            applyQueued_ = false;
            ApplyHiddenRows();
        });
    }
'@ @'
    void ScheduleApply()
    {
        if (applyQueued_)
            return;
        applyQueued_ = true;
        QTimer::singleShot(45, this, [this]() {
            applyQueued_ = false;
            ApplyHiddenRows();
        });
    }
'@ 'debounce hidden-row maintenance'

Set-Content $path $s -Encoding utf8

$issPath = 'installer/SourceDockHide.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('1.7.0', '1.8.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared Source Dock Hide v1.8 stable no-flicker model updates.'

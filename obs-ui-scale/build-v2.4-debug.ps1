$ErrorActionPreference = 'Stop'

# Start from v2.3 DEBUG, but make diagnostic logging optional and persistent.
# Logging defaults OFF. The OBS UI Scale dialog gets an "Enable debug logging"
# checkbox that can be toggled at runtime. Turning it on starts a fresh Desktop
# log immediately; turning it off stops diagnostic writes immediately.
& ./build-v2.3-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v2.4 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "2.3.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "2.4.0-debug";' 'plugin version'

# v2.3 initialized/truncated the log before settings existed. Remove that and
# initialize only after the persisted debug toggle has been read.
Replace-Required @'
    ObsUiScaleController()
    {
        InitializeDebugLog();
        DebugWrite(QStringLiteral("CONSTRUCTOR: OBS UI Scale debug controller starting"));

        char *configPath = obs_module_config_path("obs-ui-scale.ini");
'@ @'
    ObsUiScaleController()
    {
        char *configPath = obs_module_config_path("obs-ui-scale.ini");
'@ 'remove unconditional constructor logging'

Replace-Required @'
        proportionalMode_ = settings_ ? settings_->value(QStringLiteral("ui/proportionalMode"), true).toBool() : true;

        toolsAction_ = static_cast<QAction *>(obs_frontend_add_tools_menu_qaction("OBS UI Scale..."));
'@ @'
        proportionalMode_ = settings_ ? settings_->value(QStringLiteral("ui/proportionalMode"), true).toBool() : true;
        debugLoggingEnabled_ = settings_ ? settings_->value(QStringLiteral("debug/loggingEnabled"), false).toBool() : false;
        if (debugLoggingEnabled_) {
            InitializeDebugLog();
            DebugWrite(QStringLiteral("CONSTRUCTOR: OBS UI Scale debug controller starting (logging enabled from saved setting)"));
        }

        toolsAction_ = static_cast<QAction *>(obs_frontend_add_tools_menu_qaction("OBS UI Scale..."));
'@ 'load persisted debug toggle'

# Guard all file output. Debug helper calls may still occur from normal plugin
# paths, but with logging off they become no-ops and create no Desktop file.
Replace-Required @'
    void InitializeDebugLog()
    {
        QString folder = QStandardPaths::writableLocation(QStandardPaths::DesktopLocation);
'@ @'
    void InitializeDebugLog()
    {
        if (!debugLoggingEnabled_)
            return;

        QString folder = QStandardPaths::writableLocation(QStandardPaths::DesktopLocation);
'@ 'guard debug log initialization'

Replace-Required @'
    void DebugWrite(const QString &message)
    {
        if (debugLogPath_.isEmpty())
            return;
'@ @'
    void DebugWrite(const QString &message)
    {
        if (!debugLoggingEnabled_ || debugLogPath_.isEmpty())
            return;
'@ 'guard debug writes'

# Avoid expensive geometry traversal while logging is disabled.
Replace-Required @'
    void DebugSnapshot(const QString &label)
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
'@ @'
    void DebugSnapshot(const QString &label)
    {
        if (!debugLoggingEnabled_)
            return;

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
'@ 'guard snapshots'

Replace-Required @'
    void DebugWidgetEvent(QWidget *widget, QEvent::Type type)
    {
        DebugWrite(QStringLiteral("QT EVENT %1: %2")
'@ @'
    void DebugWidgetEvent(QWidget *widget, QEvent::Type type)
    {
        if (!debugLoggingEnabled_)
            return;

        DebugWrite(QStringLiteral("QT EVENT %1: %2")
'@ 'guard widget diagnostics'

Replace-Required @'
    void DebugFrontendEvent(enum obs_frontend_event event)
    {
        const QString eventName = DebugFrontendEventName(event);
'@ @'
    void DebugFrontendEvent(enum obs_frontend_event event)
    {
        if (!debugLoggingEnabled_)
            return;

        const QString eventName = DebugFrontendEventName(event);
'@ 'guard frontend diagnostics'

Replace-Required @'
    void DebugScheduleApplySnapshots(const QString &prefix)
    {
        const int delays[] = {0, 5, 15, 35, 70, 100, 150, 220, 350, 500, 800, 1200};
'@ @'
    void DebugScheduleApplySnapshots(const QString &prefix)
    {
        if (!debugLoggingEnabled_)
            return;

        const int delays[] = {0, 5, 15, 35, 70, 100, 150, 220, 350, 500, 800, 1200};
'@ 'guard apply snapshot scheduling'

# Add runtime toggle helper just before DebugSceneName(). Enabling starts a new
# file immediately. Disabling records one final line, then shuts writes off.
$toggleMarker = '    QString DebugSceneName() const'
$togglePos = $s.IndexOf($toggleMarker)
if ($togglePos -lt 0) { throw 'v2.4 could not locate DebugSceneName insertion point' }
$toggleHelper = @'
    void SetDebugLoggingEnabled(bool enabled)
    {
        if (debugLoggingEnabled_ == enabled)
            return;

        if (!enabled) {
            DebugWrite(QStringLiteral("DEBUG LOGGING DISABLED BY USER"));
            debugLoggingEnabled_ = false;
        } else {
            debugLoggingEnabled_ = true;
            debugLogPath_.clear();
            InitializeDebugLog();
            DebugWrite(QStringLiteral("DEBUG LOGGING ENABLED BY USER"));
            DebugSnapshot(QStringLiteral("logging enabled"));
        }

        if (settings_) {
            settings_->setValue(QStringLiteral("debug/loggingEnabled"), debugLoggingEnabled_);
            settings_->sync();
        }

        blog(LOG_INFO, "[%s] diagnostic logging %s", PLUGIN_NAME,
             debugLoggingEnabled_ ? "enabled" : "disabled");
    }

'@
$s = $s.Substring(0, $togglePos) + $toggleHelper + $s.Substring($togglePos)

# Do not even build detailed event summaries while disabled.
Replace-Required @'
        if (event && DebugInterestingEvent(event->type())) {
'@ @'
        if (debugLoggingEnabled_ && event && DebugInterestingEvent(event->type())) {
'@ 'skip Qt event diagnostics while disabled'

# Add the checkbox directly below the intro. It applies instantly and remembers
# its state independently of the scale Apply button.
Replace-Required @'
        intro->setWordWrap(true);
        layout->addWidget(intro);

        auto *uiRow = new QHBoxLayout();
'@ @'
        intro->setWordWrap(true);
        layout->addWidget(intro);

        auto *debugLogging = new QCheckBox(QStringLiteral("Enable debug logging"), &dialog);
        debugLogging->setChecked(debugLoggingEnabled_);
        debugLogging->setToolTip(QStringLiteral(
            "When enabled, writes OBS/Qt layout diagnostics to OBS-UI-Scale-Debug.txt on the Desktop. "
            "Turning this off stops diagnostic writes immediately."));
        QObject::connect(debugLogging, &QCheckBox::toggled, &dialog,
                         [this](bool enabled) { SetDebugLoggingEnabled(enabled); });
        layout->addWidget(debugLogging);

        auto *uiRow = new QHBoxLayout();
'@ 'add debug logging checkbox'

Replace-Required 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v2.3 DEBUG"));' 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v2.4 DEBUG"));' 'dialog title'

# Update the v2.3 intro wording without depending on exact wrapping elsewhere.
$s = $s.Replace('v2.3 DEBUG keeps the v2.2 behavior and records detailed dock/mixer geometry while you reproduce the jump.',
                'v2.4 DEBUG keeps the v2.2 behavior and adds optional dock/mixer diagnostics. Use Enable debug logging only when you need a trace.')
$s = $s.Replace('The log is written automatically to OBS-UI-Scale-Debug.txt on your Desktop.',
                'When logging is enabled, the trace is written to OBS-UI-Scale-Debug.txt on your Desktop.')

# Add toggle state member.
Replace-Required @'
    QString debugLogPath_;
    bool debugPostSnapshotQueued_ = false;
'@ @'
    QString debugLogPath_;
    bool debugPostSnapshotQueued_ = false;
    bool debugLoggingEnabled_ = false;
'@ 'debug logging member'

Set-Content $path $s -Encoding utf8

# v2.3 already branded the installer as Debug. Advance version/output only.
$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('2.3.0', '2.4.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-2.3.0', 'OBS-UI-Scale-Debug-Setup-2.4.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v2.4 DEBUG with persistent runtime logging toggle (default off).'

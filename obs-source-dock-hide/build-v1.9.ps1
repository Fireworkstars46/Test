$ErrorActionPreference = 'Stop'

# Keep v1.8's all-source hiding and low-noise model updates. The new video shows
# the counter is correct while no source is selected, but OBS compresses/reparents
# it when a source row becomes selected. v1.9 pins the counter to the original
# Sources toolbar layout and gives the native QToolButton a truly fixed horizontal
# width owned by Source Dock Hide itself.
& ./build-v1.8.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v1.9 patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "1.8.0";' 'static constexpr const char *PLUGIN_VERSION = "1.9.0";' 'plugin version'

if (-not $s.Contains('#include <QSizePolicy>')) {
    Replace-Required '#include <QSettings>' "#include <QSettings>`n#include <QSizePolicy>" 'QSizePolicy include'
}

# FullTextToolButton already prevents Qt from eliding the visible label. The
# remaining failure is that OBS can still squeeze the actual button widget when
# the selected-source UI appears. Make horizontal ownership explicit and keep the
# fixed width synchronized with the current scaled font/style.
Replace-Required @'
        label_->setStyleSheet(QStringLiteral("background: transparent; border: none; padding: 0px; margin: 0px;"));
        label_->show();
'@ @'
        label_->setStyleSheet(QStringLiteral("background: transparent; border: none; padding: 0px; margin: 0px;"));
        label_->show();
        setSizePolicy(QSizePolicy::Fixed, QSizePolicy::Preferred);
'@ 'fixed horizontal size policy'

Replace-Required @'
        label_->setFont(font());
        updateLabelGeometry();
        updateGeometry();
        update();
    }

    const QString &displayText() const { return displayText_; }
'@ @'
        label_->setFont(font());
        updateLabelGeometry();
        syncFixedWidth();
        update();
    }

    const QString &displayText() const { return displayText_; }
    void refreshFixedWidth() { syncFixedWidth(); }
'@ 'counter owns fixed width after text update'

Replace-Required @'
            label_->setFont(font());
            updateLabelGeometry();
            updateGeometry();
        }
    }

private:
    void updateLabelGeometry()
'@ @'
            label_->setFont(font());
            updateLabelGeometry();
            syncFixedWidth();
        }
    }

private:
    void syncFixedWidth()
    {
        if (!label_)
            return;

        ensurePolished();
        const int labelWidth = label_->fontMetrics().horizontalAdvance(displayText_);
        const int wantedWidth = qMax(QToolButton::sizeHint().width(), labelWidth + 14);
        if (minimumWidth() != wantedWidth || maximumWidth() != wantedWidth) {
            setMinimumWidth(wantedWidth);
            setMaximumWidth(wantedWidth);
            updateGeometry();
        }
    }

    void updateLabelGeometry()
'@ 'resync fixed width after style/font changes'

# Once the correct Sources toolbar has been found, keep using that exact layout.
# Re-running the heuristic while a source is selected can choose a temporary
# selection-specific layout and move/squeeze the counter.
Replace-Required @'
        QBoxLayout *buttonLayout = FindSourcesButtonLayout(sourcesDock);
        if (!buttonLayout)
            return;
'@ @'
        if (!sourcesButtonLayout_) {
            QBoxLayout *foundLayout = FindSourcesButtonLayout(sourcesDock);
            if (!foundLayout)
                return;
            sourcesButtonLayout_ = foundLayout;
        }

        QBoxLayout *buttonLayout = sourcesButtonLayout_.data();
        if (!buttonLayout)
            return;
'@ 'pin the original Sources button layout'

# v1.3's controller-level width recalculation is obsolete now that the custom
# tool button owns a fixed width. Remove that block so nothing can reopen the max
# width and allow OBS to compress it again.
$widthStartMarker = '        // Keep enough layout width for the full child label.'
$widthEndMarker = '        // QToolButton::click toggles its checked state itself; always make the'
$widthStart = $s.IndexOf($widthStartMarker)
$widthEnd = $s.IndexOf($widthEndMarker, $widthStart)
if ($widthStart -lt 0 -or $widthEnd -lt 0) { throw 'v1.9 could not locate old counter width block' }
$newWidthBlock = @'
        // FullTextToolButton owns the horizontal size. Recalculate only when the
        // count/font/style actually changes; ordinary source selection must not
        // resize or move the counter.
        hiddenCountButton_->refreshFixedWidth();

'@
$s = $s.Substring(0, $widthStart) + $newWidthBlock + $s.Substring($widthEnd)

Replace-Required @'
    QPointer<FullTextToolButton> hiddenCountButton_;
'@ @'
    QPointer<FullTextToolButton> hiddenCountButton_;
    QPointer<QBoxLayout> sourcesButtonLayout_;
'@ 'remember the stable Sources toolbar layout'

Set-Content $path $s -Encoding utf8

$issPath = 'installer/SourceDockHide.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('1.8.0', '1.9.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared Source Dock Hide v1.9 pinned toolbar + fixed-width native counter.'

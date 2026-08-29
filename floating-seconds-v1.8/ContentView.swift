import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var pipManager: PiPClockManager

    var body: some View {
        NavigationView {
            Form {
                Section {
                    ZStack {
                        CheckerboardView()
                        PiPSourceView(manager: pipManager)
                            .aspectRatio(settings.shape.aspectRatio, contentMode: .fit)
                    }
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    HStack(spacing: 12) {
                        Button {
                            pipManager.startPiP()
                        } label: {
                            Label("Start Seconds", systemImage: "pip.enter")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(pipManager.isPiPActive)

                        if pipManager.isPiPActive {
                            Button(role: .destructive) {
                                pipManager.stopPiP()
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    Text(pipManager.statusText)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } header: {
                    Text("Seconds only")
                }

                Section("Position inside strip") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Left / right")
                            Spacer()
                            Text(positionLabel(settings.clockX))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: Binding(
                            get: { settings.clockX },
                            set: { value in
                                settings.setHorizontal(value)
                                refreshClock()
                            }
                        ), in: -1...1, step: 0.005)
                    }

                    HStack(spacing: 8) {
                        Button("Left") { applyHorizontal(-1) }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                        Button("Center") { applyHorizontal(0) }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                        Button("Right") { applyHorizontal(1) }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                    }

                    HStack(spacing: 8) {
                        Button {
                            nudgeHorizontal(-0.02)
                        } label: {
                            Label("Nudge left", systemImage: "chevron.left")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            nudgeHorizontal(0.02)
                        } label: {
                            Label("Nudge right", systemImage: "chevron.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    Text("The buttons move the digits inside the PiP strip. To move the whole strip on the screen, drag the PiP itself; iOS controls its allowed snap locations.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Size") {
                    Picker("Window shape", selection: Binding(
                        get: { settings.shape },
                        set: { value in
                            settings.shape = value
                            refreshClock()
                        }
                    )) {
                        ForEach(ClockShape.allCases) { shape in
                            Text(shape.title).tag(shape)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Number size")
                            Spacer()
                            Text("\(Int(settings.textScale * 100))%")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: Binding(
                            get: { settings.textScale },
                            set: { value in
                                settings.textScale = value
                                refreshClock()
                            }
                        ), in: 0.25...2.00, step: 0.01)
                    }

                    HStack(spacing: 8) {
                        Button("Large") { applyScale(1.20) }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                        Button("Max") { applyScale(2.00) }
                            .buttonStyle(.borderedProminent)
                            .frame(maxWidth: .infinity)
                    }

                    HStack {
                        Text("Outer PiP size")
                        Spacer()
                        Text("Controlled by iOS")
                            .foregroundColor(.secondary)
                    }

                    Picker("Weight", selection: Binding(
                        get: { settings.fontWeight },
                        set: { value in
                            settings.fontWeight = value
                            refreshClock()
                        }
                    )) {
                        ForEach(ClockFontWeight.allCases) { weight in
                            Text(weight.title).tag(weight)
                        }
                    }
                }

                Section("Number appearance") {
                    Picker("Number color", selection: Binding(
                        get: { settings.textColor },
                        set: { value in
                            settings.textColor = value
                            refreshClock()
                        }
                    )) {
                        ForEach(ClockColor.allCases) { color in
                            HStack {
                                Circle().fill(color.swiftUIColor).frame(width: 12, height: 12)
                                Text(color.title)
                            }
                            .tag(color)
                        }
                    }

                    HStack {
                        Text("Background")
                        Spacer()
                        Text("Transparent")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("App border / padding")
                        Spacer()
                        Text("None")
                            .foregroundColor(.secondary)
                    }
                }

                Section("Touch behavior") {
                    Text("iOS Picture in Picture owns the floating strip area, so taps cannot pass through it to another app underneath.")
                }
            }
            .navigationTitle("Floating Seconds")
        }
        .navigationViewStyle(.stack)
    }

    private func applyHorizontal(_ value: Double) {
        settings.setHorizontal(value)
        refreshClock()
    }

    private func nudgeHorizontal(_ amount: Double) {
        settings.nudgeHorizontal(amount)
        refreshClock()
    }

    private func applyScale(_ value: Double) {
        settings.textScale = value
        refreshClock()
    }

    private func refreshClock() {
        pipManager.renderNow()
        DispatchQueue.main.async {
            pipManager.renderNow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            pipManager.renderNow()
        }
    }

    private func positionLabel(_ value: Double) -> String {
        let percent = Int(abs(value) * 100)
        if percent == 0 { return "Center" }
        return "\(value < 0 ? "Left" : "Right") \(percent)%"
    }
}

private struct CheckerboardView: View {
    var body: some View {
        GeometryReader { _ in
            let cell: CGFloat = 12
            Canvas { context, size in
                let cols = Int(ceil(size.width / cell))
                let rows = Int(ceil(size.height / cell))
                for row in 0..<rows {
                    for col in 0..<cols {
                        let rect = CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                        let color = ((row + col) % 2 == 0) ? Color.gray.opacity(0.18) : Color.gray.opacity(0.32)
                        context.fill(Path(rect), with: .color(color))
                    }
                }
            }
        }
        .frame(height: 54)
    }
}

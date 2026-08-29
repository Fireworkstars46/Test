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
                } footer: {
                    Text("The app renders only the two second digits on a fully transparent canvas. iOS may still paint its own PiP container behind it.")
                }

                Section("Position") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Horizontal")
                            Spacer()
                            Text(positionLabel(settings.clockX, negative: "Left", positive: "Right"))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $settings.clockX, in: -1...1, step: 0.01)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Vertical")
                            Spacer()
                            Text(positionLabel(settings.clockY, negative: "Up", positive: "Down"))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $settings.clockY, in: -1...1, step: 0.01)
                    }

                    Button("Center seconds") {
                        settings.resetPosition()
                    }
                }

                Section("Size") {
                    Picker("Window shape", selection: $settings.shape) {
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
                        Slider(value: $settings.textScale, in: 0.50...2.00, step: 0.05)
                    }

                    HStack {
                        Text("Outer PiP size")
                        Spacer()
                        Text("Controlled by iOS")
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 12) {
                        Button("Large") { settings.textScale = 1.20 }
                        Button("Max") { settings.textScale = 1.65 }
                    }

                    Picker("Weight", selection: $settings.fontWeight) {
                        ForEach(ClockFontWeight.allCases) { weight in
                            Text(weight.title).tag(weight)
                        }
                    }
                }

                Section("Number appearance") {
                    Picker("Number color", selection: $settings.textColor) {
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
                        Text("Border / padding")
                        Spacer()
                        Text("None")
                            .foregroundColor(.secondary)
                    }
                }

                Section("Important") {
                    Text("Only the seconds are drawn. The app background is transparent.")
                    Text("The thin dark rounded pill/outline you see on the Home Screen is the iOS Picture-in-Picture container. The app itself draws no background, border, or padding, but iOS does not allow that system container to be made transparent or hidden by a normal sideloaded IPA.")
                }
            }
            .navigationTitle("Floating Seconds")
        }
        .navigationViewStyle(.stack)
    }

    private func positionLabel(_ value: Double, negative: String, positive: String) -> String {
        let percent = Int(abs(value) * 100)
        if percent == 0 { return "Center" }
        return "\(value < 0 ? negative : positive) \(percent)%"
    }
}

private struct CheckerboardView: View {
    var body: some View {
        GeometryReader { proxy in
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

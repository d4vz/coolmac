import SwiftUI

struct ContentView: View {
    @ObservedObject var model: FanViewModel

    var body: some View {
        VStack(spacing: 14) {
            header
            fanGauges
            modePicker
            controlSection
            footer
        }
        .padding(16)
        .frame(width: 352)
    }

    // MARK: Header — CPU temperature

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: min(1, model.cpuTemp / 100))
                    .stroke(tempColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(String(format: "%.0f°", model.cpuTemp))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 2) {
                Text("CoolMac")
                    .font(.system(size: 15, weight: .semibold))
                Text(String(format: "CPU %.1f°C (hottest P-core)", model.cpuTemp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.mode == .curve {
                    Text(String(format: "Curve target: %.0f%%", model.targetPercent))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.mode == .manual {
                    Text(String(format: "Manual target: %.0f%%", model.manualPercent))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("System controls the fans")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var tempColor: Color {
        switch model.cpuTemp {
        case ..<55: return .green
        case ..<75: return .yellow
        case ..<90: return .orange
        default: return .red
        }
    }

    // MARK: Fan gauges

    private var fanGauges: some View {
        HStack(spacing: 12) {
            ForEach(model.fans) { fan in
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .stroke(Color.primary.opacity(0.12), lineWidth: 7)
                        Circle()
                            .trim(from: 0, to: fan.fraction)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 0) {
                            Text(String(format: "%.0f", fan.actual))
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                            Text("RPM")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 76, height: 76)
                    Text("Fan \(fan.id + 1)")
                        .font(.caption.weight(.medium))
                    Text(String(format: "%.0f – %.0f rpm", fan.minRPM, fan.maxRPM))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: Mode

    private var modePicker: some View {
        Picker("Mode", selection: $model.mode) {
            ForEach(ControlMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: Slider / curve

    /// In Manual the slider is the setpoint. In Curve it follows the
    /// live curve target — dragging it switches to Manual (the
    /// Macs Fan Control behaviour). Disabled in Auto.
    private var sliderBinding: Binding<Double> {
        Binding(
            get: { model.mode == .manual ? model.manualPercent : max(0, model.targetPercent) },
            set: { model.manualPercent = $0 }
        )
    }

    @ViewBuilder
    private var controlSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Fan speed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", sliderBinding.wrappedValue))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                if let fan = model.fans.first {
                    Text(String(format: "≈ %.0f rpm", fan.rpm(atPercent: sliderBinding.wrappedValue)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Slider(value: sliderBinding, in: 0...100, step: 1) {
                Text("Fan speed")
            } onEditingChanged: { editing in
                if !editing { model.sliderChanged() }
            }
            .labelsHidden()
            .onChange(of: model.manualPercent) { _ in model.sliderChanged() }
            .disabled(model.mode == .auto)
            .opacity(model.mode == .auto ? 0.4 : 1)

            HStack {
                Text("0%").font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                Text("50%").font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                Text("100%").font(.system(size: 9)).foregroundStyle(.secondary)
            }

            if model.mode == .manual {
                Text("Drag to set a fixed speed — or switch to Curve for automatic temperature-based control.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if model.mode == .curve {
                CurveChart(points: model.curvePoints, currentTemp: model.cpuTemp,
                           currentPercent: model.targetPercent)
                    .frame(height: 74)
                    .padding(.top, 2)
            }

            if model.mode == .auto {
                Button("Fans are under system control") {}
                    .disabled(true)
                    .font(.caption)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.helperConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(model.helperConnected ? "Helper connected" : "Helper not installed — run scripts/install-helper.sh")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if !model.lastWriteOK && model.mode != .auto {
                Label("Last fan write failed", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.conflictingAppRunning {
                Label("Macs Fan Control is running — quit it to avoid conflicts", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Restore Auto") { model.restoreAuto() }
                    .controlSize(.small)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .controlSize(.small)
                    .keyboardShortcut("q")
            }
        }
    }
}

// MARK: - Curve chart

struct CurveChart: View {
    let points: [(temp: Double, percent: Double)]
    let currentTemp: Double
    let currentPercent: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Dynamic curve — temperature → fan speed")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Canvas { context, size in
                func x(_ t: Double) -> CGFloat { CGFloat((t - 30) / 70) * size.width }   // 30–100°C
                func y(_ p: Double) -> CGFloat { size.height - CGFloat(p / 100) * size.height }
                var line = Path()
                for (i, pt) in points.enumerated() {
                    let point = CGPoint(x: x(pt.temp), y: y(pt.percent))
                    if i == 0 { line.move(to: point) } else { line.addLine(to: point) }
                }
                context.stroke(line, with: .color(.accentColor), lineWidth: 2)
                for pt in points {
                    let rect = CGRect(x: x(pt.temp) - 2.5, y: y(pt.percent) - 2.5, width: 5, height: 5)
                    context.fill(Path(ellipseIn: rect), with: .color(.accentColor))
                }
                let cx = x(min(100, max(30, currentTemp)))
                let cy = y(currentPercent)
                let dot = CGRect(x: cx - 5, y: cy - 5, width: 10, height: 10)
                context.fill(Path(ellipseIn: dot), with: .color(.orange))
                context.stroke(Path(ellipseIn: dot), with: .color(.white), lineWidth: 1.5)
            }
        }
    }
}

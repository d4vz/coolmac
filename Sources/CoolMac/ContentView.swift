import SwiftUI

struct ContentView: View {
    @ObservedObject var model: FanViewModel

    /// Fixed width, height depends only on the mode (changed
    /// deliberately by the user, never by live data) — the popover's
    /// top stays anchored under the status item on every open.
    static func popoverSize(mode: ControlMode) -> NSSize {
        let height: CGFloat
        switch mode {
        case .auto: height = 300
        case .curve: height = 528
        case .manual: height = 396
        }
        return NSSize(width: 352, height: height)
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            fanGauges
            presetRow
            modePicker
            if model.mode != .auto {
                controlSection
            }
            Spacer(minLength: 0)
            warnings
        }
        .padding(12)
        .frame(width: 352, height: Self.popoverSize(mode: model.mode).height)
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
            settingsMenu
        }
    }

    /// ⚙️ menu, top-right of the header: link fans, launch at login,
    /// restore-Auto, curve reset, quit. No disclosure arrow.
    private var settingsMenu: some View {
        Menu {
            Toggle("Link fans", isOn: $model.linkFans)
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }))
                .disabled(!model.canLaunchAtLogin)
            Divider()
            Button("Restore Auto") { model.restoreAuto() }
            Button("Reset curve") { model.resetCurve() }
            Divider()
            Button("Quit CoolMac") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22, alignment: .trailing)
        .help(model.canLaunchAtLogin ? "Settings" : "Settings (Launch at login needs the CoolMac.app bundle)")
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
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: Presets

    private var presetRow: some View {
        HStack(spacing: 6) {
            ForEach(FanPreset.allCases) { preset in
                Button {
                    model.applyPreset(preset)
                } label: {
                    Text(preset.rawValue)
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            model.activePreset == preset.rawValue
                                ? Color.accentColor.opacity(0.85)
                                : Color.primary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(
                            model.activePreset == preset.rawValue
                                ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Preset \(preset.rawValue)")
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

    // No `step:` on the sliders — AppKit draws tick marks for stepped
    // sliders. Round in the bindings instead so values still snap to
    // whole percents.
    /// In Manual the slider is the setpoint. In Curve it follows the
    /// live curve target — dragging it switches to Manual (the
    /// Macs Fan Control behaviour). Disabled in Auto.
    private var sliderBinding: Binding<Double> {
        Binding(
            get: { model.mode == .manual ? model.manualPercent : max(0, model.targetPercent) },
            set: { model.manualPercent = $0.rounded() }
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

            if model.mode == .manual && !model.linkFans {
                perFanSliders
            } else {
                Slider(value: sliderBinding, in: 0...100) {
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
            }

            if model.mode == .curve {
                CurveChart(points: model.curvePoints, currentTemp: model.cpuTemp,
                           currentPercent: model.targetPercent,
                           onEdit: { model.updateCurvePoint(index: $0, temp: $1, percent: $2) })
                    .frame(height: 118)
                    .padding(.top, 2)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private func fanPercentBinding(_ fan: Int) -> Binding<Double> {
        Binding(
            get: { fan < model.fanPercents.count ? model.fanPercents[fan] : 50 },
            set: { value in
                var next = model.fanPercents
                while next.count <= fan { next.append(value.rounded()) }
                next[fan] = value.rounded()
                model.fanPercents = next
            }
        )
    }

    private var perFanSliders: some View {
        VStack(spacing: 8) {
            ForEach(0..<max(2, model.fans.count), id: \.self) { fan in
                HStack(spacing: 8) {
                    Text("Fan \(fan + 1)")
                        .font(.caption.weight(.medium))
                        .frame(width: 36, alignment: .leading)
                    Slider(value: fanPercentBinding(fan), in: 0...100) {
                        Text("Fan \(fan + 1) speed")
                    } onEditingChanged: { editing in
                        if !editing { model.fanSliderChanged() }
                    }
                    .labelsHidden()
                    Text(String(format: "%.0f%%", fanPercentBinding(fan).wrappedValue))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }
        .onChange(of: model.fanPercents) { _ in model.fanSliderChanged() }
    }

    // MARK: Warnings (only visible when something is wrong)

    private var warnings: some View {
        VStack(spacing: 6) {
            if !model.helperConnected {
                Label("Helper not installed — run scripts/install-helper.sh", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        }
    }
}

// MARK: - Curve chart

struct CurveChart: View {
    let points: [(temp: Double, percent: Double)]
    let currentTemp: Double
    let currentPercent: Double
    /// When non-nil, the point dots are draggable (index, temp, percent).
    var onEdit: ((Int, Double, Double) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Dynamic curve — temperature → fan speed")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                let size = geo.size
                // True graph layout: Y tick labels on the left, X tick
                // labels below, 8pt headroom top/right so dots at the
                // extremes render whole (draggable dot: 6.5pt radius +
                // half its 1.5pt stroke = 7.25pt; current dot: 5.75pt).
                let left: CGFloat = 26, right: CGFloat = 8
                let top: CGFloat = 8, bottom: CGFloat = 16
                let plotWidth = max(1, size.width - left - right)
                let plotHeight = max(1, size.height - top - bottom)
                let x: (Double) -> CGFloat = { left + CGFloat(($0 - 30) / 70) * plotWidth }   // 30–100°C
                let y: (Double) -> CGFloat = { top + (1 - CGFloat($0 / 100)) * plotHeight } // 0–100%
                ZStack {
                    Canvas { context, _ in
                        // Gridlines: horizontal every 25%, vertical every 10°C.
                        for pct in [0.0, 25, 50, 75, 100] {
                            var grid = Path()
                            grid.move(to: CGPoint(x: left, y: y(pct)))
                            grid.addLine(to: CGPoint(x: left + plotWidth, y: y(pct)))
                            context.stroke(grid, with: .color(.primary.opacity(pct == 0 ? 0.3 : 0.09)), lineWidth: 1)
                        }
                        for temp in stride(from: 30.0, through: 100.0, by: 10.0) {
                            var grid = Path()
                            grid.move(to: CGPoint(x: x(temp), y: top))
                            grid.addLine(to: CGPoint(x: x(temp), y: top + plotHeight))
                            context.stroke(grid, with: .color(.primary.opacity(0.06)), lineWidth: 1)
                        }
                        // Curve: holds flat outside the first/last point,
                        // exactly like the interpolation in FanCurve.
                        var line = Path()
                        if let first = points.first, let last = points.last {
                            line.move(to: CGPoint(x: left, y: y(first.percent)))
                            for pt in points {
                                line.addLine(to: CGPoint(x: x(pt.temp), y: y(pt.percent)))
                            }
                            line.addLine(to: CGPoint(x: left + plotWidth, y: y(last.percent)))
                        }
                        context.stroke(line, with: .color(.accentColor), lineWidth: 2)
                        if onEdit == nil {
                            for pt in points {
                                let rect = CGRect(x: x(pt.temp) - 2.5, y: y(pt.percent) - 2.5, width: 5, height: 5)
                                context.fill(Path(ellipseIn: rect), with: .color(.accentColor))
                            }
                        }
                        let cx = x(min(100, max(30, currentTemp)))
                        let cy = y(currentPercent)
                        let dot = CGRect(x: cx - 5, y: cy - 5, width: 10, height: 10)
                        context.fill(Path(ellipseIn: dot), with: .color(.orange))
                        context.stroke(Path(ellipseIn: dot), with: .color(.white), lineWidth: 1.5)
                    }
                    // Y tick labels (fan %).
                    ForEach([0.0, 25, 50, 75, 100], id: \.self) { pct in
                        Text(pct == 100 ? "100%" : "\(Int(pct))")
                            .font(.system(size: 7.5))
                            .foregroundStyle(.secondary)
                            .position(x: left / 2, y: y(pct))
                    }
                    // X tick labels (temperature °C).
                    ForEach(Array(stride(from: 30.0, through: 100.0, by: 10.0)), id: \.self) { temp in
                        Text("\(Int(temp))°")
                            .font(.system(size: 7.5))
                            .foregroundStyle(.secondary)
                            .position(x: x(temp), y: top + plotHeight + bottom / 2)
                    }
                    if let onEdit {
                        ForEach(points.indices, id: \.self) { i in
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 13, height: 13)
                                .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                                .position(x: x(points[i].temp), y: y(points[i].percent))
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { value in
                                            // Invert the same plot mapping used to place the dots.
                                            let temp = 30 + Double((value.location.x - left) / plotWidth) * 70
                                            let percent = (1 - Double((value.location.y - top) / plotHeight)) * 100
                                            onEdit(i, temp, percent)
                                        }
                                )
                                .accessibilityLabel("Curve point \(i + 1)")
                        }
                    }
                }
            }
        }
    }
}

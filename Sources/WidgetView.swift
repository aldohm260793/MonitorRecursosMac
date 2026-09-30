import AppKit
import ServiceManagement

/// Barra de progreso dibujada a mano
final class ProgressBarView: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var fillColor: NSColor = .systemGreen { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 200, height: 6) }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3)
        NSColor.white.withAlphaComponent(0.12).setFill()
        bg.fill()
        let width = bounds.width * CGFloat(min(max(fraction, 0), 1))
        if width > 0.5 {
            let fg = NSBezierPath(
                roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height),
                xRadius: 3, yRadius: 3
            )
            fillColor.setFill()
            fg.fill()
        }
    }
}

/// Gráfico de líneas para el historial de red
final class LineChartView: NSView {
    var downSeries: [Double] = [] { didSet { needsDisplay = true } }
    var upSeries: [Double] = [] { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 200, height: 44) }

    override func draw(_ dirtyRect: NSRect) {
        // Fondo
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        NSColor.white.withAlphaComponent(0.06).setFill()
        bg.fill()

        let allValues = (downSeries + upSeries)
        guard let maxValue = allValues.max(), maxValue > 0 else { return }

        drawSeries(upSeries, color: .systemOrange, maxValue: maxValue)
        drawSeries(downSeries, color: .systemGreen, maxValue: maxValue)
    }

    private func drawSeries(_ series: [Double], color: NSColor, maxValue: Double) {
        guard series.count > 1 else { return }
        let inset: CGFloat = 3
        let w = bounds.width - inset * 2
        let h = bounds.height - inset * 2
        let step = w / CGFloat(series.count - 1)

        let line = NSBezierPath()
        let area = NSBezierPath()
        for (i, value) in series.enumerated() {
            let x = inset + CGFloat(i) * step
            let y = inset + h * CGFloat(min(value / maxValue, 1))
            if i == 0 {
                line.move(to: NSPoint(x: x, y: y))
                area.move(to: NSPoint(x: x, y: inset))
                area.line(to: NSPoint(x: x, y: y))
            } else {
                line.line(to: NSPoint(x: x, y: y))
                area.line(to: NSPoint(x: x, y: y))
            }
        }
        area.line(to: NSPoint(x: inset + CGFloat(series.count - 1) * step, y: inset))
        area.close()
        color.withAlphaComponent(0.15).setFill()
        area.fill()
        color.withAlphaComponent(0.9).setStroke()
        line.lineWidth = 1.5
        line.stroke()
    }
}

final class WidgetViewController: NSViewController {
    private let monitor: SystemMonitor
    private var pinned = true
    private var isCompact = false
    private var mainStack: NSStackView?
    private var compactRow: NSView?
    private var collapseButton: NSButton?

    // Controles
    private let cpuPercentLabel = NSTextField(labelWithString: "")
    private let cpuBar = ProgressBarView()
    private let thermalLabel = NSTextField(labelWithString: "")

    private let ramPercentLabel = NSTextField(labelWithString: "")
    private let ramBar = ProgressBarView()
    private let ramDetailLabel = NSTextField(labelWithString: "")

    private let disksStack = NSStackView()

    private let downLabel = NSTextField(labelWithString: "")
    private let upLabel = NSTextField(labelWithString: "")
    private let pingLabel = NSTextField(labelWithString: "")
    private let netChart = LineChartView()

    private let kimiPercentLabel = NSTextField(labelWithString: "")
    private let kimiBar = ProgressBarView()
    private let kimiDetailLabel = NSTextField(labelWithString: "")

    // Barra compacta
    private let compactCpuLabel = NSTextField(labelWithString: "")
    private let compactRamLabel = NSTextField(labelWithString: "")
    private let compactNetLabel = NSTextField(labelWithString: "")

    private let speedButton = NSButton(title: "Probar", target: nil, action: nil)
    private let speedResultLabel = NSTextField(labelWithString: "")
    private let speedHintLabel = NSTextField(labelWithString: "Pulsa «Probar» para medir descarga y subida")

    private let loginCheckbox = NSButton(checkboxWithTitle: "Abrir al iniciar sesión", target: nil, action: nil)

    init(monitor: SystemMonitor) {
        self.monitor = monitor
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no soportado") }

    override func loadView() {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.masksToBounds = true
        view = effect

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 300)
        ])

        addFullWidth(headerView(), to: stack)
        let compact = compactBarView()
        addFullWidth(compact, to: stack)
        compact.isHidden = true
        compactRow = compact
        mainStack = stack
        addFullWidth(separator(), to: stack)
        addFullWidth(cpuSection(), to: stack)
        addFullWidth(ramSection(), to: stack)
        addFullWidth(diskSection(), to: stack)
        addFullWidth(networkSection(), to: stack)
        addFullWidth(speedSection(), to: stack)
        addFullWidth(kimiSection(), to: stack)
        addFullWidth(footerView(), to: stack)

        monitor.onChange = { [weak self] in self?.refreshUI() }
        refreshUI()

        #if START_COMPACT
        if let button = collapseButton { toggleCompact(button) }
        #endif
    }

    // MARK: - Secciones

    private func headerView() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6

        let icon = NSImageView(image: NSImage(
            systemSymbolName: "gauge.with.dots.needle.67percent",
            accessibilityDescription: nil
        )!)
        icon.contentTintColor = .systemCyan
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let title = NSTextField(labelWithString: "Monitor de Recursos")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let collapse = NSButton(
            image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Contraer")!,
            target: self, action: #selector(toggleCompact)
        )
        collapse.isBordered = false
        collapse.contentTintColor = .secondaryLabelColor
        collapse.toolTip = "Modo compacto"
        collapseButton = collapse

        let pinButton = NSButton(
            image: NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Fijar")!,
            target: self, action: #selector(togglePin)
        )
        pinButton.isBordered = false
        pinButton.contentTintColor = .systemCyan
        pinButton.toolTip = "Siempre visible"
        pinButton.tag = 1001

        let closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cerrar")!,
            target: self, action: #selector(quitApp)
        )
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Cerrar"

        row.addArrangedSubview(icon)
        row.addArrangedSubview(title)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(collapse)
        row.addArrangedSubview(pinButton)
        row.addArrangedSubview(closeButton)
        return row
    }

    // MARK: - Barra compacta

    private func compactBarView() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12

        for label in [compactCpuLabel, compactRamLabel, compactNetLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            label.textColor = .labelColor
        }
        compactNetLabel.textColor = .systemGreen

        row.addArrangedSubview(compactCpuLabel)
        row.addArrangedSubview(compactRamLabel)
        row.addArrangedSubview(compactNetLabel)
        return row
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func cpuSection() -> NSView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 5

        let top = NSStackView()
        top.orientation = .horizontal
        let title = sectionTitle("CPU", symbol: "cpu")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cpuPercentLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        top.addArrangedSubview(title)
        top.addArrangedSubview(spacer)
        top.addArrangedSubview(cpuPercentLabel)

        let thermalRow = NSStackView()
        thermalRow.orientation = .horizontal
        let thermalTitle = sectionTitle("Temperatura", symbol: "thermometer.medium")
        let spacer2 = NSView()
        spacer2.setContentHuggingPriority(.defaultLow, for: .horizontal)
        thermalLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        thermalRow.addArrangedSubview(thermalTitle)
        thermalRow.addArrangedSubview(spacer2)
        thermalRow.addArrangedSubview(thermalLabel)

        section.addArrangedSubview(top)
        pinWidth(top, to: section)
        section.addArrangedSubview(cpuBar)
        pinWidth(cpuBar, to: section)
        section.addArrangedSubview(thermalRow)
        pinWidth(thermalRow, to: section)
        return section
    }

    private func ramSection() -> NSView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 5

        let top = NSStackView()
        top.orientation = .horizontal
        let title = sectionTitle("Memoria RAM", symbol: "memorychip")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        ramPercentLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        top.addArrangedSubview(title)
        top.addArrangedSubview(spacer)
        top.addArrangedSubview(ramPercentLabel)

        ramDetailLabel.font = .systemFont(ofSize: 10)
        ramDetailLabel.textColor = .secondaryLabelColor

        section.addArrangedSubview(top)
        pinWidth(top, to: section)
        section.addArrangedSubview(ramBar)
        pinWidth(ramBar, to: section)
        section.addArrangedSubview(ramDetailLabel)
        return section
    }

    private func diskSection() -> NSView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8

        disksStack.orientation = .vertical
        disksStack.alignment = .leading
        disksStack.spacing = 8

        section.addArrangedSubview(sectionTitle("Discos", symbol: "internaldrive"))
        section.addArrangedSubview(disksStack)
        pinWidth(disksStack, to: section)
        return section
    }

    private func networkSection() -> NSView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6

        let rates = NSStackView()
        rates.orientation = .horizontal
        downLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        downLabel.textColor = .systemGreen
        upLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        upLabel.textColor = .systemOrange
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rates.addArrangedSubview(labelWithIcon(downLabel, symbol: "arrow.down.circle.fill", color: .systemGreen))
        rates.addArrangedSubview(spacer)
        rates.addArrangedSubview(labelWithIcon(upLabel, symbol: "arrow.up.circle.fill", color: .systemOrange))

        let pingRow = NSStackView()
        pingRow.orientation = .horizontal
        let pingTitle = sectionTitle("Ping", symbol: "antenna.radiowaves.left.and.right")
        let spacer2 = NSView()
        spacer2.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pingLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        pingRow.addArrangedSubview(pingTitle)
        pingRow.addArrangedSubview(spacer2)
        pingRow.addArrangedSubview(pingLabel)

        section.addArrangedSubview(sectionTitle("Red en tiempo real", symbol: "network"))
        section.addArrangedSubview(rates)
        pinWidth(rates, to: section)
        section.addArrangedSubview(netChart)
        pinWidth(netChart, to: section)
        section.addArrangedSubview(pingRow)
        pinWidth(pingRow, to: section)
        return section
    }

    private func speedSection() -> NSView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6

        let top = NSStackView()
        top.orientation = .horizontal
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        speedButton.target = self
        speedButton.action = #selector(runSpeedTest)
        speedButton.bezelStyle = .rounded
        speedButton.controlSize = .small
        speedButton.font = .systemFont(ofSize: 10, weight: .semibold)
        top.addArrangedSubview(sectionTitle("Velocidad de Internet", symbol: "speedometer"))
        top.addArrangedSubview(spacer)
        top.addArrangedSubview(speedButton)

        speedResultLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        speedHintLabel.font = .systemFont(ofSize: 9)
        speedHintLabel.textColor = .tertiaryLabelColor

        section.addArrangedSubview(top)
        pinWidth(top, to: section)
        section.addArrangedSubview(speedResultLabel)
        section.addArrangedSubview(speedHintLabel)
        return section
    }

    private func kimiSection() -> NSView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 5

        let top = NSStackView()
        top.orientation = .horizontal
        let title = sectionTitle("Uso de Kimi", symbol: "moon.stars")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        kimiPercentLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        top.addArrangedSubview(title)
        top.addArrangedSubview(spacer)
        top.addArrangedSubview(kimiPercentLabel)

        kimiDetailLabel.font = .systemFont(ofSize: 10)
        kimiDetailLabel.textColor = .secondaryLabelColor

        section.addArrangedSubview(top)
        pinWidth(top, to: section)
        section.addArrangedSubview(kimiBar)
        pinWidth(kimiBar, to: section)
        section.addArrangedSubview(kimiDetailLabel)
        return section
    }

    private func footerView() -> NSView {
        loginCheckbox.target = self
        loginCheckbox.action = #selector(toggleLoginItem)
        loginCheckbox.font = .systemFont(ofSize: 10)
        loginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        return loginCheckbox
    }

    // MARK: - Actualización de la interfaz

    private func refreshUI() {
        // Barra compacta
        compactCpuLabel.stringValue = "CPU \(Int(monitor.cpuUsage * 100))%"
        compactRamLabel.stringValue = "RAM \(monitor.ramTotal > 0 ? Int(Double(monitor.ramUsed) / Double(monitor.ramTotal) * 100) : 0)%"
        compactNetLabel.stringValue = "⬇ \(SystemMonitor.formatRate(monitor.downloadRate))  ⬆ \(SystemMonitor.formatRate(monitor.uploadRate))"

        // CPU y temperatura
        cpuPercentLabel.stringValue = "\(Int(monitor.cpuUsage * 100))%"
        cpuPercentLabel.textColor = color(for: monitor.cpuUsage)
        cpuBar.fraction = monitor.cpuUsage
        cpuBar.fillColor = color(for: monitor.cpuUsage)
        thermalLabel.stringValue = SystemMonitor.thermalLabel(monitor.thermalState)
        switch monitor.thermalState {
        case .nominal: thermalLabel.textColor = .systemGreen
        case .fair: thermalLabel.textColor = .systemYellow
        default: thermalLabel.textColor = .systemRed
        }

        // RAM
        let ramFraction = monitor.ramTotal > 0
            ? Double(monitor.ramUsed) / Double(monitor.ramTotal) : 0
        ramPercentLabel.stringValue = "\(Int(ramFraction * 100))%"
        ramPercentLabel.textColor = color(for: ramFraction)
        ramBar.fraction = ramFraction
        ramBar.fillColor = color(for: ramFraction)
        ramDetailLabel.stringValue = "Usada: \(SystemMonitor.formatBytes(monitor.ramUsed))   Libre: \(SystemMonitor.formatBytes(monitor.ramFree))   Total: \(SystemMonitor.formatBytes(monitor.ramTotal))"

        // Discos
        disksStack.arrangedSubviews.forEach {
            disksStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        if monitor.disks.isEmpty {
            let empty = NSTextField(labelWithString: "Sin discos detectados")
            empty.font = .systemFont(ofSize: 10)
            empty.textColor = .secondaryLabelColor
            disksStack.addArrangedSubview(empty)
        } else {
            for disk in monitor.disks {
                disksStack.addArrangedSubview(diskRow(disk))
                pinWidth(disksStack.arrangedSubviews.last!, to: disksStack)
            }
        }

        // Red
        downLabel.stringValue = "⬇ \(SystemMonitor.formatRate(monitor.downloadRate))"
        upLabel.stringValue = "⬆ \(SystemMonitor.formatRate(monitor.uploadRate))"
        netChart.downSeries = monitor.downHistory
        netChart.upSeries = monitor.upHistory
        if let ping = monitor.pingMs {
            pingLabel.stringValue = String(format: "%.0f ms", ping)
            pingLabel.textColor = ping < 50 ? .systemGreen : ping < 120 ? .systemYellow : .systemRed
        } else {
            pingLabel.stringValue = "sin respuesta"
            pingLabel.textColor = .systemRed
        }

        // Velocidad
        speedButton.isEnabled = !monitor.speedTestRunning
        speedButton.title = monitor.speedTestRunning ? "Midiendo…" : "Probar"
        if let down = monitor.speedDown {
            let upText = monitor.speedUp.map { String(format: "   ⬆ %.1f Mbps", $0) } ?? ""
            speedResultLabel.stringValue = String(format: "⬇ %.1f Mbps%@", down, upText)
            speedResultLabel.isHidden = false
            speedHintLabel.isHidden = true
        } else if monitor.speedTestRunning {
            speedResultLabel.isHidden = true
            speedHintLabel.isHidden = false
            speedHintLabel.stringValue = "Midiendo velocidad…"
        } else {
            speedResultLabel.isHidden = true
            speedHintLabel.isHidden = false
            speedHintLabel.stringValue = "Pulsa «Probar» para medir descarga y subida"
        }

        // Uso de Kimi (contexto de la conversación activa)
        if monitor.kimiContextAvailable, monitor.kimiContextMax > 0 {
            let fraction = Double(monitor.kimiContextUsed) / Double(monitor.kimiContextMax)
            let remaining = monitor.kimiContextMax - monitor.kimiContextUsed
            kimiPercentLabel.stringValue = "\(Int(fraction * 100))%"
            kimiPercentLabel.textColor = color(for: fraction)
            kimiBar.fraction = fraction
            kimiBar.fillColor = color(for: fraction)
            kimiDetailLabel.stringValue = "Contexto usado: \(formatTokens(monitor.kimiContextUsed))   Te quedan: \(formatTokens(remaining)) tokens"
        } else {
            kimiPercentLabel.stringValue = "—"
            kimiPercentLabel.textColor = .secondaryLabelColor
            kimiBar.fraction = 0
            kimiDetailLabel.stringValue = "Sin datos de uso (abre Kimi Work)"
        }
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1000 {
            return String(format: "%.1fk", Double(tokens) / 1000)
        }
        return "\(tokens)"
    }

    private func diskRow(_ disk: DiskInfo) -> NSView {
        let fraction = disk.total > 0 ? Double(disk.used) / Double(disk.total) : 0
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4

        let top = NSStackView()
        top.orientation = .horizontal
        let name = NSTextField(labelWithString: disk.name)
        name.font = .systemFont(ofSize: 11, weight: .medium)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let detail = NSTextField(labelWithString:
            "\(SystemMonitor.formatBytes(disk.used)) / \(SystemMonitor.formatBytes(disk.total))")
        detail.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        detail.textColor = .secondaryLabelColor
        top.addArrangedSubview(name)
        top.addArrangedSubview(spacer)
        top.addArrangedSubview(detail)

        let bar = ProgressBarView()
        bar.fraction = fraction
        bar.fillColor = color(for: fraction)

        column.addArrangedSubview(top)
        pinWidth(top, to: column)
        column.addArrangedSubview(bar)
        pinWidth(bar, to: column)
        return column
    }

    // MARK: - Acciones

    @objc private func toggleCompact(_ sender: NSButton) {
        isCompact.toggle()
        guard let stack = mainStack, let compact = compactRow else { return }
        for (index, subview) in stack.arrangedSubviews.enumerated() {
            if index == 0 { continue } // el encabezado siempre visible
            subview.isHidden = isCompact ? (subview !== compact) : (subview === compact)
        }
        sender.image = NSImage(
            systemSymbolName: isCompact ? "chevron.down" : "chevron.up",
            accessibilityDescription: isCompact ? "Expandir" : "Contraer"
        )
        sender.toolTip = isCompact ? "Expandir" : "Modo compacto"

        // Redimensionar la ventana manteniendo fijo el borde superior
        view.layoutSubtreeIfNeeded()
        guard let window = view.window else { return }
        let fitting = view.fittingSize
        guard fitting.height > 0 else { return }
        var frame = window.frame
        let deltaHeight = frame.height - fitting.height
        frame.size = fitting
        frame.origin.y += deltaHeight
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            window.animator().setFrame(frame, display: true)
        }
    }

    @objc private func togglePin(_ sender: NSButton) {
        pinned.toggle()
        sender.contentTintColor = pinned ? .systemCyan : .secondaryLabelColor
        sender.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin",
                               accessibilityDescription: "Fijar")
        view.window?.level = pinned ? .floating : .normal
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func runSpeedTest() {
        monitor.runSpeedTest()
    }

    @objc private func toggleLoginItem(_ sender: NSButton) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } catch {
            sender.state = .off
        }
    }

    // MARK: - Utilidades de construcción

    private func sectionTitle(_ text: String, symbol: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 5
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        row.addArrangedSubview(icon)
        row.addArrangedSubview(label)
        return row
    }

    private func labelWithIcon(_ label: NSTextField, symbol: String, color: NSColor) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 4
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = color
        row.addArrangedSubview(icon)
        row.addArrangedSubview(label)
        return row
    }

    private func addFullWidth(_ child: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(child)
        pinWidth(child, to: stack)
    }

    private func pinWidth(_ child: NSView, to container: NSStackView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        child.widthAnchor.constraint(
            equalTo: container.widthAnchor,
            constant: -(container.edgeInsets.left + container.edgeInsets.right)
        ).isActive = true
    }

    private func color(for fraction: Double) -> NSColor {
        if fraction < 0.6 { return .systemGreen }
        if fraction < 0.85 { return .systemYellow }
        return .systemRed
    }
}

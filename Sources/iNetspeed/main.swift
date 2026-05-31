import AppKit
import Foundation

@main
enum iNetspeedApp {
    @MainActor
    private static let delegate = AppDelegate()

    @MainActor
    static func main() {
        let app = NSApplication.shared

        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let speedHistoryCapacity = 1_800
    private static let menuWidth: CGFloat = 300

    private let monitor = NetworkSpeedMonitor()
    private let formatter = SpeedFormatter()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusView = StatusItemView(frame: NSRect(x: 0, y: 0, width: 38, height: NSStatusBar.system.thickness))
    private let perAppMonitor = PerAppTrafficMonitor()

    private var timer: Timer?
    private var latestSnapshot = NetworkSnapshot.empty
    private var speedHistory: [SpeedHistoryPoint] = []
    private var perAppSnapshots: [PerAppSnapshot]?
    private weak var summaryView: SummaryMenuView?
    private weak var appTrafficView: AppTrafficSectionView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        start()
    }

    func start() {
        guard timer == nil else {
            return
        }

        configureStatusItem()
        refreshUI()

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshUI()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    private func configureStatusItem() {
        statusItem.length = 38

        guard let button = statusItem.button else {
            return
        }

        button.title = ""
        button.image = nil
        button.target = self
        button.action = #selector(openMenu)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Network speed"

        statusView.frame = button.bounds
        statusView.autoresizingMask = [.width, .height]
        button.addSubview(statusView)
    }

    private func refreshUI() {
        latestSnapshot = monitor.sample()
        appendHistoryPoint(latestSnapshot)
        statusView.update(download: formatter.menuBar(latestSnapshot.downloadBytesPerSecond),
                          upload: formatter.menuBar(latestSnapshot.uploadBytesPerSecond))
        statusView.toolTip = formatter.tooltip(for: latestSnapshot)

        summaryView?.update(
            download: formatter.full(latestSnapshot.downloadBytesPerSecond),
            upload: formatter.full(latestSnapshot.uploadBytesPerSecond),
            history: speedHistory
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshots = await self.perAppMonitor.sample()
            self.perAppSnapshots = snapshots
            self.appTrafficView?.update(snapshots: snapshots, formatter: self.formatter)
        }
    }

    private func appendHistoryPoint(_ snapshot: NetworkSnapshot) {
        if speedHistory.isEmpty {
            speedHistory = Array(
                repeating: SpeedHistoryPoint(downloadBytesPerSecond: 0, uploadBytesPerSecond: 0),
                count: Self.speedHistoryCapacity
            )
        }

        speedHistory.append(
            SpeedHistoryPoint(
                downloadBytesPerSecond: snapshot.downloadBytesPerSecond,
                uploadBytesPerSecond: snapshot.uploadBytesPerSecond
            )
        )

        if speedHistory.count > Self.speedHistoryCapacity {
            speedHistory.removeFirst(speedHistory.count - Self.speedHistoryCapacity)
        }
    }

    @objc private func openMenu() {
        guard let button = statusItem.button else {
            return
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        populate(menu)
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()

        let sv = SummaryMenuView(
            download: formatter.full(latestSnapshot.downloadBytesPerSecond),
            upload: formatter.full(latestSnapshot.uploadBytesPerSecond),
            history: speedHistory,
            width: Self.menuWidth
        )
        summaryView = sv
        menu.addViewItem(sv, height: SummaryMenuView.menuHeight)
        menu.addItem(.separator())

        let tv = AppTrafficSectionView(width: Self.menuWidth)
        if let snapshots = perAppSnapshots {
            tv.update(snapshots: snapshots, formatter: formatter)
        }
        appTrafficView = tv
        menu.addViewItem(tv, height: AppTrafficSectionView.fixedHeight)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit iNetspeed", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Status Bar View

@MainActor
private final class StatusItemView: NSView {
    private let downloadArrowLabel = StatusItemView.makeArrowLabel("↓")
    private let uploadArrowLabel = StatusItemView.makeArrowLabel("↑")
    private let downloadValueLabel = StatusItemView.makeValueLabel()
    private let uploadValueLabel = StatusItemView.makeValueLabel()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(downloadArrowLabel)
        addSubview(uploadArrowLabel)
        addSubview(downloadValueLabel)
        addSubview(uploadValueLabel)
        update(download: "0B", upload: "0B")
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 38, height: NSStatusBar.system.thickness)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()

        let halfHeight = bounds.height / 2
        let arrowWidth: CGFloat = 9
        let valueWidth = bounds.width - arrowWidth

        uploadArrowLabel.frame = NSRect(x: 0, y: halfHeight - 1, width: arrowWidth, height: halfHeight)
        uploadValueLabel.frame = NSRect(x: arrowWidth, y: halfHeight - 1, width: valueWidth, height: halfHeight)
        downloadArrowLabel.frame = NSRect(x: 0, y: 1, width: arrowWidth, height: halfHeight)
        downloadValueLabel.frame = NSRect(x: arrowWidth, y: 1, width: valueWidth, height: halfHeight)
    }

    func update(download: String, upload: String) {
        downloadValueLabel.stringValue = download
        uploadValueLabel.stringValue = upload
    }

    private static func makeArrowLabel(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.alignment = .left
        label.font = .monospacedDigitSystemFont(ofSize: 8.5, weight: .heavy)
        label.lineBreakMode = .byClipping
        label.textColor = .labelColor
        return label
    }

    private static func makeValueLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.alignment = .right
        label.font = .monospacedDigitSystemFont(ofSize: 8.5, weight: .heavy)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .labelColor
        return label
    }
}

// MARK: - Summary Menu View

@MainActor
private final class SummaryMenuView: NSView {
    static let menuHeight: CGFloat = 120

    private let downloadCaptionLabel = NSTextField(labelWithString: "DOWNLOAD")
    private let uploadCaptionLabel = NSTextField(labelWithString: "UPLOAD")
    private let downloadLabel = NSTextField(labelWithString: "")
    private let uploadLabel = NSTextField(labelWithString: "")
    private let chartStartLabel = NSTextField(labelWithString: "30m ago")
    private let chartEndLabel = NSTextField(labelWithString: "now")
    private let chartView: SpeedHistoryChartView

    init(download: String, upload: String, history: [SpeedHistoryPoint], width: CGFloat) {
        chartView = SpeedHistoryChartView(history: history)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.menuHeight))

        downloadCaptionLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        downloadCaptionLabel.textColor = .systemBlue.withAlphaComponent(0.75)

        uploadCaptionLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        uploadCaptionLabel.textColor = .systemGreen.withAlphaComponent(0.75)

        downloadLabel.stringValue = download
        downloadLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .bold)
        downloadLabel.textColor = .systemBlue

        uploadLabel.stringValue = upload
        uploadLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .bold)
        uploadLabel.textColor = .systemGreen

        for label in [chartStartLabel, chartEndLabel] {
            label.font = .systemFont(ofSize: 8, weight: .regular)
            label.textColor = .quaternaryLabelColor
        }
        chartEndLabel.alignment = .right

        [downloadCaptionLabel, uploadCaptionLabel, downloadLabel, uploadLabel,
         chartView, chartStartLabel, chartEndLabel].forEach(addSubview)
    }

    required init?(coder: NSCoder) { nil }

    func update(download: String, upload: String, history: [SpeedHistoryPoint]) {
        downloadLabel.stringValue = download
        uploadLabel.stringValue = upload
        chartView.update(history: history)
    }

    override func layout() {
        super.layout()

        let width = bounds.width - 24
        let halfWidth = width / 2
        downloadCaptionLabel.frame = NSRect(x: 12, y: 101, width: halfWidth, height: 11)
        uploadCaptionLabel.frame = NSRect(x: 12 + halfWidth, y: 101, width: halfWidth, height: 11)
        downloadLabel.frame = NSRect(x: 12, y: 79, width: halfWidth, height: 18)
        uploadLabel.frame = NSRect(x: 12 + halfWidth, y: 79, width: halfWidth, height: 18)
        chartView.frame = NSRect(x: 12, y: 8, width: width, height: 64)
        chartStartLabel.frame = NSRect(x: 18, y: 12, width: 40, height: 9)
        chartEndLabel.frame = NSRect(x: 12 + width - 30, y: 12, width: 28, height: 9)
    }
}

// MARK: - Speed History Chart

@MainActor
private final class SpeedHistoryChartView: NSView {
    private var cachedBuckets: [SpeedHistoryPoint]
    private var hoverX: CGFloat?
    private let formatter = SpeedFormatter()

    init(history: [SpeedHistoryPoint]) {
        cachedBuckets = SpeedHistoryChartView.makeBuckets(from: history)
        super.init(frame: NSRect(x: 0, y: 0, width: 296, height: 52))
    }

    required init?(coder: NSCoder) { nil }

    func update(history: [SpeedHistoryPoint]) {
        cachedBuckets = SpeedHistoryChartView.makeBuckets(from: history)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        hoverX = convert(event.locationInWindow, from: nil).x
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverX = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let roundedClip = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSColor.separatorColor.withAlphaComponent(0.10).setFill()
        roundedClip.fill()

        let buckets = cachedBuckets
        guard buckets.count > 1 else { return }

        roundedClip.addClip()

        let plotRect = bounds.insetBy(dx: 6, dy: 5)
        let maxValue = max(
            buckets.map(\.downloadBytesPerSecond).max() ?? 0,
            buckets.map(\.uploadBytesPerSecond).max() ?? 0,
            1
        )

        let toRatio = { (v: Double) in CGFloat(min(max(v / maxValue, 0), 1)) }
        let dlValues = buckets.map { toRatio($0.downloadBytesPerSecond) }
        let ulValues = buckets.map { toRatio($0.uploadBytesPerSecond) }

        NSColor.separatorColor.withAlphaComponent(0.18).setStroke()
        let gridPath = NSBezierPath()
        for fraction: CGFloat in [0.25, 0.5, 0.75] {
            let y = (plotRect.minY + plotRect.height * fraction).rounded(.toNearestOrAwayFromZero)
            gridPath.move(to: NSPoint(x: plotRect.minX, y: y))
            gridPath.line(to: NSPoint(x: plotRect.maxX, y: y))
        }
        gridPath.lineWidth = 0.5
        gridPath.stroke()

        drawArea(values: dlValues, color: .systemBlue, in: plotRect)
        drawArea(values: ulValues, color: .systemGreen, in: plotRect)

        if let hoverX {
            let clampedX = max(plotRect.minX, min(hoverX, plotRect.maxX))
            let fraction = (clampedX - plotRect.minX) / plotRect.width
            let index = min(max(Int((fraction * CGFloat(buckets.count - 1)).rounded()), 0), buckets.count - 1)
            drawHoverOverlay(index: index, x: clampedX,
                             bucket: buckets[index],
                             dlY: plotRect.minY + plotRect.height * dlValues[index],
                             ulY: plotRect.minY + plotRect.height * ulValues[index],
                             plotRect: plotRect)
        }
    }

    private func drawHoverOverlay(index: Int, x: CGFloat, bucket: SpeedHistoryPoint,
                                   dlY: CGFloat, ulY: CGFloat, plotRect: NSRect) {
        let line = NSBezierPath()
        line.move(to: NSPoint(x: x, y: plotRect.minY))
        line.line(to: NSPoint(x: x, y: plotRect.maxY))
        line.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        line.stroke()

        for (y, color) in [(dlY, NSColor.systemBlue), (ulY, NSColor.systemGreen)] {
            let r: CGFloat = 2.5
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let tip = NSMutableAttributedString()
        tip.append(NSAttributedString(
            string: "↓ \(formatter.compact(bucket.downloadBytesPerSecond))",
            attributes: [.font: font, .foregroundColor: NSColor.systemBlue]
        ))
        tip.append(NSAttributedString(string: "   ", attributes: [.font: font]))
        tip.append(NSAttributedString(
            string: "↑ \(formatter.compact(bucket.uploadBytesPerSecond))",
            attributes: [.font: font, .foregroundColor: NSColor.systemGreen]
        ))

        let tipSize = tip.size()
        let hPad: CGFloat = 6, vPad: CGFloat = 4
        let tipW = tipSize.width + hPad * 2
        let tipH = tipSize.height + vPad * 2
        let tipX = x + 8 + tipW < plotRect.maxX ? x + 8 : x - 8 - tipW
        let tipY = plotRect.maxY - tipH - 4

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let tipRect = NSRect(x: tipX, y: tipY, width: tipW, height: tipH)
        let tipPath = NSBezierPath(roundedRect: tipRect, xRadius: 4, yRadius: 4)
        (isDark ? NSColor(white: 0.15, alpha: 0.95) : NSColor(white: 0.97, alpha: 0.95)).setFill()
        tipPath.fill()
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        tipPath.lineWidth = 0.5
        tipPath.stroke()
        tip.draw(at: NSPoint(x: tipX + hPad, y: tipY + vPad))
    }

    private func drawArea(values: [CGFloat], color: NSColor, in rect: NSRect) {
        guard values.count > 1 else { return }

        let stepX = rect.width / CGFloat(values.count - 1)
        let points = values.enumerated().map { i, ratio in
            NSPoint(x: rect.minX + CGFloat(i) * stepX, y: rect.minY + rect.height * ratio)
        }

        let linePath = NSBezierPath()
        linePath.move(to: points[0])
        for i in 1..<points.count {
            let cp1 = NSPoint(x: points[i - 1].x + stepX * 0.4, y: points[i - 1].y)
            let cp2 = NSPoint(x: points[i].x - stepX * 0.4, y: points[i].y)
            linePath.curve(to: points[i], controlPoint1: cp1, controlPoint2: cp2)
        }

        guard let fillPath = linePath.copy() as? NSBezierPath else { return }
        fillPath.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        fillPath.line(to: NSPoint(x: rect.minX, y: rect.minY))
        fillPath.close()
        NSGradient(starting: color.withAlphaComponent(0.50), ending: color.withAlphaComponent(0.03))!
            .draw(in: fillPath, angle: 90)

        linePath.lineWidth = 1.5
        linePath.lineCapStyle = .round
        linePath.lineJoinStyle = .round
        color.withAlphaComponent(0.9).setStroke()
        linePath.stroke()
    }

    private static func makeBuckets(from history: [SpeedHistoryPoint]) -> [SpeedHistoryPoint] {
        let targetBucketCount = 72
        guard history.count > targetBucketCount else { return history }

        let bucketSize = Int(ceil(Double(history.count) / Double(targetBucketCount)))
        var buckets: [SpeedHistoryPoint] = []
        var index = 0

        while index < history.count {
            let endIndex = min(index + bucketSize, history.count)
            let slice = history[index..<endIndex]
            buckets.append(SpeedHistoryPoint(
                downloadBytesPerSecond: slice.map(\.downloadBytesPerSecond).max() ?? 0,
                uploadBytesPerSecond: slice.map(\.uploadBytesPerSecond).max() ?? 0
            ))
            index = endIndex
        }

        return buckets
    }
}

// MARK: - Gradient Bar View

@MainActor
private final class TrafficBarView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSColor.controlAccentColor.withAlphaComponent(isDark ? 0.45 : 0.28).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        needsDisplay = true
    }
}

// MARK: - Per-App Traffic Section View

@MainActor
private final class AppTrafficSectionView: NSView {
    private static let headerHeight: CGFloat = 28
    private static let rowHeight: CGFloat = 24
    private static let maxRows = 6
    static let fixedHeight: CGFloat = headerHeight + CGFloat(maxRows) * rowHeight

    private let rows: [AppTrafficRowView]

    init(width: CGFloat) {
        let height = Self.fixedHeight
        rows = (0..<Self.maxRows).map { i in
            let y = height - Self.headerHeight - CGFloat(i + 1) * Self.rowHeight
            return AppTrafficRowView(frame: NSRect(x: 0, y: y, width: width, height: Self.rowHeight))
        }
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let headerLabel = NSTextField(labelWithString: "PER-APP TRAFFIC")
        headerLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.frame = NSRect(x: 12, y: height - Self.headerHeight + 8, width: width - 24, height: 11)
        addSubview(headerLabel)
        rows.forEach(addSubview)
    }

    required init?(coder: NSCoder) { nil }

    func update(snapshots: [PerAppSnapshot], formatter: SpeedFormatter) {
        let display = Array(snapshots.prefix(Self.maxRows))
        let totalSpeed = display.map(\.totalBytesPerSecond).reduce(0, +)
        for (i, row) in rows.enumerated() {
            row.update(snapshot: i < display.count ? display[i] : nil, formatter: formatter, totalSpeed: totalSpeed)
        }
    }
}

@MainActor
private final class AppTrafficRowView: NSView {
    private let barView = TrafficBarView()
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let dlLabel = NSTextField(labelWithString: "")
    private let ulLabel = NSTextField(labelWithString: "")
    private var cachedIconPid: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)

        addSubview(barView)

        let pad: CGFloat = 12
        let iconSize: CGFloat = 16
        let iconGap: CGFloat = 6
        let nameColumnWidth: CGFloat = 120
        let speedWidth: CGFloat = (frame.width - pad * 2 - nameColumnWidth) / 2

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 3.5
        iconView.layer?.masksToBounds = true
        iconView.frame = NSRect(x: pad, y: (frame.height - iconSize) / 2, width: iconSize, height: iconSize)

        nameLabel.font = .systemFont(ofSize: 11, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.frame = NSRect(x: pad + iconSize + iconGap,
                                 y: (frame.height - 13) / 2,
                                 width: nameColumnWidth - iconSize - iconGap,
                                 height: 13)

        dlLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        dlLabel.alignment = .right
        dlLabel.frame = NSRect(x: pad + nameColumnWidth, y: (frame.height - 12) / 2, width: speedWidth, height: 12)

        ulLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        ulLabel.alignment = .right
        ulLabel.frame = NSRect(x: pad + nameColumnWidth + speedWidth, y: (frame.height - 12) / 2, width: speedWidth, height: 12)

        [iconView, nameLabel, dlLabel, ulLabel].forEach(addSubview)
    }

    required init?(coder: NSCoder) { nil }

    func update(snapshot: PerAppSnapshot?, formatter: SpeedFormatter, totalSpeed: Double) {
        if let snapshot {
            let ratio = totalSpeed > 0 ? CGFloat(min(snapshot.totalBytesPerSecond / totalSpeed, 1.0)) : 0
            let barWidth = (bounds.width - 24) * ratio
            barView.frame = NSRect(x: 12, y: 2, width: max(barWidth, 0), height: bounds.height - 4)
            barView.isHidden = barWidth < 1
            barView.needsDisplay = true

            if snapshot.pid != cachedIconPid {
                let appIcon = NSRunningApplication(processIdentifier: pid_t(snapshot.pid))?.icon
                iconView.image = appIcon ?? NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil)
                iconView.contentTintColor = appIcon == nil ? .secondaryLabelColor : nil
                cachedIconPid = snapshot.pid
            }
            let active = snapshot.totalBytesPerSecond > 0
            nameLabel.stringValue = snapshot.processName
            nameLabel.textColor = active ? .labelColor : .tertiaryLabelColor
            dlLabel.stringValue = "↓ \(formatter.compact(snapshot.downloadBytesPerSecond))"
            dlLabel.textColor = snapshot.downloadBytesPerSecond > 0 ? .systemBlue : .quaternaryLabelColor
            ulLabel.stringValue = "↑ \(formatter.compact(snapshot.uploadBytesPerSecond))"
            ulLabel.textColor = snapshot.uploadBytesPerSecond > 0 ? .systemGreen : .quaternaryLabelColor
        } else {
            barView.isHidden = true
            if cachedIconPid != nil {
                iconView.image = nil
                cachedIconPid = nil
            }
            nameLabel.stringValue = ""
            dlLabel.stringValue = "↓  —"
            dlLabel.textColor = .quaternaryLabelColor
            ulLabel.stringValue = "↑  —"
            ulLabel.textColor = .quaternaryLabelColor
        }
    }
}

// MARK: - NSMenu Extension

@MainActor
private extension NSMenu {
    func addViewItem(_ view: NSView, height: CGFloat) {
        let item = NSMenuItem()
        view.frame = NSRect(x: 0, y: 0, width: view.frame.width, height: height)
        item.view = view
        item.isEnabled = false
        addItem(item)
    }
}

// MARK: - Data Models

struct NetworkSnapshot {
    static let empty = NetworkSnapshot(downloadBytesPerSecond: 0, uploadBytesPerSecond: 0)
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double
}

struct SpeedHistoryPoint {
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double
}

struct PerAppSnapshot: Sendable {
    let processName: String
    let pid: Int
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double
    var totalBytesPerSecond: Double { downloadBytesPerSecond + uploadBytesPerSecond }
}

// MARK: - Network Speed Monitor

final class NetworkSpeedMonitor {
    private var previousCounters: [String: InterfaceCounters] = [:]
    private var previousSampleDate: Date?

    func sample() -> NetworkSnapshot {
        let now = Date()
        let counters = InterfaceCounters.readAll()
        let elapsed = max(now.timeIntervalSince(previousSampleDate ?? now), 1)

        var download = 0.0
        var upload = 0.0
        for counter in counters {
            let previous = previousCounters[counter.name]
            download += Double(counter.receivedBytes.delta(from: previous?.receivedBytes)) / elapsed
            upload += Double(counter.sentBytes.delta(from: previous?.sentBytes)) / elapsed
        }

        previousCounters = Dictionary(uniqueKeysWithValues: counters.map { ($0.name, $0) })
        previousSampleDate = now

        return NetworkSnapshot(downloadBytesPerSecond: download, uploadBytesPerSecond: upload)
    }
}

// MARK: - Per-App Traffic Monitor

actor PerAppTrafficMonitor {
    private var previousCounts: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var previousDate: Date?
    private var knownApps: [String: PerAppSnapshot] = [:]
    private var inactiveAppQueue: [String] = []
    private var isSampling = false
    private var lastSnapshots: [PerAppSnapshot] = []
    private var rootPidCache: [String: pid_t] = [:]   // keyed by nettop "name.pid"
    private var appNameCache: [pid_t: String] = [:]   // keyed by root pid

    func sample() async -> [PerAppSnapshot] {
        guard !isSampling else { return lastSnapshots }
        isSampling = true
        defer { isSampling = false }

        let now = Date()
        let elapsed = previousDate.map { max(now.timeIntervalSince($0), 0.5) } ?? 1.0
        let current = await fetchNettopData()

        var activeNames: Set<String> = []
        var grouped: [pid_t: (name: String, dl: Double, ul: Double)] = [:]

        for (key, counts) in current {
            guard let prev = previousCounts[key] else { continue }
            let rxDelta = counts.rx >= prev.rx ? counts.rx - prev.rx : 0
            let txDelta = counts.tx >= prev.tx ? counts.tx - prev.tx : 0
            guard rxDelta > 0 || txDelta > 0 else { continue }

            guard let lastDot = key.lastIndex(of: ".") else { continue }
            let rawName = String(key[key.startIndex..<lastDot])
            let pidStr  = String(key[key.index(after: lastDot)...])
            guard let pid = Int(pidStr) else { continue }

            let root: pid_t
            if let cached = rootPidCache[key] {
                root = cached
            } else {
                root = PerAppTrafficMonitor.rootPid(pid_t(pid))
                rootPidCache[key] = root
            }
            let name: String
            if let cached = appNameCache[root] {
                name = cached
            } else {
                let resolved = PerAppTrafficMonitor.appName(for: root) ?? rawName
                appNameCache[root] = resolved
                name = resolved
            }
            let dl = Double(rxDelta) / elapsed
            let ul = Double(txDelta) / elapsed

            if let existing = grouped[root] {
                grouped[root] = (name: existing.name, dl: existing.dl + dl, ul: existing.ul + ul)
            } else {
                grouped[root] = (name: name, dl: dl, ul: ul)
            }
        }

        // Merge entries that share the same app name (e.g. apps with multiple
        // independent root processes, all direct children of launchd).
        var byName: [String: (pid: pid_t, dl: Double, ul: Double)] = [:]
        for (rootPid, totals) in grouped {
            if let existing = byName[totals.name] {
                byName[totals.name] = (pid: existing.pid, dl: existing.dl + totals.dl, ul: existing.ul + totals.ul)
            } else {
                byName[totals.name] = (pid: rootPid, dl: totals.dl, ul: totals.ul)
            }
        }

        var activeSnapshots: [PerAppSnapshot] = []
        for (name, totals) in byName {
            let snapshot = PerAppSnapshot(
                processName: name,
                pid: Int(totals.pid),
                downloadBytesPerSecond: totals.dl,
                uploadBytesPerSecond: totals.ul
            )
            activeSnapshots.append(snapshot)
            knownApps[name] = snapshot
            activeNames.insert(name)
        }

        var snapshots = activeSnapshots.sorted { $0.totalBytesPerSecond > $1.totalBytesPerSecond }
        let previousDisplayNames = lastSnapshots.map(\.processName)
        let inactiveNames = Set(knownApps.keys).subtracting(activeNames)

        inactiveAppQueue.removeAll { activeNames.contains($0) || knownApps[$0] == nil }
        for name in previousDisplayNames where inactiveNames.contains(name) && !inactiveAppQueue.contains(name) {
            inactiveAppQueue.append(name)
        }
        for name in inactiveNames.sorted() where !inactiveAppQueue.contains(name) {
            inactiveAppQueue.append(name)
        }

        for name in inactiveAppQueue.reversed() {
            guard let last = knownApps[name], !activeNames.contains(name) else { continue }
            snapshots.append(PerAppSnapshot(
                processName: name,
                pid: last.pid,
                downloadBytesPerSecond: 0,
                uploadBytesPerSecond: 0
            ))
        }

        if knownApps.count > 20 {
            let activeCount = activeNames.count
            let inactiveLimit = max(20 - activeCount, 0)
            if inactiveAppQueue.count > inactiveLimit {
                for name in inactiveAppQueue.prefix(inactiveAppQueue.count - inactiveLimit) {
                    knownApps.removeValue(forKey: name)
                }
                inactiveAppQueue.removeFirst(inactiveAppQueue.count - inactiveLimit)
            }
        }

        rootPidCache = rootPidCache.filter { current[$0.key] != nil }
        let activeRoots = Set(grouped.keys)
        appNameCache = appNameCache.filter { activeRoots.contains($0.key) }

        previousCounts = current
        previousDate = now

        lastSnapshots = snapshots
        return lastSnapshots
    }

    private static func rootPid(_ pid: pid_t) -> pid_t {
        var current = pid
        for _ in 0..<8 {
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
            let ppid = info.kp_eproc.e_ppid
            if ppid <= 1 { break }
            current = ppid
        }
        return current
    }

    private static func appName(for pid: pid_t) -> String? {
        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &pathBuf, UInt32(MAXPATHLEN)) > 0 else { return nil }
        let path = pathBuf.withUnsafeBytes { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        for component in path.split(separator: "/") {
            if component.hasSuffix(".app") {
                return String(component.dropLast(4))
            }
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func fetchNettopData() async -> [String: (rx: UInt64, tx: UInt64)] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let pipe = Pipe()
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
                proc.arguments = ["-x", "-n", "-L", "1", "-P"]
                proc.standardOutput = pipe
                proc.standardError = Pipe()

                do {
                    try proc.run()
                    proc.waitUntilExit()
                } catch {
                    continuation.resume(returning: [:])
                    return
                }

                guard let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
                    continuation.resume(returning: [:])
                    return
                }

                var result: [String: (rx: UInt64, tx: UInt64)] = [:]
                for line in output.split(separator: "\n").dropFirst() {
                    let cols = line.split(separator: ",", omittingEmptySubsequences: false)
                    guard cols.count >= 6 else { continue }
                    let key = String(cols[1])
                    guard !key.isEmpty, key.contains("."),
                          let rx = UInt64(cols[4]),
                          let tx = UInt64(cols[5]) else { continue }
                    result[key] = (rx: rx, tx: tx)
                }
                continuation.resume(returning: result)
            }
        }
    }
}

// MARK: - Interface Counters

private struct InterfaceCounters {
    let name: String
    let receivedBytes: UInt64
    let sentBytes: UInt64

    static func readAll() -> [InterfaceCounters] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            return []
        }
        defer {
            freeifaddrs(interfaces)
        }

        var counters: [String: InterfaceCounters] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstInterface

        while let interface = cursor {
            defer {
                cursor = interface.pointee.ifa_next
            }

            guard let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  let data = interface.pointee.ifa_data else {
                continue
            }

            let name = String(cString: interface.pointee.ifa_name)
            guard !name.hasPrefix("lo") else {
                continue
            }

            let networkData = data.assumingMemoryBound(to: if_data.self).pointee
            counters[name] = InterfaceCounters(
                name: name,
                receivedBytes: UInt64(networkData.ifi_ibytes),
                sentBytes: UInt64(networkData.ifi_obytes)
            )
        }

        return Array(counters.values)
    }
}

// MARK: - Speed Formatter

private struct SpeedFormatter {
    private static let units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
    private static let menuBarUnits = ["", "K", "M", "G", "T"]
    private static let compactUnits = ["B/s", "K/s", "M/s", "G/s"]

    private static let intFormatter: NumberFormatter = {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.usesGroupingSeparator = false
        nf.maximumFractionDigits = 0
        nf.minimumFractionDigits = 0
        return nf
    }()

    private static let decimalFormatter: NumberFormatter = {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.usesGroupingSeparator = false
        nf.maximumFractionDigits = 1
        nf.minimumFractionDigits = 0
        return nf
    }()

    private static func string(for value: Double, fractionDigits: Int) -> String {
        let nf = fractionDigits == 0 ? intFormatter : decimalFormatter
        return nf.string(from: NSNumber(value: value)) ?? "\(Int(value))"
    }

    func menuBar(_ bytesPerSecond: Double) -> String {
        var scaledValue = max(bytesPerSecond, 0)
        var unitIndex = 0

        while scaledValue >= 999.5, unitIndex < Self.menuBarUnits.count - 1 {
            scaledValue /= 1024
            unitIndex += 1
        }

        let frac = scaledValue < 10 && unitIndex > 0 ? 1 : 0
        return "\(Self.string(for: scaledValue, fractionDigits: frac))\(Self.menuBarUnits[unitIndex])"
    }

    func tooltip(for snapshot: NetworkSnapshot) -> String {
        "Download \(full(snapshot.downloadBytesPerSecond))\nUpload \(full(snapshot.uploadBytesPerSecond))"
    }

    func full(_ bytesPerSecond: Double) -> String {
        format(bytesPerSecond, units: Self.units, fractionDigits: bytesPerSecond < 1024 * 1024 ? 0 : 1)
    }

    func compact(_ bytesPerSecond: Double) -> String {
        var v = max(bytesPerSecond, 0)
        var i = 0
        while v >= 1024, i < Self.compactUnits.count - 1 {
            v /= 1024
            i += 1
        }
        let frac = v < 10 && i > 0 ? 1 : 0
        return "\(Self.string(for: v, fractionDigits: frac)) \(Self.compactUnits[i])"
    }

    private func format(_ value: Double, units: [String], fractionDigits: Int) -> String {
        var v = max(value, 0)
        var i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        return "\(Self.string(for: v, fractionDigits: fractionDigits)) \(units[i])"
    }
}

private extension UInt64 {
    func delta(from previous: UInt64?) -> UInt64 {
        guard let previous, self >= previous else {
            return 0
        }
        return self - previous
    }
}

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
    private static let menuWidth: CGFloat = 340

    private let monitor = NetworkSpeedMonitor()
    private let formatter = SpeedFormatter()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusView = StatusItemView(frame: NSRect(x: 0, y: 0, width: 44, height: NSStatusBar.system.thickness))
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
        statusItem.length = 44

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

        let footer = FooterMenuView(width: Self.menuWidth, target: self, action: #selector(quit))
        menu.addViewItem(footer, height: FooterMenuView.fixedHeight)
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
        NSSize(width: 44, height: NSStatusBar.system.thickness)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()

        let halfHeight = bounds.height / 2
        let arrowWidth: CGFloat = 10
        let valueWidth = bounds.width - arrowWidth - 1

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
        label.font = .monospacedDigitSystemFont(ofSize: 9, weight: .heavy)
        label.lineBreakMode = .byClipping
        label.textColor = value == "↓" ? .systemBlue : .systemGreen
        return label
    }

    private static func makeValueLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.alignment = .right
        label.font = .monospacedDigitSystemFont(ofSize: 8.8, weight: .bold)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .labelColor
        return label
    }
}

// MARK: - Summary Menu View

@MainActor
private final class SummaryMenuView: NSView {
    static let menuHeight: CGFloat = 144

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
        downloadCaptionLabel.textColor = .systemBlue.withAlphaComponent(0.85)

        uploadCaptionLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        uploadCaptionLabel.textColor = .systemGreen.withAlphaComponent(0.85)

        downloadLabel.stringValue = download
        downloadLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .bold)
        downloadLabel.textColor = .systemBlue

        uploadLabel.stringValue = upload
        uploadLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .bold)
        uploadLabel.textColor = .systemGreen

        for label in [chartStartLabel, chartEndLabel] {
            label.font = .systemFont(ofSize: 9, weight: .medium)
            label.textColor = .tertiaryLabelColor
        }
        chartEndLabel.alignment = .right

        [downloadCaptionLabel, uploadCaptionLabel, downloadLabel, uploadLabel,
         chartView, chartStartLabel, chartEndLabel].forEach(addSubview)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let contentRect = bounds.insetBy(dx: 8, dy: 7)
        let metricsRect = NSRect(x: contentRect.minX + 4, y: 82, width: contentRect.width - 8, height: 48)
        let leftRect = NSRect(x: metricsRect.minX, y: metricsRect.minY, width: (metricsRect.width - 8) / 2, height: metricsRect.height)
        let rightRect = NSRect(x: leftRect.maxX + 8, y: metricsRect.minY, width: leftRect.width, height: metricsRect.height)

        drawMetricBackdrop(leftRect, color: .systemBlue)
        drawMetricBackdrop(rightRect, color: .systemGreen)
    }

    func update(download: String, upload: String, history: [SpeedHistoryPoint]) {
        downloadLabel.stringValue = download
        uploadLabel.stringValue = upload
        chartView.update(history: history)
    }

    override func layout() {
        super.layout()

        let width = bounds.width - 32
        let gap: CGFloat = 8
        let halfWidth = (width - gap) / 2
        downloadCaptionLabel.frame = NSRect(x: 18, y: 114, width: halfWidth - 12, height: 11)
        uploadCaptionLabel.frame = NSRect(x: 18 + halfWidth + gap, y: 114, width: halfWidth - 12, height: 11)
        downloadLabel.frame = NSRect(x: 18, y: 92, width: halfWidth - 12, height: 22)
        uploadLabel.frame = NSRect(x: 18 + halfWidth + gap, y: 92, width: halfWidth - 12, height: 22)
        chartView.frame = NSRect(x: 16, y: 24, width: width, height: 54)
        chartStartLabel.frame = NSRect(x: 20, y: 9, width: 54, height: 12)
        chartEndLabel.frame = NSRect(x: 16 + width - 34, y: 9, width: 34, height: 12)
    }

    private func drawMetricBackdrop(_ rect: NSRect, color: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        color.withAlphaComponent(isDark ? 0.13 : 0.08).setFill()
        path.fill()
        color.withAlphaComponent(isDark ? 0.22 : 0.14).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}

// MARK: - Speed History Chart

@MainActor
private final class SpeedHistoryChartView: NSView {
    private static let targetBucketCount = 72
    private var cachedBuckets: [SpeedHistoryPoint]
    private var cachedDownloadRatios: [CGFloat]
    private var cachedUploadRatios: [CGFloat]
    private var updatesSinceBucketAdvance = 0
    private var hoverX: CGFloat?
    private let formatter = SpeedFormatter()

    init(history: [SpeedHistoryPoint]) {
        let buckets = SpeedHistoryChartView.makeBuckets(from: history)
        let ratios = SpeedHistoryChartView.makeRatios(for: buckets)
        cachedBuckets = buckets
        cachedDownloadRatios = ratios.download
        cachedUploadRatios = ratios.upload
        super.init(frame: NSRect(x: 0, y: 0, width: 296, height: 52))
    }

    required init?(coder: NSCoder) { nil }

    func update(history: [SpeedHistoryPoint]) {
        let buckets = SpeedHistoryChartView.makeBuckets(from: history)
        let bucketAdvanceInterval = max(1, Int(ceil(Double(history.count) / Double(Self.targetBucketCount))))

        if cachedBuckets.count == buckets.count,
           cachedDownloadRatios.count == buckets.count,
           cachedUploadRatios.count == buckets.count,
           let freshBucket = buckets.last {
            updatesSinceBucketAdvance += 1
            if updatesSinceBucketAdvance >= bucketAdvanceInterval {
                cachedBuckets = Array(cachedBuckets.dropFirst()) + [freshBucket]
                updatesSinceBucketAdvance = 0
            } else if !cachedBuckets.isEmpty {
                cachedBuckets[cachedBuckets.count - 1] = freshBucket
            }
        } else if cachedDownloadRatios.count < buckets.count,
                  cachedUploadRatios.count < buckets.count {
            let startIndex = cachedBuckets.count
            cachedBuckets += buckets.dropFirst(startIndex)
            updatesSinceBucketAdvance = 0
        } else {
            cachedBuckets = buckets
            updatesSinceBucketAdvance = 0
        }

        let ratios = SpeedHistoryChartView.makeRatios(for: cachedBuckets)
        cachedDownloadRatios = ratios.download
        cachedUploadRatios = ratios.upload
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
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (isDark ? NSColor(white: 1.0, alpha: 0.055) : NSColor(white: 0.0, alpha: 0.035)).setFill()
        roundedClip.fill()
        NSColor.separatorColor.withAlphaComponent(isDark ? 0.20 : 0.16).setStroke()
        roundedClip.lineWidth = 0.5
        roundedClip.stroke()

        let buckets = cachedBuckets
        guard buckets.count > 1 else { return }

        roundedClip.addClip()

        let plotRect = bounds.insetBy(dx: 6, dy: 5)
        let midY = plotRect.midY.rounded(.toNearestOrAwayFromZero)
        let chartGap: CGFloat = 3
        let uploadRect = NSRect(
            x: plotRect.minX,
            y: midY + chartGap,
            width: plotRect.width,
            height: plotRect.maxY - midY - chartGap
        )
        let downloadRect = NSRect(
            x: plotRect.minX,
            y: plotRect.minY,
            width: plotRect.width,
            height: midY - plotRect.minY - chartGap
        )
        let dlValues = cachedDownloadRatios
        let ulValues = cachedUploadRatios

        drawChartPanel(in: uploadRect, color: .systemGreen)
        drawChartPanel(in: downloadRect, color: .systemBlue)

        let gridPath = NSBezierPath()
        for rect in [uploadRect, downloadRect] {
            let y = rect.midY.rounded(.toNearestOrAwayFromZero)
            gridPath.move(to: NSPoint(x: rect.minX, y: y))
            gridPath.line(to: NSPoint(x: rect.maxX, y: y))
        }
        for index in 1..<4 {
            let x = (plotRect.minX + plotRect.width * CGFloat(index) / 4).rounded(.toNearestOrAwayFromZero)
            gridPath.move(to: NSPoint(x: x, y: plotRect.minY))
            gridPath.line(to: NSPoint(x: x, y: plotRect.maxY))
        }
        gridPath.lineWidth = 0.5
        NSColor.separatorColor.withAlphaComponent(isDark ? 0.15 : 0.12).setStroke()
        gridPath.stroke()

        drawBars(values: ulValues, color: .systemGreen, in: uploadRect, direction: .up)
        drawBars(values: dlValues, color: .systemBlue, in: downloadRect, direction: .down)

        let centerBand = NSBezierPath(rect: NSRect(x: plotRect.minX, y: midY - 1.5, width: plotRect.width, height: 3))
        NSColor.labelColor.withAlphaComponent(isDark ? 0.18 : 0.12).setFill()
        centerBand.fill()

        let centerLine = NSBezierPath()
        centerLine.move(to: NSPoint(x: plotRect.minX, y: midY))
        centerLine.line(to: NSPoint(x: plotRect.maxX, y: midY))
        centerLine.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(isDark ? 0.42 : 0.32).setStroke()
        centerLine.stroke()

        if let hoverX {
            let clampedX = max(plotRect.minX, min(hoverX, plotRect.maxX))
            let fraction = (clampedX - plotRect.minX) / plotRect.width
            let index = min(max(Int((fraction * CGFloat(buckets.count - 1)).rounded()), 0), buckets.count - 1)
            drawHoverOverlay(index: index, x: clampedX,
                             bucket: buckets[index],
                             dlY: downloadRect.maxY - downloadRect.height * dlValues[index],
                             ulY: uploadRect.minY + uploadRect.height * ulValues[index],
                             plotRect: plotRect)
        }
    }

    private func drawHoverOverlay(index: Int, x: CGFloat, bucket: SpeedHistoryPoint,
                                   dlY: CGFloat, ulY: CGFloat, plotRect: NSRect) {
        let line = NSBezierPath()
        line.move(to: NSPoint(x: x, y: plotRect.minY))
        line.line(to: NSPoint(x: x, y: plotRect.maxY))
        line.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.28).setStroke()
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
        (isDark ? NSColor(white: 0.11, alpha: 0.96) : NSColor(white: 1.0, alpha: 0.96)).setFill()
        tipPath.fill()
        NSColor.separatorColor.withAlphaComponent(isDark ? 0.45 : 0.28).setStroke()
        tipPath.lineWidth = 0.5
        tipPath.stroke()
        tip.draw(at: NSPoint(x: tipX + hPad, y: tipY + vPad))
    }

    private enum BarDirection {
        case up
        case down
    }

    private func drawChartPanel(in rect: NSRect, color: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let tintAlpha: CGFloat = isDark ? 0.16 : 0.09
        let washAlpha: CGFloat = isDark ? 0.045 : 0.025

        if let gradient = NSGradient(
            starting: color.withAlphaComponent(tintAlpha),
            ending: NSColor.labelColor.withAlphaComponent(washAlpha)
        ) {
            gradient.draw(in: path, angle: 90)
        } else {
            color.withAlphaComponent(tintAlpha).setFill()
            path.fill()
        }

        NSColor.separatorColor.withAlphaComponent(isDark ? 0.18 : 0.12).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    private func drawBars(values: [CGFloat], color: NSColor, in rect: NSRect, direction: BarDirection) {
        guard values.count > 1 else { return }

        let stepX = rect.width / CGFloat(values.count)
        let barWidth = max(1, floor(stepX * 0.68))
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let baseAlpha: CGFloat = isDark ? 0.45 : 0.42
        let peakAlpha: CGFloat = isDark ? 0.92 : 0.82

        for (index, ratio) in values.enumerated() {
            let height = floor(rect.height * ratio)
            guard height >= 1 else { continue }
            let x = rect.minX + CGFloat(index) * stepX + (stepX - barWidth) / 2
            let y = switch direction {
            case .up:
                rect.minY
            case .down:
                rect.maxY - height
            }
            let barRect = NSRect(x: x, y: y, width: barWidth, height: height)
            let radius = min(min(2.0, barWidth / 2), height / 2)
            let barPath = tipRoundedPath(rect: barRect, radius: radius, direction: direction)
            let startColor = color.withAlphaComponent(direction == .up ? baseAlpha : peakAlpha)
            let endColor = color.withAlphaComponent(direction == .up ? peakAlpha : baseAlpha)

            if let gradient = NSGradient(starting: startColor, ending: endColor) {
                gradient.draw(in: barPath, angle: 90)
            } else {
                color.withAlphaComponent(peakAlpha).setFill()
                barPath.fill()
            }
        }
    }

    private func tipRoundedPath(rect: NSRect, radius r: CGFloat, direction: BarDirection) -> NSBezierPath {
        guard r > 0 else { return NSBezierPath(rect: rect) }
        let path = NSBezierPath()
        switch direction {
        case .up:
            path.move(to: NSPoint(x: rect.minX, y: rect.minY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - r))
            path.appendArc(withCenter: NSPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: 0, endAngle: 90)
            path.line(to: NSPoint(x: rect.minX + r, y: rect.maxY))
            path.appendArc(withCenter: NSPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: 90, endAngle: 180)
            path.close()
        case .down:
            path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.minY + r))
            path.appendArc(withCenter: NSPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: 0, endAngle: -90, clockwise: true)
            path.line(to: NSPoint(x: rect.minX + r, y: rect.minY))
            path.appendArc(withCenter: NSPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: -90, endAngle: 180, clockwise: true)
            path.close()
        }
        return path
    }

    private static func makeBuckets(from history: [SpeedHistoryPoint]) -> [SpeedHistoryPoint] {
        let targetBucketCount = Self.targetBucketCount
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

    private static func makeRatios(for buckets: [SpeedHistoryPoint]) -> (download: [CGFloat], upload: [CGFloat]) {
        let maxDownload = max(buckets.map(\.downloadBytesPerSecond).max() ?? 0, 1)
        let maxUpload = max(buckets.map(\.uploadBytesPerSecond).max() ?? 0, 1)
        let toRatio = { (value: Double, maxValue: Double) in CGFloat(min(max(value / maxValue, 0), 1)) }
        return (
            buckets.map { toRatio($0.downloadBytesPerSecond, maxDownload) },
            buckets.map { toRatio($0.uploadBytesPerSecond, maxUpload) }
        )
    }
}

// MARK: - Gradient Bar View

@MainActor
private final class TrafficBarView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let path = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        let startColor = NSColor.controlAccentColor.withAlphaComponent(isDark ? 0.34 : 0.18)
        let endColor = NSColor.controlAccentColor.withAlphaComponent(isDark ? 0.62 : 0.34)
        if let gradient = NSGradient(starting: startColor, ending: endColor) {
            gradient.draw(in: path, angle: 0)
        } else {
            endColor.setFill()
            path.fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        needsDisplay = true
    }
}

// MARK: - Per-App Traffic Section View

@MainActor
private final class AppTrafficSectionView: NSView {
    private static let headerHeight: CGFloat = 34
    private static let rowHeight: CGFloat = 26
    private static let maxRows = 6
    static let fixedHeight: CGFloat = headerHeight + CGFloat(maxRows) * rowHeight

    private let rows: [AppTrafficRowView]
    private let emptyIconView = NSImageView()
    private let emptyTitleLabel = NSTextField(labelWithString: "Collecting app traffic")
    private let emptySubtitleLabel = NSTextField(labelWithString: "Activity appears here as apps use the network")

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
        headerLabel.frame = NSRect(x: 14, y: height - Self.headerHeight + 16, width: 130, height: 11)

        let downloadHeader = NSTextField(labelWithString: "DOWN")
        downloadHeader.font = .systemFont(ofSize: 8, weight: .semibold)
        downloadHeader.textColor = .tertiaryLabelColor
        downloadHeader.alignment = .right
        downloadHeader.frame = NSRect(x: width - 126, y: height - Self.headerHeight + 16, width: 54, height: 10)

        let uploadHeader = NSTextField(labelWithString: "UP")
        uploadHeader.font = .systemFont(ofSize: 8, weight: .semibold)
        uploadHeader.textColor = .tertiaryLabelColor
        uploadHeader.alignment = .right
        uploadHeader.frame = NSRect(x: width - 70, y: height - Self.headerHeight + 16, width: 56, height: 10)

        [headerLabel, downloadHeader, uploadHeader].forEach(addSubview)
        rows.forEach(addSubview)

        emptyIconView.image = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: nil)
        emptyIconView.contentTintColor = .tertiaryLabelColor
        emptyIconView.imageScaling = .scaleProportionallyUpOrDown

        emptyTitleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        emptyTitleLabel.textColor = .secondaryLabelColor
        emptyTitleLabel.alignment = .center

        emptySubtitleLabel.font = .systemFont(ofSize: 10, weight: .regular)
        emptySubtitleLabel.textColor = .tertiaryLabelColor
        emptySubtitleLabel.alignment = .center

        [emptyIconView, emptyTitleLabel, emptySubtitleLabel].forEach(addSubview)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()

        let centerY = (bounds.height - Self.headerHeight) / 2 - 2
        emptyIconView.frame = NSRect(x: (bounds.width - 24) / 2, y: centerY + 18, width: 24, height: 24)
        emptyTitleLabel.frame = NSRect(x: 24, y: centerY - 2, width: bounds.width - 48, height: 16)
        emptySubtitleLabel.frame = NSRect(x: 24, y: centerY - 20, width: bounds.width - 48, height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 12, y: bounds.height - Self.headerHeight + 5.5))
        line.line(to: NSPoint(x: bounds.width - 12, y: bounds.height - Self.headerHeight + 5.5))
        line.lineWidth = 0.5
        NSColor.separatorColor.withAlphaComponent(isDark ? 0.18 : 0.12).setStroke()
        line.stroke()
    }

    func update(snapshots: [PerAppSnapshot], formatter: SpeedFormatter) {
        let display = Array(snapshots.prefix(Self.maxRows))
        let totalSpeed = display.map(\.totalBytesPerSecond).reduce(0, +)
        for (i, row) in rows.enumerated() {
            row.update(snapshot: i < display.count ? display[i] : nil, formatter: formatter, totalSpeed: totalSpeed)
        }

        let isEmpty = display.isEmpty
        emptyIconView.isHidden = !isEmpty
        emptyTitleLabel.isHidden = !isEmpty
        emptySubtitleLabel.isHidden = !isEmpty
        if isEmpty {
            emptyTitleLabel.stringValue = "No app traffic yet"
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
    private var hasContent = false
    private var isActive = false

    override init(frame: NSRect) {
        super.init(frame: frame)

        addSubview(barView)

        let pad: CGFloat = 12
        let iconSize: CGFloat = 17
        let iconGap: CGFloat = 7
        let nameColumnWidth: CGFloat = 150
        let speedWidth: CGFloat = (frame.width - pad * 2 - nameColumnWidth) / 2

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 4
        iconView.layer?.masksToBounds = true
        iconView.frame = NSRect(x: pad, y: (frame.height - iconSize) / 2, width: iconSize, height: iconSize)

        nameLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard hasContent else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let rowRect = bounds.insetBy(dx: 8, dy: 2)
        let rowPath = NSBezierPath(roundedRect: rowRect, xRadius: 6, yRadius: 6)
        let alpha: CGFloat = isActive ? (isDark ? 0.055 : 0.035) : (isDark ? 0.025 : 0.018)
        NSColor.labelColor.withAlphaComponent(alpha).setFill()
        rowPath.fill()

        NSColor.separatorColor.withAlphaComponent(isDark ? 0.12 : 0.08).setStroke()
        rowPath.lineWidth = 0.5
        rowPath.stroke()
    }

    func update(snapshot: PerAppSnapshot?, formatter: SpeedFormatter, totalSpeed: Double) {
        if let snapshot {
            hasContent = true
            let ratio = totalSpeed > 0 ? CGFloat(min(snapshot.totalBytesPerSecond / totalSpeed, 1.0)) : 0
            let barWidth = (bounds.width - 24) * ratio
            barView.frame = NSRect(x: 12, y: 4, width: max(barWidth, 0), height: bounds.height - 8)
            barView.isHidden = barWidth < 1
            barView.needsDisplay = true

            if snapshot.pid != cachedIconPid {
                let appIcon = NSRunningApplication(processIdentifier: pid_t(snapshot.pid))?.icon
                iconView.image = appIcon ?? NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil)
                iconView.contentTintColor = appIcon == nil ? .secondaryLabelColor : nil
                cachedIconPid = snapshot.pid
            }
            let active = snapshot.totalBytesPerSecond > 0
            isActive = active
            nameLabel.stringValue = snapshot.processName
            nameLabel.textColor = active ? .labelColor : .tertiaryLabelColor
            iconView.alphaValue = active ? 1.0 : 0.45
            dlLabel.stringValue = "↓ \(formatter.compact(snapshot.downloadBytesPerSecond))"
            dlLabel.textColor = snapshot.downloadBytesPerSecond > 0 ? .systemBlue : .quaternaryLabelColor
            ulLabel.stringValue = "↑ \(formatter.compact(snapshot.uploadBytesPerSecond))"
            ulLabel.textColor = snapshot.uploadBytesPerSecond > 0 ? .systemGreen : .quaternaryLabelColor
            needsDisplay = true
        } else {
            hasContent = false
            isActive = false
            barView.isHidden = true
            if cachedIconPid != nil {
                iconView.image = nil
                cachedIconPid = nil
            }
            iconView.alphaValue = 1
            nameLabel.stringValue = ""
            dlLabel.stringValue = "↓  —"
            dlLabel.textColor = .quaternaryLabelColor
            ulLabel.stringValue = "↑  —"
            ulLabel.textColor = .quaternaryLabelColor
            needsDisplay = true
        }
    }
}

// MARK: - Footer Menu View

@MainActor
private final class FooterMenuView: NSView {
    static let fixedHeight: CGFloat = 46

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "iNetspeed")
    private let subtitleLabel = NSTextField(labelWithString: "Live network monitor")
    private let quitButton = NSButton(title: "Quit", target: nil, action: nil)

    init(width: CGFloat, target: AnyObject, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.fixedHeight))

        iconView.image = NSImage(systemSymbolName: "speedometer", accessibilityDescription: nil)
        iconView.contentTintColor = .controlAccentColor
        iconView.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .labelColor

        subtitleLabel.font = .systemFont(ofSize: 9, weight: .medium)
        subtitleLabel.textColor = .tertiaryLabelColor

        quitButton.target = target
        quitButton.action = action
        quitButton.bezelStyle = .rounded
        quitButton.controlSize = .small
        quitButton.font = .systemFont(ofSize: 11, weight: .medium)
        quitButton.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Quit")
        quitButton.imagePosition = .imageLeading
        quitButton.contentTintColor = .secondaryLabelColor

        [iconView, titleLabel, subtitleLabel, quitButton].forEach(addSubview)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()

        iconView.frame = NSRect(x: 14, y: 13, width: 20, height: 20)
        titleLabel.frame = NSRect(x: 42, y: 22, width: 120, height: 14)
        subtitleLabel.frame = NSRect(x: 42, y: 10, width: 140, height: 12)
        quitButton.frame = NSRect(x: bounds.width - 78, y: 10, width: 64, height: 26)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let background = NSBezierPath(rect: bounds)
        NSColor.labelColor.withAlphaComponent(isDark ? 0.018 : 0.012).setFill()
        background.fill()

        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: 12, y: bounds.height - 0.5))
        separator.line(to: NSPoint(x: bounds.width - 12, y: bounds.height - 0.5))
        separator.lineWidth = 0.5
        NSColor.separatorColor.withAlphaComponent(isDark ? 0.22 : 0.18).setStroke()
        separator.stroke()
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
    private static let ignoredAppNames: Set<String> = [
        "charles",
        "clash verge",
        "clashx",
        "little snitch",
        "proxyman",
        "shadowrocket",
        "surge",
        "tailscale",
        "tunnelblick",
        "v2rayu",
        "wireguard"
    ]

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
            guard !PerAppTrafficMonitor.shouldIgnoreApp(named: name) else { continue }

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

    private static func shouldIgnoreApp(named name: String) -> Bool {
        ignoredAppNames.contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
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
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let pipe = Pipe()
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
                let args = ["-x", "-n", "-L", "1", "-P"]
                proc.arguments = args
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

    static func isVirtual(_ name: String) -> Bool {
        name.hasPrefix("lo") || name.hasPrefix("utun") || name.hasPrefix("ppp") || name.hasPrefix("ipsec")
    }

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
            guard !InterfaceCounters.isVirtual(name) else {
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

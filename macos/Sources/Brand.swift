import AppKit

/// 两端共用的定稿图标与字标；PDF 保留 SVG 轮廓，不依赖本机字体。
final class BrandHeader: NSView {
    private static func image(_ name: String) -> NSImage? {
        Bundle.main.resourceURL.flatMap { NSImage(contentsOf: $0.appendingPathComponent(name)) }
    }
    /// ImageGen 生成的单色 OM；按主体范围取样，保留透明边缘抗锯齿。
    private static let statusIcon: NSImage? = {
        guard let source = image("MenuBarOM.png") else { return nil }
        let result = NSImage(size: NSSize(width: 24, height: 18), flipped: false) { _ in
            // 原图1648×954；主体像素范围 x145…1464、y119…851（从上向下）。
            let sourceRect = NSRect(x: 145, y: 103, width: 1319, height: 732)
            let size = NSSize(width: 22, height: 22 * 732 / 1319)
            source.draw(in: NSRect(x: 1, y: (18 - size.height) / 2, width: size.width, height: size.height),
                        from: sourceRect, operation: .sourceOver, fraction: 1,
                        respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            return true
        }
        result.isTemplate = true
        result.accessibilityDescription = "OneMore · 语音输入"
        return result
    }()
    static func menuIcon() -> NSImage? { statusIcon }
    init(compact: Bool = false) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(); icon.image = Self.image("AppIcon.png")
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel("OneMore 图标")
        let wordmark = NSImageView(); wordmark.image = Self.image("OneMore-wordmark.pdf")
        wordmark.image?.isTemplate = true
        wordmark.contentTintColor = AppTheme.color(NSColor(srgbRed: 0.345, green: 0.38, blue: 0.431, alpha: 1), .init(white: 0.88, alpha: 1))
        wordmark.imageScaling = .scaleProportionallyUpOrDown
        wordmark.setAccessibilityLabel("OneMore")
        let subtitle = note("又一个语音输入法", size: compact ? 10.5 : 11.5)
        let words = stack([wordmark, subtitle], spacing: 3)
        let row = NSStackView(views: [icon, words]); row.spacing = 6; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: compact ? 146 : 174), heightAnchor.constraint(equalToConstant: compact ? 44 : 56),
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: compact ? 44 : 56), icon.heightAnchor.constraint(equalToConstant: compact ? 44 : 56),
            wordmark.widthAnchor.constraint(equalToConstant: compact ? 96 : 112), wordmark.heightAnchor.constraint(equalToConstant: compact ? 18 : 21)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

import AppKit

/// 与 NoASR 字标共用色相；文字使用深浅两档，保持对比度。
enum BrandPalette {
    static let green = NSColor(srgbRed: 0, green: 191.0/255, blue: 152.0/255, alpha: 1)
    static let greenHover = NSColor(srgbRed: 0, green: 170.0/255, blue: 135.0/255, alpha: 1)
    static let ink = NSColor(srgbRed: 7.0/255, green: 60.0/255, blue: 50.0/255, alpha: 1)
    static let accent = AppTheme.color(AppTheme.rgb(0, 138.0/255, 111.0/255), AppTheme.rgb(37.0/255, 221.0/255, 181.0/255))
}

/// 两端共用的定稿图标与字标；PDF 保留 SVG 轮廓，不依赖本机字体。
final class BrandHeader: NSView {
    private let wordmark = NSImageView()
    private static func image(_ name: String) -> NSImage? {
        Bundle.main.resourceURL.flatMap { NSImage(contentsOf: $0.appendingPathComponent(name)) }
    }
    /// 透明单色 N 与声波镂空，作为系统菜单栏模板图像。
    private static let statusIcon: NSImage? = {
        guard let result = image("MenuBarNoASR.png") else { return nil }
        result.size = NSSize(width: 16, height: 14.4)
        result.isTemplate = true
        result.accessibilityDescription = "NoASR · 语音输入"
        return result
    }()
    static func menuIcon() -> NSImage? { statusIcon }
    init(compact: Bool = false) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        refreshWordmark()
        wordmark.imageScaling = .scaleProportionallyUpOrDown
        wordmark.setAccessibilityLabel("NoASR")
        let subtitle = note("Omni全模态语音输入法", size: 11)
        subtitle.maximumNumberOfLines = 1
        let row = stack([wordmark, subtitle], spacing: 4)
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: compact ? 146 : 174), heightAnchor.constraint(equalToConstant: compact ? 48 : 56),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: compact ? 0 : 16), row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            wordmark.widthAnchor.constraint(equalToConstant: 124), wordmark.heightAnchor.constraint(equalToConstant: 29)
        ])
    }
    private func refreshWordmark() {
        wordmark.image = Self.image(AppTheme.dark(effectiveAppearance) ? "NoASR-wordmark-dark.pdf" : "NoASR-wordmark.pdf")
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshWordmark() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshWordmark() }
    required init?(coder: NSCoder) { fatalError() }
}

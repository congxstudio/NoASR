import AppKit
import AVFoundation
import ApplicationServices
import ImageIO

func label(_ text: String, size: CGFloat = 13, bold: Bool = false) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = NSFont(name: bold ? "PingFangSC-Semibold" : "PingFangSC-Regular", size: size) ?? .systemFont(ofSize: size)
    field.textColor = Glass.text
    return field
}
/// 次要说明文字:灰色、可换行。
func note(_ text: String, size: CGFloat = 12) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = NSFont(name: "PingFangSC-Regular", size: size) ?? .systemFont(ofSize: size); field.textColor = Glass.secondary
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
}
func stack(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
    let result = NSStackView(views: views); result.orientation = .vertical
    result.alignment = .leading; result.spacing = spacing
    return result
}
func host(_ content: NSView, in window: NSWindow, margin: CGFloat = 24) {
    guard let view = window.contentView else { return }
    content.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(content)
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
        content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),
        content.topAnchor.constraint(equalTo: view.topAnchor, constant: margin),
        content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -margin)
    ])
}
/// 默认安装尺寸与最小尺寸分开；设置和初始化使用同一默认尺寸。
enum AppWindowLayout {
    static let minimum = NSSize(width: 820, height: 550)
    static var initialSize: NSSize {
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        return NSSize(width: min(890, max(minimum.width, visible.width - 48)),
                      height: min(660, max(minimum.height, visible.height - 48)))
    }
}
func makeWindow(title: String, width: CGFloat, height: CGFloat) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled,.closable], backing: .buffered, defer: false)
    window.title = title; window.isReleasedWhenClosed = false; window.center()
    return window
}
func showWindow(_ controller: NSWindowController) {
    if controller.window?.isMiniaturized == true { controller.window?.deminiaturize(nil) }
    controller.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
    controller.window?.makeKeyAndOrderFront(nil)
}
/// AppKit 原生外观负责系统材质；动态颜色和图层分别响应外观变化。
enum AppTheme {
    static func apply(_ mode: String) {
        let name: NSAppearance.Name? = mode == "dark" ? .darkAqua : (mode == "light" ? .aqua : nil)
        if NSApp.appearance?.name != name { NSApp.appearance = name.flatMap { NSAppearance(named: $0) } }
    }
    static func dark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
    static func color(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in self.dark(appearance) ? dark : light }
    }
    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
    static var veil: NSColor { color(rgb(0.98, 0.98, 0.988, Glass.params.windowOverlay), rgb(0.07, 0.09, 0.13, 0.40)) }
    static var sidebar: NSColor { color(.white.withAlphaComponent(Glass.params.sidebarOverlay), rgb(0.04, 0.06, 0.09, 0.20)) }
    static var input: NSColor { color(.white.withAlphaComponent(0.24), rgb(0.08, 0.11, 0.16, 0.32)) }
    static var border: NSColor { color(.white.withAlphaComponent(0.9), .white.withAlphaComponent(0.14)) }
}
/// CALayer 不会自动解析动态色，必须在视图外观改变时重新取 CGColor。
final class ThemeSurface: NSView {
    var fill: () -> NSColor = { .clear }
    var stroke: () -> NSColor = { .clear }
    init(fill: @escaping () -> NSColor, stroke: @escaping () -> NSColor = { .clear }) {
        self.fill = fill; self.stroke = stroke
        super.init(frame: .zero); wantsLayer = true; refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    func refresh() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer?.backgroundColor = fill().cgColor; layer?.borderColor = stroke().cgColor
            CATransaction.commit()
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh() }
}
/// Liquid Glass 风格(随外观切换):半透明白玻璃、细白边、柔和投影;窗口底层透出壁纸。
enum Glass {
    // 取自网页稿的 CSS:h3 #5e656a、p #9098a1、h1 #989fa9、h2 #6f747b。
    static let text = AppTheme.color(NSColor(srgbRed: 0.369, green: 0.396, blue: 0.416, alpha: 1), AppTheme.rgb(0.87, 0.9, 0.94))        // h3 #5e656a
    static let secondary = AppTheme.color(NSColor(srgbRed: 0.565, green: 0.596, blue: 0.631, alpha: 1), AppTheme.rgb(0.61, 0.66, 0.73))   // p #9098a1
    static let control = AppTheme.color(NSColor(srgbRed: 0.439, green: 0.463, blue: 0.482, alpha: 1), AppTheme.rgb(0.8, 0.85, 0.91))     // 按钮/分段文字 #70767b
    static let title = AppTheme.color(NSColor(srgbRed: 0.596, green: 0.623, blue: 0.663, alpha: 1), AppTheme.rgb(0.91, 0.94, 0.98))
    static let section = AppTheme.color(NSColor(srgbRed: 0.435, green: 0.455, blue: 0.482, alpha: 1), AppTheme.rgb(0.82, 0.87, 0.94))
    static let segmentOn = AppTheme.color(NSColor(srgbRed: 0.361, green: 0.412, blue: 0.443, alpha: 1), AppTheme.rgb(0.91, 0.96, 1))
    static func style(_ layer: CALayer, alpha: CGFloat = 0.62, radius: CGFloat = 14, shadow: Bool = true) {
        layer.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
        layer.borderColor = NSColor.white.withAlphaComponent(0.92).cgColor; layer.borderWidth = 1
        layer.cornerRadius = radius; layer.masksToBounds = false
        layer.shadowColor = NSColor(srgbRed: 0.24, green: 0.31, blue: 0.47, alpha: 1).cgColor
        layer.shadowOpacity = shadow ? 0.12 : 0; layer.shadowOffset = CGSize(width: 0, height: -3); layer.shadowRadius = 9
    }
    static func clear(_ layer: CALayer) {
        layer.backgroundColor = NSColor.clear.cgColor; layer.borderWidth = 0; layer.shadowOpacity = 0
    }
}
/// 可调的玻璃参数:默认值即当前版本的取值;改动保存在本机 glass.json,下次启动沿用。
struct GlassParams: Codable {
    // 以下默认值全部来自网页稿 getComputedStyle 实测(网页 1rem=10.89px),再按窗口尺寸比例 0.88 换算。
    // 保留旧调参文件的字段兼容性;薄层表面不再依赖系统卡片样式。
    var clearStyle = true
    var interactive = false
    var cardAlpha = 0.35, cardRadius = 17.7          // .glass: 渐变 .35→.22, 1px 白 88%, radius 20.15px
    var buttonAlpha = 0.40, buttonRadius = 12.0      // .change/.keycap: 渐变 .40→.30(灰), 1.5px 白 95%, radius 13.6px
    var keycapAlpha = 0.40, keycapRadius = 12.0
    var sidebarAlpha = 0.22, sidebarRadius = 14.4    // .nav-item.selected: 白 22%, 1.5px 白 93%, radius 16.3px
    var pillAlpha = 0.67, pillRadius = 11.5          // .segments .active: rgb(239,249,255) 67%, 1.5px 白, radius 13.07px
    var windowOverlay = 0.26       // 整窗底层的白色蒙层(网页 .app-window background rgba(250,250,252,.26))
    var contentOverlay = 0.0
    var sidebarOverlay = 0.12      // 网页 .sidebar rgba(234,237,240,.12)
    var windowHeight = 550.0
    var borderWidth = 1.5, borderAlpha = 0.95
    var windowRadius = 22.0, edgeWidth = 1.5, edgeAlpha = 0.95, glowWidth = 10.0, glowAlpha = 0.6
    static let file = Paths.data.appendingPathComponent("glass.json")
    static func load() -> GlassParams {
        guard let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(GlassParams.self, from: data) else { return GlassParams() }
        return value
    }
    func save() {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: GlassParams.file, options: .atomic)
    }
}
enum GlassRole { case card, button, keycap, sidebar, pill }
extension Glass {
    static var params = GlassParams.load()
    private static let registry = NSHashTable<GlassView>.weakObjects()
    static var onParamsChange: (() -> Void)?
    static func register(_ view: GlassView) { registry.add(view) }
    /// 参数改动后,所有玻璃块立刻按新参数重绘。
    static func applyAll() { for view in registry.allObjects { view.apply() }; onParamsChange?() }
    static func alpha(for role: GlassRole) -> CGFloat {
        switch role { case .card: return params.cardAlpha; case .button: return params.buttonAlpha; case .keycap: return params.keycapAlpha; case .sidebar: return params.sidebarAlpha; case .pill: return params.pillAlpha }
    }
    static func radius(for role: GlassRole) -> CGFloat {
        switch role { case .card: return params.cardRadius; case .button: return params.buttonRadius; case .keycap: return params.keycapRadius; case .sidebar: return params.sidebarRadius; case .pill: return params.pillRadius }
    }
}
/// 窗口最外圈的亮白边和内发光(照网页稿的 border + inset box-shadow),盖在所有内容上面,不接鼠标。
final class EdgeGlowView: NSView {
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    var radiusOverride: CGFloat?
    var glowWidthOverride: Double?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let params = Glass.params
        let dim: CGFloat = AppTheme.dark(effectiveAppearance) ? 0.20 : 1
        let radius = radiusOverride ?? CGFloat(params.windowRadius)
        let glowWidth = glowWidthOverride ?? params.glowWidth
        let clip = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        clip.addClip()
        if AppTheme.dark(effectiveAppearance) {
            drawNightEdge(radius: radius, glowWidth: min(6, glowWidth))
            return
        }
        if params.glowAlpha > 0 && glowWidth > 0 {
            // 直接画在边框内:外部阴影会被 NSView 的 backing surface 裁掉。
            let steps = max(1, Int(glowWidth * 2))
            for step in 0..<steps {
                let inset = CGFloat(params.edgeWidth) + CGFloat(step) * 0.5
                let rect = bounds.insetBy(dx: inset, dy: inset)
                guard rect.width > 0, rect.height > 0 else { break }
                let path = NSBezierPath(roundedRect: rect, xRadius: max(0, radius - inset), yRadius: max(0, radius - inset))
                path.lineWidth = 1
                let fade = exp(-Double(step) / max(1, glowWidth * 0.55))
                NSColor.white.withAlphaComponent(CGFloat(min(1, params.glowAlpha * 0.8) * fade) * dim).setStroke()
                path.stroke()
            }
        }
        if params.edgeWidth > 0 {
            let inset = CGFloat(params.edgeWidth) / 2
            let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: radius - inset, yRadius: radius - inset)
            edge.lineWidth = CGFloat(params.edgeWidth); NSColor.white.withAlphaComponent(CGFloat(params.edgeAlpha) * dim).setStroke(); edge.stroke()
        }
    }
    /// 单色冷夜蓝反光：窄范围柔和衰减，不形成彩色灯带。
    private func drawNightEdge(radius: CGFloat, glowWidth: Double) {
        func ring(inset: CGFloat, width: CGFloat, opacity: CGFloat) {
            let outer = bounds.insetBy(dx: inset, dy: inset)
            let inner = outer.insetBy(dx: width, dy: width)
            guard inner.width > 0, inner.height > 0 else { return }
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let mask = NSBezierPath(roundedRect: outer, xRadius: max(0, radius - inset), yRadius: max(0, radius - inset))
            mask.append(NSBezierPath(roundedRect: inner, xRadius: max(0, radius - inset - width), yRadius: max(0, radius - inset - width)))
            mask.windingRule = .evenOdd; mask.addClip()
            AppTheme.rgb(0.27, 0.48, 0.76, opacity).setFill()
            outer.fill()
        }
        ring(inset: 0.35, width: 0.7, opacity: 0.30)
        for step in 0..<max(0, Int(glowWidth * 2)) {
            ring(inset: 1.05 + CGFloat(step) * 0.5, width: 0.5,
                 opacity: 0.15 * CGFloat(exp(-pow(Double(step) * 0.5 / (glowWidth * 0.43), 2))))
        }
    }
}
/// 玻璃块:在窗口原生毛玻璃上绘制薄透表面,避免每张卡片再次染白。
/// 子视图一律加到 content 里,不要直接加到它身上。参数见 GlassParams。
final class GlassView: NSView {
    let content = NSView()
    let role: GlassRole
    var opaqueSurface = false { didSet { apply() } }
    var gradientOverride: [CGColor]? { didSet { apply() } }
    private let gradient = CAGradientLayer()
    private let highlight = InsetHighlightLayer()
    private let highlightMask = CAShapeLayer()
    init(role: GlassRole) {
        self.role = role
        super.init(frame: .zero); wantsLayer = true
        content.translatesAutoresizingMaskIntoConstraints = false
        gradient.startPoint = CGPoint(x: 0.1, y: 1); gradient.endPoint = CGPoint(x: 0.9, y: 0)
        highlight.mask = highlightMask
        layer?.addSublayer(gradient); layer?.addSublayer(highlight)
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        apply(); Glass.register(self)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let radius = Glass.radius(for: role)
        gradient.frame = bounds; gradient.cornerRadius = radius
        // 顶部内高光:6px 高的渐隐带,裁在圆角里
        highlight.frame = CGRect(x: 0, y: bounds.height - 6, width: bounds.width, height: 6)
        highlightMask.frame = CGRect(x: 0, y: -(bounds.height - 6), width: bounds.width, height: bounds.height)
        highlightMask.path = CGPath(roundedRect: CGRect(x: 1.5, y: 1.5, width: max(0, bounds.width - 3), height: max(0, bounds.height - 3)), cornerWidth: max(0, radius - 1.5), cornerHeight: max(0, radius - 1.5), transform: nil)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); apply() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
    func apply() {
        effectiveAppearance.performAsCurrentDrawingAppearance { renderSurface() }
    }
    private func renderSurface() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let alpha = Glass.alpha(for: role), radius = Glass.radius(for: role)
        if let layer {
            highlight.opacity = 1
            switch role {
            case .card:
                // 网页 .glass: 白色 .35 → 暖白 .22,只加内高光,不投下厚重阴影。
                gradient.colors = [NSColor.white.withAlphaComponent(alpha).cgColor,
                    NSColor(srgbRed: 0.98, green: 0.973, blue: 0.969, alpha: alpha * 0.63).cgColor]
                layer.borderWidth = 0.8
                layer.borderColor = NSColor.white.withAlphaComponent(0.88).cgColor
                layer.shadowOpacity = 0
                highlight.opacity = 0.45
            case .pill:
                // .segments button.active: background rgba(239,249,255,.67); border 1.5px #fff;
                // box-shadow inset 0 2px 5px #fff, 0 5px 10px rgba(130,149,164,.1)
                gradient.colors = [NSColor(srgbRed: 0.937, green: 0.976, blue: 1.0, alpha: alpha).cgColor, NSColor(srgbRed: 0.937, green: 0.976, blue: 1.0, alpha: alpha).cgColor]
                layer.borderWidth = 1.5; layer.borderColor = NSColor.white.cgColor
                layer.shadowColor = NSColor(srgbRed: 0.51, green: 0.584, blue: 0.643, alpha: 1).cgColor
                layer.shadowOpacity = 0.10; layer.shadowOffset = CGSize(width: 0, height: -5); layer.shadowRadius = 5
            case .sidebar:
                // .nav-item.selected: background rgba(255,255,255,.22); border 1.5px rgba(255,255,255,.93);
                // box-shadow inset 0 2px 4px #fff, 0 3px 10px rgba(143,165,179,.1)
                gradient.colors = [NSColor.white.withAlphaComponent(alpha).cgColor, NSColor.white.withAlphaComponent(alpha).cgColor]
                layer.borderWidth = 1.5; layer.borderColor = NSColor.white.withAlphaComponent(0.93).cgColor
                layer.shadowColor = NSColor(srgbRed: 0.561, green: 0.647, blue: 0.702, alpha: 1).cgColor
                layer.shadowOpacity = 0.10; layer.shadowOffset = CGSize(width: 0, height: -3); layer.shadowRadius = 5
            default:
                // .keycap/.change: background linear-gradient(140deg, rgba(255,255,255,.4), rgba(222,225,228,.3));
                // border 1.5px rgba(255,255,255,.95); box-shadow inset 0 2px 5px #fff, 0 3px 7px rgba(130,144,155,.137)
                gradient.colors = [NSColor.white.withAlphaComponent(alpha).cgColor, NSColor(srgbRed: 0.871, green: 0.882, blue: 0.894, alpha: max(0, alpha - 0.1)).cgColor]
                layer.borderWidth = Glass.params.borderWidth; layer.borderColor = NSColor.white.withAlphaComponent(Glass.params.borderAlpha).cgColor
                layer.shadowColor = NSColor(srgbRed: 0.51, green: 0.565, blue: 0.608, alpha: 1).cgColor
                layer.shadowOpacity = 0.137; layer.shadowOffset = CGSize(width: 0, height: -3); layer.shadowRadius = 3.5
            }
            if AppTheme.dark(effectiveAppearance) {
                // 深色内容采用厚实的烟灰表面，以明暗分层，避免亮边和内光形成薄膜感。
                let top: NSColor, bottom: NSColor
                switch role {
                case .card:
                    top = AppTheme.rgb(0.145, 0.153, 0.165, 0.96)
                    bottom = AppTheme.rgb(0.138, 0.146, 0.158, 0.96)
                case .pill:
                    top = AppTheme.rgb(0.285, 0.300, 0.320, 0.96)
                    bottom = AppTheme.rgb(0.275, 0.290, 0.310, 0.96)
                case .sidebar:
                    top = AppTheme.rgb(0.34, 0.38, 0.43, 0.38)
                    bottom = AppTheme.rgb(0.30, 0.34, 0.39, 0.35)
                case .button:
                    top = AppTheme.rgb(0.245, 0.258, 0.278, 0.94)
                    bottom = AppTheme.rgb(0.235, 0.248, 0.268, 0.94)
                case .keycap:
                    top = AppTheme.rgb(0.115, 0.125, 0.140, 0.90)
                    bottom = top
                }
                gradient.colors = [top.cgColor, bottom.cgColor]
                layer.borderWidth = 0.5
                layer.borderColor = NSColor.white.withAlphaComponent(role == .sidebar ? 0.10 : 0.055).cgColor
                layer.shadowOpacity = 0
                highlight.opacity = 0
                if gradientOverride != nil { gradient.colors = [AppTheme.rgb(0.25, 0.54, 0.85, 0.40).cgColor, AppTheme.rgb(0.16, 0.37, 0.64, 0.28).cgColor] }
            } else if let gradientOverride { gradient.colors = gradientOverride }
            layer.backgroundColor = opaqueSurface ? (AppTheme.dark(effectiveAppearance) ? AppTheme.rgb(0.12, 0.15, 0.20, 0.98) : AppTheme.rgb(0.95, 0.97, 0.99, 0.98)).cgColor : NSColor.clear.cgColor
            // CSS 140deg ≈ 从左上到右下略偏
            gradient.startPoint = CGPoint(x: 0.1, y: 1); gradient.endPoint = CGPoint(x: 0.9, y: 0)
            layer.cornerRadius = radius; layer.masksToBounds = false
            needsLayout = true
        }
    }
}
/// 顶部内高光:inset 0 2px 5px #fff 的近似,一条 2px 白色、向下渐隐的渐变带,裁在圆角内。
final class InsetHighlightLayer: CAGradientLayer {
    override init() {
        super.init()
        colors = [NSColor.white.withAlphaComponent(0.95).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        startPoint = CGPoint(x: 0.5, y: 1); endPoint = CGPoint(x: 0.5, y: 0)
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }
}
/// 玻璃按钮:按钮本身不画,底下垫一块玻璃,文字放在玻璃里;点击仍由按钮接。
final class GlassButton: NSButton {
    private let glass = GlassView(role: .button)
    private let text = label("", size: 13)
    init(_ title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target; self.action = action
        isBordered = false; self.title = ""
        glass.translatesAutoresizingMaskIntoConstraints = false; text.translatesAutoresizingMaskIntoConstraints = false
        text.textColor = Glass.control; text.font = .systemFont(ofSize: 13, weight: .regular)
        addSubview(glass); glass.content.addSubview(text)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            text.centerXAnchor.constraint(equalTo: glass.content.centerXAnchor), text.centerYAnchor.constraint(equalTo: glass.content.centerYAnchor),
            heightAnchor.constraint(equalToConstant: 36), widthAnchor.constraint(greaterThanOrEqualToConstant: 69)
        ])
        setTitle(title)
    }
    required init?(coder: NSCoder) { fatalError() }
    func setTitle(_ title: String) { text.stringValue = title; setAccessibilityLabel(title); invalidateIntrinsicContentSize() }
    func usePrimaryStyle() {
        // 网页 .onboarding-next：#edf7ffb0 → #b7d9f778，文字 #637c94。
        glass.gradientOverride = [
            NSColor(srgbRed: 237/255, green: 247/255, blue: 1, alpha: 176/255).cgColor,
            NSColor(srgbRed: 183/255, green: 217/255, blue: 247/255, alpha: 120/255).cgColor
        ]
        text.textColor = AppTheme.color(NSColor(srgbRed: 99/255, green: 124/255, blue: 148/255, alpha: 1), AppTheme.rgb(0.80, 0.91, 1))
    }
    override var intrinsicContentSize: NSSize { NSSize(width: text.intrinsicContentSize.width + 30, height: 36) }
    // 玻璃层盖在按钮上面,点击要落回按钮本身。
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override var isEnabled: Bool { didSet { text.textColor = isEnabled ? Glass.control : Glass.secondary } }
}
/// 独立子视图让角标始终位于玻璃选中背景上方，同时不影响点击。
final class RecommendationBadge: NSView {
    private let text = CATextLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemBlue.cgColor; layer?.cornerRadius = 4
        text.string = "推荐"; text.fontSize = 8; text.alignmentMode = .center
        text.foregroundColor = NSColor.white.cgColor
        text.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(text)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); text.frame = bounds }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
/// 玻璃分段选择:一条浅玻璃轨道,选中项是一块更白的玻璃。
final class GlassSegmented: NSView {
    private var buttons: [NSButton] = []
    private let pill = GlassView(role: .pill)
    private var separators: [NSView] = []
    private let recommendation = RecommendationBadge(frame: .zero)
    private let recommended: Int?
    var target: AnyObject?; var action: Selector?
    var selectedSegment = 0 { didSet { refresh() } }
    init(labels: [String], symbols: [String]? = nil, recommended: Int? = nil) {
        self.recommended = recommended
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.518, green: 0.561, blue: 0.62, alpha: 0.10).cgColor; layer?.cornerRadius = 13
        // 内部子视图都在 layout() 里按 frame 摆,保持默认的 autoresizing,别和自动布局打架。
        addSubview(pill)
        for (index, text) in labels.enumerated() {
            let button = NSButton(title: text, target: self, action: #selector(tapped(_:)))
            button.tag = index; button.isBordered = false
            if let symbols, index < symbols.count {
                button.image = NSImage(systemSymbolName: symbols[index], accessibilityDescription: text)?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
                button.imagePosition = .imageOnly
                button.toolTip = text
                button.setAccessibilityLabel(text)
            }
            addSubview(button); buttons.append(button)
            if index > 0 {
                let line = ThemeSurface(fill: { AppTheme.color(AppTheme.rgb(0.78, 0.808, 0.839), .white.withAlphaComponent(0.10)) })
                addSubview(line); separators.append(line)
            }
        }
        if let recommended {
            addSubview(recommendation)
            buttons[recommended].setAccessibilityLabel(labels[recommended] + "，推荐")
        }
        heightAnchor.constraint(equalToConstant: symbols == nil ? 42 : 34).isActive = true
        if symbols != nil {
            widthAnchor.constraint(equalToConstant: 102).isActive = true
            setContentHuggingPriority(.required, for: .horizontal)
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let count = CGFloat(max(1, buttons.count)); let width = bounds.width / count
        for (index, button) in buttons.enumerated() {
            let inset: CGFloat = index == recommended ? 6 : 0
            button.frame = NSRect(x: CGFloat(index) * width, y: inset, width: width, height: bounds.height - inset)
        }
        if let recommended { recommendation.frame = CGRect(x: CGFloat(recommended + 1) * width - 31, y: 3, width: 26, height: 12) }
        for (index, line) in separators.enumerated() { line.frame = NSRect(x: CGFloat(index + 1) * width - 0.5, y: 11, width: 1, height: bounds.height - 22) }
        pill.frame = NSRect(x: CGFloat(selectedSegment) * width + 3, y: 3, width: width - 6, height: bounds.height - 6)
        pill.layoutSubtreeIfNeeded()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
    private func refresh() {
        for (index, button) in buttons.enumerated() {
            let on = index == selectedSegment
            button.contentTintColor = on ? Glass.segmentOn : Glass.secondary
            button.setAccessibilityValue(on ? "已选择" : "未选择")
            button.attributedTitle = NSAttributedString(string: button.image == nil ? button.title : "", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .regular), .foregroundColor: on ? Glass.segmentOn : Glass.control])
        }
        for (index, line) in separators.enumerated() { line.isHidden = index == selectedSegment || index + 1 == selectedSegment }
        needsLayout = true
    }
    @objc private func tapped(_ sender: NSButton) {
        guard sender.tag != selectedSegment else { return }
        selectedSegment = sender.tag
        if let action { NSApp.sendAction(action, to: target, from: self) }
    }
}
/// 侧栏图标:优先用 Resources/Icons 里设计稿的 PNG,没有时画渐变色块加白色符号。
func glassIcon(_ symbol: String, asset: String = "", colors: [NSColor]) -> NSView {
    if let url = Bundle.main.resourceURL?.appendingPathComponent("Icons/\(asset).png"), let image = NSImage(contentsOf: url) {
        let view = NSImageView(); view.image = image; view.imageScaling = .scaleProportionallyUpOrDown; view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: 30), view.heightAnchor.constraint(equalToConstant: 30)])
        return view
    }
    let tile = NSView(); tile.wantsLayer = true; tile.translatesAutoresizingMaskIntoConstraints = false
    let gradient = CAGradientLayer(); gradient.colors = colors.map(\.cgColor)
    gradient.startPoint = CGPoint(x: 0, y: 1); gradient.endPoint = CGPoint(x: 1, y: 0); gradient.cornerRadius = 8
    gradient.frame = CGRect(x: 0, y: 0, width: 28, height: 28); tile.layer?.addSublayer(gradient)
    tile.layer?.shadowColor = colors.last?.cgColor; tile.layer?.shadowOpacity = 0.35; tile.layer?.shadowOffset = CGSize(width: 0, height: -2); tile.layer?.shadowRadius = 4
    let image = NSImageView(); image.translatesAutoresizingMaskIntoConstraints = false
    image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .bold))
    image.contentTintColor = .white; tile.addSubview(image)
    NSLayoutConstraint.activate([tile.widthAnchor.constraint(equalToConstant: 28), tile.heightAnchor.constraint(equalToConstant: 28), image.centerXAnchor.constraint(equalTo: tile.centerXAnchor), image.centerYAnchor.constraint(equalTo: tile.centerYAnchor)])
    return tile
}
/// 快捷键显示文字:right option -> ⌥ 右 Option。
func hotkeyDisplay(_ name: String) -> String {
    let table: [String: String] = ["right option": "⌥ 右 Option", "left option": "⌥ 左 Option", "option": "⌥ Option", "right command": "⌘ 右 Command", "left command": "⌘ 左 Command", "command": "⌘ Command", "right ctrl": "⌃ 右 Ctrl", "left ctrl": "⌃ 左 Ctrl", "ctrl": "⌃ Ctrl", "right shift": "⇧ 右 Shift", "left shift": "⇧ 左 Shift", "shift": "⇧ Shift", "space": "空格", "esc": "Esc", "fn": "fn"]
    return name.lowercased().components(separatedBy: "+").map { part in
        let key = part.trimmingCharacters(in: .whitespaces)
        return table[key] ?? key.uppercased()
    }.joined(separator: " + ")
}
func screenshotHotkeyDisplay(_ name: String) -> String {
    let table = ["command": "⌘", "cmd": "⌘", "shift": "⇧", "option": "⌥", "alt": "⌥", "ctrl": "⌃", "control": "⌃", "space": "Space"]
    return name.lowercased().components(separatedBy: "+").map {
        let key = $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "left ", with: "").replacingOccurrences(of: "right ", with: "")
        return table[key] ?? key.uppercased()
    }.joined(separator: " ")
}
/// 圆角玻璃卡片,设置页里每一组选项一张。
func card(_ views: [NSView], spacing: CGFloat = 10, verticalPadding: CGFloat = 14) -> NSView {
    let box = GlassView(role: .card)
    let content = stack(views, spacing: spacing); content.translatesAutoresizingMaskIntoConstraints = false
    box.content.addSubview(content)
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: box.content.leadingAnchor, constant: 17), content.trailingAnchor.constraint(equalTo: box.content.trailingAnchor, constant: -17),
        content.topAnchor.constraint(equalTo: box.content.topAnchor, constant: verticalPadding), content.bottomAnchor.constraint(equalTo: box.content.bottomAnchor, constant: -verticalPadding)
    ])
    for view in views { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
    return box
}
/// 左文字(标题+说明)右控件的一行:中间一个“弹簧”吃掉多余空间,控件稳稳靠右。
func spring() -> NSView {
    let view = NSView(); view.translatesAutoresizingMaskIntoConstraints = false
    view.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    view.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    view.widthAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
    return view
}
func row(_ title: String, _ subtitle: String = "", control: NSView, titleColor: NSColor = Glass.text) -> NSView {
    let head = label(title, size: 14.5); head.textColor = titleColor
    var words: [NSView] = [head]
    if !subtitle.isEmpty { let sub = note(subtitle); sub.textColor = Glass.secondary; words.append(sub) }
    let text = stack(words, spacing: 3)
    for word in words { word.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
    let line = NSStackView(views: [text, spring(), control]); line.spacing = 14; line.alignment = .centerY; line.distribution = .fill
    control.setContentHuggingPriority(.required, for: .horizontal)
    (control as? NSStackView)?.setHuggingPriority(.required, for: .horizontal)
    control.setContentCompressionResistancePriority(.required, for: .horizontal)
    return line
}
/// 自绘开关(照网页稿):开=蓝色渐变轨道,关=浅灰;白色圆滑块带阴影,切换有动画。
final class GlassToggle: NSButton {
    private let track = CAGradientLayer()
    private let knob = CAGradientLayer()
    private let innerLight = CAGradientLayer()
    static let size = NSSize(width: 52, height: 28)
    init(on: Bool, target: AnyObject?, action: Selector?) {
        super.init(frame: NSRect(origin: .zero, size: GlassToggle.size))
        self.target = target; self.action = action
        isBordered = false; title = ""; setButtonType(.toggle); state = on ? .on : .off
        wantsLayer = true
        track.frame = bounds; track.cornerRadius = bounds.height / 2; track.borderWidth = 0.6
        // CSS 150deg: the light arrives from the upper left.
        track.startPoint = CGPoint(x: 0.25, y: 0); track.endPoint = CGPoint(x: 0.75, y: 1)
        innerLight.frame = bounds.insetBy(dx: 0.6, dy: 0.6)
        innerLight.cornerRadius = innerLight.bounds.height / 2
        innerLight.startPoint = CGPoint(x: 0.5, y: 0); innerLight.endPoint = CGPoint(x: 0.5, y: 1)
        innerLight.colors = [NSColor.white.withAlphaComponent(0.5).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        innerLight.locations = [0, 0.45]
        let lightMask = CAShapeLayer()
        lightMask.frame = innerLight.bounds
        lightMask.path = CGPath(roundedRect: innerLight.bounds.insetBy(dx: 0.7, dy: 0.7), cornerWidth: 13, cornerHeight: 13, transform: nil)
        lightMask.fillColor = nil; lightMask.strokeColor = NSColor.white.cgColor; lightMask.lineWidth = 1.4
        innerLight.mask = lightMask
        knob.frame = CGRect(x: 1.15, y: 1.15, width: 25.7, height: 25.7); knob.cornerRadius = 12.85
        knob.startPoint = CGPoint(x: 0, y: 0); knob.endPoint = CGPoint(x: 1, y: 1)
        knob.colors = [NSColor.white.cgColor, NSColor(srgbRed: 244/255, green: 247/255, blue: 250/255, alpha: 1).cgColor]
        knob.borderWidth = 0.6; knob.borderColor = NSColor.white.withAlphaComponent(0.95).cgColor
        knob.shadowColor = NSColor(srgbRed: 117/255, green: 139/255, blue: 166/255, alpha: 1).cgColor
        knob.shadowOpacity = 0.2; knob.shadowOffset = CGSize(width: 0, height: 1.15); knob.shadowRadius = 2.3
        knob.shadowPath = CGPath(ellipseIn: knob.bounds, transform: nil)
        layer?.masksToBounds = false
        layer?.addSublayer(track); layer?.addSublayer(innerLight); layer?.addSublayer(knob)
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: GlassToggle.size.width), heightAnchor.constraint(equalToConstant: GlassToggle.size.height)])
        render(animated: false)
        setAccessibilityRole(.checkBox)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { GlassToggle.size }
    override var state: NSControl.StateValue { didSet { if oldValue != state { render(animated: true) } } }
    override func draw(_ dirtyRect: NSRect) {}
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        state = state == .on ? .off : .on
        if let action { NSApp.sendAction(action, to: target, from: self) }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); render(animated: false) }
    private func render(animated: Bool) {
        let on = state == .on
        CATransaction.begin(); CATransaction.setAnimationDuration(animated ? 0.2 : 0)
        track.colors = on ? [NSColor(srgbRed: 0.514, green: 0.78, blue: 1.0, alpha: 1).cgColor, NSColor(srgbRed: 0.263, green: 0.604, blue: 1.0, alpha: 1).cgColor]
                          : [NSColor(srgbRed: 0.796, green: 0.824, blue: 0.847, alpha: 1).cgColor, NSColor(srgbRed: 0.796, green: 0.824, blue: 0.847, alpha: 1).cgColor]
        track.borderColor = (on ? NSColor(srgbRed: 0.412, green: 0.694, blue: 1.0, alpha: 1) : NSColor(srgbRed: 0.78, green: 0.824, blue: 0.863, alpha: 1)).cgColor
        if AppTheme.dark(effectiveAppearance) {
            track.colors = on ? [AppTheme.rgb(0.30, 0.62, 0.96).cgColor, AppTheme.rgb(0.18, 0.43, 0.81).cgColor] : [AppTheme.rgb(0.26, 0.30, 0.37).cgColor, AppTheme.rgb(0.21, 0.25, 0.31).cgColor]
            track.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        }
        innerLight.opacity = AppTheme.dark(effectiveAppearance) ? 0.3 : 1
        knob.frame.origin.x = on ? bounds.width - knob.frame.width - 1.15 : 1.15
        CATransaction.commit()
    }
}
func toggle(_ on: Bool, target: AnyObject, action: Selector) -> GlassToggle {
    GlassToggle(on: on, target: target, action: action)
}
func segmented(_ labels: [String], selected: Int, target: AnyObject, action: Selector, recommended: Int? = nil) -> GlassSegmented {
    let control = GlassSegmented(labels: labels, recommended: recommended)
    control.target = target; control.action = action; control.selectedSegment = selected
    return control
}
func button(_ title: String, target: AnyObject, action: Selector, prominent: Bool = false) -> NSButton {
    let control = GlassButton(title, target: target, action: action)
    if prominent { control.keyEquivalent = "\r" }
    return control
}
/// 鼠标操作图示：高亮左键/右键，无高亮表示松开。
final class MouseGestureIcon: NSView {
    enum Key { case left, released, right }
    private let key: Key
    init(_ key: Key) {
        self.key = key
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 18), heightAnchor.constraint(equalToConstant: 26)])
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let body = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 8, yRadius: 8)
        NSColor.white.withAlphaComponent(0.7).setFill(); body.fill()
        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        if key != .released {
            NSColor(srgbRed: 0.55, green: 0.78, blue: 1, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: key == .left ? 0 : 9, y: 0, width: 9, height: 11)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 1, y: 11)); line.line(to: NSPoint(x: 17, y: 11))
        line.move(to: NSPoint(x: 9, y: 1)); line.line(to: NSPoint(x: 9, y: 11))
        Glass.secondary.setStroke(); body.lineWidth = 1.2; body.stroke()
        line.lineWidth = 1; line.stroke()
    }
}

/// 悬停说明绘制在窗口内容层内，避免越过窗口边缘。
final class MouseHelpIcon: NSButton {
    private var tracking: NSTrackingArea?
    private var bubble: NSView?
    private var pinned = false
    private var eventMonitor: Any?
    private let fastHelp: Bool
    init(fastHelp: Bool = false) {
        self.fastHelp = fastHelp
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: fastHelp ? "Fast 开通说明" : "鼠标录音说明")
        title = ""; isBordered = false; imagePosition = .imageOnly
        target = self; action = #selector(toggleHelp)
        contentTintColor = Glass.secondary
        setAccessibilityLabel(fastHelp ? "Fast 开通说明" : "鼠标录音说明")
        setAccessibilityHelp(fastHelp ? "火山方舟控制台：开通管理、模型、语言模型，找到对应模型，向右横向滚动表格，开启低延迟。" : "按住左键0.5秒开始录音，松开输入文字；录音时点一下右键，松开后自动回车发送。")
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 16), heightAnchor.constraint(equalToConstant: 16)])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        guard let window else { return }
        window.acceptsMouseMovedEvents = true
        updateTrackingAreas()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, let window = self.window else { return event }
            let overIcon = event.window === window && self.bounds.contains(self.convert(event.locationInWindow, from: nil))
            if event.type == .mouseMoved && !self.pinned {
                if overIcon { self.showHelp() } else { self.hideHelp() }
            } else if event.type == .keyDown && event.keyCode == 53 && self.bubble != nil {
                self.hideHelp()
                return nil
            } else if (event.type == .leftMouseDown || event.type == .rightMouseDown) && !overIcon {
                let overBubble = event.window === window && self.bubble.map { $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) } == true
                if !overBubble { self.hideHelp() }
            }
            return event
        }
    }
    deinit { if let eventMonitor { NSEvent.removeMonitor(eventMonitor) } }
    @objc private func toggleHelp() {
        if pinned { hideHelp() } else { pinned = true; showHelp() }
    }
    override func mouseMoved(with event: NSEvent) { showHelp() }
    override func mouseEntered(with event: NSEvent) { showHelp() }
    override func mouseExited(with event: NSEvent) { if !pinned { hideHelp() } }
    override func viewWillMove(toWindow newWindow: NSWindow?) { hideHelp(); super.viewWillMove(toWindow: newWindow) }
    private func hideHelp() { bubble?.removeFromSuperview(); bubble = nil; pinned = false }
    private func showHelp() {
        guard bubble == nil, let root = window?.contentView else { return }
        func gesture(_ key: MouseGestureIcon.Key, _ title: String, _ detail: String) -> NSView {
            let words = stack([label(title, size: 12), note(detail, size: 11)], spacing: 2)
            let row = NSStackView(views: [MouseGestureIcon(key), words])
            row.spacing = 10; row.alignment = .centerY
            return row
        }
        let help = fastHelp ? card([
            label("开通 Fast 低延迟", size: 12),
            note("火山方舟控制台 → 开通管理", size: 11),
            note("模型 → 语言模型 → 找到对应模型", size: 11),
            note("向右横向滚动表格，开启「低延迟」。", size: 11),
            note("每个模型需单独开通，费用为常规档的 2 倍。", size: 11)
        ], spacing: 7, verticalPadding: 12) : card([
            gesture(.left, "按住左键 0.5 秒", "开始录音"),
            gesture(.released, "松开左键", "识别后，将文字填入输入框"),
            gesture(.right, "录音时点一下右键 · 可选", "松开左键后，填入文字并自动回车发送")
        ], spacing: 10, verticalPadding: 12)
        help.wantsLayer = true
        (help as? GlassView)?.opaqueSurface = true
        help.layer?.cornerRadius = 14
        help.layer?.shadowColor = NSColor.black.cgColor; help.layer?.shadowOpacity = 0.12; help.layer?.shadowRadius = 10
        let anchor = convert(bounds, to: root)
        let width: CGFloat = 300, height: CGFloat = 148, inset: CGFloat = 12
        let x = min(max(inset, anchor.midX - width / 2), root.bounds.width - width - inset)
        let above = root.isFlipped ? anchor.minY - height - 8 : anchor.maxY + 8
        let y = min(max(inset, above), root.bounds.height - height - inset)
        // 浮层坐标已转换到root，直接设置frame，避免bottomAnchor在翻转坐标系中的方向差异。
        help.translatesAutoresizingMaskIntoConstraints = true
        help.frame = NSRect(x: x, y: y, width: width, height: height)
        root.addSubview(help, positioned: .above, relativeTo: nil)
        help.layoutSubtreeIfNeeded()
        bubble = help
    }
}

/// 原点在左上角的容器,放进 NSScrollView 后内容从顶部开始排。
final class StatusNote: NSTextField {
    override var stringValue: String { didSet { isHidden = stringValue.isEmpty } }
}
final class FlippedView: NSView { override var isFlipped: Bool { true } }
/// 保留原生滚动交互，但不绘制系统在悬停或常显模式下加上的轨道底色。
final class GlassScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override var isOpaque: Bool { false }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    override func draw(_ dirtyRect: NSRect) {
        guard knobProportion < 1 else { return }
        let knob = rect(for: .knob)
        guard knob.height > 0 else { return }
        let width: CGFloat = 5
        let slim = NSRect(x: knob.midX - width / 2, y: knob.minY, width: width, height: knob.height)
        AppTheme.color(NSColor(calibratedWhite: 0.40, alpha: 0.45), NSColor.white.withAlphaComponent(0.35)).setFill()
        NSBezierPath(roundedRect: slim, xRadius: width / 2, yRadius: width / 2).fill()
    }
}

func scrollPane(_ content: NSStackView, margin: CGFloat = 28, trailingMargin: CGFloat? = nil, topMargin: CGFloat = 24, showsScroller: Bool = false) -> NSScrollView {
    let document = FlippedView(); document.translatesAutoresizingMaskIntoConstraints = false
    content.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(content)
    let scroll = NSScrollView(); scroll.documentView = document; scroll.hasVerticalScroller = showsScroller; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay; scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.contentView.drawsBackground = false
    if showsScroller { scroll.verticalScroller = GlassScroller() }
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: margin),
        content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -(trailingMargin ?? margin)),
        content.topAnchor.constraint(equalTo: document.topAnchor, constant: topMargin),
        content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
    ])
    for view in content.arrangedSubviews { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
    return scroll
}

final class ThemeEditorScroll: NSScrollView {
    private func refreshSurface() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            wantsLayer = true
            layer?.backgroundColor = AppTheme.input.cgColor
            layer?.borderColor = AppTheme.border.cgColor
        }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshSurface() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshSurface() }
}

func inputSurface(_ control: NSView, height: CGFloat = 38) -> NSView {
    let surface = ThemeSurface(fill: { AppTheme.input }, stroke: { AppTheme.border })
    surface.layer?.cornerRadius = 10; surface.layer?.borderWidth = 0.8
    control.translatesAutoresizingMaskIntoConstraints = false
    surface.addSubview(control)
    if let field = control as? NSTextField {
        field.isBezeled = false; field.isBordered = false; field.drawsBackground = false
        field.font = NSFont(name: "PingFangSC-Regular", size: 13); field.textColor = Glass.text
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    NSLayoutConstraint.activate([
        surface.heightAnchor.constraint(equalToConstant: height),
        control.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 11),
        control.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -11),
        control.centerYAnchor.constraint(equalTo: surface.centerYAnchor)
    ])
    return surface
}

enum Permission {
    static let names = ["麦克风", "输入监控", "辅助功能", "屏幕录制"]
    static let descriptions = ["录下你说的话,空闲时不占用", "听到你按热键、长按鼠标", "将识别文字输入到光标处", "仅在使用窗口截图时需要"]
    private static let panes = ["Privacy_Microphone", "Privacy_ListenEvent", "Privacy_Accessibility", "Privacy_ScreenCapture"]
    /// 顺序与 names 一致:麦克风、输入监控、辅助功能。
    static var granted: [Bool] { [AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, CGPreflightListenEventAccess(), AXIsProcessTrusted()] }
    // 初始化与菜单缺失提醒仍只检查三项基础权限。
    static var allGranted: Bool { granted.allSatisfy { $0 } }
    static var displayedGranted: [Bool] { granted + [CGPreflightScreenCaptureAccess()] }
    static func open(_ index: Int, completion: @escaping () -> Void = {}) {
        guard panes.indices.contains(index), !CommandLine.arguments.contains("--screenshot-ui-preview") else { return }
        if index == 3 && !CGPreflightScreenCaptureAccess() {
            // 只请求系统权限，不改变窗口截图功能开关。
            if !CGRequestScreenCaptureAccess() {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            completion()
        } else if index == 0 && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async(execute: completion) }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(panes[index])")!)
        }
    }
    static func restartApp() {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; exec /usr/bin/open \"$1\"", "voice-input-restart", Bundle.main.bundlePath]
        try? process.run(); NSApp.terminate(nil)
    }
}

/// 设置页完整展示所有权限；首次引导单独显示三项基础权限。
final class PermissionsPane: NSView {
    private var states: [NSTextField] = []
    private var buttons: [NSButton] = []
    private var icons: [NSImageView] = []
    private var timer: Timer?
    var onChange: (() -> Void)?
    init() {
        super.init(frame: .zero)
        var rows: [NSView] = []
        for index in Permission.names.indices {
            let icon = NSImageView(); icon.imageScaling = .scaleProportionallyUpOrDown
            icon.widthAnchor.constraint(equalToConstant: 22).isActive = true; icon.heightAnchor.constraint(equalToConstant: 22).isActive = true
            icons.append(icon)
            let words = stack([label(Permission.names[index], size: 14.5), note(Permission.descriptions[index])], spacing: 3)
            let state = label("", size: 12); states.append(state)
            state.widthAnchor.constraint(equalToConstant: 48).isActive = true
            let open = button("去开启", target: self, action: #selector(openPermission(_:))); open.tag = index; buttons.append(open)
            open.widthAnchor.constraint(equalToConstant: 82).isActive = true
            let line = NSStackView(views: [icon, words, spring(), state, open]); line.spacing = 12; line.alignment = .centerY; line.distribution = .fill
            rows.append(card([line]))
        }
        let content = stack(rows, spacing: 10); content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor), content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor)])
        for view in rows { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }
    func refresh() {
        for (i, value) in Permission.displayedGranted.enumerated() {
            states[i].stringValue = value ? "已开启" : "未开启"
            states[i].textColor = value ? .systemGreen : .systemOrange
            (buttons[i] as? GlassButton)?.setTitle(value ? "查看" : "去开启")
            icons[i].image = NSImage(systemSymbolName: value ? "checkmark.circle.fill" : "circle.dashed", accessibilityDescription: states[i].stringValue)
            icons[i].contentTintColor = value ? .systemGreen : .tertiaryLabelColor
        }
        onChange?()
    }
    @objc private func openPermission(_ sender: NSButton) { Permission.open(sender.tag) { [weak self] in self?.refresh() } }
}

/// 用一句合成语音试一次识别,返回耗时和听到的内容;设置页和首次引导共用。
enum ServiceCheck {
    static func run(_ settings: Settings) async -> String {
        let folder = FileManager.default.temporaryDirectory
        let source = folder.appendingPathComponent("voice-check-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: source) }
        let say = Process(); say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", source.path, "--data-format=LEI16@16000", "今天天气不错"]
        say.standardOutput = FileHandle.nullDevice; say.standardError = FileHandle.nullDevice
        do { try say.run(); say.waitUntilExit() } catch { return "无法合成测试语音" }
        guard say.terminationStatus == 0 else { return "无法合成测试语音" }
        do {
            let prepared = try AudioPreparation.prepare(source)
            defer { try? FileManager.default.removeItem(at: prepared.url) }
            let start = Date()
            let result = try await Recognition.transcribeDetailed(audio: prepared.url, settings: settings, context: "")
            let prefix = result.statistics.fastFallback == true ? "Fast 未开通，已改用常规档。" : ""
            return prefix + String(format: "通了,%.1f 秒 · 听到:%@", Date().timeIntervalSince(start), result.text.prefix(20) as CVarArg)
        } catch { return "没通:\(error.localizedDescription)" }
    }
}

/// 展示时换算单位，保存和计费仍使用人民币元。
private func historyCostText(_ yuan: Double) -> String {
    guard yuan.isFinite, yuan >= 0 else { return "—" }
    if yuan > 0 && yuan < 0.0001 { return "<0.01 分" }
    let scale: Double = yuan < 0.1 ? 100 : 1
    let unit = yuan < 0.1 ? "分" : "元"
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 2
    return (formatter.string(from: NSNumber(value: yuan * scale)) ?? "—") + " " + unit
}

/// 个人词典页:一张卡,顶部无边框输入行(右侧 ＋),下面胶囊式词条;词条用和按钮同款的自绘玻璃。
final class DictionaryPane: NSView, NSTextFieldDelegate {
    private var dictionary = Dictionary.load()
    /// 外部(快捷键/纠错)改了词典后刷新。
    func reload() { dictionary = Dictionary.load(); refresh() }
    private let field = NSTextField()
    private let flow = FlowView()
    private let status = note("", size: 11.5)
    private let empty = note("还没有词条,输入一个试试。", size: 12.5)
    private var highlighted: Set<String> = []
    init() {
        super.init(frame: .zero)
        field.placeholderAttributedString = NSAttributedString(string: "输入词条,回车添加;可一次粘贴多个", attributes: [.foregroundColor: Glass.secondary, .font: NSFont.systemFont(ofSize: 14)]); field.delegate = self
        field.font = .systemFont(ofSize: 14); field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.textColor = Glass.text; field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let add = NSButton(title: "", target: self, action: #selector(addTapped)); add.isBordered = false
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "添加")?.withSymbolConfiguration(.init(pointSize: 14, weight: .light))
        add.contentTintColor = Glass.control; add.setAccessibilityLabel("添加词条"); add.toolTip = "添加(回车)"
        add.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let inputRow = NSStackView(views: [field, add]); inputRow.spacing = 8; inputRow.alignment = .centerY
        inputRow.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let divider = NSView(); divider.wantsLayer = true; divider.layer?.backgroundColor = NSColor(srgbRed: 0.6, green: 0.65, blue: 0.72, alpha: 0.22).cgColor
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        status.textColor = Glass.secondary; status.isHidden = true
        empty.textColor = Glass.secondary
        flow.translatesAutoresizingMaskIntoConstraints = false
        let body = stack([inputRow, divider, status, flow, empty], spacing: 12)
        let content = card([body], spacing: 0); content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor), content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor)])
        for view in body.arrangedSubviews { view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { addTapped(); return true }
        return false
    }
    @objc private func addTapped() {
        let app = NSWorkspace.shared.frontmostApplication
        let result = dictionary.add(field.stringValue, source: "manual", app: app?.bundleIdentifier ?? "", appName: app?.localizedName ?? "")
        guard !result.added.isEmpty || !result.duplicates.isEmpty else { return }
        dictionary.save(); field.stringValue = ""
        highlighted = Set(result.added + result.duplicates)
        status.stringValue = result.duplicates.isEmpty ? "已添加 \(result.added.count) 个" : "已添加 \(result.added.count) 个,\(result.duplicates.count) 个已存在"
        status.isHidden = false
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in self?.highlighted = []; self?.status.isHidden = true; self?.refresh() }
    }
    @objc private func removeTapped(_ sender: NSButton) {
        guard let term = sender.identifier?.rawValue else { return }
        dictionary.remove(term); dictionary.save(); refresh()
    }
    private func refresh() {
        empty.isHidden = !dictionary.items.isEmpty
        flow.isHidden = dictionary.items.isEmpty
        flow.items = dictionary.items.map { item in
            let pill = GlassView(role: .button)
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.layer?.cornerRadius = 15
            if highlighted.contains(item.text) { pill.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor }
            let text = label(item.text, size: 13); text.textColor = Glass.text; text.translatesAutoresizingMaskIntoConstraints = false
            var tip = ["manual": "手动添加", "hotkey": "快捷键添加", "correction": "从修改中学到"][item.source] ?? item.source
            if !item.appName.isEmpty { tip += " · 来自 \(item.appName)" }
            if let hit = item.lastHit { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; tip += " · 最近用到 \(f.string(from: hit))" }
            pill.toolTip = tip
            let close = NSButton(title: "", target: self, action: #selector(removeTapped(_:))); close.isBordered = false
            close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "删除 \(item.text)")?.withSymbolConfiguration(.init(pointSize: 8, weight: .regular))
            close.contentTintColor = Glass.secondary.withAlphaComponent(0.7); close.identifier = NSUserInterfaceItemIdentifier(item.text); close.translatesAutoresizingMaskIntoConstraints = false
            close.setAccessibilityLabel("删除 \(item.text)")
            pill.content.addSubview(text); pill.content.addSubview(close)
            NSLayoutConstraint.activate([
                pill.heightAnchor.constraint(equalToConstant: 30),
                text.leadingAnchor.constraint(equalTo: pill.content.leadingAnchor, constant: 12), text.centerYAnchor.constraint(equalTo: pill.content.centerYAnchor),
                close.leadingAnchor.constraint(equalTo: text.trailingAnchor, constant: 8), close.trailingAnchor.constraint(equalTo: pill.content.trailingAnchor, constant: -9),
                close.centerYAnchor.constraint(equalTo: pill.content.centerYAnchor), close.widthAnchor.constraint(equalToConstant: 12), close.heightAnchor.constraint(equalToConstant: 12)
            ])
            return pill
        }
    }
}
/// 自动换行排列子视图的容器;高度随内容变化。
final class FlowView: NSView {
    var items: [NSView] = [] { didSet { subviews.forEach { $0.removeFromSuperview() }; items.forEach(addSubview); needsLayout = true; invalidateIntrinsicContentSize() } }
    private var measuredHeight: CGFloat = 26
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight) }
    override func layout() {
        super.layout()
        let gap: CGFloat = 8; var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in items {
            let size = view.fittingSize
            if x > 0 && x + size.width > bounds.width { x = 0; y += rowHeight + gap; rowHeight = 0 }
            view.frame = NSRect(x: x, y: y, width: min(size.width, bounds.width), height: size.height)
            x += size.width + gap; rowHeight = max(rowHeight, size.height)
        }
        let total = items.isEmpty ? 26 : y + rowHeight
        if abs(total - measuredHeight) > 0.5 { measuredHeight = total; invalidateIntrinsicContentSize() }
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
}

/// 历史记录列表:播放、复制、重新识别。
final class HistoryPane: NSView, AVAudioPlayerDelegate {
    private let content = stack([], spacing: 10)
    private var items: [HistoryEntry] = []
    private var player: AVAudioPlayer?
    private var playingID: String?
    var screenshotDirectory = Paths.recordings
    private var expandedIDs = Set<String>()
    private var comparisonExpandedIDs = Set<String>()
    private var screenshotPreview: NSWindowController?
    private var previewEntryID: String?
    private var playbackToken = UUID()
    var busyID: String?
    var onRegenerate: ((String) -> Void)?
    var onClear: (() throws -> Void)?
    var historyEnabled = true
    var historyLimit = 100
    var onRetentionChange: ((Bool, Int) throws -> Void)?
    init() {
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor), content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }
    func stopPlayback() { playbackToken = UUID(); player?.stop(); player = nil; playingID = nil }
    func refresh(_ items: [HistoryEntry]) {
        self.items = items
        expandedIDs.formIntersection(Set(items.map(\.id)))
        comparisonExpandedIDs.formIntersection(Set(items.flatMap { [$0.screenshotComparison?.id, $0.audioSpeedComparison?.id].compactMap { $0 } }))
        if let id = previewEntryID, !items.contains(where: { $0.id == id }) { screenshotPreview?.close(); screenshotPreview = nil; previewEntryID = nil }
        if let id = playingID, !items.contains(where: { $0.id == id }) { stopPlayback() }
        for view in content.arrangedSubviews { content.removeArrangedSubview(view); view.removeFromSuperview() }
        let heading = label("历史记录", size: 23, bold: true); heading.textColor = Glass.title
        let enabled = toggle(historyEnabled, target: self, action: #selector(historyEnabledChanged(_:)))
        enabled.setAccessibilityLabel("保存历史记录")
        enabled.toolTip = "关闭后清空已有文字、录音和截图，后续不再保留历史"
        enabled.isEnabled = busyID == nil
        let titleRow = NSStackView(views: [heading, spring(), enabled]); titleRow.alignment = .centerY
        content.addArrangedSubview(titleRow); titleRow.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        let retention = note(historyLimit == 0 ? "仅在本地保存" : "仅在本地保存最近")
        let choices = NSPopUpButton(frame: .zero, pullsDown: false)
        choices.addItems(withTitles: Settings.historyLimits.map { $0 == 0 ? "永久" : "\($0) 条" })
        choices.selectItem(at: Settings.historyLimits.firstIndex(of: historyLimit) ?? 4)
        choices.font = .systemFont(ofSize: 12); choices.isBordered = false
        choices.target = self; choices.action = #selector(historyLimitChanged(_:))
        choices.isEnabled = historyEnabled && busyID == nil
        choices.setAccessibilityLabel("历史保留数量")
        choices.toolTip = "调小数量会立即删除超出的旧记录及其录音和截图"
        let clear = button("清空", target: self, action: #selector(clearHistory))
        clear.isEnabled = !items.isEmpty && busyID == nil
        let header = NSStackView(views: [retention, choices, spring(), clear])
        header.spacing = 6; header.alignment = .centerY
        content.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        if !historyEnabled {
            let empty = card([label("历史记录已关闭", size: 14.5), note("后续不保留文字、录音和截图。")], verticalPadding: 24)
            content.addArrangedSubview(empty); empty.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            return
        }
        if items.isEmpty {
            let empty = card([label("还没有录音", size: 14.5), note("按下快捷键开始说话,记录会出现在这里。")], verticalPadding: 24)
            content.addArrangedSubview(empty); empty.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        let format = DateFormatter(); format.dateFormat = "MM-dd HH:mm"
        for entry in items {
            let failed = !entry.error.isEmpty
            let title = label("", size: 12)
            title.stringValue = format.string(from: entry.date) + ((entry.context ?? "").isEmpty ? "" : " · " + (entry.context ?? ""))
            title.textColor = Glass.secondary
            // 长窗口标题只在卡片内截断，不能反过来撑大整个设置窗口。
            title.maximumNumberOfLines = 1
            title.lineBreakMode = .byTruncatingTail
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            title.toolTip = title.stringValue
            let text = NSTextField(wrappingLabelWithString: entry.text.isEmpty ? (failed ? entry.error : "暂无识别结果") : entry.text)
            text.font = NSFont(name: "PingFangSC-Regular", size: 14); text.isSelectable = true
            text.textColor = failed && entry.text.isEmpty ? .systemRed : Glass.text
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let displayed = text.stringValue
            let canFold = displayed.count > 100 || displayed.filter { $0 == "\n" }.count >= 4
            let expanded = expandedIDs.contains(entry.id)
            if canFold && !expanded {
                text.maximumNumberOfLines = 4
                text.cell?.truncatesLastVisibleLine = true
                text.heightAnchor.constraint(lessThanOrEqualToConstant: 82).isActive = true
            }
            var textArea: NSView = text
            if canFold {
                let disclosure = NSButton(image: NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down", accessibilityDescription: expanded ? "收起全文" : "展开全文")!, target: self, action: #selector(toggleText(_:)))
                disclosure.isBordered = false; disclosure.contentTintColor = Glass.secondary
                disclosure.identifier = NSUserInterfaceItemIdentifier(entry.id)
                disclosure.toolTip = expanded ? "收起全文" : "展开全文"
                disclosure.widthAnchor.constraint(equalToConstant: 22).isActive = true
                disclosure.heightAnchor.constraint(equalToConstant: 22).isActive = true
                let line = NSStackView(views: [text, disclosure]); line.spacing = 8; line.alignment = .top
                textArea = line
            }
            var views: [NSView] = [title, textArea]
            let providerName = ["bailian_cn": "百炼·北京", "bailian": "百炼·新加坡", "mimo": "小米 MiMo", "gemini": "Gemini", "volcano": "火山方舟"][entry.provider ?? ""]
            let modelInfo = note((entry.screenshotComparison == nil ? "" : "带截图 · ") + Provider.modelTitle(entry.model) + (entry.statistics?.fastFallback == true ? " · 常规（Fast 未开通）" : (entry.statistics?.serviceTier == "fast" ? " · Fast" : "")) + (providerName.map { " · " + $0 } ?? ""), size: 11.5)
            // 旧 Seed 记录仅补展示，保留原有总费用与服务用量。
            let stats = entry.statistics.map { value in
                entry.provider == "volcano" ? RecognitionPricing.addingSeedImageEstimate(value, model: entry.model, hasScreenshot: entry.screenshot != nil) : value
            }
            let first = stats?.firstTextSeconds.map { String(format: "%.2f s", $0) } ?? "—"
            let total = stats.map { String(format: "%.2f s", $0.totalSeconds) } ?? "—"
            let cost = stats?.estimatedCNY.map(historyCostText) ?? "—"
            let imageShare: String
            if let image = stats?.estimatedImageCNY, let totalCost = stats?.estimatedCNY, totalCost > 0 {
                let percent = image / totalCost * 100
                imageShare = percent > 0 && percent < 1 ? "<1%" : String(format: "%.0f%%", percent)
            } else { imageShare = "—" }
            let imageSuffix = entry.screenshot == nil ? "" : "（截图\(stats?.imageCostEstimatedFromRule == true ? "约占" : "占比") \(imageShare)）"
            let timing = note("首字 \(first)  ·  总耗时 \(total)  ·  预估 \(cost)\(imageSuffix)", size: 11.5)
            let origin = stats?.retried == true ? "点击重新识别" : "结束录音"
            timing.toolTip = "首字：从\(origin)到首次收到有效文字；总耗时：从\(origin)到完整结果接收完毕。\n" + (stats?.pricingNote ?? "此记录未保存耗时和计费用量。")
            if entry.screenshot != nil {
                timing.toolTip = (timing.toolTip ?? "") + "\n截图占比为图片输入预估费用÷本次总预估费用，按服务返回的图片Token及当次公开单价计算；不包含附图提示词及输出变化。Seed 默认 high 单图按 1280 Token 规则估算时标注“约占”；已有记录也可按该规则补展示。缺少其他必要明细或缓存无法按模态拆分时显示—。"
            }
            let metadata = NSStackView(views: [modelInfo, timing]); metadata.orientation = .vertical
            metadata.alignment = .leading; metadata.spacing = 4
            views.append(metadata)
            if entry.audioSpeedComparison != nil {
                views.append(note("原速 · 音频 Token " + (stats?.audioTokens.map(String.init) ?? "—"), size: 11.5))
            }
            for comparison in [entry.screenshotComparison, entry.audioSpeedComparison].compactMap({ $0 }) {
                let expanded = comparisonExpandedIDs.contains(comparison.id)
                let suffix = comparison.status == "running" ? " · 识别中…" : (comparison.status == "failed" ? " · 未完成" : "")
                let disclosure = NSButton(title: (comparison.speedRate.map { "录音加速 \($0)× 对比" } ?? "无截图对比") + suffix, target: self, action: #selector(toggleComparison(_:)))
                disclosure.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
                disclosure.imagePosition = .imageLeading; disclosure.isBordered = false
                disclosure.font = NSFont(name: "PingFangSC-Regular", size: 11.5); disclosure.contentTintColor = Glass.secondary
                disclosure.identifier = NSUserInterfaceItemIdentifier(comparison.id)
                disclosure.toolTip = "仅保存对比，不回填输入框；加速对比保持主请求的截图与提示词不变"
                let comparisonHeader = NSStackView(views: [disclosure, spring()]); comparisonHeader.alignment = .centerY
                views.append(comparisonHeader)
                if expanded {
                    if comparison.status == "complete" {
                        let result = NSTextField(wrappingLabelWithString: comparison.text)
                        result.font = NSFont(name: "PingFangSC-Regular", size: 13); result.textColor = Glass.text; result.isSelectable = true
                        result.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                        views.append(result)
                        let stats = comparison.statistics
                        let first = stats?.firstTextSeconds.map { String(format: "%.2f s", $0) } ?? "—"
                        let total = stats.map { String(format: "%.2f s", $0.totalSeconds) } ?? "—"
                        let cost = stats?.estimatedCNY.map(historyCostText) ?? "—"
                        let timing = note("首字 \(first)  ·  总耗时 \(total)  ·  预估 \(cost)", size: 11.5)
                        timing.toolTip = "与主请求同一起点：从结束录音开始计时。双路并行可能相互竞争网络及服务配额。\n" + (stats?.pricingNote ?? "")
                        views.append(timing)
                        if let ms = comparison.preparationMS, let before = comparison.originalSeconds, let after = comparison.acceleratedSeconds {
                            let tokens = stats?.audioTokens.map(String.init) ?? "—"
                            views.append(note(String(format: "变速 %d ms  ·  音频 %.1f → %.1f s", ms, before, after) + "  ·  音频 Token \(tokens)", size: 11.5))
                        }
                        let copy = NSButton(title: "复制对比文本", target: self, action: #selector(copyComparison(_:)))
                        copy.isBordered = false; copy.font = NSFont(name: "PingFangSC-Regular", size: 11.5); copy.contentTintColor = Glass.secondary
                        copy.identifier = NSUserInterfaceItemIdentifier(comparison.id)
                        comparisonHeader.addArrangedSubview(copy)
                    } else {
                        views.append(note(comparison.status == "running" ? "对比请求处理中，不影响主结果回填" : comparison.error, size: 11.5))
                    }
                }
            }
            if let message = entry.screenshotNote { views.append(note(message, size: 11)) }
            if failed && !entry.text.isEmpty { let error = note(entry.error, size: 11); error.textColor = .systemRed; views.append(error) }
            let exists = FileManager.default.fileExists(atPath: audioURL(entry).path)
            let play = button(playingID == entry.id ? "停止" : "播放", target: self, action: #selector(playAudio(_:)))
            play.identifier = NSUserInterfaceItemIdentifier(entry.id); play.isEnabled = exists
            let copy = button("复制", target: self, action: #selector(copyText(_:)))
            copy.identifier = NSUserInterfaceItemIdentifier(entry.id); copy.isEnabled = !entry.text.isEmpty
            let retry = button(busyID == entry.id ? "识别中…" : "重新识别", target: self, action: #selector(regenerate(_:)))
            retry.identifier = NSUserInterfaceItemIdentifier(entry.id); retry.isEnabled = exists && busyID == nil && entry.screenshotComparison?.status != "running" && entry.audioSpeedComparison?.status != "running"
            let actions = NSStackView(views: [play, copy, retry, spring()]); actions.spacing = 8; actions.alignment = .centerY
            for action in [play, copy, retry] { action.widthAnchor.constraint(equalToConstant: 100).isActive = true }
            if !exists { views.append(note("录音文件不存在", size: 11)) }
            if let url = screenshotURL(entry) {
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 144, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
                    let thumb = NSButton(image: NSImage(cgImage: cg, size: .zero), target: self, action: #selector(showScreenshot(_:)))
                    thumb.isBordered = false; thumb.imageScaling = .scaleProportionallyUpOrDown
                    thumb.identifier = NSUserInterfaceItemIdentifier(entry.id)
                    thumb.setAccessibilityLabel("查看截图"); thumb.toolTip = entry.screenshotSource == "display" ? "查看录音开始时的屏幕截图" : "查看录音开始时的窗口截图"
                    thumb.wantsLayer = true; thumb.layer?.cornerRadius = 6; thumb.layer?.masksToBounds = true
                    thumb.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
                    thumb.layer?.borderWidth = 1; thumb.layer?.borderColor = NSColor.white.withAlphaComponent(0.8).cgColor
                    thumb.widthAnchor.constraint(equalToConstant: 64).isActive = true; thumb.heightAnchor.constraint(equalToConstant: 40).isActive = true
                    if let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        let sizeText = note(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file), size: 11)
                        sizeText.toolTip = "实际提交的压缩截图大小"
                        actions.addArrangedSubview(sizeText)
                    }
                    actions.addArrangedSubview(thumb)
                } else { views.append(note("截图文件不存在", size: 11)) }
            }
            views.append(actions)
            let item = card(views, spacing: 10)
            content.addArrangedSubview(item); item.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
    }
    private func changeRetention(enabled: Bool, limit: Int) {
        do {
            try onRetentionChange?(enabled, limit)
            historyEnabled = enabled; historyLimit = limit
        } catch {
            let alert = NSAlert(); alert.messageText = "历史记录设置未完成"; alert.informativeText = error.localizedDescription
            if let window { alert.beginSheetModal(for: window) }
        }
        refresh(items)
    }
    @objc private func historyEnabledChanged(_ sender: GlassToggle) {
        if sender.state == .on { changeRetention(enabled: true, limit: historyLimit); return }
        sender.state = .on
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = "关闭历史记录？"
        alert.informativeText = "将删除全部历史文字、录音和截图，且无法恢复。关闭后，新录音也不会保留历史记录。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "关闭并清空")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self else { return }
            self.stopPlayback(); self.changeRetention(enabled: false, limit: self.historyLimit)
        }
    }
    @objc private func historyLimitChanged(_ sender: NSPopUpButton) { changeRetention(enabled: historyEnabled, limit: Settings.historyLimits[sender.indexOfSelectedItem]) }
    @objc private func toggleComparison(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if comparisonExpandedIDs.contains(id) { comparisonExpandedIDs.remove(id) } else { comparisonExpandedIDs.insert(id) }
        refresh(items)
    }
    @objc private func copyComparison(_ sender: NSButton) {
        guard let text = items.flatMap({ [$0.screenshotComparison, $0.audioSpeedComparison].compactMap { $0 } }).first(where: { $0.id == sender.identifier?.rawValue })?.text, !text.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    @objc private func toggleText(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if expandedIDs.contains(id) { expandedIDs.remove(id) } else { expandedIDs.insert(id) }
        refresh(items)
    }
    private func screenshotURL(_ entry: HistoryEntry) -> URL? {
        guard let name = entry.screenshot, !name.isEmpty else { return nil }
        return screenshotDirectory.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
    }
    @objc private func showScreenshot(_ sender: NSButton) {
        guard let entry = items.first(where: { $0.id == sender.identifier?.rawValue }), let url = screenshotURL(entry), let image = NSImage(contentsOf: url) else { return }
        screenshotPreview?.close()
        let screen = window?.screen?.visibleFrame.size ?? NSSize(width: 1000, height: 750)
        let size = NSSize(width: min(960, screen.width - 80), height: min(700, screen.height - 80))
        let preview = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        preview.title = entry.screenshotSource == "display" ? "屏幕截图 · 录音开始时" : "窗口截图 · 录音开始时"
        preview.isReleasedWhenClosed = false; preview.minSize = NSSize(width: 360, height: 240)
        let view = NSImageView(); view.image = image; view.imageScaling = .scaleProportionallyUpOrDown
        preview.contentView = view; preview.center()
        screenshotPreview = NSWindowController(window: preview); previewEntryID = entry.id
        screenshotPreview?.showWindow(nil); preview.makeKeyAndOrderFront(nil)
    }
    @objc private func clearHistory() {
        guard !items.isEmpty, busyID == nil, let window else { return }
        let alert = NSAlert()
        alert.messageText = "清空历史记录？"
        alert.informativeText = "将删除本地保存的全部历史文字、录音和截图，无法撤销。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "清空")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self else { return }
            self.stopPlayback()
            do { try self.onClear?() }
            catch {
                let failure = NSAlert()
                failure.messageText = "未能清空全部历史记录"
                failure.informativeText = "部分文件可能已删除，请稍后重试。"
                failure.beginSheetModal(for: window)
            }
        }
    }
    private func audioURL(_ entry: HistoryEntry) -> URL { Paths.recordings.appendingPathComponent(URL(fileURLWithPath: entry.audio).lastPathComponent) }
    @objc private func playAudio(_ sender: NSButton) {
        guard let entry = items.first(where: { $0.id == sender.identifier?.rawValue }) else { return }
        player?.stop(); playbackToken = UUID()
        if playingID == entry.id { player = nil; playingID = nil; refresh(items); return }
        let token = playbackToken; let url = audioURL(entry)
        playingID = entry.id; refresh(items)
        Task { @MainActor in
            do {
                let data = try await Task.detached(priority: .userInitiated) { try AudioPlayback.enhanced(url) }.value
                guard token == playbackToken else { return }
                let sound = try AVAudioPlayer(data: data)
                sound.currentDevice = AudioPlayback.outputUID; sound.volume = 1
                sound.delegate = self; sound.prepareToPlay(); player = sound
                guard sound.play() else { throw VoiceError(message: "录音无法播放") }
            } catch {
                guard token == playbackToken else { return }
                player = nil; playingID = nil; refresh(items)
                let alert = NSAlert(); alert.messageText = "无法播放录音"; alert.informativeText = error.localizedDescription
                if let window { await alert.beginSheetModal(for: window) }
            }
        }
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { playingID = nil; self.player = nil; refresh(items) }
    @objc private func copyText(_ sender: NSButton) {
        guard let entry = items.first(where: { $0.id == sender.identifier?.rawValue }), !entry.text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(entry.text, forType: .string) {
            (sender as? GlassButton)?.setTitle("已复制")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak sender] in (sender as? GlassButton)?.setTitle("复制") }
        }
    }
    @objc private func regenerate(_ sender: NSButton) { if let id = sender.identifier?.rawValue { onRegenerate?(id) } }
}

/// 失焦时系统会把毛玻璃和原生玻璃切成“非活跃”(变实变白);这个窗口始终报告自己是活跃的,外观不随焦点变化。
final class AlwaysActiveWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        positionWindowButtons()
    }
    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        positionWindowButtons()
    }
    private func positionWindowButtons() {
        guard !styleMask.contains(.fullScreen),
              let close = standardWindowButton(.closeButton), let titlebar = close.superview else { return }
        // 给下移后的原生按钮保留完整点击区域；固定位置，避免重复布局累加偏移。
        let height: CGFloat = 40
        if titlebar.frame.height < height {
            var frame = titlebar.frame
            frame.origin.y -= height - frame.height; frame.size.height = height
            titlebar.frame = frame
        }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { standardWindowButton($0) }
        let spacing = buttons.count > 1 ? buttons[1].frame.minX - close.frame.minX : 20
        for (index, button) in buttons.enumerated() {
            var frame = button.frame
            frame.origin.x = 14 + CGFloat(index) * spacing
            frame.origin.y = titlebar.isFlipped ? 15 : titlebar.bounds.height - 15 - frame.height
            button.setFrameOrigin(frame.origin)
        }
    }
}
/// 设置窗口:左侧分栏,改动立即保存,没有“保存”按钮。
final class SettingsWindow: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    enum Tab: Int, CaseIterable {
        case general, service, dictionary, audio, history, permissions, tools
        var title: String { ["通用", "模型配置", "个人词典", "麦克风与提示音", "历史记录", "权限", "附带工具"][rawValue] }
        var symbol: String { ["keyboard", "cloud", "character.book.closed", "mic", "clock", "checkmark.shield", "wrench.and.screwdriver"][rawValue] }
        var asset: String { ["keyboard", "cloud", "dictionary", "microphone", "history", "shield", "tools"][rawValue] }
    }
    private(set) var settings: Settings
    private var volcanoFastSwitch: GlassToggle!
    private var volcanoFastRow: NSView!
    private let geminiHint = note("通过系统代理连接 · 使用所选模型的最低推理等级", size: 11)
    private var providerName: String
    private let providerKeys = Provider.order
    private var sidebarButtons: [NSButton] = []
    private var sidebarHighlights: [GlassView] = []
    private var sidebarView: NSView?
    private var windowVeil: NSView?
    private var edgeView: EdgeGlowView?
    private let container = NSView()
    private var panes: [Tab: NSView] = [:]
    private var current: Tab = .general
    // 通用
    private var screenshotMarkupSwitch: GlassToggle!
    private var screenshotToolSwitch: GlassToggle!
    private var screenshotToolOptions: NSView!
    private let screenshotKeyLabel = label("", size: 13)
    private var screenshotKeyButton: GlassButton!
    private let screenshotKeyError = note("", size: 11)
    private var capturingScreenshotKey = false
    private var capturingSecondaryScreenshotKey = false
    private var capturingDictionaryKey = false
    private let secondaryScreenshotKeyLabel = label("", size: 13)
    private var secondaryScreenshotKeyButton: GlassButton!
    private let hotkey = NSTextField()
    private let hotkeyError = note("", size: 11)
    private var recordButton: GlassButton!
    private let keyCap = GlassView(role: .keycap)
    private let modeHint = note("")
    private let keyCapLabel = label("", size: 14)
    private var appearanceControl: GlassSegmented!
    private let appearanceKeys = ["system", "light", "dark"]
    private var modeControl: GlassSegmented!
    private var mouseSwitch: GlassToggle!
    private var punctSwitch: GlassToggle!
    private var autostartSwitch: GlassToggle!
    // 识别服务
    private var providerControl: GlassSegmented!
    private let apiKey = NSSecureTextField()
    private let model = NSPopUpButton(frame: .zero, pullsDown: false)
    private let baseURL = NSTextField()
    private let checkResult: NSTextField = {
        let field = StatusNote(wrappingLabelWithString: "")
        field.font = NSFont(name: "PingFangSC-Regular", size: 12); field.textColor = Glass.secondary
        field.isHidden = true; field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }()
    private let prompt = NSTextView()
    private var contextSwitch: GlassToggle!
    private var screenshotSwitch: GlassToggle!
    private let screenshotStatus = note("", size: 12)
    private var screenshotHelp: NSStackView!
    private var screenshotRestart: GlassButton!
    private var screenshotTimer: Timer?
    private var screenshotConsentShown = false
    private var versionClicks: [Double] = []
    private var developerAlert: NSAlert?
    // 麦克风与提示音
    private let microphoneList = stack([], spacing: 0)
    private var microphones: [Microphone] = []
    private var soundSwitch: GlassToggle!
    private var overlayPositionControl: GlassSegmented!
    private let overlayPositionHint = note("", size: 11.5)
    private let overlayPositionKeys = ["window", "bottom", "cursor"]
    private var styleControl: GlassSegmented!
    private let volume = NSSlider(value: 0.85, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let volumeLabel = label("85%", size: 12)
    let historyPane = HistoryPane()
    let permissionsPane = PermissionsPane()
    private var capturingHotkey = false
    private var loading = false
    var onAppearanceChange: ((String) -> Void)?
    var onChange: ((Settings) -> Void)?

    init(settings: Settings, history: [HistoryEntry]) {
        self.settings = settings; providerName = settings.provider
        AppTheme.apply(settings.appearance)
        let window = AlwaysActiveWindow(contentRect: NSRect(origin: .zero, size: AppWindowLayout.initialSize), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentMinSize = AppWindowLayout.minimum
        window.title = "OneMore"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.center()
        // 保留透出壁纸的系统毛玻璃，外观继承应用设置。
        window.isOpaque = false; window.backgroundColor = .clear; window.appearance = nil
        // 系统投影紧贴外沿会形成深色轮廓;玻璃轮廓由白色边缘与内光定义。
        window.hasShadow = false
        let glass = NSVisualEffectView(); glass.material = .underWindowBackground; glass.blendingMode = .behindWindow; glass.state = .active
        glass.wantsLayer = true; glass.layer?.cornerRadius = Glass.params.windowRadius; glass.layer?.masksToBounds = true
        window.contentView = glass
        let veil = ThemeSurface(fill: { AppTheme.veil }); veil.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(veil)
        NSLayoutConstraint.activate([veil.leadingAnchor.constraint(equalTo: glass.leadingAnchor), veil.trailingAnchor.constraint(equalTo: glass.trailingAnchor), veil.topAnchor.constraint(equalTo: glass.topAnchor), veil.bottomAnchor.constraint(equalTo: glass.bottomAnchor)])
        windowVeil = veil

        super.init(window: window)
        window.delegate = self
        buildLayout()
        historyPane.historyEnabled = settings.history_enabled; historyPane.historyLimit = settings.history_limit
        historyPane.refresh(history)
        load(settings)
        screenshotTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { return }
            self.refreshScreenshotPermission()
        }
    }
    deinit { screenshotTimer?.invalidate() }
    required init?(coder: NSCoder) { fatalError() }
    func windowWillClose(_ notification: Notification) { historyPane.stopPlayback(); cancelKeyCapture() }

    private func buildLayout() {
        guard let root = window?.contentView else { return }
        let sidebar = ThemeSurface(fill: { AppTheme.sidebar })
        sidebarView = sidebar
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let version = label("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"), size: 11)
        version.textColor = Glass.secondary
        version.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(version)
        let versionHit = NSButton(title: "", target: self, action: #selector(versionClicked))
        versionHit.isBordered = false; versionHit.isTransparent = true; versionHit.translatesAutoresizingMaskIntoConstraints = false
        versionHit.setAccessibilityLabel(version.stringValue)
        sidebar.addSubview(versionHit)
        NSLayoutConstraint.activate([
            versionHit.leadingAnchor.constraint(equalTo: version.leadingAnchor, constant: -5),
            versionHit.centerYAnchor.constraint(equalTo: version.centerYAnchor),
            versionHit.widthAnchor.constraint(equalToConstant: 70), versionHit.heightAnchor.constraint(equalToConstant: 26),
            version.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 24),
            version.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -22)
        ])
        let divider = ThemeSurface(fill: { AppTheme.color(.white.withAlphaComponent(0.55), .white.withAlphaComponent(0.08)) })
        divider.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true; container.layer?.backgroundColor = NSColor.white.withAlphaComponent(Glass.params.contentOverlay).cgColor
        Glass.onParamsChange = { [weak self] in self?.applyOverlays() }
        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar); root.addSubview(container); root.addSubview(divider)
        let edge = EdgeGlowView(); edge.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(edge); edgeView = edge
        NSLayoutConstraint.activate([edge.leadingAnchor.constraint(equalTo: root.leadingAnchor), edge.trailingAnchor.constraint(equalTo: root.trailingAnchor), edge.topAnchor.constraint(equalTo: root.topAnchor), edge.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor), sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant: 198),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: root.topAnchor), divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: root.topAnchor), container.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        let colors: [[NSColor]] = [
            [NSColor(srgbRed: 0.49, green: 0.77, blue: 1.0, alpha: 1), NSColor(srgbRed: 0.23, green: 0.55, blue: 1.0, alpha: 1)],
            [NSColor(srgbRed: 0.78, green: 0.66, blue: 1.0, alpha: 1), NSColor(srgbRed: 0.56, green: 0.42, blue: 1.0, alpha: 1)],
            [NSColor(srgbRed: 0.55, green: 0.85, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.25, green: 0.65, blue: 0.85, alpha: 1)],
            [NSColor(srgbRed: 1.0, green: 0.69, blue: 0.60, alpha: 1), NSColor(srgbRed: 1.0, green: 0.42, blue: 0.34, alpha: 1)],
            [NSColor(srgbRed: 1.0, green: 0.83, blue: 0.42, alpha: 1), NSColor(srgbRed: 1.0, green: 0.67, blue: 0.18, alpha: 1)],
            [NSColor(srgbRed: 0.62, green: 0.94, blue: 0.71, alpha: 1), NSColor(srgbRed: 0.31, green: 0.83, blue: 0.50, alpha: 1)]
        ]
        let list = stack([], spacing: 3); list.translatesAutoresizingMaskIntoConstraints = false
        for tab in Tab.allCases {
            // 选中项是一块玻璃;图标是渐变色块;整行用一个透明按钮接点击。
            let holder = NSView(); holder.translatesAutoresizingMaskIntoConstraints = false
            let highlight = GlassView(role: .sidebar); highlight.translatesAutoresizingMaskIntoConstraints = false; highlight.isHidden = true
            holder.addSubview(highlight); sidebarHighlights.append(highlight)
            NSLayoutConstraint.activate([highlight.leadingAnchor.constraint(equalTo: holder.leadingAnchor), highlight.trailingAnchor.constraint(equalTo: holder.trailingAnchor), highlight.topAnchor.constraint(equalTo: holder.topAnchor), highlight.bottomAnchor.constraint(equalTo: holder.bottomAnchor)])
            let icon = glassIcon(tab.symbol, asset: tab.asset, colors: colors[tab.rawValue % colors.count])
            let title = label(tab.title, size: 14); title.textColor = Glass.control; title.translatesAutoresizingMaskIntoConstraints = false
            let hit = NSButton(title: "", target: self, action: #selector(selectTab(_:))); hit.tag = tab.rawValue
            hit.isBordered = false; hit.isTransparent = true; hit.translatesAutoresizingMaskIntoConstraints = false
            hit.setAccessibilityLabel(tab.title)
            holder.addSubview(icon); holder.addSubview(title); holder.addSubview(hit)
            NSLayoutConstraint.activate([
                holder.heightAnchor.constraint(equalToConstant: 40),
                icon.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 8), icon.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
                title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8), title.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
                hit.leadingAnchor.constraint(equalTo: holder.leadingAnchor), hit.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
                hit.topAnchor.constraint(equalTo: holder.topAnchor), hit.bottomAnchor.constraint(equalTo: holder.bottomAnchor)
            ])
            list.addArrangedSubview(holder); holder.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            sidebarButtons.append(hit)
        }
        let brand = BrandHeader(compact: true)
        sidebar.addSubview(brand)
        NSLayoutConstraint.activate([brand.centerXAnchor.constraint(equalTo: sidebar.centerXAnchor), brand.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 43)])
        sidebar.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12), list.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            list.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 24)
        ])
        panes[.general] = buildGeneral(); panes[.service] = buildService(); panes[.audio] = buildAudio()
        panes[.history] = buildHistory(); panes[.permissions] = buildPermissions(); panes[.tools] = buildTools(); panes[.dictionary] = buildDictionary()
        select(.general)
    }
    @objc private func versionClicked() {
        let now = ProcessInfo.processInfo.systemUptime
        versionClicks = versionClicks.filter { now - $0 <= 3 }; versionClicks.append(now)
        guard versionClicks.count >= 5 else { return }
        versionClicks.removeAll()
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = "开发者选项"
        alert.informativeText = "暂无开发者选项"
        alert.addButton(withTitle: "完成")
        developerAlert = alert
        alert.beginSheetModal(for: window) { [weak self] _ in self?.developerAlert = nil }
    }
    private func titled(_ title: String, _ views: [NSView], showsScroller: Bool = false) -> NSScrollView {
        let heading = label(title, size: 23); heading.font = NSFont(name: "PingFangSC-Semibold", size: 23); heading.textColor = Glass.title
        let content = stack([heading] + views, spacing: 12)
        content.setCustomSpacing(12, after: heading)
        return scrollPane(content, margin: 31, trailingMargin: 26, topMargin: 10, showsScroller: showsScroller)
    }
    private func section(_ title: String) -> NSTextField {
        let field = label(title, size: 14); field.font = NSFont(name: "PingFangSC-Medium", size: 14); field.textColor = Glass.section
        return field
    }
    private func buildGeneral() -> NSView {
        hotkey.isHidden = true
        keyCap.translatesAutoresizingMaskIntoConstraints = false
        keyCapLabel.textColor = Glass.control; keyCapLabel.font = .systemFont(ofSize: 13, weight: .regular); keyCapLabel.alignment = .center; keyCapLabel.translatesAutoresizingMaskIntoConstraints = false
        keyCap.content.addSubview(keyCapLabel)
        NSLayoutConstraint.activate([
            keyCap.heightAnchor.constraint(equalToConstant: 36), keyCap.widthAnchor.constraint(equalToConstant: 158),
            keyCapLabel.leadingAnchor.constraint(equalTo: keyCap.content.leadingAnchor, constant: 18), keyCapLabel.trailingAnchor.constraint(equalTo: keyCap.content.trailingAnchor, constant: -18),
            keyCapLabel.centerYAnchor.constraint(equalTo: keyCap.content.centerYAnchor)
        ])
        recordButton = GlassButton("更改", target: self, action: #selector(captureHotkey))
        hotkeyError.textColor = .systemRed; hotkeyError.isHidden = true
        let hotkeyRow = NSStackView(views: [keyCap, recordButton]); hotkeyRow.spacing = 10
        hotkeyRow.setHuggingPriority(.required, for: .horizontal)
        modeControl = segmented(["同时支持", "长按模式", "点按模式"], selected: 0, target: self, action: #selector(modeChanged))
        modeHint.textColor = Glass.secondary; modeHint.font = .systemFont(ofSize: 11.5)
        mouseSwitch = toggle(true, target: self, action: #selector(changed))
        punctSwitch = toggle(false, target: self, action: #selector(changed))
        autostartSwitch = toggle(false, target: self, action: #selector(autostartChanged))
        let info = MouseHelpIcon()
        let mouseHead = label("鼠标长按说话", size: 14.5); mouseHead.textColor = Glass.control
        let mouseTitle = NSStackView(views: [mouseHead, info]); mouseTitle.spacing = 6
        let mouseSub = note("在输入框内按住左键说话，松开输入文字"); mouseSub.textColor = Glass.secondary
        let mouseWords = stack([mouseTitle, mouseSub], spacing: 3)
        let mouseRow = NSStackView(views: [mouseWords, spring(), mouseSwitch]); mouseRow.spacing = 14; mouseRow.alignment = .centerY; mouseRow.distribution = .fill
        let modeTitle = label("触发方式", size: 14.5); modeTitle.textColor = Glass.control
        updateModeHint()
        let keyboard = card([row("快捷键", control: hotkeyRow, titleColor: Glass.control), hotkeyError])
        let trigger = card([modeTitle, modeControl, modeHint], spacing: 7)
        let mouse = card([mouseRow])
        let punctuation = card([row("去掉末尾标点", control: punctSwitch, titleColor: Glass.control)], verticalPadding: 9)
        let launch = card([row("登录时自动启动", control: autostartSwitch, titleColor: Glass.control)], verticalPadding: 9)
        appearanceControl = GlassSegmented(labels: ["跟随系统", "浅色", "深色"], symbols: ["desktopcomputer", "sun.max", "moon"])
        appearanceControl.target = self; appearanceControl.action = #selector(appearanceChanged)
        appearanceControl.selectedSegment = appearanceKeys.firstIndex(of: settings.appearance) ?? 0
        let appearance = card([row("外观", control: appearanceControl, titleColor: Glass.control)], verticalPadding: 9)
        return titled("通用", [keyboard, trigger, mouse, punctuation, launch, appearance], showsScroller: true)
    }

    private func buildTools() -> NSView {
        screenshotToolSwitch = toggle(settings.screenshot_tool_enabled, target: self, action: #selector(changed))
        screenshotToolSwitch.setAccessibilityLabel("启用截图工具")
        screenshotKeyButton = GlassButton("更改", target: self, action: #selector(captureScreenshotKey))
        screenshotKeyLabel.alignment = .center
        let screenshotKeys = NSStackView(views: [inputSurface(screenshotKeyLabel), screenshotKeyButton!])
        screenshotKeys.spacing = 10
        screenshotKeyLabel.widthAnchor.constraint(equalToConstant: 134).isActive = true
        screenshotKeyError.textColor = .systemRed
        screenshotMarkupSwitch = toggle(settings.screenshot_markup, target: self, action: #selector(changed))
        screenshotMarkupSwitch.setAccessibilityLabel("支持标记")
        secondaryScreenshotKeyButton = GlassButton("更改", target: self, action: #selector(captureSecondaryScreenshotKey))
        secondaryScreenshotKeyLabel.alignment = .center
        secondaryScreenshotKeyLabel.widthAnchor.constraint(equalToConstant: 134).isActive = true
        let secondaryKeys = NSStackView(views: [inputSurface(secondaryScreenshotKeyLabel), secondaryScreenshotKeyButton!])
        secondaryKeys.spacing = 10
        screenshotToolOptions = card([row("截图快捷键 1", control: screenshotKeys, titleColor: Glass.control),
            row("截图快捷键 2", control: secondaryKeys, titleColor: Glass.control), screenshotKeyError,
            row("支持标记", control: screenshotMarkupSwitch, titleColor: Glass.control)])
        let heading = label("截图工具", size: 17)
        heading.font = NSFont(name: "PingFangSC-Medium", size: 17)
        heading.textColor = Glass.section
        let header = NSStackView(views: [heading, spring(), screenshotToolSwitch!])
        header.alignment = .centerY
        header.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        return titled("附带工具", [header, screenshotToolOptions])
    }

    private func updateScreenshotToolAvailability(_ enabled: Bool) {
        screenshotToolOptions.alphaValue = enabled ? 1 : 0.45
        screenshotKeyButton.isEnabled = enabled
        secondaryScreenshotKeyButton.isEnabled = enabled
        screenshotMarkupSwitch.isEnabled = enabled
    }

    private func buildService() -> NSView {
        providerControl = segmented(Provider.order.map { Provider.titles[$0]! }, selected: 0, target: self, action: #selector(providerChanged), recommended: 0)
        apiKey.placeholderString = "输入 API Key"; apiKey.target = self; apiKey.action = #selector(changed)
        apiKey.setAccessibilityLabel("API Key")
        let check = button("测试连接", target: self, action: #selector(runCheck(_:)))
        let keyRow = NSStackView(views: [inputSurface(apiKey), check]); keyRow.spacing = 10; keyRow.alignment = .centerY
        check.setContentHuggingPriority(.required, for: .horizontal)
        model.isBordered = false; model.font = NSFont(name: "PingFangSC-Regular", size: 13)
        model.target = self; model.action = #selector(changed)
        model.setAccessibilityLabel("模型")
        baseURL.target = self; baseURL.action = #selector(changed); baseURL.setAccessibilityLabel("接口地址")
        prompt.font = NSFont(name: "PingFangSC-Regular", size: 13); prompt.textColor = Glass.text
        prompt.isRichText = false; prompt.delegate = self; prompt.drawsBackground = false
        prompt.textContainerInset = NSSize(width: 10, height: 9); prompt.autoresizingMask = [.width]; prompt.textContainer?.widthTracksTextView = true
        let editor = ThemeEditorScroll(); editor.documentView = prompt; editor.hasVerticalScroller = false; editor.autohidesScrollers = true
        editor.drawsBackground = false; editor.borderType = .noBorder
        editor.wantsLayer = true; editor.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.24).cgColor
        editor.layer?.cornerRadius = 10; editor.layer?.borderWidth = 0.8; editor.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        editor.heightAnchor.constraint(equalToConstant: 110).isActive = true
        let reset = button("恢复默认", target: self, action: #selector(resetPrompt))
        contextSwitch = toggle(true, target: self, action: #selector(changed))
        contextSwitch.setAccessibilityLabel("应用名称与窗口标题")
        screenshotSwitch = toggle(false, target: self, action: #selector(screenshotChanged))
        screenshotSwitch.setAccessibilityLabel("窗口截图")
        screenshotRestart = GlassButton("重启应用", target: self, action: #selector(restartApp))
        screenshotRestart.isHidden = true
        let repair = NSStackView(views: [button("前往设置", target: self, action: #selector(openScreenshotSettings)), button("重新检测", target: self, action: #selector(recheckScreenshot)), screenshotRestart!, button("取消", target: self, action: #selector(cancelScreenshot)), spring()])
        repair.spacing = 8
        screenshotHelp = stack([screenshotStatus, repair], spacing: 8)
        screenshotHelp.isHidden = true
        volcanoFastSwitch = toggle(settings.volcano_fast, target: self, action: #selector(changed))
        volcanoFastSwitch.setAccessibilityLabel("Fast 低延迟")
        let fastTitle = NSStackView(views: [label("Fast 低延迟", size: 14.5), MouseHelpIcon(fastHelp: true)])
        fastTitle.spacing = 6; fastTitle.alignment = .centerY
        let fastLine = NSStackView(views: [fastTitle, spring(), volcanoFastSwitch!])
        fastLine.spacing = 14; fastLine.alignment = .centerY
        volcanoFastRow = fastLine
        volcanoFastRow.toolTip = "降低响应延迟，费用为常规档的 2 倍；需在火山方舟开通对应模型的 Fast 权限。"
        let connection = card([label("API Key", size: 14.5), keyRow, checkResult,
            label("模型", size: 14.5), inputSurface(model), geminiHint, volcanoFastRow!])
        // 标题与“提示词”同级，子选项缩进并使用较小字号；开关保持右侧对齐。
        func contextOption(_ title: String, control: NSView) -> NSView {
            let line = NSStackView(views: [label(title, size: 13), spring(), control])
            line.spacing = 14; line.alignment = .centerY
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            return line
        }
        let children = stack([contextOption("应用名称与窗口标题", control: contextSwitch), contextOption("窗口截图", control: screenshotSwitch), screenshotHelp], spacing: 12)
        let inset = NSView(); children.translatesAutoresizingMaskIntoConstraints = false; inset.addSubview(children)
        NSLayoutConstraint.activate([children.leadingAnchor.constraint(equalTo: inset.leadingAnchor, constant: 16), children.trailingAnchor.constraint(equalTo: inset.trailingAnchor), children.topAnchor.constraint(equalTo: inset.topAnchor), children.bottomAnchor.constraint(equalTo: inset.bottomAnchor)])
        for child in children.arrangedSubviews { child.widthAnchor.constraint(equalTo: children.widthAnchor).isActive = true }
        return titled("模型配置", [providerControl, connection,
            card([row("提示词", control: reset), editor]),
            card([label("附带应用上下文", size: 14.5), inset], spacing: 16)])
    }
    private func buildAudio() -> NSView {
        overlayPositionControl = segmented(["跟随窗口", "固定底部", "跟随光标"], selected: 0, target: self, action: #selector(changed))
        soundSwitch = toggle(true, target: self, action: #selector(changed))
        styleControl = segmented(Cues.styles.map(\.title), selected: 0, target: self, action: #selector(styleChanged))
        volume.target = self; volume.action = #selector(volumeChanged)
        volume.setAccessibilityLabel("提示音音量")
        volumeLabel.widthAnchor.constraint(equalToConstant: 38).isActive = true
        let preview = button("试听", target: self, action: #selector(previewSound))
        let volumeRow = NSStackView(views: [label("音量", size: 13), volume, volumeLabel, preview])
        volumeRow.spacing = 12; volumeRow.alignment = .centerY
        preview.setContentHuggingPriority(.required, for: .horizontal)
        return titled("麦克风与提示音", [
            card([label("麦克风选择", size: 14.5), microphoneList]),
            card([row("录音提示音", control: soundSwitch), styleControl, volumeRow]),
            card([label("胶囊位置", size: 14.5), overlayPositionControl, overlayPositionHint])])
    }

    private func updateOverlayPositionHint() {
        overlayPositionHint.stringValue = [
            "显示在当前窗口下方 56pt；空间不足时移到内侧底部，无法获取窗口时固定在屏幕底部。",
            "固定在触发所在屏幕的底部中央，距底部 56pt。",
            "显示在触发时鼠标位置下方 56pt；靠近屏幕底部时移到上方。"
        ][overlayPositionControl.selectedSegment]
    }

    let dictionaryPane = DictionaryPane()
    private let dictionaryKeyLabel = label("", size: 13)
    private var dictionaryKeyButton: GlassButton!
    private let dictionaryKeyError = note("", size: 11)
    private var learnControl: GlassSegmented!
    private func buildDictionary() -> NSView {
        dictionaryKeyButton = GlassButton("更改", target: self, action: #selector(captureDictionaryKey))
        dictionaryKeyLabel.alignment = .center; dictionaryKeyLabel.textColor = Glass.control
        dictionaryKeyLabel.widthAnchor.constraint(equalToConstant: 134).isActive = true
        let dictionaryKeys = NSStackView(views: [inputSurface(dictionaryKeyLabel), dictionaryKeyButton!]); dictionaryKeys.spacing = 10
        dictionaryKeyError.textColor = .systemRed; dictionaryKeyError.isHidden = true
        learnControl = segmented(["每次询问", "第 2 次自动记住", "关闭"], selected: 0, target: self, action: #selector(changed))
        let options = card([
            row("选中文字加入词典", "在任何地方选中词,按这个快捷键", control: dictionaryKeys, titleColor: Glass.control),
            dictionaryKeyError,
            row("从你的修改里学", "语音打完 15 秒内你改了某个词,就问要不要记住;⌘⏎ 或点胶囊确认", control: NSView(), titleColor: Glass.control),
            learnControl
        ])
        // 设置项在上、词条列表在下:词多了只往下长,整页可滚,不需要再做收起。
        return titled("个人词典", [note("常用的人名、专有名词、英文短语,识别时优先按这些写法。", size: 13), options, dictionaryPane])
    }
    func setDictionaryHotkeyError(_ message: String?) {
        dictionaryKeyError.stringValue = message ?? ""; dictionaryKeyError.isHidden = message == nil
    }
    private func buildHistory() -> NSView { scrollPane(stack([historyPane]), margin: 31, trailingMargin: 26, topMargin: 10, showsScroller: true) }
    private func buildPermissions() -> NSView {
        let restart = button("重启应用", target: self, action: #selector(restartApp))
        let reveal = button("在 Finder 中显示", target: self, action: #selector(revealApp))
        let actions = NSStackView(views: [restart, reveal, spring()]); actions.spacing = 10
        restart.widthAnchor.constraint(equalToConstant: 146).isActive = true
        reveal.widthAnchor.constraint(equalTo: restart.widthAnchor).isActive = true
        return titled("权限", [permissionsPane,
            card([label("权限未生效？", size: 14.5), note("在系统设置中添加本应用,开启权限后重启一次。"), actions])])
    }

    /// 把设置灌进控件;菜单栏改了设置时也会调用。
    func load(_ value: Settings) {
        loading = true; defer { loading = false }
        settings = value; providerName = value.provider
        appearanceControl.selectedSegment = appearanceKeys.firstIndex(of: value.appearance) ?? 0
        AppTheme.apply(value.appearance)
        historyPane.historyEnabled = value.history_enabled; historyPane.historyLimit = value.history_limit
        screenshotToolSwitch.state = value.screenshot_tool_enabled ? .on : .off
        updateScreenshotToolAvailability(value.screenshot_tool_enabled)
        screenshotMarkupSwitch.state = value.screenshot_markup ? .on : .off
        screenshotKeyLabel.stringValue = screenshotHotkeyDisplay(value.screenshot_hotkey)
        secondaryScreenshotKeyLabel.stringValue = screenshotHotkeyDisplay(value.screenshot_hotkey_secondary)
        dictionaryKeyLabel.stringValue = screenshotHotkeyDisplay(value.dictionary_hotkey)
        learnControl.selectedSegment = ["ask", "auto", "off"].firstIndex(of: value.dictionary_learn) ?? 0
        screenshotKeyError.isHidden = screenshotKeyError.stringValue.isEmpty
        hotkey.stringValue = value.hotkey; hotkeyError.stringValue = ""; hotkeyError.isHidden = true; keyCapLabel.stringValue = hotkeyDisplay(value.hotkey)
        modeControl.selectedSegment = ["both", "hold", "toggle"].firstIndex(of: value.mode) ?? 0; updateModeHint()
        mouseSwitch.state = value.mouse_longpress ? .on : .off
        overlayPositionControl.selectedSegment = overlayPositionKeys.firstIndex(of: value.overlay_position) ?? 0
        updateOverlayPositionHint()
        punctSwitch.state = value.strip_trailing_punct ? .on : .off
        autostartSwitch.state = Startup.enabled ? .on : .off
        providerControl.selectedSegment = providerKeys.firstIndex(of: value.provider) ?? 0
        loadProvider()
        prompt.string = value.prompt
        contextSwitch.state = value.app_context ? .on : .off
        updateScreenshotUI()
        reloadMicrophones()
        soundSwitch.state = value.sound ? .on : .off
        styleControl.selectedSegment = Cues.styles.firstIndex { $0.key == value.sound_style } ?? 0
        volume.doubleValue = value.sound_volume; volumeLabel.stringValue = "\(Int(value.sound_volume * 100))%"
    }
    func disableFastAfterFallback() {
        settings.volcano_fast = false
        volcanoFastSwitch.state = .off
        if providerName == "volcano" { checkResult.stringValue = "Fast 未开通，已关闭开关，正在使用常规档重试。" }
    }
    private func loadProvider() {
        geminiHint.isHidden = providerName != "gemini"
        volcanoFastRow.isHidden = providerName != "volcano"
        volcanoFastSwitch.state = settings.volcano_fast ? .on : .off
        let value = settings.providers[providerName]!
        apiKey.stringValue = value.api_key; baseURL.stringValue = value.base_url
        model.removeAllItems()
        var ids = providerName.hasPrefix("bailian") ? ["qwen3.5-omni-flash", "qwen3-omni-flash", "qwen3.8-omni-flash"] : (providerName == "gemini" ? GeminiAPI.models : (providerName == "volcano" ? Provider.volcanoModels : ["mimo-v2.6-flash"]))
        // 展示名称与接口 ID 分离，保留已有自定义模型。
        if !value.model.isEmpty, !ids.contains(value.model) { ids.append(value.model) }
        for id in ids {
            model.addItem(withTitle: Provider.modelTitle(id))
            model.lastItem?.representedObject = id
        }
        if let index = ids.firstIndex(of: value.model) { model.selectItem(at: index) }
        checkResult.stringValue = ""
    }
    private func reloadMicrophones() {
        for view in microphoneList.arrangedSubviews { microphoneList.removeArrangedSubview(view); view.removeFromSuperview() }
        microphones = Microphone.list()
        let auto = Microphone.preferred(microphones, defaultID: Microphone.defaultID())
        let manual = microphones.firstIndex { settings.device_uid.isEmpty ? (!settings.device.isEmpty && $0.name == settings.device) : $0.uid == settings.device_uid }
        func radio(_ title: String, _ detail: String, tag: Int, on: Bool) -> NSView {
            let control = NSButton(radioButtonWithTitle: title, target: self, action: #selector(microphoneChosen(_:)))
            control.tag = tag; control.isEnabled = tag != -2; control.state = on ? .on : .off; control.font = NSFont(name: "PingFangSC-Regular", size: 14)
            var views: [NSView] = [control]
            if !detail.isEmpty { let text = note(detail); views.append(text) }
            let words = stack(views, spacing: 2); words.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [words, spring()]); row.spacing = 10; row.alignment = .centerY
            row.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
            return row
        }
        microphoneList.addArrangedSubview(radio("自动", "当前：\(auto?.name ?? "系统默认") · 优先使用有线或内建麦克风", tag: -1, on: manual == nil))
        for (index, mic) in microphones.enumerated() {
            let detail = mic.rank == 2 ? "开麦要等约 0.7 秒,录音时耳机里听不到提示音" : ""
            microphoneList.addArrangedSubview(radio(mic.name, detail, tag: index, on: manual == index))
        }
        if manual == nil, !settings.device.isEmpty || !settings.device_uid.isEmpty {
            microphoneList.addArrangedSubview(radio("未连接:\(settings.device)", "连上后会自动用它;现在先按“自动”选", tag: -2, on: true))
        }
        for view in microphoneList.arrangedSubviews { view.widthAnchor.constraint(equalTo: microphoneList.widthAnchor).isActive = true }
    }

    func select(_ tab: Tab) {
        current = tab
        for (index, item) in sidebarButtons.enumerated() {
            guard let holder = item.superview else { continue }
            sidebarHighlights[index].isHidden = index != tab.rawValue
            for case let text as NSTextField in holder.subviews { text.font = .systemFont(ofSize: 14, weight: .regular) }
        }
        for view in container.subviews { view.removeFromSuperview() }
        guard let pane = panes[tab] else { return }
        pane.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pane)
        NSLayoutConstraint.activate([pane.leadingAnchor.constraint(equalTo: container.leadingAnchor), pane.trailingAnchor.constraint(equalTo: container.trailingAnchor), pane.topAnchor.constraint(equalTo: container.topAnchor, constant: 30), pane.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
        if tab == .audio { reloadMicrophones() }
        if tab == .permissions { permissionsPane.refresh() }
        // 打开或切页时不自动选中任何输入框,免得热键框一进来就处于编辑状态。
        DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(nil) }
    }
    @objc private func selectTab(_ sender: NSButton) { select(Tab(rawValue: sender.tag) ?? .general) }
    private func applyOverlays() {
        edgeView?.needsDisplay = true
        window?.contentView?.layer?.cornerRadius = Glass.params.windowRadius
        (windowVeil as? ThemeSurface)?.refresh()
        (sidebarView as? ThemeSurface)?.refresh()
        container.layer?.backgroundColor = NSColor.white.withAlphaComponent(Glass.params.contentOverlay).cgColor

    }

    // 热键录入:按下的键累计(可组合),第一次松开时定稿。
    private var capturedCodes: [CGKeyCode] = []
    func setScreenshotHotkeyError(_ message: String?) {
        screenshotKeyError.stringValue = message ?? ""
        screenshotKeyError.isHidden = message == nil
    }
    @objc private func captureScreenshotKey() {
        if capturingHotkey { cancelKeyCapture(); return }
        capturingScreenshotKey = true; capturingHotkey = true; capturedCodes = []
        screenshotKeyLabel.stringValue = "请按键…"; screenshotKeyButton.setTitle("取消")
        setScreenshotHotkeyError(nil)
    }
    @objc private func captureSecondaryScreenshotKey() {
        if capturingHotkey { cancelKeyCapture(); return }
        capturingScreenshotKey = true; capturingSecondaryScreenshotKey = true; capturingHotkey = true; capturedCodes = []
        secondaryScreenshotKeyLabel.stringValue = "请按键…"; secondaryScreenshotKeyButton.setTitle("取消")
        setScreenshotHotkeyError(nil)
    }
    @objc private func captureDictionaryKey() {
        if capturingHotkey { cancelKeyCapture(); return }
        capturingDictionaryKey = true; capturingHotkey = true; capturedCodes = []
        dictionaryKeyLabel.stringValue = "请按键…"; dictionaryKeyButton.setTitle("取消")
        setDictionaryHotkeyError(nil)
    }
    private func cancelKeyCapture() {
        capturingDictionaryKey = false
        dictionaryKeyLabel.stringValue = screenshotHotkeyDisplay(settings.dictionary_hotkey); dictionaryKeyButton.setTitle("更改")
        capturingSecondaryScreenshotKey = false
        secondaryScreenshotKeyLabel.stringValue = screenshotHotkeyDisplay(settings.screenshot_hotkey_secondary)
        secondaryScreenshotKeyButton.setTitle("更改")
        capturingHotkey = false; capturingScreenshotKey = false; capturedCodes = []
        keyCapLabel.stringValue = hotkeyDisplay(settings.hotkey); recordButton.setTitle("更改")
        screenshotKeyLabel.stringValue = screenshotHotkeyDisplay(settings.screenshot_hotkey); screenshotKeyButton.setTitle("更改")
    }
    @objc private func captureHotkey() {
        if capturingHotkey { cancelKeyCapture(); return }
        capturingScreenshotKey = false
        capturingHotkey = true; capturedCodes = []
        keyCapLabel.stringValue = "请按键…"; recordButton.setTitle("取消"); hotkeyError.stringValue = ""; hotkeyError.isHidden = true
    }
    var isCapturingHotkey: Bool { capturingHotkey }
    func keyCaptured(_ code: CGKeyCode, down: Bool) {
        guard capturingHotkey else { return }
        if code == 53 { cancelKeyCapture(); return }
        if down { if !capturedCodes.contains(code) { capturedCodes.append(code) }; return }
        guard !capturedCodes.isEmpty else { return }
        if capturingDictionaryKey {
            let names = capturedCodes.compactMap { HotkeyMonitor.name(for: $0) }
            let candidate = names.map { $0.replacingOccurrences(of: "left ", with: "").replacingOccurrences(of: "right ", with: "") }.joined(separator: "+")
            do {
                guard names.count == capturedCodes.count else { throw VoiceError(message: "这个按键暂不支持") }
                let binding = try ScreenshotTool.binding(candidate)
                for other in [settings.screenshot_hotkey, settings.screenshot_hotkey_secondary] where !other.isEmpty {
                    if let b = try? ScreenshotTool.binding(other), b == binding { throw VoiceError(message: "和截图快捷键重复了") }
                }
                let voice = try HotkeyMonitor.parse(settings.hotkey), selected = try HotkeyMonitor.parse(candidate)
                guard !(voice.count == selected.count && voice.allSatisfy({ v in selected.contains { !v.isDisjoint(with: $0) } })) else { throw VoiceError(message: "和语音快捷键重复了") }
                settings.dictionary_hotkey = candidate
                cancelKeyCapture(); changed()
            } catch { cancelKeyCapture(); setDictionaryHotkeyError(error.localizedDescription) }
            return
        }
        if capturingScreenshotKey {
            let names = capturedCodes.compactMap { HotkeyMonitor.name(for: $0) }
            let candidate = names.map { $0.replacingOccurrences(of: "left ", with: "").replacingOccurrences(of: "right ", with: "") }.joined(separator: "+")
            do {
                guard names.count == capturedCodes.count else { throw VoiceError(message: "这个按键暂不支持") }
                _ = try ScreenshotTool.binding(candidate)
                let voice = try HotkeyMonitor.parse(settings.hotkey)
                let selected = try HotkeyMonitor.parse(candidate)
                guard !(voice.count == selected.count && voice.allSatisfy({ v in selected.contains { !v.isDisjoint(with: $0) } })) else { throw VoiceError(message: "截图与语音快捷键不能完全相同") }
                let other = capturingSecondaryScreenshotKey ? settings.screenshot_hotkey : settings.screenshot_hotkey_secondary
                guard try ScreenshotTool.binding(candidate) != ScreenshotTool.binding(other) else { throw VoiceError(message: "两组截图快捷键不能相同") }
                if capturingSecondaryScreenshotKey { settings.screenshot_hotkey_secondary = candidate }
                else { settings.screenshot_hotkey = candidate }
                cancelKeyCapture(); changed()
            } catch { cancelKeyCapture(); setScreenshotHotkeyError(error.localizedDescription) }
            return
        }
        capturingHotkey = false; recordButton.setTitle("更改")
        let names = capturedCodes.map { HotkeyMonitor.name(for: $0) }
        guard names.allSatisfy({ $0 != nil }) else { hotkeyError.stringValue = "有不支持当热键的键"; hotkeyError.isHidden = false; keyCapLabel.stringValue = hotkeyDisplay(settings.hotkey); return }
        hotkey.stringValue = names.compactMap { $0 }.joined(separator: "+"); hotkeyEdited()
    }
    @objc private func hotkeyEdited() {
        do {
            let voice = try HotkeyMonitor.parse(hotkey.stringValue)
            for shortcut in [settings.screenshot_hotkey, settings.screenshot_hotkey_secondary] {
                let screenshot = try HotkeyMonitor.parse(shortcut)
                guard !(voice.count == screenshot.count && voice.allSatisfy({ v in screenshot.contains { !v.isDisjoint(with: $0) } })) else { throw VoiceError(message: "语音快捷键与截图快捷键冲突，请换一个组合") }
            }
            hotkeyError.stringValue = ""; hotkeyError.isHidden = true; keyCapLabel.stringValue = hotkeyDisplay(hotkey.stringValue); changed() }
        catch { hotkeyError.stringValue = error.localizedDescription; hotkeyError.isHidden = false; hotkey.stringValue = settings.hotkey; keyCapLabel.stringValue = hotkeyDisplay(settings.hotkey) }
    }
    private func updateModeHint() {
        modeHint.toolTip = "录音中按 Esc 取消"
        modeHint.stringValue = ["长按说话，松开结束；点按开始，再按结束", "按住快捷键说话，松开结束录音", "按一下开始录音，再按一下结束"][modeControl.selectedSegment]
    }
    @objc private func modeChanged() { updateModeHint(); changed() }
    @objc private func providerChanged() {
        storeProvider()
        providerName = providerKeys[providerControl.selectedSegment]
        loadProvider(); changed()
    }
    private func storeProvider() {
        if providerName == "volcano" { settings.volcano_fast = volcanoFastSwitch.state == .on }
        settings.providers[providerName] = Provider(api_key: apiKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), base_url: baseURL.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), model: (model.selectedItem?.representedObject as? String ?? model.titleOfSelectedItem ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }
    @objc private func runCheck(_ sender: NSButton) {
        guard !CommandLine.arguments.contains("--screenshot-ui-preview") else { return }
        storeProvider(); var trial = settings; trial.provider = providerName
        guard !trial.active.api_key.isEmpty else { checkResult.stringValue = "请先填写 API Key"; return }
        sender.isEnabled = false; (sender as? GlassButton)?.setTitle("测试中…")
        checkResult.stringValue = "正在测试连接…"
        Task { @MainActor in
            let result = await ServiceCheck.run(trial)
            if providerName == trial.provider { checkResult.stringValue = result }
            sender.isEnabled = true; (sender as? GlassButton)?.setTitle("测试连接")
        }
    }
    @objc private func resetPrompt() { prompt.string = Settings().prompt; changed() }
    func textDidChange(_ notification: Notification) { changed() }
    @objc private func microphoneChosen(_ sender: NSButton) {
        for case let row as NSStackView in microphoneList.arrangedSubviews {
            for case let words as NSStackView in row.arrangedSubviews { for case let radio as NSButton in words.arrangedSubviews { radio.state = radio === sender ? .on : .off } }
        }
        if sender.tag >= 0, sender.tag < microphones.count { settings.device = microphones[sender.tag].name; settings.device_uid = microphones[sender.tag].uid }
        else if sender.tag == -1 { settings.device = ""; settings.device_uid = "" }
        changed()
    }
    @objc private func styleChanged() { changed(); previewSound() }
    @objc private func volumeChanged() { volumeLabel.stringValue = "\(Int(volume.doubleValue * 100))%"; changed() }
    @objc private func previewSound() { Cues.preview(volume: volume.doubleValue, style: Cues.styles[styleControl.selectedSegment].key) }
    @objc private func autostartChanged() {
        guard !CommandLine.arguments.contains("--screenshot-ui-preview") else { return }
        do { try Startup.set(autostartSwitch.state == .on) }
        catch { autostartSwitch.state = Startup.enabled ? .on : .off; let alert = NSAlert(); alert.messageText = "无法设置登录自启"; alert.informativeText = error.localizedDescription; alert.runModal() }
        changed()
    }
    // 截图意愿与系统授权分别保存；只在主动录音时采集。
    private func updateScreenshotUI() {
        let granted = (settings.window_screenshot || settings.screenshot_authorization_pending) && CGPreflightScreenCaptureAccess()
        screenshotSwitch.state = settings.window_screenshot && granted ? .on : .off
        screenshotHelp.isHidden = !(settings.screenshot_authorization_pending || (settings.window_screenshot && !granted))
        if screenshotRestart.isHidden { screenshotStatus.stringValue = settings.window_screenshot ? "屏幕录制权限已失效，请重新授权。" : "尚未获得屏幕录制权限。" }
        if screenshotHelp.isHidden { screenshotRestart.isHidden = true }
    }
    private func saveScreenshotState() {
        guard !CommandLine.arguments.contains("--screenshot-ui-preview") else { return }
        // 单独保存，避免授权返回时覆盖正在编辑的模型配置。
        do { try settings.save(); onChange?(settings) }
        catch { screenshotStatus.stringValue = "设置保存失败，请重试。"; screenshotHelp.isHidden = false }
    }
    private func refreshScreenshotPermission() {
        guard !loading, !screenshotConsentShown else { return }
        if settings.screenshot_authorization_pending && CGPreflightScreenCaptureAccess() {
            settings.screenshot_authorization_pending = false
            settings.window_screenshot = true
            saveScreenshotState()
        }
        updateScreenshotUI()
    }
    @objc private func screenshotChanged() {
        guard !CommandLine.arguments.contains("--screenshot-ui-preview") else { updateScreenshotUI(); return }
        guard !loading, !screenshotConsentShown else { return }
        if screenshotSwitch.state == .off { cancelScreenshot(); return }
        screenshotSwitch.state = .off
        if settings.screenshot_consent && CGPreflightScreenCaptureAccess() {
            settings.window_screenshot = true; settings.screenshot_authorization_pending = false
            saveScreenshotState(); updateScreenshotUI(); return
        }
        guard let window else { return }
        // 已开启过但权限被撤销，也必须重新走授权；不悄悄恢复权限。
        let alert = NSAlert()
        alert.messageText = "开启窗口截图"
        alert.informativeText = "识别时，会将当前应用窗口截图发送给模型；无法获取窗口时，使用鼠标所在屏幕的截图。截图可能包含私人信息，需要允许屏幕录制权限。"
        alert.addButton(withTitle: "继续授权")
        alert.addButton(withTitle: "取消")
        screenshotConsentShown = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.screenshotConsentShown = false
            guard response == .alertFirstButtonReturn else { self.updateScreenshotUI(); return }
            self.settings.screenshot_consent = true
            self.settings.screenshot_authorization_pending = true
            self.settings.window_screenshot = false
            self.saveScreenshotState()
            if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
            self.refreshScreenshotPermission()
        }
    }
    @objc private func cancelScreenshot() {
        settings.window_screenshot = false
        settings.screenshot_authorization_pending = false
        screenshotRestart.isHidden = true
        saveScreenshotState(); updateScreenshotUI()
    }
    @objc private func openScreenshotSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
    @objc private func recheckScreenshot() {
        refreshScreenshotPermission()
        if !screenshotHelp.isHidden {
            screenshotStatus.stringValue = "权限尚未生效；若已在系统设置中开启，请重启应用。"
            screenshotRestart.isHidden = false
        }
    }
    @objc private func restartApp() { Permission.restartApp() }
    @objc private func revealApp() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }

    /// 任一控件变化:收集、校验、保存、通知主程序。
    @objc private func appearanceChanged() {
        guard !loading else { return }
        var draft = settings
        draft.appearance = appearanceKeys[appearanceControl.selectedSegment]
        do {
            try draft.save(); settings = draft; AppTheme.apply(draft.appearance)
            onAppearanceChange?(draft.appearance)
        } catch {
            appearanceControl.selectedSegment = appearanceKeys.firstIndex(of: settings.appearance) ?? 0
            let alert = NSAlert(); alert.messageText = "外观设置未能保存"; alert.informativeText = "请稍后重试。"
            if let window { alert.beginSheetModal(for: window) }
        }
    }
    @objc private func changed() {
        guard !loading, !CommandLine.arguments.contains("--screenshot-ui-preview") else { return }
        storeProvider()
        var draft = settings
        draft.provider = providerName
        if (try? HotkeyMonitor.parse(hotkey.stringValue)) != nil { draft.hotkey = hotkey.stringValue }
        draft.mode = ["both", "hold", "toggle"][modeControl.selectedSegment]
        draft.screenshot_tool_enabled = screenshotToolSwitch.state == .on
        updateScreenshotToolAvailability(draft.screenshot_tool_enabled)
        if !draft.screenshot_tool_enabled && capturingScreenshotKey { cancelKeyCapture() }
        draft.screenshot_markup = screenshotMarkupSwitch.state == .on
        draft.mouse_longpress = mouseSwitch.state == .on
        draft.overlay_position = overlayPositionKeys[overlayPositionControl.selectedSegment]
        updateOverlayPositionHint()
        draft.strip_trailing_punct = punctSwitch.state == .on
        draft.autostart = autostartSwitch.state == .on
        draft.prompt = prompt.string
        draft.app_context = contextSwitch.state == .on
        draft.sound = soundSwitch.state == .on
        draft.sound_style = Cues.styles[styleControl.selectedSegment].key
        draft.sound_volume = volume.doubleValue
        draft.dictionary_hotkey = settings.dictionary_hotkey
        draft.dictionary_learn = ["ask", "auto", "off"][learnControl.selectedSegment]
        if let url = URL(string: draft.active.base_url), ["https", "http"].contains(url.scheme ?? ""), url.host != nil {} else {
            checkResult.stringValue = "接口地址无效,未保存"; return
        }
        if draft.active.model.isEmpty { checkResult.stringValue = "模型不能为空,未保存"; return }
        settings = draft
        do { try draft.save() } catch { checkResult.stringValue = "保存失败:\(error.localizedDescription)" }
        onChange?(draft)
    }
}

/// 首次使用：与主窗口同尺寸、同材质；预览模式不保存配置或申请权限。
final class OnboardingWindow: NSWindowController, NSWindowDelegate {
    private var step = 1
    private var settings: Settings
    private let previewOnly: Bool
    private var steps: GlassSegmented!
    private var providerControl: GlassSegmented!
    private let apiKey = NSSecureTextField()
    private let checkResult = note("API Key 仅保存在这台电脑上。", size: 12)
    private let tryBox = NSTextView()
    private let title = label("", size: 25, bold: true)
    private let subtitle = note("", size: 13)
    private let headingIcon = NSImageView()
    private let body = NSView()
    private var back: GlassButton!
    private var next: GlassButton!
    private var recordButton: GlassButton!
    private let keyLabel = label("", size: 13)
    private let keyHint = note("按一下开始，再按一下结束；也可以按住说话，松开结束。", size: 12)
    private let providerKeys = Provider.order
    private var permissionButtons: [GlassButton] = []
    private var permissionTimer: Timer?
    private var keyMonitor: Any?
    private var capturedCodes: [CGKeyCode] = []
    private(set) var isCapturingHotkey = false
    var onChange: ((Settings) -> Void)?
    var onFinish: (() -> Void)?
    init(settings: Settings, previewOnly: Bool = false) {
        self.settings = settings; self.previewOnly = previewOnly
        let window = AlwaysActiveWindow(contentRect: NSRect(origin: .zero, size: AppWindowLayout.initialSize), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "OneMore"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.center(); window.hasShadow = false
        window.isOpaque = false; window.backgroundColor = .clear; window.appearance = nil
        let glass = NSVisualEffectView(); glass.material = .underWindowBackground; glass.blendingMode = .behindWindow; glass.state = .active
        glass.wantsLayer = true; glass.layer?.cornerRadius = Glass.params.windowRadius; glass.layer?.masksToBounds = true
        window.contentView = glass
        let veil = ThemeSurface(fill: { AppTheme.veil });
        veil.translatesAutoresizingMaskIntoConstraints = false; glass.addSubview(veil)
        NSLayoutConstraint.activate([veil.leadingAnchor.constraint(equalTo: glass.leadingAnchor), veil.trailingAnchor.constraint(equalTo: glass.trailingAnchor), veil.topAnchor.constraint(equalTo: glass.topAnchor), veil.bottomAnchor.constraint(equalTo: glass.bottomAnchor)])
        super.init(window: window); window.delegate = self
        steps = segmented(["① 开启权限", "② 模型配置", "③ 试着说话"], selected: 0, target: self, action: #selector(stepChanged))
        steps.translatesAutoresizingMaskIntoConstraints = false
        let stepHolder = NSView(); stepHolder.translatesAutoresizingMaskIntoConstraints = false; stepHolder.addSubview(steps)
        NSLayoutConstraint.activate([stepHolder.heightAnchor.constraint(equalToConstant: 42), steps.widthAnchor.constraint(equalToConstant: 470), steps.centerXAnchor.constraint(equalTo: stepHolder.centerXAnchor), steps.centerYAnchor.constraint(equalTo: stepHolder.centerYAnchor)])
        title.textColor = Glass.title
        headingIcon.imageScaling = .scaleProportionallyUpOrDown
        headingIcon.widthAnchor.constraint(equalToConstant: 48).isActive = true; headingIcon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let head = NSStackView(views: [headingIcon, stack([title, subtitle], spacing: 6), spring()]); head.spacing = 14; head.alignment = .centerY
        providerControl = segmented(Provider.order.map { Provider.titles[$0]! }, selected: providerKeys.firstIndex(of: settings.provider) ?? 0, target: self, action: #selector(providerChanged), recommended: 0)
        apiKey.placeholderString = "输入 API Key"; apiKey.stringValue = previewOnly ? "" : settings.active.api_key
        apiKey.font = .systemFont(ofSize: 14); apiKey.isBordered = false; apiKey.drawsBackground = false; apiKey.focusRingType = .none
        tryBox.font = NSFont(name: "PingFangSC-Regular", size: 14); tryBox.isRichText = false; tryBox.drawsBackground = false; tryBox.textColor = Glass.text; tryBox.textContainerInset = NSSize(width: 12, height: 12)
        back = GlassButton("上一步", target: self, action: #selector(goBack)); next = GlassButton("下一步", target: self, action: #selector(goNext))
        next.usePrimaryStyle()
        let later = NSButton(title: "跳过", target: self, action: #selector(skip)); later.isBordered = false; later.font = .systemFont(ofSize: 12); later.contentTintColor = Glass.secondary
        let footer = NSStackView(views: [later, spring(), back, next]); footer.spacing = 9
        body.translatesAutoresizingMaskIntoConstraints = false
        let brand = BrandHeader()
        let brandRow = NSView(); brandRow.translatesAutoresizingMaskIntoConstraints = false; brandRow.addSubview(brand)
        NSLayoutConstraint.activate([brandRow.heightAnchor.constraint(equalToConstant: 56), brand.centerXAnchor.constraint(equalTo: brandRow.centerXAnchor), brand.centerYAnchor.constraint(equalTo: brandRow.centerYAnchor)])
        let content = stack([brandRow, stepHolder, head, body, footer], spacing: 12); content.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 34), content.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -34), content.topAnchor.constraint(equalTo: glass.topAnchor, constant: 46), content.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -22)])
        for view in [brandRow, stepHolder, head, body, footer] { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        body.setContentHuggingPriority(.defaultLow, for: .vertical)
        let edge = EdgeGlowView(); edge.translatesAutoresizingMaskIntoConstraints = false; glass.addSubview(edge)
        NSLayoutConstraint.activate([edge.leadingAnchor.constraint(equalTo: glass.leadingAnchor), edge.trailingAnchor.constraint(equalTo: glass.trailingAnchor), edge.topAnchor.constraint(equalTo: glass.topAnchor), edge.bottomAnchor.constraint(equalTo: glass.bottomAnchor)])
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, self.isCapturingHotkey, event.window === self.window else { return event }
            if event.keyCode == 53 { self.cancelCapture(); return nil }
            let down = event.type == .flagsChanged ? HotkeyMonitor.modifierDown(code: event.keyCode, flags: UInt64(event.modifierFlags.rawValue)) : event.type == .keyDown
            self.keyCaptured(event.keyCode, down: down); return nil
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshPermissions() }
        show(step: 1)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { permissionTimer?.invalidate(); if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
    func windowWillClose(_ notification: Notification) { cancelCapture() }
    private func show(step: Int) {
        cancelCapture(); self.step = step; steps.selectedSegment = step - 1
        for view in body.subviews { view.removeFromSuperview() }
        permissionButtons.removeAll()
        back.isHidden = step == 1; next.setTitle(step == 3 ? "开始使用" : "下一步")
        title.stringValue = ["开启权限", "模型配置", "试着说话"][step - 1]
        subtitle.stringValue = ["让语音输入在你需要的时候工作。", "选择服务商，添加 API Key。", "点进输入框，用快捷键开始说话。"][step - 1]
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Icons/\(["shield", "cloud", "microphone"][step - 1]).png") { headingIcon.image = NSImage(contentsOf: url) }
        let content: NSStackView
        switch step {
        case 1:
            var rows: [NSView] = []
            for index in 0..<3 {
                let icon = glassIcon(["mic", "keyboard", "checkmark.shield"][index], asset: ["microphone", "keyboard", "shield"][index], colors: [.systemBlue, .systemPurple])
                let words = stack([label(Permission.names[index], size: 14), note(["录下你说的话，空闲时不占用", "响应快捷键与鼠标长按", "将识别文字输入到光标处"][index], size: 12)], spacing: 3)
                let open = GlassButton("去开启", target: self, action: #selector(openPermission(_:))); open.tag = index
                open.widthAnchor.constraint(equalToConstant: 78).isActive = true; permissionButtons.append(open)
                let line = NSStackView(views: [icon, words, spring(), open]); line.spacing = 12; line.alignment = .centerY
                rows.append(card([line], verticalPadding: 12))
            }
            rows.append(note("可在系统设置中开启，之后随时在「权限」中查看。", size: 12))
            content = stack(rows, spacing: 9); refreshPermissions()
        case 2:
            let check = GlassButton("测试连接", target: self, action: #selector(runCheck))
            let keyRow = NSStackView(views: [inputSurface(apiKey), check]); keyRow.spacing = 10
            content = stack([card([providerControl, label("API Key", size: 14), keyRow, checkResult], spacing: 14, verticalPadding: 18), note("模型和提示词，可稍后在「模型配置」中调整。", size: 12)], spacing: 12)
        default:
            keyLabel.stringValue = hotkeyDisplay(settings.hotkey)
            let keycap = card([keyLabel], verticalPadding: 8); keycap.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
            recordButton = GlassButton("更改", target: self, action: #selector(captureHotkey))
            let shortcut = NSStackView(views: [keycap, recordButton!, spring()]); shortcut.spacing = 12; shortcut.alignment = .centerY
            tryBox.autoresizingMask = [.width]; tryBox.textContainer?.widthTracksTextView = true
            let scroll = ThemeEditorScroll(); scroll.documentView = tryBox; scroll.drawsBackground = false; scroll.borderType = .noBorder; scroll.hasVerticalScroller = false
            scroll.wantsLayer = true; scroll.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor; scroll.layer?.cornerRadius = 12; scroll.layer?.borderWidth = 1; scroll.layer?.borderColor = NSColor.white.cgColor
            scroll.heightAnchor.constraint(equalToConstant: 105).isActive = true
            content = stack([card([shortcut, scroll, keyHint], spacing: 10, verticalPadding: 14)])
            DispatchQueue.main.async { self.window?.makeFirstResponder(self.tryBox) }
        }
        content.translatesAutoresizingMaskIntoConstraints = false; body.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: body.leadingAnchor), content.trailingAnchor.constraint(equalTo: body.trailingAnchor), content.topAnchor.constraint(equalTo: body.topAnchor), content.bottomAnchor.constraint(lessThanOrEqualTo: body.bottomAnchor)])
        for view in content.arrangedSubviews { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
    }
    private func refreshPermissions() {
        let granted = Permission.granted
        for (index, button) in permissionButtons.enumerated() { button.setTitle(granted[index] ? "已开启" : "去开启") }
    }
    @objc private func openPermission(_ sender: NSButton) { guard !previewOnly else { return }; Permission.open(sender.tag) { [weak self] in self?.refreshPermissions() } }
    private func storeKey() { settings.providers[settings.provider]!.api_key = apiKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func save() { guard !previewOnly else { return }; try? settings.save(); onChange?(settings) }
    @objc private func providerChanged() {
        storeKey(); settings.provider = providerKeys[providerControl.selectedSegment]
        apiKey.stringValue = previewOnly ? "" : settings.active.api_key; checkResult.stringValue = "API Key 仅保存在这台电脑上。"
    }
    @objc private func runCheck() {
        guard !previewOnly else { checkResult.stringValue = "预览模式，不发起连接测试。"; return }
        storeKey(); guard !settings.active.api_key.isEmpty else { checkResult.stringValue = "请先填写 API Key"; return }
        checkResult.stringValue = "正在测试连接…"; let trial = settings
        Task { @MainActor in checkResult.stringValue = await ServiceCheck.run(trial) }
    }
    @objc private func captureHotkey() {
        if isCapturingHotkey { cancelCapture(); return }
        isCapturingHotkey = true; capturedCodes = []; keyLabel.stringValue = "请按键…"; recordButton.setTitle("取消"); keyHint.stringValue = "按下新快捷键，Esc 取消。"
    }
    private func cancelCapture() { isCapturingHotkey = false; capturedCodes = []; keyLabel.stringValue = hotkeyDisplay(settings.hotkey); recordButton?.setTitle("更改"); keyHint.stringValue = "按一下开始，再按一下结束；也可以按住说话，松开结束。" }
    private func keyCaptured(_ code: CGKeyCode, down: Bool) {
        if down { if !capturedCodes.contains(code) { capturedCodes.append(code) }; return }
        guard !capturedCodes.isEmpty else { return }
        let names = capturedCodes.compactMap { HotkeyMonitor.name(for: $0) }
        let candidate = names.joined(separator: "+")
        guard names.count == capturedCodes.count, (try? HotkeyMonitor.parse(candidate)) != nil else { cancelCapture(); keyHint.stringValue = "这个按键暂不支持，请换一个。"; return }
        settings.hotkey = candidate; cancelCapture(); save()
    }
    func preview(step: Int) { show(step: step) }
    @objc private func stepChanged() { if step == 2 { storeKey(); save() }; show(step: steps.selectedSegment + 1) }
    @objc private func goBack() { if step == 2 { storeKey() }; show(step: max(1, step - 1)) }
    @objc private func goNext() {
        if step == 2 { storeKey(); save() }
        if step == 3 { finish(); return }; show(step: step + 1)
    }
    private func finish() { cancelCapture(); onFinish?() }
    @objc private func skip() { finish() }
}

/// 菜单顶部的状态块:不可点、不高亮。圆点颜色表示状态,下面一行是麦克风和服务。
final class MenuStatusView: NSView {
    private let dot = NSView()
    private let title = label("", size: 13, bold: true)
    private let detail = note("", size: 11)
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 48))
        dot.wantsLayer = true; dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        title.translatesAutoresizingMaskIntoConstraints = false
        detail.translatesAutoresizingMaskIntoConstraints = false; detail.maximumNumberOfLines = 1; detail.lineBreakMode = .byTruncatingTail
        addSubview(dot); addSubview(title); addSubview(detail)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), dot.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8), title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor), detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(title text: String, detail info: String, color: NSColor) {
        title.stringValue = text; detail.stringValue = info; dot.layer?.backgroundColor = color.cgColor
    }
}

enum Startup {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/com.daiwen.voice-input.plist")
    static var enabled: Bool { !Paths.isDevelopment && FileManager.default.fileExists(atPath: url.path) }
    static func set(_ enabled: Bool) throws {
        guard !Paths.isDevelopment else { throw VoiceError(message: "本地开发版不设置登录自启，请使用正式版") }
        let domain = "gui/\(getuid())"
        func launch(_ args: [String]) -> Int32 {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
        }
        _ = launch(["bootout",domain,url.path])
        if !enabled { try? FileManager.default.removeItem(at: url); return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let object: [String: Any] = ["Label":"com.daiwen.voice-input","ProgramArguments":["/usr/bin/open","-g",Bundle.main.bundlePath],"RunAtLoad":true,"ProcessType":"Interactive"]
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0).write(to: url, options: .atomic)
        if launch(["bootstrap",domain,url.path]) != 0 { try? FileManager.default.removeItem(at: url); throw VoiceError(message: "无法设置登录自启") }
    }
}

/// 胶囊里的动态部分:录音波形、准备中的三个点、识别中的进度条。
final class WaveView: NSView {
    enum Mode { case bars, dots, progress, spinner }
    var target: Double = 0
    var mode: Mode = .bars
    var color: NSColor = .white
    private var smooth: Double = 0
    private var phase: Double = 0
    func advance() {
        smooth += (target - smooth) * (target > smooth ? 0.48 : 0.16)
        phase += 0.17
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        switch mode {
        case .dots:
            for i in 0..<3 {
                let alpha = 0.3 + 0.65 * (sin(phase * 1.3 - Double(i) * 0.9) + 1) / 2
                color.withAlphaComponent(alpha).setFill()
                NSBezierPath(ovalIn: NSRect(x: bounds.midX - 14 + CGFloat(i) * 12, y: bounds.midY - 3, width: 6, height: 6)).fill()
            }
        case .spinner:
            let center = NSPoint(x: bounds.midX, y: bounds.midY)
            let radius = max(1, min(bounds.width, bounds.height) / 2 - 1.5)
            color.withAlphaComponent(0.22).setStroke()
            let track = NSBezierPath(ovalIn: NSRect(x: center.x-radius, y: center.y-radius, width: radius*2, height: radius*2))
            track.lineWidth = 1.5; track.stroke()
            color.setStroke()
            let arc = NSBezierPath(); arc.lineWidth = 1.5; arc.lineCapStyle = .round
            arc.appendArc(withCenter: center, radius: radius, startAngle: CGFloat(-phase*80), endAngle: CGFloat(-phase*80+100))
            arc.stroke()
        case .progress:
            color.withAlphaComponent(0.25).setFill()
            let barHeight: CGFloat = bounds.height <= 6 ? 2 : 3
            NSBezierPath(roundedRect: NSRect(x: 0, y: bounds.midY - barHeight / 2, width: bounds.width, height: barHeight), xRadius: 1, yRadius: 1).fill()
            color.setFill()
            if target > 0 {
                // 确定进度(纠错询问的倒计时):从满到空
                NSBezierPath(roundedRect: NSRect(x: 0, y: bounds.midY - barHeight / 2, width: bounds.width * CGFloat(target), height: barHeight), xRadius: 1, yRadius: 1).fill()
            } else {
                let width = bounds.width * 0.45
                let x = (bounds.width + width) * CGFloat((sin(phase * 0.9) + 1) / 2) - width
                NSBezierPath(roundedRect: NSRect(x: max(0, x), y: bounds.midY - barHeight / 2, width: min(width, bounds.width - max(0, x)), height: barHeight), xRadius: 1, yRadius: 1).fill()
            }
        case .bars:
            let count = 18
            let step = bounds.width / CGFloat(count)
            for i in 0..<count {
                let center = 1 - abs(Double(i) - Double(count - 1) / 2) / (Double(count) / 2)
                let motion = 0.35 + 0.65 * abs(sin(Double(i) * 0.72 + phase))
                let height = CGFloat(3 + 17 * smooth * motion * (0.45 + 0.55 * center))
                color.withAlphaComponent(0.55 + center * 0.45).setFill()
                NSBezierPath(roundedRect: NSRect(x: CGFloat(i) * step, y: (bounds.height - height) / 2, width: 2.5, height: height), xRadius: 1.25, yRadius: 1.25).fill()
            }
        }
    }
}

enum OverlayState {
    case preparing
    case recording(level: Double, seconds: Int)
    case processing
    case done
    case error(String)
    case copied(partial: Bool)
    case fastFallback
    case screenshotCopied
    case learnAsk(term: String, progress: Double)   // 记住 X?  底部进度条
    case learned(terms: [String])                   // 已记住 / 已加入词典
    /// 错误只说一句人话,详细原因留在历史记录。
    static func shortMessage(_ message: String) -> String {
        if message.contains("没有听清") || message.contains("没有录到") { return "没听清,再说一次" }
        if message.contains("API Key") { return "先填 API Key" }
        if message.contains("权限") { return "缺权限,看菜单栏" }
        if message.contains("麦克风") { return "麦克风打不开" }
        let first = message.components(separatedBy: CharacterSet(charactersIn: ",，。;；:：\n")).first ?? message
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 14 ? String(trimmed.prefix(14)) + "…" : trimmed
    }
}

/// 无焦点自绘玻璃胶囊，与设置窗同源材质，固定160×40，无录音计时。
enum OverlayPlacement {
    static func origin(size: NSSize, frame: CGRect, pointer: NSPoint?, window: CGRect? = nil) -> NSPoint {
        if let window {
            let x = min(max(window.midX - size.width / 2, frame.minX + 8), frame.maxX - size.width - 8)
            let outside = window.minY - 56 - size.height
            let y = outside >= frame.minY + 8 ? outside : max(window.minY, frame.minY) + 56
            return NSPoint(x: x, y: min(max(y, frame.minY + 8), frame.maxY - size.height - 8))
        }
        guard let pointer else { return NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 56) }
        let x = min(max(pointer.x - size.width / 2, frame.minX + 8), frame.maxX - size.width - 8)
        let below = pointer.y - 56 - size.height
        let y = below >= frame.minY + 8 ? below : pointer.y + 56
        return NSPoint(x: x, y: min(max(y, frame.minY + 8), frame.maxY - size.height - 8))
    }
}

final class Overlay: NSObject {
    let panel: NSPanel
    private let message = label("", size: 12, bold: true)
    private let icon = NSImageView()
    private let hint = label("", size: 10)
    private let wave = WaveView(frame: .zero)
    private var animation: Timer?
    private var hideTimer: Timer?
    private let background = ThemeSurface(fill: { AppTheme.veil })
    private var placementFrame: CGRect?
    private var placementPoint: NSPoint?
    private var placementWindow: CGRect?
    var awaitingPosition = false
    var onTap: (() -> Void)?
    /// 一次录音锁定触发所在屏幕，避免准备/录音/识别之间跳动。
    func lockPosition(at point: NSPoint, mode: String = "bottom", window: CGRect? = nil) {
        placementWindow = mode == "window" ? window : nil
        placementPoint = mode == "cursor" ? point : nil
        let screen: NSScreen?
        if let window = placementWindow {
            screen = NSScreen.screens.max { a, b in
                let ar = a.frame.intersection(window), br = b.frame.intersection(window)
                return (ar.isNull ? 0 : ar.width * ar.height) < (br.isNull ? 0 : br.width * br.height)
            }
        } else { screen = NSScreen.screens.first { $0.frame.contains(point) } }
        placementFrame = (screen ?? NSScreen.main)?.visibleFrame
    }
    private let accent = NSColor(srgbRed: 0.12, green: 0.43, blue: 0.84, alpha: 1)
    private let blue = NSColor(srgbRed: 0.30, green: 0.62, blue: 1.0, alpha: 1)
    private let red = NSColor(srgbRed: 1.0, green: 0.353, blue: 0.373, alpha: 1)
    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: 40), styleMask: [.borderless,.nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.ignoresMouseEvents = true
        panel.hasShadow = false
        super.init()
        background.wantsLayer = true
        // 与设置窗口同一分层：活跃毛玻璃底 + 白色薄层 + 自绘轮廓光。
        panel.appearance = nil
        let glass = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 160, height: 40))
        glass.material = .underWindowBackground
        glass.blendingMode = .behindWindow; glass.state = .active
        glass.wantsLayer = true; glass.layer?.cornerRadius = 20; glass.layer?.masksToBounds = true
        panel.contentView = glass
        background.frame = glass.bounds; background.autoresizingMask = [.width, .height]
        glass.addSubview(background)
        let edge = EdgeGlowView(frame: glass.bounds)
        edge.radiusOverride = 20; edge.glowWidthOverride = 5
        edge.autoresizingMask = [.width, .height]
        glass.addSubview(edge)
        icon.imageScaling = .scaleProportionallyUpOrDown
        message.textColor = Glass.text; message.lineBreakMode = .byTruncatingTail; message.alignment = .center
        for view in [icon, wave, message, hint] { background.addSubview(view) }
        background.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(tapped)))
    }
    @objc private func tapped() { onTap?() }
    func show(_ state: OverlayState) {
        if awaitingPosition {
            switch state {
            case .preparing, .recording, .processing: return
            case .done, .error, .copied, .fastFallback, .screenshotCopied, .learnAsk, .learned: awaitingPosition = false
            }
        }
        hideTimer?.invalidate(); hideTimer = nil
        panel.ignoresMouseEvents = true
        let size = NSSize(width: 160, height: 40)
        icon.isHidden = true; wave.isHidden = true; message.isHidden = true; hint.isHidden = true
        switch state {
        case .preparing:
            wave.isHidden = false; wave.mode = .dots; wave.color = Glass.control
            wave.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        case .recording(let level, _):
            icon.isHidden = false; icon.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "录音中"); icon.contentTintColor = accent
            icon.frame = NSRect(x: 30, y: 11, width: 14, height: 18)
            wave.isHidden = false; wave.mode = .bars; wave.color = accent; wave.target = level
            wave.frame = NSRect(x: 56, y: 10, width: 74, height: 20)
        case .processing:
            message.isHidden = false; message.stringValue = "识别中"; message.font = .systemFont(ofSize: 11, weight: .regular); message.alignment = .center
            message.frame = NSRect(x: 70, y: 12, width: 42, height: 16)
            wave.isHidden = false; wave.mode = .spinner; wave.color = Glass.control
            wave.frame = NSRect(x: 48, y: 13, width: 14, height: 14)
        case .done:
            hide(); return
        case .learnAsk(let term, let progress):
            // 记住 X？ / ⌘⏎ 或点一下 ;底部 2pt 倒计时条
            icon.isHidden = false; icon.image = NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: "词典"); icon.contentTintColor = accent
            icon.frame = NSRect(x: 12, y: 12, width: 14, height: 16)
            let attributed = NSMutableAttributedString(string: "记住 ", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: Glass.text])
            attributed.append(NSAttributedString(string: term, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: accent]))
            attributed.append(NSAttributedString(string: "？", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: Glass.text]))
            message.isHidden = false; message.attributedStringValue = attributed; message.alignment = .left
            message.frame = NSRect(x: 33, y: 21, width: 120, height: 14)
            hint.isHidden = false; hint.stringValue = "⌘⏎ 或点一下"; hint.alignment = .left; hint.textColor = Glass.secondary
            hint.frame = NSRect(x: 33, y: 7, width: 120, height: 13)
            wave.isHidden = false; wave.mode = .progress; wave.color = accent; wave.target = max(0.001, progress)
            wave.frame = NSRect(x: 12, y: 1, width: size.width - 24, height: 4)
            panel.ignoresMouseEvents = false
        case .learned(let terms):
            let shown = terms.count > 2 ? terms.prefix(2).joined(separator: "、") + " 等 \(terms.count) 个" : terms.joined(separator: "、")
            icon.isHidden = false; icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "已记住"); icon.contentTintColor = accent
            icon.frame = NSRect(x: 12, y: 13, width: 14, height: 14)
            let attributed = NSMutableAttributedString(string: terms.count == 1 ? "已记住 " : "已加入词典 ", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: Glass.text])
            attributed.append(NSAttributedString(string: shown, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: accent]))
            message.isHidden = false; message.attributedStringValue = attributed; message.alignment = .left
            message.frame = NSRect(x: 33, y: 12, width: 120, height: 16)
            hideTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { [weak self] _ in self?.fadeOut() }
        case .screenshotCopied:
            message.isHidden = false; message.stringValue = "已复制截图"
            message.font = .systemFont(ofSize: 11); message.alignment = .center
            message.frame = NSRect(x: 8, y: 12, width: 144, height: 16)
            hideTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in self?.fadeOut() }
        case .fastFallback:
            message.isHidden = false; message.stringValue = "Fast 未开通"
            message.font = .systemFont(ofSize: 11, weight: .medium); message.alignment = .center
            message.frame = NSRect(x: 8, y: 21, width: 144, height: 14)
            hint.isHidden = false; hint.stringValue = "本次已使用常规档"
            hint.textColor = Glass.secondary; hint.alignment = .center
            hint.frame = NSRect(x: 8, y: 6, width: 144, height: 14)
            hideTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in self?.fadeOut() }
        case .copied(let partial):
            icon.isHidden = false
            icon.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "完整结果已复制")
            icon.contentTintColor = accent
            icon.frame = NSRect(x: 12, y: 12, width: 14, height: 17)
            message.isHidden = false
            message.stringValue = partial ? "输入中断 · 已复制全文" : "已复制全文"
            message.font = .systemFont(ofSize: 10.5, weight: .medium)
            message.alignment = .left
            message.frame = NSRect(x: 33, y: 21, width: 120, height: 14)
            hint.isHidden = false; hint.stringValue = "按 ⌘V 手动粘贴"; hint.alignment = .left
            hint.textColor = Glass.secondary
            hint.frame = NSRect(x: 33, y: 6, width: 120, height: 14)
            hideTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in self?.fadeOut() }
        case .error(let text):
            icon.isHidden = false; icon.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "未识别成功")
            icon.contentTintColor = Glass.text
            icon.frame = NSRect(x: 12, y: 13, width: 14, height: 14)
            message.isHidden = false; message.stringValue = OverlayState.shortMessage(text)
            message.font = .systemFont(ofSize: 11, weight: .regular); message.alignment = .center
            message.frame = NSRect(x: 32, y: 12, width: 116, height: 16)
            hideTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in self?.fadeOut() }
        }
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size))
        if !panel.isVisible {
            panel.alphaValue = 0; panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in context.duration = 0.12; panel.animator().alphaValue = 1 }
        } else { panel.alphaValue = 1 }
        if animation == nil {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.wave.advance() }
            RunLoop.main.add(timer, forMode: .common); animation = timer
        }
    }
    /// 固定在目标屏幕可用区域底部上方56pt，避开Dock。
    private func origin(for size: NSSize) -> NSPoint {
        if placementFrame == nil { lockPosition(at: NSEvent.mouseLocation) }
        let frame = placementFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        return OverlayPlacement.origin(size: size, frame: frame, pointer: placementPoint, window: placementWindow)
    }
    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ context in context.duration = 0.18; panel.animator().alphaValue = 0 }) { [weak self] in
            guard let self, self.panel.alphaValue == 0 else { return }
            self.hide()
        }
    }
    func hide() {
        hideTimer?.invalidate(); hideTimer = nil
        animation?.invalidate(); animation = nil
        panel.orderOut(nil); panel.alphaValue = 1; placementFrame = nil; placementPoint = nil; placementWindow = nil; awaitingPosition = false
    }
}

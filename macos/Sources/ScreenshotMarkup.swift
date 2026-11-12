import AppKit

/// 标记只存在于内存中；按原截图像素导出，不把窗口缩放带入最终图片。
final class ScreenshotMarkupCanvas: NSView, NSTextViewDelegate {
    enum Tool: Int { case rectangle, ellipse, arrow, pen, text }
    struct Mark {
        let tool: Tool
        let color: NSColor
        var points: [NSPoint]
        var text = ""
    }
    private(set) var image: NSImage
    private(set) var pixels: NSSize
    var tool: Tool = .rectangle
    var color: NSColor = .systemRed
    private var marks: [Mark] = []
    private var draft: Mark?
    private var textEditor: NSTextView?
    private var textAnchor = NSPoint.zero
    private var textColor = NSColor.systemRed
    var copyRequested: (() -> Void)?
    var cancelRequested: (() -> Void)?
    init(image: NSImage) {
        self.image = image
        if let rep = image.representations.first {
            pixels = NSSize(width: max(1, rep.pixelsWide), height: max(1, rep.pixelsHigh))
        } else { pixels = image.size }
        super.init(frame: .zero)
    }
    func replaceImage(_ image: NSImage) {
        self.image = image
        if let rep = image.representations.first {
            pixels = NSSize(width: max(1, rep.pixelsWide), height: max(1, rep.pixelsHigh))
        } else { pixels = image.size }
        needsDisplay = true
    }
    required init?(coder: NSCoder) { fatalError() }
    private var imageRect: NSRect {
        let ratio = min(bounds.width / pixels.width, bounds.height / pixels.height)
        let size = NSSize(width: pixels.width * ratio, height: pixels.height * ratio)
        return NSRect(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2, width: size.width, height: size.height)
    }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(imageRect, cursor: tool == .text ? .iBeam : .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        render(in: imageRect)
    }
    private func render(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSBezierPath(rect: rect).addClip()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        let scale = rect.width / pixels.width
        // 笔宽随图片分辨率适当调整，但窗口缩放不改变标记比例。
        let width = max(2, pixels.width / 450) * scale
        for mark in marks + (draft.map { [$0] } ?? []) {
            let points = mark.points.map { NSPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
            guard let first = points.first, let last = points.last else { continue }
            mark.color.setStroke(); mark.color.setFill()
            let path = NSBezierPath(); path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
            switch mark.tool {
            case .rectangle, .ellipse:
                let rect = NSRect(x: min(first.x,last.x), y: min(first.y,last.y), width: abs(last.x-first.x), height: abs(last.y-first.y))
                if mark.tool == .ellipse { path.appendOval(in: rect) } else { path.appendRect(rect) }
                path.stroke()
            case .pen:
                path.move(to: first)
                for point in points.dropFirst() { path.line(to: point) }
                path.stroke()
            case .arrow:
                let dx = last.x-first.x, dy = last.y-first.y
                let length = hypot(dx, dy)
                guard length > 0.5 else { continue }
                let ux = dx/length, uy = dy/length
                func vertex(_ distance: CGFloat, _ offset: CGFloat) -> NSPoint {
                    NSPoint(x: first.x + ux*distance - uy*offset, y: first.y + uy*distance + ux*offset)
                }
                // 实心锥形箭身，尾部细、肩部宽；箭头尺寸随拖拽适度增长。
                let headLength = min(length * 0.45, max(width * 8, length * 0.18))
                let shoulder = length - headLength
                let headHalf = headLength * 0.48
                let neckHalf = headHalf * 0.38
                let tailHalf = min(width * 0.35, neckHalf * 0.25)
                let arrow = NSBezierPath()
                arrow.move(to: vertex(0, tailHalf))
                arrow.line(to: vertex(shoulder, neckHalf))
                arrow.line(to: vertex(shoulder, headHalf))
                arrow.line(to: last)
                arrow.line(to: vertex(shoulder, -headHalf))
                arrow.line(to: vertex(shoulder, -neckHalf))
                arrow.line(to: vertex(0, -tailHalf))
                arrow.close(); arrow.fill()
            case .text:
                let font = NSFont.systemFont(ofSize: max(18, pixels.width / 40) * scale, weight: .semibold)
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: mark.color]
                let available = max(1, rect.maxX-first.x)
                let text = mark.text as NSString
                let measured = text.boundingRect(with: NSSize(width: available,height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin,.usesFontLeading], attributes: attributes)
                text.draw(with: NSRect(x: first.x,y: first.y-ceil(measured.height),width: available,height: ceil(measured.height)), options: [.usesLineFragmentOrigin,.usesFontLeading], attributes: attributes)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    private func point(_ event: NSEvent) -> NSPoint {
        let p = convert(event.locationInWindow, from: nil), rect = imageRect
        return NSPoint(x: min(1,max(0,(p.x-rect.minX)/rect.width)), y: min(1,max(0,(p.y-rect.minY)/rect.height)))
    }
    override func mouseDown(with event: NSEvent) {
        guard imageRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        finishText()
        window?.makeFirstResponder(self)
        let p = point(event)
        if tool == .text { beginText(at: p); return }
        draft = Mark(tool: tool, color: color, points: [p,p]); needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard draft != nil else { return }
        if draft?.tool == .pen { draft?.points.append(point(event)) }
        else {
            var end = point(event)
            if draft?.tool == .ellipse, event.modifierFlags.contains(.shift), let start = draft?.points.first {
                let dx = (end.x-start.x)*pixels.width, dy = (end.y-start.y)*pixels.height
                let availableX = (dx < 0 ? start.x : 1-start.x)*pixels.width
                let availableY = (dy < 0 ? start.y : 1-start.y)*pixels.height
                let side = min(max(abs(dx),abs(dy)),availableX,availableY)
                end = NSPoint(x: start.x + (dx < 0 ? -side : side)/pixels.width, y: start.y + (dy < 0 ? -side : side)/pixels.height)
            }
            draft?.points[1] = end
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        guard let draft else { return }
        marks.append(draft); self.draft = nil; needsDisplay = true
    }
    private func beginText(at point: NSPoint) {
        textAnchor = point; textColor = color
        let rect = imageRect
        let font = NSFont.systemFont(ofSize: max(18,pixels.width/40) * rect.width/pixels.width, weight: .semibold)
        let x = rect.minX + point.x*rect.width, top = rect.minY + point.y*rect.height
        let editor = NSTextView(frame: NSRect(x: x,y: top-font.pointSize*1.5,width: max(8,rect.maxX-x),height: font.pointSize*1.5))
        editor.font = font; editor.textColor = color; editor.insertionPointColor = color
        editor.isRichText = false; editor.drawsBackground = false
        editor.textContainerInset = .zero; editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: editor.bounds.width,height: .greatestFiniteMagnitude)
        editor.isHorizontallyResizable = false; editor.isVerticallyResizable = false
        editor.delegate = self
        editor.setAccessibilityLabel("截图标记文字")
        addSubview(editor); textEditor = editor
        window?.makeFirstResponder(editor)
    }
    func textDidChange(_ notification: Notification) {
        guard let editor = textEditor, let layout = editor.layoutManager, let container = editor.textContainer else { return }
        layout.ensureLayout(for: container)
        let height = max((editor.font?.pointSize ?? 14)*1.5, ceil(layout.usedRect(for: container).height)+2)
        let top = imageRect.minY + textAnchor.y*imageRect.height
        editor.frame.origin.y = top-height
        editor.frame.size.height = height
    }
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // 中文输入法确认候选时先交给系统，不把选字的回车当作复制。
        guard !textView.hasMarkedText() else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
            finishText(); copyRequested?(); return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { cancelRequested?(); return true }
        return false
    }
    func finishText() {
        guard let editor = textEditor else { return }
        let text = editor.string
        textEditor = nil
        window?.makeFirstResponder(self); editor.removeFromSuperview()
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            marks.append(Mark(tool: .text, color: textColor, points: [textAnchor], text: text))
        }
        needsDisplay = true
    }
    func undoMark() { draft = nil; if !marks.isEmpty { marks.removeLast() }; needsDisplay = true }
    func renderedImage() -> NSImage? {
        finishText()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        render(in: NSRect(origin: .zero, size: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: pixels); result.addRepresentation(rep); return result
    }
}

final class ScreenshotOverlayPanel: NSPanel {
    var command: ((UInt16) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        if command?(event.keyCode) == true { return }
        super.keyDown(with: event)
    }
}

/// 独立顶层控制框，避免画布或文字编辑器吞掉控制点事件。
final class ScreenshotSelectionChrome: NSView {
    weak var owner: ScreenshotSelectionView?
    private static func diagonalCursor(_ symbol: String) -> NSCursor {
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "缩放选区") else { return .resizeLeftRight }
        let cursorImage = image.copy() as! NSImage
        cursorImage.size = NSSize(width: 20,height: 20)
        return NSCursor(image: cursorImage, hotSpot: NSPoint(x: 10,y: 10))
    }
    private static let risingCursor = diagonalCursor("arrow.up.right.and.arrow.down.left")
    private static let fallingCursor = diagonalCursor("arrow.up.left.and.arrow.down.right")
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard let owner, let rect = owner.selection else { return nil }
        return owner.handle(at: local) != nil || (owner.allowsMove && rect.contains(local)) ? self : nil
    }
    override func resetCursorRects() {
        guard let owner, let rect = owner.selection else { return }
        if owner.allowsMove { addCursorRect(rect, cursor: .openHand) }
        for (index, point) in owner.handles {
            let cursor: NSCursor
            if index < 4 { cursor = index == 0 || index == 3 ? Self.risingCursor : Self.fallingCursor }
            else { cursor = index < 6 ? .resizeLeftRight : .resizeUpDown }
            addCursorRect(owner.hitRect(point), cursor: cursor)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let owner, let rect = owner.selection else { return }
        NSColor.systemBlue.setStroke()
        let border = NSBezierPath(rect: rect); border.lineWidth = 1; border.stroke()
        for (_, point) in owner.handles {
            // 控制点向屏幕内夹紧，贴边时仍完整可见。
            let handle = NSBezierPath(rect: NSRect(x: min(max(0,point.x-3),bounds.width-6), y: min(max(0,point.y-3),bounds.height-6), width: 6,height: 6))
            NSColor.white.setFill(); handle.fill()
            NSColor.systemBlue.setStroke(); handle.lineWidth = 1; handle.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) { owner?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { owner?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { owner?.mouseUp(with: event) }
}

final class ScreenshotSelectionView: NSView {
    let image: NSImage
    var selection: NSRect?
    var allowsMove = true
    let chrome = ScreenshotSelectionChrome()
    private var start: NSPoint?
    private var original: NSRect?
    private var activeHandle: Int?
    var onSelect: ((NSRect) -> Void)?
    var onBeginAdjustment: (() -> Void)?
    var handles: [(Int, NSPoint)] {
        guard let r = selection else { return [] }
        return [NSPoint(x:r.minX,y:r.minY), NSPoint(x:r.maxX,y:r.minY),
                NSPoint(x:r.minX,y:r.maxY), NSPoint(x:r.maxX,y:r.maxY),
                NSPoint(x:r.minX,y:r.midY), NSPoint(x:r.maxX,y:r.midY),
                NSPoint(x:r.midX,y:r.minY), NSPoint(x:r.midX,y:r.maxY)].enumerated().map { ($0.offset,$0.element) }
    }
    func hitRect(_ point: NSPoint) -> NSRect {
        NSRect(x: point.x-7,y: point.y-7,width: 14,height: 14).intersection(bounds)
    }
    func handle(at point: NSPoint) -> Int? { handles.first { hitRect($0.1).contains(point) }?.0 }
    init(image: NSImage) {
        self.image = image; super.init(frame: .zero)
        chrome.owner = self; chrome.autoresizingMask = [.width,.height]
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: bounds)
        let mask = NSBezierPath(rect: bounds)
        if let selection { mask.appendRect(selection); mask.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(0.28).setFill(); mask.fill()
        if let selection { NSColor.systemBlue.setStroke(); NSBezierPath(rect: selection).stroke() }
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        activeHandle = handle(at: p)
        if let selection {
            guard activeHandle != nil || (allowsMove && selection.contains(p)) else { return }
            onBeginAdjustment?(); original = selection
        } else { original = nil }
        window?.makeKey(); window?.makeFirstResponder(self)
        start = p
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let r = original {
            let dx = p.x-start.x, dy = p.y-start.y
            if let h = activeHandle {
                var left = r.minX, right = r.maxX, bottom = r.minY, top = r.maxY
                let minimum: CGFloat = 16
                if [0,2,4].contains(h) { left = min(max(0,r.minX+dx),right-minimum) }
                if [1,3,5].contains(h) { right = max(min(bounds.maxX,r.maxX+dx),left+minimum) }
                if [0,1,6].contains(h) { bottom = min(max(0,r.minY+dy),top-minimum) }
                if [2,3,7].contains(h) { top = max(min(bounds.maxY,r.maxY+dy),bottom+minimum) }
                selection = NSRect(x:left,y:bottom,width:right-left,height:top-bottom)
            } else {
                selection = NSRect(x: min(max(0,r.minX+dx),bounds.width-r.width), y: min(max(0,r.minY+dy),bounds.height-r.height), width:r.width,height:r.height)
            }
            if let selection { onSelect?(selection) }
        } else {
            let end = NSPoint(x:min(max(0,p.x),bounds.maxX),y:min(max(0,p.y),bounds.maxY))
            selection = NSRect(x:min(end.x,start.x),y:min(end.y,start.y),width:abs(end.x-start.x),height:abs(end.y-start.y))
        }
        needsDisplay = true; chrome.needsDisplay = true
        window?.invalidateCursorRects(for: chrome)
    }
    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        mouseDragged(with: event); start = nil; original = nil; activeHandle = nil
        guard let selection, selection.width >= 16, selection.height >= 16 else {
            selection = nil; needsDisplay = true; return
        }
        onSelect?(selection)
    }
}

/// 屏幕原位框选与标记，截图保持原位置和比例，工具条贴近选区。
final class ScreenshotMarkupWindow: NSWindowController {
    private var canvas: ScreenshotMarkupCanvas?
    private let background: ScreenshotSelectionView
    private let snapshot: CGImage
    private var toolbar: NSVisualEffectView?
    private var toolButtons: [NSButton] = []
    private var selectedTool: Int?
    private let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .light)
    private var completion: ((NSImage?) -> Void)?
    var onSelected: (() -> Void)?
    init(image: CGImage, screenFrame: NSRect, completion: @escaping (NSImage?) -> Void) {
        snapshot = image
        background = ScreenshotSelectionView(image: NSImage(cgImage: image, size: screenFrame.size))
        self.completion = completion
        let window = ScreenshotOverlayPanel(contentRect: screenFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = true; window.hasShadow = false; window.hidesOnDeactivate = false
        super.init(window: window)
        window.contentView = background
        background.onBeginAdjustment = { [weak self] in self?.canvas?.finishText() }
        background.onSelect = { [weak self] rect in self?.select(rect) }
        window.command = { [weak self] code in
            guard let self else { return false }
            if code == 53 { self.cancelMarkup(); return true }
            if code == 36 || code == 76 { self.copyImage(); return true }
            return false
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    func present(key: Bool) {
        window?.orderFrontRegardless()
        if key { window?.makeKey(); window?.makeFirstResponder(background) }
    }
    private func select(_ rect: NSRect) {
        let sx = CGFloat(snapshot.width)/background.bounds.width, sy = CGFloat(snapshot.height)/background.bounds.height
        let crop = CGRect(x: rect.minX*sx, y: (background.bounds.height-rect.maxY)*sy, width: rect.width*sx, height: rect.height*sy).integral
        guard let pixels = snapshot.cropping(to: crop) else { cancelMarkup(); return }
        // 点数按像素除以倍率反算,画布 frame 与之一致,预览不再二次缩放。
        let pointSize = NSSize(width: CGFloat(pixels.width) / sx, height: CGFloat(pixels.height) / sy)
        let aligned = NSRect(x: crop.minX / sx, y: background.bounds.height - (crop.minY + crop.height) / sy, width: pointSize.width, height: pointSize.height)
        if let canvas {
            canvas.replaceImage(NSImage(cgImage: pixels, size: pointSize)); canvas.frame = aligned
            positionToolbar(aligned); return
        }
        onSelected?()
        let view = ScreenshotMarkupCanvas(image: NSImage(cgImage: pixels, size: pointSize))
        view.frame = aligned; background.addSubview(view); canvas = view
        view.copyRequested = { [weak self] in self?.copyImage() }
        view.cancelRequested = { [weak self] in self?.cancelMarkup() }
        let names = ["rectangle", "circle", "arrow.up.right", "pencil.tip", "T"]
        let labels = ["画框", "椭圆（按住 Shift 绘制正圆）", "箭头", "画笔", "文字（Shift+Enter 换行）"]
        toolButtons = names.enumerated().map { index, name in
            let button = iconButton(name, label: labels[index] + "（⌘\(index+1)）；再次点击取消工具并移动选区", action: #selector(selectTool(_:)))
            button.tag = index; button.setButtonType(.toggle); (button as? MarkupToolButton)?.showsSelection = true
            button.keyEquivalent = String(index+1); button.keyEquivalentModifierMask = [.command]
            return button
        }
        let colors = NSPopUpButton(frame: .zero, pullsDown: false)
        for (index, name) in ["红色", "蓝色", "黄色", "白色", "黑色"].enumerated() {
            colors.addItem(withTitle: name)
            colors.lastItem?.image = colorSwatch([NSColor.systemRed,.systemBlue,.systemYellow,.white,.black][index])
        }
        colors.imagePosition = .imageOnly
        colors.toolTip = "标记颜色（点击选择）"; colors.setAccessibilityLabel("标记颜色")
        colors.widthAnchor.constraint(equalToConstant: 36).isActive = true
        colors.heightAnchor.constraint(equalToConstant: 30).isActive = true
        colors.target = self; colors.action = #selector(selectColor(_:))
        let undo = iconButton("arrow.uturn.backward", label: "撤销（⌘Z）", action: #selector(undoMark))
        undo.keyEquivalent = "z"; undo.keyEquivalentModifierMask = [.command]
        let cancel = iconButton("xmark", label: "取消（Esc）", action: #selector(cancelMarkup))
        let copy = iconButton("doc.on.doc", label: "复制（Enter）", action: #selector(copyImage))
        let bar = NSStackView(views: toolButtons + [colors,undo,cancel,copy]); bar.spacing = 4; bar.alignment = .centerY
        let box = NSVisualEffectView(); box.material = .popover; box.state = .active
        box.wantsLayer = true; box.layer?.cornerRadius = 10; box.layer?.masksToBounds = true
        bar.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(bar)
        NSLayoutConstraint.activate([bar.leadingAnchor.constraint(equalTo: box.leadingAnchor,constant: 12), bar.trailingAnchor.constraint(equalTo: box.trailingAnchor,constant: -12), bar.centerYAnchor.constraint(equalTo: box.centerYAnchor)])
        box.frame.size = NSSize(width: bar.fittingSize.width+24, height: 44)
        background.chrome.frame = background.bounds
        background.addSubview(background.chrome)
        background.addSubview(box); toolbar = box
        positionToolbar(rect)
        window?.invalidateCursorRects(for: background.chrome)
        window?.makeFirstResponder(view)
    }
    /// 工具栏按钮:无系统边框,自己画圆角底;图标是模板图(矢量,按屏幕倍率清晰渲染),选中时蓝底白图。
    private func iconButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = MarkupToolButton(title: label.components(separatedBy: "（")[0].components(separatedBy: "；")[0], target: self, action: action)
        button.showsSelection = false
        if symbol == "T" {
            // 文字工具:一个细体大写 T,和 SF 细线图标粗细一致。
            let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                let text = NSAttributedString(string: "T", attributes: [.font: NSFont.systemFont(ofSize: 17, weight: .light), .foregroundColor: NSColor.black])
                let size = text.size()
                text.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2 + 0.5))
                return true
            }
            image.isTemplate = true; button.image = image; button.imagePosition = .imageOnly
        } else if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(symbolConfiguration) {
            image.isTemplate = true
            button.image = image; button.imagePosition = .imageOnly
        }
        button.isBordered = false
        // 撤销/取消/复制是动作按钮,点一下就弹回;工具按钮在外面改成 toggle。
        button.setButtonType(.momentaryChange)
        button.toolTip = label; button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }
    private func colorSwatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 16,height: 16), flipped: false) { rect in
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 2,dy: 2))
            color.setFill(); dot.fill()
            NSColor.gray.setStroke(); dot.lineWidth = 1; dot.stroke()
            return true
        }
    }
    private func positionToolbar(_ rect: NSRect) {
        guard let toolbar else { return }
        let width = toolbar.frame.width, height = toolbar.frame.height
        let x = min(max(8,rect.maxX-width),max(8,background.bounds.width-width-8))
        let preferredY = rect.minY-height-10
        let y = preferredY >= 8 ? preferredY : min(rect.maxY+10,background.bounds.height-height-8)
        toolbar.frame.origin = NSPoint(x:x,y:max(8,y))
    }
    @objc private func selectTool(_ sender: NSButton) {
        canvas?.finishText()
        selectedTool = selectedTool == sender.tag ? nil : sender.tag
        for button in toolButtons { button.state = selectedTool == button.tag ? .on : .off }
        background.allowsMove = selectedTool == nil
        if let selectedTool { canvas?.tool = ScreenshotMarkupCanvas.Tool(rawValue: selectedTool) ?? .rectangle }
        if let canvas { window?.invalidateCursorRects(for: canvas); window?.makeFirstResponder(canvas) }
        window?.invalidateCursorRects(for: background.chrome)
    }
    @objc private func selectColor(_ sender: NSPopUpButton) {
        canvas?.finishText()
        canvas?.color = [NSColor.systemRed,.systemBlue,.systemYellow,.white,.black][sender.indexOfSelectedItem]
        if let canvas { window?.makeFirstResponder(canvas) }
    }
    @objc private func undoMark() { canvas?.finishText(); canvas?.undoMark() }
    @objc private func cancelMarkup() { finish(nil) }
    @objc private func copyImage() {
        guard let image = canvas?.renderedImage() else { return }
        finish(image)
    }
    private func finish(_ image: NSImage?) { let callback = completion; completion = nil; callback?(image) }
}

/// 截图工具栏按钮:选中=蓝底白图,悬停=淡灰底,普通=无底。state 变化时重绘。
final class MarkupToolButton: NSButton {
    /// 动作按钮(撤销/取消/复制)不显示选中态,只有悬停底。
    var showsSelection = true
    private var hovering = false
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let on = showsSelection && state == .on
        if on || hovering {
            (on ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.08)).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
        }
        // 图标交给系统画(模板图按 contentTintColor 着色),自己画会翻转。
        contentTintColor = on ? .white : .labelColor
        super.draw(dirtyRect)
    }
}

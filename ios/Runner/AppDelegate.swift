import Flutter
import PDFKit
import UIKit
import UIKit.UIGestureRecognizerSubclass

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NativePdfView") {
      registrar.register(
        NativePdfViewFactory(messenger: registrar.messenger()),
        withId: "ink_note/native_pdf_view"
      )
    }
  }
}

final class NativePdfViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    NativePdfPlatformView(
      frame: frame,
      viewIdentifier: viewId,
      arguments: args,
      messenger: messenger
    )
  }
}

final class SelectablePdfView: PDFView {
  override var canBecomeFirstResponder: Bool { true }

  override func copy(_ sender: Any?) {
    guard let text = currentSelection?.string, !text.isEmpty else { return }
    UIPasteboard.general.string = text
  }

  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    if action == #selector(copy(_:)) {
      return currentSelection?.string?.isEmpty == false
    }
    return super.canPerformAction(action, withSender: sender)
  }
}

// MARK: - Ink Note custom iPad ink engine

/// One raw input sample in PDFView coordinates. The engine keeps pressure,
/// tilt and azimuth now so the renderer can grow into pressure-sensitive
/// brushes later without changing the input architecture.
struct InkInputSample {
  let point: CGPoint
  let force: CGFloat
  let altitude: CGFloat
  let azimuth: CGFloat
  let timestamp: TimeInterval
}

/// A page-local sample used by the live vector renderer and by the final PDF
/// annotation converter.
struct InkPageSample {
  let pagePoint: CGPoint
  let overlayPoint: CGPoint
  let force: CGFloat
  let altitude: CGFloat
  let azimuth: CGFloat
  let timestamp: TimeInterval
}

/// Receives Apple Pencil input directly from UIKit. No PencilKit canvas is
/// involved. Coalesced touches provide the real high-frequency samples and
/// predicted touches provide the low-latency tip preview.
final class InkInputGestureRecognizer: UIGestureRecognizer {
  fileprivate private(set) var phaseSamples: [InkInputSample] = []
  fileprivate private(set) var predictedSamples: [InkInputSample] = []
  private weak var trackedTouch: UITouch?

  private func sample(_ touch: UITouch) -> InkInputSample {
    let point = touch.location(in: view)
    let maxForce = max(touch.maximumPossibleForce, 0.0001)
    let normalizedForce = min(1.0, max(0.0, touch.force / maxForce))
    return InkInputSample(
      point: point,
      force: normalizedForce,
      altitude: touch.altitudeAngle,
      azimuth: touch.azimuthAngle(in: view),
      timestamp: touch.timestamp
    )
  }

  private func samples(_ touches: [UITouch]) -> [InkInputSample] {
    touches.map(sample)
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    guard trackedTouch == nil, let touch = touches.first else {
      state = .failed
      return
    }
    trackedTouch = touch
    phaseSamples = [sample(touch)]
    predictedSamples = []
    state = .began
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    guard let touch = trackedTouch, touches.contains(where: { $0 === touch }) else { return }
    let realTouches = event.coalescedTouches(for: touch) ?? [touch]
    phaseSamples = samples(realTouches)
    predictedSamples = samples(event.predictedTouches(for: touch) ?? [])
    state = .changed
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    guard let touch = trackedTouch, touches.contains(where: { $0 === touch }) else { return }
    let realTouches = event.coalescedTouches(for: touch) ?? [touch]
    phaseSamples = samples(realTouches)
    predictedSamples = []
    state = .ended
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    phaseSamples = []
    predictedSamples = []
    state = .cancelled
  }

  override func reset() {
    super.reset()
    trackedTouch = nil
    phaseSamples = []
    predictedSamples = []
  }
}

/// Page overlay used only for the live stroke. The visible pen stroke is a
/// CAShapeLayer path, so it is vector geometry from pencil-down rather than a
/// bitmap snapshot of a PencilKit canvas. The layer is discarded as soon as
/// the stroke is committed as a vector PDF annotation.
final class NativeInkOverlayView: UIView {
  private let liveStrokeLayer = CAShapeLayer()
  private var committedSamples: [InkPageSample] = []
  private var predictedSamples: [InkPageSample] = []
  private var tool = "pen"
  private var inkColor = UIColor.label
  private var inkWidth: CGFloat = 2.5

  override init(frame: CGRect) {
    super.init(frame: frame)
    configure()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configure()
  }

  private func configure() {
    backgroundColor = .clear
    isOpaque = false
    isUserInteractionEnabled = false
    contentMode = .redraw
    layer.shouldRasterize = false
    layer.drawsAsynchronously = false
    layer.allowsEdgeAntialiasing = true

    liveStrokeLayer.fillColor = UIColor.clear.cgColor
    liveStrokeLayer.lineCap = .round
    liveStrokeLayer.lineJoin = .round
    liveStrokeLayer.miterLimit = 1
    liveStrokeLayer.shouldRasterize = false
    liveStrokeLayer.drawsAsynchronously = false
    liveStrokeLayer.allowsEdgeAntialiasing = true
    liveStrokeLayer.actions = [
      "path": NSNull(),
      "strokeColor": NSNull(),
      "lineWidth": NSNull(),
      "opacity": NSNull(),
    ]
    layer.addSublayer(liveStrokeLayer)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    liveStrokeLayer.frame = bounds
  }

  func configureTool(tool: String, color: UIColor, width: CGFloat) {
    self.tool = tool
    inkColor = color
    inkWidth = max(0.5, width)
    updateAppearance()
  }

  /// Quality-first: no artificial render-scale cap. The layer follows the
  /// actual Retina scale multiplied by the PDF zoom scale.
  func setRenderScale(_ scale: CGFloat) {
    contentScaleFactor = scale
    layer.contentsScale = scale
    layer.rasterizationScale = scale
    liveStrokeLayer.contentsScale = scale
    liveStrokeLayer.rasterizationScale = scale
    liveStrokeLayer.shouldRasterize = false
    setNeedsDisplay()
    layer.setNeedsDisplay()
  }

  func beginStroke(with samples: [InkPageSample]) {
    committedSamples.removeAll(keepingCapacity: true)
    predictedSamples.removeAll(keepingCapacity: true)
    appendCommitted(samples)
  }

  func appendCommitted(_ samples: [InkPageSample]) {
    for sample in samples {
      if let last = committedSamples.last,
         hypot(last.overlayPoint.x - sample.overlayPoint.x,
               last.overlayPoint.y - sample.overlayPoint.y) < 0.04 {
        continue
      }
      committedSamples.append(sample)
    }
    rebuildPath()
  }

  func setPredicted(_ samples: [InkPageSample]) {
    predictedSamples = samples
    rebuildPath()
  }

  func clearStroke() {
    committedSamples.removeAll(keepingCapacity: true)
    predictedSamples.removeAll(keepingCapacity: true)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    liveStrokeLayer.path = nil
    CATransaction.commit()
  }

  private func updateAppearance() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if tool == "highlighter" {
      // Final highlighter is a PDF highlight annotation. During the few
      // milliseconds of live input this translucent vector preview follows the
      // pencil; it disappears immediately when the semantic PDF highlight is
      // committed.
      liveStrokeLayer.strokeColor = inkColor.withAlphaComponent(0.28).cgColor
      liveStrokeLayer.opacity = 1
    } else {
      liveStrokeLayer.strokeColor = inkColor.cgColor
      liveStrokeLayer.opacity = 1
    }
    liveStrokeLayer.lineWidth = inkWidth
    CATransaction.commit()
  }

  private func rebuildPath() {
    updateAppearance()
    let allSamples = committedSamples + predictedSamples
    guard let first = allSamples.first else {
      liveStrokeLayer.path = nil
      return
    }

    let path = UIBezierPath()
    path.move(to: first.overlayPoint)

    if allSamples.count == 1 {
      // A tiny vector segment makes a pencil tap visible immediately.
      path.addLine(to: CGPoint(
        x: first.overlayPoint.x + 0.01,
        y: first.overlayPoint.y + 0.01
      ))
    } else {
      var previous = first.overlayPoint
      for sample in allSamples.dropFirst() {
        let current = sample.overlayPoint
        let midpoint = CGPoint(
          x: (previous.x + current.x) * 0.5,
          y: (previous.y + current.y) * 0.5
        )
        path.addQuadCurve(to: midpoint, controlPoint: previous)
        previous = current
      }
      if let last = allSamples.last?.overlayPoint {
        path.addLine(to: last)
      }
    }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    liveStrokeLayer.path = path.cgPath
    CATransaction.commit()
  }
}

private enum NativePdfEdit {
  case added(page: PDFPage, annotations: [PDFAnnotation])
  case removed(page: PDFPage, annotations: [PDFAnnotation])
}

final class NativePdfPlatformView: NSObject, FlutterPlatformView {
  private static let annotationOwner = "Ink Note"
  private static let annotationPrefix = "ink_note:"

  private let pdfView: SelectablePdfView
  private let channel: FlutterMethodChannel
  private let documentURL: URL?
  private let inkInput = InkInputGestureRecognizer()

  private var pageOverlays: [ObjectIdentifier: NativeInkOverlayView] = [:]
  private var pageForOverlay: [ObjectIdentifier: PDFPage] = [:]
  private var pendingPage: Int?
  private var activeTool = "pen"
  private var activeColor = UIColor.label
  private var activeWidth: CGFloat = 2.5
  private var activeEraserMode = "precision"
  private var allowFinger = false
  private var resolvedPanGestureRecognizer: UIPanGestureRecognizer?

  private var activeInputPage: PDFPage?
  private weak var activeInputOverlay: NativeInkOverlayView?
  private var activePageSamples: [InkPageSample] = []

  private var undoStack: [NativePdfEdit] = []
  private var redoStack: [NativePdfEdit] = []
  private var activeEraserPage: PDFPage?
  private var activeEraserAnnotations: [PDFAnnotation] = []
  private var activeEraserIds: Set<ObjectIdentifier> = []
  private var saveTimer: Timer?
  private var hasUnsavedChanges = false
  private var lastOverlayRenderScale: CGFloat = 0

  init(
    frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?,
    messenger: FlutterBinaryMessenger
  ) {
    pdfView = SelectablePdfView(frame: frame)
    channel = FlutterMethodChannel(
      name: "ink_note/native_pdf_view_\(viewId)",
      binaryMessenger: messenger
    )

    let values = args as? [String: Any]
    if let path = values?["path"] as? String, !path.isEmpty {
      documentURL = URL(fileURLWithPath: path)
    } else {
      documentURL = nil
    }

    super.init()

    pdfView.backgroundColor = .systemGray6
    pdfView.autoScales = true
    pdfView.displayBox = .cropBox
    pdfView.displayMode = .singlePageContinuous
    pdfView.displayDirection = .vertical
    pdfView.displaysPageBreaks = true
    pdfView.pageBreakMargins = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
    pdfView.usePageViewController(false)
    pdfView.isUserInteractionEnabled = true

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      switch call.method {
      case "goToPage":
        let values = call.arguments as? [String: Any]
        let page = values?["page"] as? Int ?? 0
        self.goToPage(page)
        result(nil)
      case "setTool":
        self.updateTool(call.arguments as? [String: Any])
        self.sendHistoryState()
        result(nil)
      case "undo":
        self.undo()
        result(nil)
      case "redo":
        self.redo()
        result(nil)
      case "save":
        do {
          try self.saveDocument()
          result(nil)
        } catch {
          result(
            FlutterError(
              code: "native_pdf_save_failed",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handlePageChanged),
      name: Notification.Name.PDFViewPageChanged,
      object: pdfView
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleScaleChanged),
      name: Notification.Name.PDFViewScaleChanged,
      object: pdfView
    )

    if #available(iOS 16.0, *) {
      pdfView.pageOverlayViewProvider = self
      // Keep PDFKit's markup machinery available for semantic annotations, but
      // live handwriting is entirely handled by Ink Note's engine above it.
      pdfView.isInMarkupMode = true
    }

    inkInput.addTarget(self, action: #selector(handleInkInput(_:)))
    inkInput.cancelsTouchesInView = false
    inkInput.delaysTouchesBegan = false
    inkInput.delaysTouchesEnded = false
    inkInput.delegate = self
    pdfView.addGestureRecognizer(inkInput)

    let longPress = UILongPressGestureRecognizer(
      target: self,
      action: #selector(handleTextLongPress(_:))
    )
    longPress.minimumPressDuration = 0.45
    longPress.cancelsTouchesInView = false
    longPress.delegate = self
    pdfView.addGestureRecognizer(longPress)

    guard let url = documentURL, let document = PDFDocument(url: url) else {
      updateInputPolicy()
      sendHistoryState()
      return
    }

    pdfView.document = document
    let initialPage = values?["initialPage"] as? Int ?? 0
    allowFinger = values?["allowFinger"] as? Bool ?? false
    updateTool(values)
    pendingPage = initialPage
    goToPage(initialPage)
    sendHistoryState()
  }

  deinit {
    saveTimer?.invalidate()
    if hasUnsavedChanges {
      try? saveDocument()
    }
    NotificationCenter.default.removeObserver(self)
    channel.setMethodCallHandler(nil)
  }

  func view() -> UIView {
    pdfView
  }

  private func colorFromArgb(_ value: Int) -> UIColor {
    let alpha = CGFloat((value >> 24) & 0xFF) / 255.0
    let red = CGFloat((value >> 16) & 0xFF) / 255.0
    let green = CGFloat((value >> 8) & 0xFF) / 255.0
    let blue = CGFloat(value & 0xFF) / 255.0
    return UIColor(red: red, green: green, blue: blue, alpha: alpha)
  }

  private func updateTool(_ values: [String: Any]?) {
    activeTool = values?["tool"] as? String ?? activeTool
    if let color = values?["color"] as? Int {
      activeColor = colorFromArgb(color)
    }
    if let width = values?["width"] as? NSNumber {
      activeWidth = max(0.5, CGFloat(truncating: width))
    }
    if let eraserMode = values?["eraserMode"] as? String {
      activeEraserMode = eraserMode
    }
    if let finger = values?["allowFinger"] as? Bool {
      allowFinger = finger
    }

    updateInputPolicy()
    for overlay in pageOverlays.values {
      overlay.configureTool(tool: activeTool, color: activeColor, width: activeWidth)
      refreshOverlayRenderingScale(overlay, force: true)
    }
  }

  /// PDFKit's built-in single-finger pan recognizer, found by scanning the
  /// view's own gesture recognizers. Pinch-to-zoom is a separate
  /// UIPinchGestureRecognizer PDFKit manages independently, so this scan
  /// never touches it. The result isn't cached when nil, in case PDFKit
  /// hasn't attached its recognizers yet on first access.
  private func nativePanGestureRecognizer() -> UIPanGestureRecognizer? {
    if let cached = resolvedPanGestureRecognizer { return cached }
    let found = pdfView.gestureRecognizers?
      .compactMap { $0 as? UIPanGestureRecognizer }
      .first
    resolvedPanGestureRecognizer = found
    return found
  }

  private func updateInputPolicy() {
    let nativeInkTools: Set<String> = [
      "pen", "fountainPen", "brushPen", "highlighter", "eraser",
    ]
    let acceptsInk = nativeInkTools.contains(activeTool)
    inkInput.isEnabled = acceptsInk

    // A non-Apple stylus is reported by iOS as a plain `.direct` touch,
    // indistinguishable from a finger. When "Draw with finger" is on, a
    // single touch of either kind draws, so panning is pushed to a
    // two-finger drag instead of relying on touch-type detection. Apple
    // Pencil users (the default, allowFinger == false) see no change: the
    // ink recognizer only ever receives `.stylus` touches, so finger
    // scrolling keeps working untouched.
    let requiresTwoFingerPan = acceptsInk && allowFinger
    inkInput.allowedTouchTypes = requiresTwoFingerPan
      ? [
          NSNumber(value: UITouch.TouchType.stylus.rawValue),
          NSNumber(value: UITouch.TouchType.direct.rawValue),
        ]
      : [NSNumber(value: UITouch.TouchType.stylus.rawValue)]
    nativePanGestureRecognizer()?.minimumNumberOfTouches =
      requiresTwoFingerPan ? 2 : 1
  }

  private func goToPage(_ pageIndex: Int) {
    guard let document = pdfView.document else {
      pendingPage = pageIndex
      return
    }
    let safePage = max(0, min(pageIndex, document.pageCount - 1))
    guard let page = document.page(at: safePage) else { return }
    pendingPage = nil
    pdfView.go(to: page)
  }

  @objc private func handlePageChanged() {
    guard let document = pdfView.document, let page = pdfView.currentPage else { return }
    channel.invokeMethod(
      "pageChanged",
      arguments: ["page": document.index(for: page)]
    )
  }

  @objc private func handleScaleChanged() {
    // Force the live vector overlay to follow the exact current zoom scale.
    // There is intentionally no upper quality cap in this build.
    refreshAllOverlayRenderingScales(force: true)
  }

  private func preferredOverlayRenderScale() -> CGFloat {
    let screenScale = pdfView.window?.screen.scale ?? UIScreen.main.scale
    let pdfScale = max(1.0, pdfView.scaleFactor)
    return max(screenScale, screenScale * pdfScale)
  }

  private func refreshOverlayRenderingScale(
    _ overlay: NativeInkOverlayView,
    force: Bool = false
  ) {
    let scale = preferredOverlayRenderScale()
    if !force, abs(overlay.contentScaleFactor - scale) < 0.05 { return }
    overlay.setRenderScale(scale)
  }

  private func refreshAllOverlayRenderingScales(force: Bool = false) {
    let scale = preferredOverlayRenderScale()
    if !force, abs(lastOverlayRenderScale - scale) < 0.05 { return }
    lastOverlayRenderScale = scale
    for overlay in pageOverlays.values {
      overlay.setRenderScale(scale)
    }
  }

  @objc private func handleTextLongPress(_ recognizer: UILongPressGestureRecognizer) {
    guard recognizer.state == .began else { return }
    let viewPoint = recognizer.location(in: pdfView)
    guard let page = pdfView.page(for: viewPoint, nearest: true) else { return }
    let pagePoint = pdfView.convert(viewPoint, to: page)
    guard
      let selection = page.selectionForWord(at: pagePoint),
      let text = selection.string,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      pdfView.clearSelection()
      return
    }

    selection.color = UIColor.systemBlue.withAlphaComponent(0.35)
    pdfView.setCurrentSelection(selection, animate: true)
    pdfView.scrollSelectionToVisible(nil)
    _ = pdfView.becomeFirstResponder()

    UIMenuController.shared.showMenu(
      from: pdfView,
      rect: CGRect(origin: viewPoint, size: CGSize(width: 1, height: 1))
    )
  }

  private func convertSamples(
    _ samples: [InkInputSample],
    page: PDFPage,
    overlay: NativeInkOverlayView
  ) -> [InkPageSample] {
    samples.map { sample in
      InkPageSample(
        pagePoint: pdfView.convert(sample.point, to: page),
        overlayPoint: overlay.convert(sample.point, from: pdfView),
        force: sample.force,
        altitude: sample.altitude,
        azimuth: sample.azimuth,
        timestamp: sample.timestamp
      )
    }
  }

  private func appendPageSamples(_ samples: [InkPageSample]) {
    for sample in samples {
      if let last = activePageSamples.last,
         hypot(last.pagePoint.x - sample.pagePoint.x,
               last.pagePoint.y - sample.pagePoint.y) < 0.04 {
        continue
      }
      activePageSamples.append(sample)
    }
  }

  @objc private func handleInkInput(_ recognizer: InkInputGestureRecognizer) {
    switch recognizer.state {
    case .began:
      guard let first = recognizer.phaseSamples.first else { return }
      guard let page = pdfView.page(for: first.point, nearest: false) ??
        pdfView.page(for: first.point, nearest: true) else { return }

      activeInputPage = page
      activePageSamples.removeAll(keepingCapacity: true)
      activeEraserPage = nil
      activeEraserAnnotations.removeAll(keepingCapacity: true)
      activeEraserIds.removeAll(keepingCapacity: true)

      if activeTool == "eraser" {
        activeEraserPage = page
        for sample in recognizer.phaseSamples {
          let pagePoint = pdfView.convert(sample.point, to: page)
          eraseAnnotations(atPagePoint: pagePoint, page: page)
        }
        return
      }

      guard let overlay = pageOverlays[ObjectIdentifier(page)] else { return }
      activeInputOverlay = overlay
      overlay.configureTool(tool: activeTool, color: activeColor, width: activeWidth)
      refreshOverlayRenderingScale(overlay, force: true)

      let real = convertSamples(recognizer.phaseSamples, page: page, overlay: overlay)
      appendPageSamples(real)
      overlay.beginStroke(with: real)
      let predicted = convertSamples(recognizer.predictedSamples, page: page, overlay: overlay)
      overlay.setPredicted(predicted)

    case .changed:
      guard let page = activeInputPage else { return }
      if activeTool == "eraser" {
        for sample in recognizer.phaseSamples {
          let pagePoint = pdfView.convert(sample.point, to: page)
          eraseAnnotations(atPagePoint: pagePoint, page: page)
        }
        return
      }

      guard let overlay = activeInputOverlay else { return }
      let real = convertSamples(recognizer.phaseSamples, page: page, overlay: overlay)
      appendPageSamples(real)
      overlay.appendCommitted(real)
      let predicted = convertSamples(recognizer.predictedSamples, page: page, overlay: overlay)
      overlay.setPredicted(predicted)

    case .ended:
      guard let page = activeInputPage else {
        resetActiveInput()
        return
      }

      if activeTool == "eraser" {
        for sample in recognizer.phaseSamples {
          let pagePoint = pdfView.convert(sample.point, to: page)
          eraseAnnotations(atPagePoint: pagePoint, page: page)
        }
        if !activeEraserAnnotations.isEmpty {
          commitRemovedAnnotations(activeEraserAnnotations, page: page)
        }
        resetActiveInput()
        return
      }

      if let overlay = activeInputOverlay {
        let real = convertSamples(recognizer.phaseSamples, page: page, overlay: overlay)
        appendPageSamples(real)
        overlay.appendCommitted(real)
        overlay.setPredicted([])
      }

      let points = activePageSamples.map(\.pagePoint)
      let annotation: PDFAnnotation?
      if activeTool == "highlighter" {
        annotation = makeHighlightAnnotation(
          points: points,
          color: activeColor,
          width: activeWidth
        )
      } else {
        annotation = makeInkAnnotation(
          points: points,
          color: activeColor,
          width: activeWidth
        )
      }

      if let annotation {
        commitAddedAnnotations([annotation], page: page)
      }
      activeInputOverlay?.clearStroke()
      resetActiveInput()

    case .cancelled, .failed:
      activeInputOverlay?.clearStroke()
      // An eraser cancellation is treated as a completed edit for everything
      // already removed during that gesture, so Undo can restore it.
      if let page = activeEraserPage, !activeEraserAnnotations.isEmpty {
        commitRemovedAnnotations(activeEraserAnnotations, page: page)
      }
      resetActiveInput()

    default:
      break
    }
  }

  private func resetActiveInput() {
    activeInputPage = nil
    activeInputOverlay = nil
    activePageSamples.removeAll(keepingCapacity: true)
    activeEraserPage = nil
    activeEraserAnnotations.removeAll(keepingCapacity: true)
    activeEraserIds.removeAll(keepingCapacity: true)
  }

  private func makeInkAnnotation(
    points: [CGPoint],
    color: UIColor,
    width: CGFloat
  ) -> PDFAnnotation? {
    guard let first = points.first else { return nil }
    var normalizedPoints = points
    if normalizedPoints.count == 1 {
      normalizedPoints.append(CGPoint(x: first.x + 0.01, y: first.y + 0.01))
    }

    var bounds = CGRect(origin: normalizedPoints[0], size: .zero)
    for point in normalizedPoints.dropFirst() {
      bounds = bounds.union(CGRect(origin: point, size: .zero))
    }
    bounds = bounds.insetBy(dx: -(width + 2), dy: -(width + 2))

    let localPoints = normalizedPoints.map {
      CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY)
    }
    let path = UIBezierPath()
    path.move(to: localPoints[0])
    if localPoints.count == 2 {
      path.addLine(to: localPoints[1])
    } else {
      var previous = localPoints[0]
      for current in localPoints.dropFirst() {
        let midpoint = CGPoint(
          x: (previous.x + current.x) * 0.5,
          y: (previous.y + current.y) * 0.5
        )
        path.addQuadCurve(to: midpoint, controlPoint: previous)
        previous = current
      }
      if let last = localPoints.last {
        path.addLine(to: last)
      }
    }

    let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
    let border = PDFBorder()
    border.lineWidth = width
    annotation.border = border
    annotation.color = color
    annotation.add(path)
    configure(annotation)
    return annotation
  }

  private func makeHighlightAnnotation(
    points: [CGPoint],
    color: UIColor,
    width: CGFloat
  ) -> PDFAnnotation? {
    guard let first = points.first else { return nil }
    var normalizedPoints = points
    if normalizedPoints.count == 1 {
      normalizedPoints.append(CGPoint(x: first.x + 0.01, y: first.y))
    }

    let halfWidth = max(2.0, width * 0.5)
    var quads: [(CGPoint, CGPoint, CGPoint, CGPoint)] = []
    var bounds = CGRect.null

    for index in 0..<(normalizedPoints.count - 1) {
      let start = normalizedPoints[index]
      let end = normalizedPoints[index + 1]
      let dx = end.x - start.x
      let dy = end.y - start.y
      let length = hypot(dx, dy)
      guard length > 0.001 else { continue }
      let nx = -dy / length * halfWidth
      let ny = dx / length * halfWidth
      var upperStart = CGPoint(x: start.x + nx, y: start.y + ny)
      var upperEnd = CGPoint(x: end.x + nx, y: end.y + ny)
      var lowerStart = CGPoint(x: start.x - nx, y: start.y - ny)
      var lowerEnd = CGPoint(x: end.x - nx, y: end.y - ny)

      if (upperStart.y + upperEnd.y) < (lowerStart.y + lowerEnd.y) {
        swap(&upperStart, &lowerStart)
        swap(&upperEnd, &lowerEnd)
      }
      if upperStart.x > upperEnd.x {
        swap(&upperStart, &upperEnd)
        swap(&lowerStart, &lowerEnd)
      }

      quads.append((upperStart, upperEnd, lowerStart, lowerEnd))
      for point in [upperStart, upperEnd, lowerStart, lowerEnd] {
        bounds = bounds.union(CGRect(origin: point, size: .zero))
      }
    }

    guard !quads.isEmpty, !bounds.isNull else { return nil }
    bounds = bounds.insetBy(dx: -1, dy: -1)
    var quadValues: [NSValue] = []
    for quad in quads {
      quadValues.append(NSValue(cgPoint: CGPoint(
        x: quad.0.x - bounds.minX,
        y: quad.0.y - bounds.minY
      )))
      quadValues.append(NSValue(cgPoint: CGPoint(
        x: quad.1.x - bounds.minX,
        y: quad.1.y - bounds.minY
      )))
      quadValues.append(NSValue(cgPoint: CGPoint(
        x: quad.2.x - bounds.minX,
        y: quad.2.y - bounds.minY
      )))
      quadValues.append(NSValue(cgPoint: CGPoint(
        x: quad.3.x - bounds.minX,
        y: quad.3.y - bounds.minY
      )))
    }

    let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
    annotation.markupType = .highlight
    annotation.color = color.withAlphaComponent(0.32)
    annotation.quadrilateralPoints = quadValues
    configure(annotation)
    return annotation
  }

  private func configure(_ annotation: PDFAnnotation) {
    annotation.userName = Self.annotationOwner
    annotation.contents = Self.annotationPrefix + UUID().uuidString
    annotation.modificationDate = Date()
    annotation.shouldDisplay = true
    annotation.shouldPrint = true
  }

  private func isInkNoteAnnotation(_ annotation: PDFAnnotation) -> Bool {
    annotation.userName == Self.annotationOwner ||
      annotation.contents?.hasPrefix(Self.annotationPrefix) == true
  }

  private func eraseAnnotations(atPagePoint point: CGPoint, page: PDFPage) {
    let radius = max(4.0, activeWidth * 0.5)
    let hitRect = CGRect(
      x: point.x - radius,
      y: point.y - radius,
      width: radius * 2,
      height: radius * 2
    )

    for annotation in page.annotations.reversed() {
      guard isInkNoteAnnotation(annotation) else { continue }
      let id = ObjectIdentifier(annotation)
      guard !activeEraserIds.contains(id) else { continue }
      let expanded = annotation.bounds.insetBy(dx: -radius, dy: -radius)
      guard expanded.intersects(hitRect) else { continue }
      page.removeAnnotation(annotation)
      activeEraserIds.insert(id)
      activeEraserAnnotations.append(annotation)
      if activeEraserMode == "stroke" {
        break
      }
    }
  }

  private func commitAddedAnnotations(_ annotations: [PDFAnnotation], page: PDFPage) {
    guard !annotations.isEmpty else { return }
    for annotation in annotations {
      page.addAnnotation(annotation)
    }
    undoStack.append(.added(page: page, annotations: annotations))
    redoStack.removeAll()
    nativeDocumentDidChange()
  }

  private func commitRemovedAnnotations(_ annotations: [PDFAnnotation], page: PDFPage) {
    guard !annotations.isEmpty else { return }
    undoStack.append(.removed(page: page, annotations: annotations))
    redoStack.removeAll()
    nativeDocumentDidChange()
  }

  private func applyUndo(_ edit: NativePdfEdit) {
    switch edit {
    case let .added(page, annotations):
      for annotation in annotations {
        page.removeAnnotation(annotation)
      }
    case let .removed(page, annotations):
      for annotation in annotations {
        page.addAnnotation(annotation)
      }
    }
  }

  private func applyRedo(_ edit: NativePdfEdit) {
    switch edit {
    case let .added(page, annotations):
      for annotation in annotations {
        page.addAnnotation(annotation)
      }
    case let .removed(page, annotations):
      for annotation in annotations {
        page.removeAnnotation(annotation)
      }
    }
  }

  private func undo() {
    guard let edit = undoStack.popLast() else { return }
    applyUndo(edit)
    redoStack.append(edit)
    nativeDocumentDidChange()
  }

  private func redo() {
    guard let edit = redoStack.popLast() else { return }
    applyRedo(edit)
    undoStack.append(edit)
    nativeDocumentDidChange()
  }

  private func sendHistoryState() {
    channel.invokeMethod(
      "historyChanged",
      arguments: [
        "canUndo": !undoStack.isEmpty,
        "canRedo": !redoStack.isEmpty,
        "supportsAppHistory": true,
      ]
    )
  }

  private func nativeDocumentDidChange() {
    hasUnsavedChanges = true
    sendHistoryState()
    channel.invokeMethod("documentChanged", arguments: nil)
    scheduleSave()
  }

  private func scheduleSave() {
    saveTimer?.invalidate()
    saveTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
      guard let self else { return }
      try? self.saveDocument()
    }
  }

  private func saveDocument() throws {
    saveTimer?.invalidate()
    saveTimer = nil
    guard hasUnsavedChanges else { return }
    guard let document = pdfView.document, let url = documentURL else { return }
    guard let data = document.dataRepresentation() else {
      throw NSError(
        domain: "InkNote.NativePdf",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Could not serialize the edited PDF."]
      )
    }
    try data.write(to: url, options: .atomic)
    hasUnsavedChanges = false
  }
}

@available(iOS 16.0, *)
extension NativePdfPlatformView: PDFPageOverlayViewProvider {
  func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
    let key = ObjectIdentifier(page)
    if let overlay = pageOverlays[key] {
      return overlay
    }

    let pageBounds = page.bounds(for: view.displayBox)
    let overlay = NativeInkOverlayView(frame: pageBounds)
    overlay.configureTool(tool: activeTool, color: activeColor, width: activeWidth)
    refreshOverlayRenderingScale(overlay, force: true)

    pageOverlays[key] = overlay
    pageForOverlay[ObjectIdentifier(overlay)] = page
    return overlay
  }

  func pdfView(
    _ view: PDFView,
    willDisplayOverlayView overlayView: UIView,
    for page: PDFPage
  ) {
    overlayView.isHidden = false
    if let overlay = overlayView as? NativeInkOverlayView {
      pageForOverlay[ObjectIdentifier(overlay)] = page
      overlay.configureTool(tool: activeTool, color: activeColor, width: activeWidth)
      refreshOverlayRenderingScale(overlay, force: true)
    }
    view.isInMarkupMode = true
  }

  func pdfView(
    _ view: PDFView,
    willEndDisplayingOverlayView overlayView: UIView,
    for page: PDFPage
  ) {
    overlayView.isHidden = false
  }
}

extension NativePdfPlatformView: UIGestureRecognizerDelegate {
  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    // inkInput always wins exclusively over PDFKit's own pan/pinch/tap
    // recognizers for any touch it actually receives, mirroring the eager,
    // exclusive claim the Flutter canvas gives its own ink recognizer over
    // its InteractiveViewer (see _ConditionalEagerGestureRecognizer in
    // editor_screen.dart). Without this, both recognizers were allowed to
    // race for the same touch, and inkInput usually but not always won —
    // occasionally letting a genuine stylus touch scroll the page instead of
    // drawing. Finger scrolling is unaffected: with "Draw with finger" off,
    // inkInput's allowedTouchTypes already excludes direct touches, so it
    // never becomes a participant for those in the first place.
    if gestureRecognizer === inkInput || otherGestureRecognizer === inkInput {
      return false
    }
    return true
  }
}

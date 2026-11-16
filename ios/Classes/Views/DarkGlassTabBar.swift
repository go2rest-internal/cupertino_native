import UIKit

/// UITabBar, который на iOS 26+ всегда рисует тёмное Liquid Glass.
///
/// На iOS 26 стекло таб-бара адаптируется к контенту под ним: в режиме
/// «Прозрачное» (Settings → Display & Brightness → Liquid Glass → Clear)
/// поверх светлого контента оно становится светлым, а активный таб — тёмным.
/// `overrideUserInterfaceStyle = .dark` и `UITabBarAppearance.backgroundColor`
/// на плавающий таб-бар iOS 26 почти не влияют.
///
/// Чтобы поведение было одинаковым на всех устройствах, под «пилюлей»
/// таб-бара кладём тёмную подложку той же формы. Стекло сэмплирует её,
/// поэтому всегда выглядит тёмным (как в режиме «Тонированное»), а активный
/// таб — светлее фона. Дополнительно тонируем само стекло, если оно доступно
/// как `UIVisualEffectView` с `UIGlassEffect`.
///
/// На iOS < 26 класс ведёт себя как обычный UITabBar (там фон задаёт
/// `UITabBarAppearance`).
final class DarkGlassTabBar: UITabBar {
  /// Цвет тёмной подложки под стеклом. Полупрозрачный, чтобы контент
  /// под баром слегка просвечивал сквозь стекло.
  static let defaultGlassColor = UIColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 0.35)

  var glassBackgroundColor: UIColor = DarkGlassTabBar.defaultGlassColor {
    didSet {
      backingView.backgroundColor = glassBackgroundColor
      appliedGlassTint = nil
      setNeedsLayout()
    }
  }

  private let backingView: UIView = {
    let v = UIView()
    v.isUserInteractionEnabled = false
    v.clipsToBounds = true
    if #available(iOS 13.0, *) { v.layer.cornerCurve = .continuous }
    return v
  }()

  private var appliedGlassTint: UIColor?

  /// iOS 27+: затемняющий слой внутри самой стеклянной «пилюли» — поверх
  /// материала стекла, но под иконками и индикатором выбора.
  private let innerDimView: UIView = {
    let v = UIView()
    v.isUserInteractionEnabled = false
    v.clipsToBounds = true
    v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    if #available(iOS 13.0, *) { v.layer.cornerCurve = .continuous }
    return v
  }()

  #if DEBUG
  private var didDumpHierarchy = false
  #endif

  override init(frame: CGRect) {
    super.init(frame: frame)
    if #available(iOS 13.0, *) { overrideUserInterfaceStyle = .dark }
    backingView.backgroundColor = glassBackgroundColor
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    if #available(iOS 13.0, *) { overrideUserInterfaceStyle = .dark }
    backingView.backgroundColor = glassBackgroundColor
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard #available(iOS 26.0, *) else {
      backingView.removeFromSuperview()
      return
    }
    #if DEBUG
    dumpHierarchyOnce()
    #endif
    updateBacking()
    tintGlassIfPossible()
    if #available(iOS 27.0, *) {
      updateInnerDim()
    } else {
      innerDimView.removeFromSuperview()
    }
  }

  override func didMoveToSuperview() {
    super.didMoveToSuperview()
    if superview == nil { backingView.removeFromSuperview() }
    setNeedsLayout()
  }

  override func removeFromSuperview() {
    backingView.removeFromSuperview()
    innerDimView.removeFromSuperview()
    super.removeFromSuperview()
  }

  // MARK: - Подложка

  private func updateBacking() {
    guard let host = superview else { return }
    if backingView.superview !== host {
      backingView.removeFromSuperview()
      host.insertSubview(backingView, belowSubview: self)
    } else if let myIdx = host.subviews.firstIndex(of: self),
              let backIdx = host.subviews.firstIndex(of: backingView),
              backIdx > myIdx {
      host.insertSubview(backingView, belowSubview: self)
    }

    let platterRect = platterFrame()
    backingView.frame = convert(platterRect, to: host)
    backingView.layer.cornerRadius = platterCornerRadius(for: platterRect)
    backingView.isHidden = isHidden || alpha < 0.01
  }

  /// Рамка «пилюли» таб-бара в координатах self.
  private func platterFrame() -> CGRect {
    if let platter = findPlatterView() {
      let r = platter.convert(platter.bounds, to: self)
      if r.width > 1 && r.height > 1 { return r }
    }
    // Фолбэк: объединение кнопок табов с отступом.
    let buttons = allDescendants(of: self).filter {
      $0 is UIControl && $0.bounds.width > 1 && $0.bounds.height > 1
    }
    if !buttons.isEmpty {
      var union = CGRect.null
      for b in buttons { union = union.union(b.convert(b.bounds, to: self)) }
      return union.insetBy(dx: -4, dy: -4).intersection(bounds)
    }
    return bounds
  }

  private func platterCornerRadius(for rect: CGRect) -> CGFloat {
    if let platter = findPlatterView(), platter.layer.cornerRadius > 0 {
      return min(platter.layer.cornerRadius, rect.height / 2)
    }
    return rect.height / 2
  }

  /// Ищем фоновую стеклянную «пилюлю» таб-бара. Это самая большая view,
  /// которая либо является UIVisualEffectView, либо по имени класса похожа
  /// на фон/платтер, и при этом не растянута на весь бар.
  private func findPlatterView() -> UIView? {
    let barArea = bounds.width * bounds.height
    guard barArea > 0 else { return nil }
    var best: UIView?
    var bestArea: CGFloat = 0
    for v in allDescendants(of: self) {
      let name = NSStringFromClass(type(of: v))
      let looksLikePlatter = v is UIVisualEffectView
        || name.contains("Platter")
        || name.contains("Glass")
        || name.contains("Background")
      guard looksLikePlatter, !(v is UIControl) else { continue }
      let r = v.convert(v.bounds, to: self)
      let area = r.width * r.height
      // Пропускаем совсем мелкие (индикатор выбора, бейджи).
      guard r.height >= bounds.height * 0.4, r.width >= bounds.width * 0.4 else { continue }
      if area > bestArea {
        bestArea = area
        best = v
      }
    }
    return best
  }

  // MARK: - iOS 27: затемнение внутри стекла

  /// На iOS 27 светлое стекло рисуется поверх подложки и всё равно выглядит
  /// белым. Поэтому кладём полупрозрачный тёмный слой первым сабвью внутрь
  /// «пилюли»: он лежит над материалом стекла, но под иконками/подписями и
  /// индикатором выбора — фон темнеет, а активный таб остаётся светлее.
  private func updateInnerDim() {
    guard let platter = findPlatterView() else {
      innerDimView.removeFromSuperview()
      return
    }
    let host: UIView = (platter as? UIVisualEffectView)?.contentView ?? platter
    if innerDimView.superview !== host || host.subviews.first !== innerDimView {
      innerDimView.removeFromSuperview()
      host.insertSubview(innerDimView, at: 0)
    }
    innerDimView.frame = host.bounds
    let radius = platter.layer.cornerRadius > 0 ? platter.layer.cornerRadius : host.bounds.height / 2
    innerDimView.layer.cornerRadius = min(radius, host.bounds.height / 2)
    var alpha: CGFloat = 1
    glassBackgroundColor.getRed(nil, green: nil, blue: nil, alpha: &alpha)
    innerDimView.backgroundColor = glassBackgroundColor.withAlphaComponent(min(1, alpha + 0.2))
  }

  #if DEBUG
  /// Один раз печатает иерархию таб-бара в консоль Xcode — пригодится, если
  /// на новой версии iOS Apple снова поменяет внутренности.
  private func dumpHierarchyOnce() {
    guard !didDumpHierarchy, bounds.width > 0 else { return }
    didDumpHierarchy = true
    func dump(_ v: UIView, _ depth: Int) {
      let pad = String(repeating: "  ", count: depth)
      let effect = (v as? UIVisualEffectView).map { " effect=\(String(describing: $0.effect))" } ?? ""
      NSLog("[DarkGlassTabBar] \(pad)\(type(of: v)) frame=\(v.frame) r=\(v.layer.cornerRadius)\(effect)")
      for s in v.subviews where s !== backingView && s !== innerDimView { dump(s, depth + 1) }
    }
    NSLog("[DarkGlassTabBar] iOS \(UIDevice.current.systemVersion), platter=\(String(describing: findPlatterView().map { type(of: $0) }))")
    dump(self, 0)
  }
  #endif

  private func allDescendants(of view: UIView) -> [UIView] {
    var result: [UIView] = []
    var stack = view.subviews
    while let v = stack.popLast() {
      if v === backingView || v === innerDimView { continue }
      result.append(v)
      stack.append(contentsOf: v.subviews)
    }
    return result
  }

  // MARK: - Тонирование стекла (iOS 26 SDK)

  private func tintGlassIfPossible() {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      if let applied = appliedGlassTint, applied.isEqual(glassBackgroundColor) { return }
      guard let platter = findPlatterView() as? UIVisualEffectView,
            let current = platter.effect as? UIGlassEffect else { return }
      let glass = UIGlassEffect(style: .regular)
      glass.isInteractive = current.isInteractive
      // Тонируем стекло слабее подложки, иначе бар становится глухим.
      var alpha: CGFloat = 1
      glassBackgroundColor.getRed(nil, green: nil, blue: nil, alpha: &alpha)
      // На iOS 27 стекло в тёмной теме заметно светлее, поэтому тонируем сильнее.
      let factor: CGFloat
      if #available(iOS 27.0, *) { factor = 1.6 } else { factor = 0.4 }
      glass.tintColor = glassBackgroundColor.withAlphaComponent(min(1, alpha * factor))
      platter.effect = glass
      appliedGlassTint = glassBackgroundColor
    }
    #endif
  }
}

import AppKit

/// Dialog Sdílet odkaz: jeden odkaz relace, veřejný nebo týmový, jako na webu.
@MainActor final class ShareDialog: NSObject, NSWindowDelegate {
 private var window: NSWindow!
 private var root: NSView!
 private let content = NSView()
 private var id = UUID()
 private var name = ""
 private var team = false
 private var state: ShareState?
 private var audience = ShareAudience.public
 private var loading = true
 private var busy = false
 private var confirming = false
 private var copied = false
 private var message: String?

 func run(id: UUID, title: String, team: Bool) {
  self.id = id; name = title.isEmpty ? L("Relace bez názvu") : title; self.team = team
  window = ScreenshotPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 360), styleMask: [.nonactivatingPanel], backing: .buffered, defer: false)
  window.delegate = self
  root = installDesignRoot(window, headerHeight: 76, showClose: false)
  root.addSubview(designLabel(L("Sdílet odkaz"), NSRect(x: 28, y: 304, width: 484, height: 32), size: 21, weight: .semibold))
  content.frame = NSRect(x: 0, y: 0, width: 540, height: 284); root.addSubview(content)
  render()
  presentScreenshotPanel(window)
  if isExportingDesign { exportDesignWindow(window, name: "share-dialog"); return }
  Task { @MainActor [weak self] in
   guard let self else { return }
   do { let current = try await CloudLibrary.shared.shareState(id); self.state = current; self.audience = current?.audience ?? .public }
   catch { self.message = error.localizedDescription }
   self.loading = false; self.render()
  }
  NSApp.runModal(for: window); window.orderOut(nil)
 }

 /// Obsah se kreslí znovu po každé změně stavu.
 private func render() {
  content.subviews.forEach { $0.removeFromSuperview() }
  var top: CGFloat = 268
  if team {
   for (index, value) in [ShareAudience.public, .team].enumerated() {
    let label = value == .team ? L("Jen členové týmu") : L("Kdokoli s odkazem")
    let option = styledButton(label + (state?.audience == value ? " · " + L("aktivní") : ""), symbol: audience == value ? "largecircle.fill.circle" : "circle",
                              role: audience == value ? .selected : .quiet, frame: NSRect(x: 28 + CGFloat(index) * 246, y: top - 38, width: 238, height: 38), target: self, action: #selector(choose(_:)))
    option.tag = index; option.isEnabled = !busy && !loading; option.setAccessibilityLabel(label); content.addSubview(option)
   }
   top -= 54
  }
  let info = audience == .team ? LF("Přihlášení členové týmu uvidí relaci „%@“, její text a snímky. Komentáře se nesdílí.", name)
   : LF("Kdokoli s odkazem uvidí relaci „%@“, její text a snímky bez přihlášení. Komentáře se nesdílí.", name)
  let text = designLabel(info, NSRect(x: 28, y: top - 44, width: 484, height: 44), size: 12, color: AppPalette.secondary)
  text.maximumNumberOfLines = 3; text.lineBreakMode = .byWordWrapping; content.addSubview(text)
  top -= 60
  if let message { let error = designLabel(message, NSRect(x: 28, y: top - 36, width: 484, height: 36), size: 12, color: .systemRed); error.maximumNumberOfLines = 2; content.addSubview(error); top -= 44 }
  let close = styledButton(L("Zavřít"), role: .quiet, frame: NSRect(x: 28, y: 22, width: 100, height: 34), target: self, action: #selector(cancel))
  close.keyEquivalent = "\u{1b}"; content.addSubview(close)
  if loading { content.addSubview(designLabel(L("Načítám odkaz…"), NSRect(x: 28, y: top - 24, width: 484, height: 20), size: 12, color: AppPalette.secondary)); return }
  if let state, state.audience == audience {
   // Aktivní odkaz zvoleného publika: adresa, kopírování a zrušení.
   let field = NSTextField(labelWithString: state.url.absoluteString); field.isSelectable = true; field.lineBreakMode = .byTruncatingMiddle
   field.font = .monospacedSystemFont(ofSize: 12, weight: .regular); field.setAccessibilityLabel(audience == .team ? L("Týmový odkaz") : L("Veřejný odkaz"))
   inputShell(field, frame: NSRect(x: 28, y: top - 38, width: 340, height: 38), in: content)
   let copy = styledButton(copied ? L("Odkaz zkopírován") : L("Kopírovat odkaz"), symbol: copied ? "checkmark" : "link", role: copied ? .success : .primary,
                           frame: NSRect(x: 378, y: top - 38, width: 134, height: 38), target: self, action: #selector(copyLink))
   copy.keyEquivalent = "\r"; content.addSubview(copy)
   top -= 54
   let note = designLabel(audience == .team ? L("Kdo není přihlášený, bude vyzván k přihlášení. Zrušení odkaz hned zastaví.") : L("Zrušení odkaz hned zastaví. Náhledy v aplikacích jako Slack si mohou krátce ponechat kopii."),
                          NSRect(x: 28, y: top - 32, width: 484, height: 32), size: 11, color: AppPalette.secondary)
   note.maximumNumberOfLines = 2; content.addSubview(note)
   if !state.revocable { content.addSubview(designLabel(L("Odkaz může zrušit jen jeho autor nebo owner či admin týmu."), NSRect(x: 140, y: 28, width: 372, height: 20), size: 11, color: AppPalette.secondary)); return }
   if confirming {
    content.addSubview(styledButton(L("Zpět"), role: .quiet, frame: NSRect(x: 252, y: 22, width: 90, height: 34), target: self, action: #selector(back)))
    let revoke = styledButton(busy ? L("Ruším…") : L("Zrušit odkaz"), role: .primary, frame: NSRect(x: 352, y: 22, width: 160, height: 34), target: self, action: #selector(revoke))
    revoke.isEnabled = !busy; content.addSubview(revoke)
   } else {
    content.addSubview(styledButton(L("Zrušit odkaz…"), role: .secondary, frame: NSRect(x: 352, y: 22, width: 160, height: 34), target: self, action: #selector(askRevoke)))
   }
   return
  }
  if let state {
   // Jiné publikum než aktivní odkaz: výměna v jedné transakci.
   let warn = designLabel(LF("Současný %@ odkaz přestane fungovat a vznikne nový.", state.audience == .team ? L("týmový") : L("veřejný")),
                          NSRect(x: 28, y: top - 20, width: 484, height: 20), size: 12)
   content.addSubview(warn)
   if !state.revocable { content.addSubview(designLabel(L("Odkaz může změnit jen jeho autor nebo owner či admin týmu."), NSRect(x: 28, y: top - 44, width: 484, height: 20), size: 11, color: AppPalette.secondary)); return }
  }
  let title = state != nil ? (audience == .team ? L("Přepnout na týmový odkaz") : L("Přepnout na veřejný odkaz")) : (audience == .team ? L("Vytvořit týmový odkaz") : L("Vytvořit veřejný odkaz"))
  let create = styledButton(busy ? L("Pracuji…") : title, role: .primary, frame: NSRect(x: 292, y: 22, width: 220, height: 34), target: self, action: #selector(create))
  create.isEnabled = !busy; create.keyEquivalent = "\r"; content.addSubview(create)
 }

 @objc private func choose(_ sender: NSButton) { audience = sender.tag == 1 ? .team : .public; confirming = false; copied = false; message = nil; render() }
 @objc private func back() { confirming = false; render() }
 @objc private func askRevoke() { confirming = true; message = nil; render() }
 @objc private func copyLink() {
  guard let url = state?.url else { return }
  copyShareLink(url); copied = true; render()
  NSAccessibility.post(element: window as Any, notification: .announcementRequested, userInfo: [.announcement: L("Odkaz zkopírován"), .priority: NSAccessibilityPriorityLevel.medium.rawValue])
 }
 @objc private func create() {
  let replace = state != nil, wanted = audience
  perform { [id] in
   let url = try await CloudLibrary.shared.createShare(id, audience: wanted, replace: replace)
   return ShareState(audience: wanted, url: url, revocable: true)
  }
 }
 @objc private func revoke() { perform { [id] in try await CloudLibrary.shared.revokeShares(id); return nil } }
 private func perform(_ work: @escaping @MainActor () async throws -> ShareState?) {
  guard !busy else { return }
  busy = true; message = nil; copied = false; render()
  Task { @MainActor [weak self] in
   do { let next = try await work(); self?.state = next; self?.confirming = false }
   catch { self?.message = error.localizedDescription }
   self?.busy = false; self?.render()
  }
 }
 @objc private func cancel() { NSApp.stopModal() }
 func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return false }
}

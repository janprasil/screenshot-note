import AppKit

/// Dialog se seznamem složek ve stylu appky; všechny dialogy synchronizace složek mají stejné rozměry.
@MainActor final class FolderListDialog: NSObject, NSWindowDelegate {
 private(set) var window: NSWindow!
 private var choice: Int?
 private var boxes: [NSButton] = []
 private static let width: CGFloat = 540, rowHeight: CGFloat = 46, maxRows = 6

 /// Vrací index tlačítka (0 = hlavní vpravo) a zaškrtnutí; zavření nebo Esc vrací poslední tlačítko.
 func run(title: String, message: String, folders: [Topic], checkboxes: Bool, buttons: [String]) -> (choice: Int, checked: [Bool]) {
  let width = Self.width, inner = width - 56
  let text = NSTextField(wrappingLabelWithString: message)
  text.font = .systemFont(ofSize: 13); text.textColor = AppPalette.secondary
  let textHeight = ceil(text.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 1000)).height)
  let listHeight = CGFloat(min(folders.count, Self.maxRows)) * Self.rowHeight + 2
  let height = 88 + 24 + textHeight + 16 + listHeight + 24 + 66
  window = ScreenshotPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.nonactivatingPanel], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false; window.delegate = self
  let view = installDesignRoot(window, headerHeight: 88, showClose: false)
  view.addSubview(designLabel(title, NSRect(x: 28, y: height - 60, width: inner, height: 30), size: 20, weight: .semibold))
  var top = height - 88 - 24
  text.frame = NSRect(x: 28, y: top - textHeight, width: inner, height: textHeight); view.addSubview(text)
  top -= textHeight + 16
  // Karta se složkami: ikona podle úložiště, název a pod ním typ (tým, osobní cloud, jen Mac).
  let card = DesignSurface(frame: NSRect(x: 28, y: top - listHeight, width: inner, height: listHeight), fill: AppPalette.paper, radius: 10)
  card.border = AppPalette.stroke; card.wantsLayer = true; card.layer?.cornerRadius = 10; card.layer?.masksToBounds = true; view.addSubview(card)
  let document = NSView(frame: NSRect(x: 0, y: 0, width: inner - 2, height: CGFloat(folders.count) * Self.rowHeight))
  for (i, topic) in folders.enumerated() {
   let y = document.bounds.height - CGFloat(i + 1) * Self.rowHeight
   var x: CGFloat = 12
   if checkboxes {
    let box = NSButton(checkboxWithTitle: "", target: nil, action: nil); box.state = .on
    box.frame = NSRect(x: x, y: y + 13, width: 20, height: 20); box.setAccessibilityLabel(topic.displayName); document.addSubview(box); boxes.append(box); x += 28
   }
   let badge = DesignSurface(frame: NSRect(x: x, y: y + 9, width: 28, height: 28), fill: AppPalette.accent.withAlphaComponent(0.1), radius: 8); document.addSubview(badge)
   let icon = NSImageView(frame: NSRect(x: 6, y: 6, width: 16, height: 16)); icon.image = NSImage(systemSymbolName: topic.storageSymbol, accessibilityDescription: topic.storageKind); icon.contentTintColor = AppPalette.accent; badge.addSubview(icon)
   document.addSubview(designLabel(topic.name, NSRect(x: x + 40, y: y + 23, width: inner - x - 56, height: 18), size: 13, weight: .medium))
   document.addSubview(designLabel(topic.storageKind, NSRect(x: x + 40, y: y + 6, width: inner - x - 56, height: 16), size: 11, color: AppPalette.secondary))
   if i < folders.count - 1 { document.addSubview(DesignDivider(NSRect(x: x + 40, y: y, width: inner - x - 52, height: 1))) }
  }
  let scroll = NSScrollView(frame: NSRect(x: 1, y: 1, width: inner - 2, height: listHeight - 2))
  scroll.drawsBackground = false; scroll.hasVerticalScroller = folders.count > Self.maxRows; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
  scroll.documentView = document; document.scroll(NSPoint(x: 0, y: max(0, document.bounds.height - listHeight + 2))); card.addSubview(scroll)
  view.addSubview(DesignDivider(NSRect(x: 28, y: 64, width: inner, height: 1)))
  // Hlavní akce vpravo, další vlevo od ní; odmítnutí (poslední) je tiché vlevo jako v Cloudové knihovně.
  var right = width - 28
  for (i, label) in buttons.enumerated() {
   let dismiss = i == buttons.count - 1 && i > 0
   let button = styledButton(label, role: i == 0 ? .primary : dismiss ? .quiet : .secondary, frame: .zero, target: self, action: #selector(press(_:)))
   let w = max(dismiss ? 96 : 130, ceil((label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width) + 40)
   button.frame = dismiss ? NSRect(x: 28, y: 16, width: w, height: 34) : NSRect(x: right - w, y: 16, width: w, height: 34)
   button.tag = i; if !dismiss { right -= w + 10 }
   if i == 0 { button.keyEquivalent = "\r" } else if dismiss { button.keyEquivalent = "\u{1b}" }
   view.addSubview(button)
  }
  presentAppWindow(window)
  if isExportingDesign { exportDesignWindow(window, name: checkboxes ? "folder-sync-offer" : "folder-mapping"); window.orderOut(nil); return (buttons.count - 1, boxes.map { _ in false }) }
  NSApp.activate(ignoringOtherApps: true)
  NSApp.runModal(for: window); window.orderOut(nil)
  return (choice ?? buttons.count - 1, boxes.map { $0.state == .on })
 }
 @objc private func press(_ sender: NSButton) { choice = sender.tag; NSApp.stopModal() }
 func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.stopModal(); return false }
}

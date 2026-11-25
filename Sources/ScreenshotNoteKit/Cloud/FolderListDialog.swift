import AppKit

/// Dialog se seznamem složek ve stylu appky; všechny dialogy synchronizace složek mají stejné rozměry.
@MainActor final class FolderListDialog: NSObject, NSWindowDelegate {
 private(set) var window: NSWindow!
 private var choice: Int?
 private var boxes: [NSButton] = []
 private static let width: CGFloat = 540, rowHeight: CGFloat = 26, maxRows = 8

 /// Vrací index tlačítka (0 = hlavní vpravo) a zaškrtnutí; zavření nebo Esc vrací poslední tlačítko.
 func run(title: String, message: String, folders: [String], checkboxes: Bool, buttons: [String]) -> (choice: Int, checked: [Bool]) {
  let width = Self.width, inner = width - 56
  let text = NSTextField(wrappingLabelWithString: message)
  text.font = .systemFont(ofSize: 13); text.textColor = AppPalette.secondary
  let textHeight = ceil(text.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 1000)).height)
  let listHeight = CGFloat(min(folders.count, Self.maxRows)) * Self.rowHeight
  let height = 88 + 24 + textHeight + 16 + listHeight + 24 + 66
  window = ScreenshotPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.nonactivatingPanel], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false; window.delegate = self
  let view = installDesignRoot(window, headerHeight: 88, showClose: false)
  view.addSubview(designLabel(title, NSRect(x: 28, y: height - 60, width: inner, height: 30), size: 20, weight: .semibold))
  var top = height - 88 - 24
  text.frame = NSRect(x: 28, y: top - textHeight, width: inner, height: textHeight); view.addSubview(text)
  top -= textHeight + 16
  // Dlouhý seznam se posouvá; řádky začínají na stejné hraně jako text.
  let document = NSView(frame: NSRect(x: 0, y: 0, width: inner, height: CGFloat(folders.count) * Self.rowHeight))
  for (i, name) in folders.enumerated() {
   let y = document.bounds.height - CGFloat(i + 1) * Self.rowHeight
   if checkboxes {
    let box = NSButton(checkboxWithTitle: name, target: nil, action: nil); box.state = .on; box.font = .systemFont(ofSize: 13)
    box.frame = NSRect(x: 0, y: y + 3, width: inner, height: 20); document.addSubview(box); boxes.append(box)
   } else {
    document.addSubview(designLabel("• " + name, NSRect(x: 0, y: y + 3, width: inner, height: 20), size: 13))
   }
  }
  let scroll = NSScrollView(frame: NSRect(x: 28, y: top - listHeight, width: inner, height: listHeight))
  scroll.drawsBackground = false; scroll.hasVerticalScroller = folders.count > Self.maxRows; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
  scroll.documentView = document; document.scroll(NSPoint(x: 0, y: max(0, document.bounds.height - listHeight))); view.addSubview(scroll)
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
  presentScreenshotPanel(window)
  if isExportingDesign { exportDesignWindow(window, name: checkboxes ? "folder-sync-offer" : "folder-mapping"); window.orderOut(nil); return (buttons.count - 1, boxes.map { _ in false }) }
  NSApp.activate(ignoringOtherApps: true)
  NSApp.runModal(for: window); window.orderOut(nil)
  return (choice ?? buttons.count - 1, boxes.map { $0.state == .on })
 }
 @objc private func press(_ sender: NSButton) { choice = sender.tag; NSApp.stopModal() }
 func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.stopModal(); return false }
}

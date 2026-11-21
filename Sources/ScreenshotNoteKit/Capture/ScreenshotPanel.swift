import AppKit
import Carbon
import ServiceManagement

// Nonactivating panels can take keyboard input without activating the app's old Space.
final class ScreenshotPanel:NSPanel {
 override init(contentRect:NSRect,styleMask style:NSWindow.StyleMask,backing:NSWindow.BackingStoreType,defer flag:Bool){
  let mask=style.subtracting([.titled,.closable,.miniaturizable,.fullSizeContentView]).union(.nonactivatingPanel)
  super.init(contentRect:contentRect,styleMask:mask,backing:backing,defer:flag)
  isOpaque=false;backgroundColor = .clear;hasShadow=true;isMovableByWindowBackground=true
 }

 override var canBecomeKey:Bool {true}
 override var canBecomeMain:Bool {false}
}

var capturePresentationScreen:NSScreen?

func prepareScreenshotPanel(_ window:NSWindow) {
 window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.canJoinAllApplications]
 window.level = .floating
 if let panel=window as? NSPanel {panel.hidesOnDeactivate=false;panel.isFloatingPanel=true;panel.becomesKeyOnlyIfNeeded=false}
}

func presentScreenshotPanel(_ window:NSWindow) {
 prepareScreenshotPanel(window)
 let screen=NSApp.keyWindow?.screen ?? capturePresentationScreen ?? NSScreen.screens.first(where:{$0.frame.contains(NSEvent.mouseLocation)}) ?? NSScreen.main
 if let frame=screen?.visibleFrame {
  window.setFrameOrigin(NSPoint(x:frame.midX-window.frame.width/2,y:frame.midY-window.frame.height/2))
 }
 if !isExportingDesign{let fresh = !window.isVisible;if fresh && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion{window.alphaValue=0};window.makeKeyAndOrderFront(nil);if fresh{animateDesign{window.animator().alphaValue=1}}}
}

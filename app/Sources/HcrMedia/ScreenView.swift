import AVFoundation
import AppKit
import CoreMedia
import Foundation
import SwiftUI

public final class ScreenSurfaceView: NSView {
  public let displayLayer = AVSampleBufferDisplayLayer()
  public var onInput: ((MediaProtocol) -> Void)?

  public override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    displayLayer.videoGravity = .resizeAspect
    displayLayer.backgroundColor = NSColor.black.cgColor
    layer = displayLayer
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  public override var acceptsFirstResponder: Bool { true }

  public func enqueue(_ sampleBuffer: CMSampleBuffer) {
    displayLayer.enqueue(sampleBuffer)
  }

  private func normalized(_ event: NSEvent) -> (x: Double, y: Double) {
    let point = convert(event.locationInWindow, from: nil)
    guard bounds.width > 0, bounds.height > 0 else { return (0, 0) }
    return (
      Double(point.x / bounds.width),
      Double(1 - point.y / bounds.height)
    )
  }

  private func send(_ message: MediaProtocol) {
    onInput?(message)
  }

  public override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    let position = normalized(event)
    send(.mouseMove(x: position.x, y: position.y))
    send(.mouseDown(button: event.buttonNumber))
  }

  public override func mouseUp(with event: NSEvent) {
    send(.mouseUp(button: event.buttonNumber))
  }

  public override func rightMouseDown(with event: NSEvent) {
    send(.mouseDown(button: 1))
  }

  public override func rightMouseUp(with event: NSEvent) {
    send(.mouseUp(button: 1))
  }

  public override func mouseDragged(with event: NSEvent) {
    let position = normalized(event)
    send(.mouseMove(x: position.x, y: position.y))
  }

  public override func mouseMoved(with event: NSEvent) {
    let position = normalized(event)
    send(.mouseMove(x: position.x, y: position.y))
  }

  public override func scrollWheel(with event: NSEvent) {
    send(.scroll(dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY)))
  }

  public override func keyDown(with event: NSEvent) {
    guard !event.isARepeat else { return }
    send(.keyDown(code: UInt16(event.keyCode), flags: event.modifierFlags.cgFlags))
  }

  public override func keyUp(with event: NSEvent) {
    send(.keyUp(code: UInt16(event.keyCode), flags: event.modifierFlags.cgFlags))
  }

  public override func flagsChanged(with event: NSEvent) {
    send(.keyDown(code: UInt16(event.keyCode), flags: event.modifierFlags.cgFlags))
  }
}

private extension NSEvent.ModifierFlags {
  var cgFlags: UInt64 {
    var flags: CGEventFlags = []
    if contains(.shift) { flags.insert(.maskShift) }
    if contains(.control) { flags.insert(.maskControl) }
    if contains(.option) { flags.insert(.maskAlternate) }
    if contains(.command) { flags.insert(.maskCommand) }
    return flags.rawValue
  }
}

public final class ScreenBox {
  public weak var view: ScreenSurfaceView?

  public init() {}

  public func enqueue(_ sampleBuffer: CMSampleBuffer) {
    if Thread.isMainThread {
      view?.enqueue(sampleBuffer)
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.view?.enqueue(sampleBuffer)
      }
    }
  }
}

public struct ScreenView: NSViewRepresentable {
  public let box: ScreenBox
  public let onInput: (MediaProtocol) -> Void

  public init(box: ScreenBox, onInput: @escaping (MediaProtocol) -> Void) {
    self.box = box
    self.onInput = onInput
  }

  public func makeNSView(context: Context) -> ScreenSurfaceView {
    let view = ScreenSurfaceView(frame: .zero)
    view.onInput = onInput
    box.view = view
    return view
  }

  public func updateNSView(_ nsView: ScreenSurfaceView, context: Context) {
    nsView.onInput = onInput
    box.view = nsView
  }
}

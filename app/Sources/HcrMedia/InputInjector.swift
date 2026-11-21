import ApplicationServices
import CoreGraphics
import Foundation

public enum Permissions {
  public static func screenCaptureGranted() -> Bool {
    CGPreflightScreenCaptureAccess()
  }

  public static func requestScreenCapture() {
    CGRequestScreenCaptureAccess()
  }

  public static func accessibilityGranted(prompt: Bool) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [key: prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }
}

public enum InputInjector {
  public static func inject(_ message: MediaProtocol, displayBounds: CGRect) {
    switch message {
    case .mouseMove(let x, let y):
      post(mouseType: .mouseMoved, x: x, y: y, displayBounds: displayBounds)
    case .mouseDown(let button):
      post(
        mouseType: downType(for: button), x: nil, y: nil,
        displayBounds: displayBounds)
    case .mouseUp(let button):
      post(
        mouseType: upType(for: button), x: nil, y: nil,
        displayBounds: displayBounds)
    case .scroll(let dx, let dy):
      if let event = CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
        wheel1: Int32(-dy), wheel2: Int32(dx), wheel3: 0)
      {
        event.post(tap: .cghidEventTap)
      }
    case .keyDown(let code, let flags):
      post(keyCode: code, flags: flags, down: true)
    case .keyUp(let code, let flags):
      post(keyCode: code, flags: flags, down: false)
    default:
      break
    }
  }

  private static func post(
    mouseType: CGEventType, x: Double?, y: Double?, displayBounds: CGRect
  ) {
    let current = CGEvent(source: nil)?.location ?? .zero
    let point = CGPoint(
      x: x.map { $0 * displayBounds.width + displayBounds.origin.x } ?? current.x,
      y: y.map { (1 - $0) * displayBounds.height + displayBounds.origin.y } ?? current.y
    )
    guard
      let event = CGEvent(
        mouseEventSource: nil, mouseType: mouseType,
        mouseCursorPosition: point, mouseButton: button(for: mouseType))
    else {
      return
    }
    event.post(tap: .cghidEventTap)
  }

  private static func post(keyCode: UInt16, flags: UInt64, down: Bool) {
    guard
      let event = CGEvent(
        keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode),
        keyDown: down)
    else {
      return
    }
    event.flags = CGEventFlags(rawValue: flags)
    event.post(tap: .cghidEventTap)
  }

  private static func downType(for button: Int) -> CGEventType {
    switch button {
    case 1: return .rightMouseDown
    case 2: return .otherMouseDown
    default: return .leftMouseDown
    }
  }

  private static func upType(for button: Int) -> CGEventType {
    switch button {
    case 1: return .rightMouseUp
    case 2: return .otherMouseUp
    default: return .leftMouseUp
    }
  }

  private static func button(for type: CGEventType) -> CGMouseButton {
    switch type {
    case .rightMouseDown, .rightMouseUp: return .right
    case .otherMouseDown, .otherMouseUp: return .center
    default: return .left
    }
  }
}

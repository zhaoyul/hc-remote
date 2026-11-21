import Foundation

public enum MediaProtocol: Equatable {
  case streamStart(width: Int, height: Int, fps: Int)
  case streamStop
  case keyframeRequest
  case mouseMove(x: Double, y: Double)
  case mouseDown(button: Int)
  case mouseUp(button: Int)
  case scroll(dx: Double, dy: Double)
  case keyDown(code: UInt16, flags: UInt64)
  case keyUp(code: UInt16, flags: UInt64)

  public static func decode(_ text: String) -> MediaProtocol? {
    guard let data = text.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = object["type"] as? String
    else {
      return nil
    }
    switch type {
    case "stream-start":
      guard
        let width = object["width"] as? Int,
        let height = object["height"] as? Int,
        let fps = object["fps"] as? Int
      else {
        return nil
      }
      return .streamStart(width: width, height: height, fps: fps)
    case "stream-stop":
      return .streamStop
    case "keyframe-request":
      return .keyframeRequest
    case "mouse-move":
      guard let x = object["x"] as? Double, let y = object["y"] as? Double else {
        return nil
      }
      return .mouseMove(x: x, y: y)
    case "mouse-down":
      return .mouseDown(button: object["button"] as? Int ?? 0)
    case "mouse-up":
      return .mouseUp(button: object["button"] as? Int ?? 0)
    case "scroll":
      return .scroll(
        dx: object["dx"] as? Double ?? 0, dy: object["dy"] as? Double ?? 0)
    case "key-down":
      guard let code = object["code"] as? Int else { return nil }
      return .keyDown(
        code: UInt16(code), flags: UInt64(object["flags"] as? Int ?? 0))
    case "key-up":
      guard let code = object["code"] as? Int else { return nil }
      return .keyUp(
        code: UInt16(code), flags: UInt64(object["flags"] as? Int ?? 0))
    default:
      return nil
    }
  }

  public func encode() -> String {
    var object: [String: Any] = [:]
    switch self {
    case .streamStart(let width, let height, let fps):
      object = ["type": "stream-start", "width": width, "height": height, "fps": fps]
    case .streamStop:
      object = ["type": "stream-stop"]
    case .keyframeRequest:
      object = ["type": "keyframe-request"]
    case .mouseMove(let x, let y):
      object = ["type": "mouse-move", "x": x, "y": y]
    case .mouseDown(let button):
      object = ["type": "mouse-down", "button": button]
    case .mouseUp(let button):
      object = ["type": "mouse-up", "button": button]
    case .scroll(let dx, let dy):
      object = ["type": "scroll", "dx": dx, "dy": dy]
    case .keyDown(let code, let flags):
      object = ["type": "key-down", "code": code, "flags": flags]
    case .keyUp(let code, let flags):
      object = ["type": "key-up", "code": code, "flags": flags]
    }
    guard
      let data = try? JSONSerialization.data(withJSONObject: object),
      let text = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return text
  }
}

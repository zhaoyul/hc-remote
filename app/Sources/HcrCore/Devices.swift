import CHcr
import Foundation

public struct Device: Identifiable, Codable, Equatable {
  public let id: UUID
  public var name: String
  public var room: String

  public init(id: UUID = UUID(), name: String, room: String) {
    self.id = id
    self.name = name
    self.room = room
  }
}

public enum DeviceStore {
  private static let key = "hcr.devices"

  public static func load() -> [Device] {
    guard let data = UserDefaults.standard.data(forKey: key),
      let devices = try? JSONDecoder().decode([Device].self, from: data)
    else {
      return []
    }
    return devices
  }

  public static func save(_ devices: [Device]) {
    guard let data = try? JSONEncoder().encode(devices) else { return }
    UserDefaults.standard.set(data, forKey: key)
  }
}

public final class ProbeService {
  public var onResult: (([String: Int]) -> Void)?

  private let workQueue = DispatchQueue(
    label: "hcr-probe", attributes: .concurrent)
  private let lock = NSLock()
  private var timer: DispatchSourceTimer?
  private var server = ""
  private var token = ""
  private var rooms: [String] = []

  public init() {}

  public func update(server: String, token: String, rooms: [String]) {
    lock.lock()
    self.server = server
    self.token = token
    self.rooms = rooms
    lock.unlock()
  }

  public func start(interval: TimeInterval = 5) {
    stop()
    let timer = DispatchSource.makeTimerSource(queue: workQueue)
    timer.schedule(deadline: .now(), repeating: interval)
    timer.setEventHandler { [weak self] in
      self?.tick()
    }
    timer.resume()
    self.timer = timer
  }

  public func stop() {
    timer?.cancel()
    timer = nil
  }

  public func probeOnce() {
    tick()
  }

  private func tick() {
    lock.lock()
    let server = self.server
    let token = self.token
    let rooms = self.rooms
    lock.unlock()

    guard !server.isEmpty, !rooms.isEmpty else { return }

    let group = DispatchGroup()
    let resultLock = NSLock()
    var results: [String: Int] = [:]

    for room in rooms {
      group.enter()
      workQueue.async {
        let peers = server.withCString { cServer in
          room.withCString { cRoom in
            token.withCString { cToken in
              hcr_signal_probe(cServer, cRoom, cToken, 2500)
            }
          }
        }
        resultLock.lock()
        results[room] = Int(peers)
        resultLock.unlock()
        group.leave()
      }
    }

    group.notify(queue: workQueue) { [weak self] in
      guard let self else { return }
      self.onResult?(results)
    }
  }
}

#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace hcr {

enum class EventType {
  None,
  SignalingOpen,
  SignalingClosed,
  Joined,
  Ready,
  PeerLeft,
  LocalDescription,
  LocalCandidate,
  RemoteDescription,
  RemoteCandidate,
  PeerState,
  ChannelOpen,
  ChannelClosed,
  Message,
  BinaryMessage,
  Error,
  QueueOverflow,
  FrameMessage,
};

struct Event {
  EventType type = EventType::None;
  std::string room;
  std::string peer;
  std::string role;
  std::string state;
  std::string description;
  std::string candidate;
  std::string mid;
  std::string channel;
  std::string text;
  std::string code;
  bool initiator = false;
  std::vector<std::byte> binary;
  std::uint32_t frameId = 0;
  std::uint32_t timestampMs = 0;
  bool keyframe = false;
};

class Peer {
public:
  explicit Peer(const std::string &stunUrl = "");
  ~Peer();

  Peer(const Peer &) = delete;
  Peer &operator=(const Peer &) = delete;

  void createOffer();
  void acceptOffer(const std::string &sdp);
  void setRemoteAnswer(const std::string &sdp);
  void addRemoteCandidate(const std::string &candidate, const std::string &mid);
  bool sendText(const std::string &channel, const std::string &message);
  bool sendBinary(const std::string &channel, const std::vector<std::byte> &message);
  Event pollEvent();
  void close();

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

class SignalingClient {
public:
  SignalingClient(std::string url, std::string room, std::string peer,
                  std::string token = "");
  ~SignalingClient();

  SignalingClient(const SignalingClient &) = delete;
  SignalingClient &operator=(const SignalingClient &) = delete;

  void connect();
  void sendDescription(const std::string &description);
  void sendCandidate(const std::string &candidate, const std::string &mid);
  Event pollEvent();
  void close();

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

const char *eventName(EventType type);
long long nowMilliseconds();
void sleepMilliseconds(int milliseconds);

// Synchronous presence probe: returns the number of peers currently in the
// room (0..2), or -1 on error/timeout. Does not join or occupy the room.
int probeRoom(const std::string &url, const std::string &room,
              const std::string &token, int timeoutMs = 3000);

struct SessionConfig {
  std::string server;
  std::string room;
  std::string peer;
  std::string token;
  std::string stun;
};

// Owns SignalingClient + Peer and runs the offerer/answerer orchestration
// (SDP and ICE forwarding) internally. pollEvent() pumps both sources and
// returns only user-visible events: LocalDescription, LocalCandidate,
// RemoteDescription and RemoteCandidate are consumed by the state machine.
// Not thread-safe; call all methods from a single thread.
class Session {
public:
  explicit Session(SessionConfig config);
  ~Session();

  Session(const Session &) = delete;
  Session &operator=(const Session &) = delete;

  void connect();
  bool sendText(const std::string &channel, const std::string &message);
  bool sendBinary(const std::string &channel, const std::vector<std::byte> &message);
  // Chunk an encoded media frame over the game channel. Reassembly happens
  // in the native layer; the peer only sees complete frames as FrameMessage
  // events.
  bool sendFrame(std::uint32_t frameId, bool keyframe, std::uint32_t timestampMs,
                 const std::vector<std::byte> &payload);
  Event pollEvent();
  void close();

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

} // namespace hcr

#include "event_queue.hpp"

#include <chrono>
#include <thread>

namespace hcr {

Event errorEvent(std::string code, std::string message) {
  Event event;
  event.type = EventType::Error;
  event.code = std::move(code);
  event.text = std::move(message);
  return event;
}

const char *eventName(EventType type) {
  switch (type) {
  case EventType::None: return "none";
  case EventType::SignalingOpen: return "signaling-open";
  case EventType::SignalingClosed: return "signaling-closed";
  case EventType::Joined: return "joined";
  case EventType::Ready: return "ready";
  case EventType::PeerLeft: return "peer-left";
  case EventType::LocalDescription: return "local-description";
  case EventType::LocalCandidate: return "local-candidate";
  case EventType::RemoteDescription: return "remote-description";
  case EventType::RemoteCandidate: return "remote-candidate";
  case EventType::PeerState: return "peer-state";
  case EventType::ChannelOpen: return "channel-open";
  case EventType::ChannelClosed: return "channel-closed";
  case EventType::Message: return "message";
  case EventType::BinaryMessage: return "binary-message";
  case EventType::Error: return "error";
  case EventType::QueueOverflow: return "queue-overflow";
  case EventType::FrameMessage: return "frame-message";
  }
  return "unknown";
}

long long nowMilliseconds() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

void sleepMilliseconds(int milliseconds) {
  std::this_thread::sleep_for(std::chrono::milliseconds(milliseconds));
}

} // namespace hcr

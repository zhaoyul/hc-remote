#include "hcr/hcr.hpp"

#include "event_queue.hpp"
#include "frame_codec.hpp"

#include <utility>

namespace hcr {

struct Session::Impl {
  explicit Impl(SessionConfig config)
      : config(std::move(config)),
        signaling(this->config.server, this->config.room, this->config.peer,
                  this->config.token),
        peer(this->config.stun) {}

  SessionConfig config;
  SignalingClient signaling;
  Peer peer;
  EventQueue output;
  FrameReassembler reassembler;
  std::string role;
  bool remoteDescriptionSet = false;

  void pump() {
    for (;;) {
      auto event = signaling.pollEvent();
      if (event.type == EventType::None) {
        break;
      }
      handleSignaling(event);
    }
    for (;;) {
      auto event = peer.pollEvent();
      if (event.type == EventType::None) {
        break;
      }
      handlePeer(event);
    }
  }

  void handleSignaling(const Event &event) {
    switch (event.type) {
    case EventType::Joined:
      role = event.role;
      output.push(event);
      break;
    case EventType::Ready:
      if (event.initiator) {
        peer.createOffer();
      }
      output.push(event);
      break;
    case EventType::RemoteDescription:
      if (!remoteDescriptionSet) {
        if (role == "answerer") {
          peer.acceptOffer(event.description);
        } else {
          peer.setRemoteAnswer(event.description);
        }
        remoteDescriptionSet = true;
      }
      break;
    case EventType::RemoteCandidate:
      peer.addRemoteCandidate(event.candidate, event.mid);
      break;
    default:
      output.push(event);
      break;
    }
  }

  void handlePeer(const Event &event) {
    switch (event.type) {
    case EventType::LocalDescription:
      signaling.sendDescription(event.description);
      break;
    case EventType::LocalCandidate:
      signaling.sendCandidate(event.candidate, event.mid);
      break;
    case EventType::BinaryMessage: {
      Event frame;
      auto passthrough = reassembler.offer(event.binary, frame);
      if (!passthrough) {
        if (frame.type == EventType::FrameMessage) {
          output.push(std::move(frame));
        }
        break;
      }
      output.push(event);
      break;
    }
    default:
      output.push(event);
      break;
    }
  }
};

Session::Session(SessionConfig config)
    : impl_(std::make_unique<Impl>(std::move(config))) {}

Session::~Session() = default;

void Session::connect() { impl_->signaling.connect(); }

bool Session::sendText(const std::string &channel, const std::string &message) {
  return impl_->peer.sendText(channel, message);
}

bool Session::sendBinary(const std::string &channel,
                         const std::vector<std::byte> &message) {
  return impl_->peer.sendBinary(channel, message);
}

bool Session::sendFrame(std::uint32_t frameId, bool keyframe,
                        std::uint32_t timestampMs,
                        const std::vector<std::byte> &payload) {
  for (auto &chunk : encodeFrameChunks(frameId, keyframe, timestampMs, payload)) {
    if (!impl_->peer.sendBinary("game", chunk)) {
      return false;
    }
  }
  return true;
}

Event Session::pollEvent() {
  impl_->pump();
  return impl_->output.poll();
}

void Session::close() {
  impl_->peer.close();
  impl_->signaling.close();
}

} // namespace hcr

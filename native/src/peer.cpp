#include "event_queue.hpp"

#include <rtc/rtc.hpp>

#include <sstream>
#include <stdexcept>
#include <unordered_map>
#include <utility>

namespace hcr {
namespace {

rtc::Configuration makeConfiguration(const std::string &stunUrl) {
  if (stunUrl.rfind("turn:", 0) == 0 || stunUrl.rfind("turns:", 0) == 0) {
    throw std::invalid_argument("TURN is not supported");
  }
  rtc::Configuration config;
  config.maxMessageSize = maxPayloadBytes;
  if (!stunUrl.empty()) {
    config.iceServers.emplace_back(stunUrl);
  }
  return config;
}

template <typename T> std::string stateString(T state) {
  std::ostringstream output;
  output << state;
  return output.str();
}

} // namespace

struct Peer::Impl {
  explicit Impl(const std::string &stunUrl) : pc(makeConfiguration(stunUrl)) {
    pc.onLocalDescription([this](rtc::Description description) {
      Event event;
      event.type = EventType::LocalDescription;
      event.description = std::string(description);
      events.push(std::move(event));
    });
    pc.onLocalCandidate([this](rtc::Candidate candidate) {
      Event event;
      event.type = EventType::LocalCandidate;
      event.candidate = candidate.candidate();
      event.mid = candidate.mid();
      events.push(std::move(event));
    });
    pc.onStateChange([this](rtc::PeerConnection::State state) {
      Event event;
      event.type = EventType::PeerState;
      event.state = stateString(state);
      events.push(std::move(event));
    });
    pc.onDataChannel([this](std::shared_ptr<rtc::DataChannel> channel) {
      installChannel(channel);
    });
  }

  ~Impl() {
    // Unbind every callback before members are destroyed: the
    // PeerConnection destructor fires state callbacks which would otherwise
    // write into the already-destroyed event queue (heap-use-after-free).
    {
      std::lock_guard lock(mutex);
      for (auto &[label, ch] : channels) {
        if (ch) {
          ch->onOpen(nullptr);
          ch->onClosed(nullptr);
          ch->onError(nullptr);
          ch->onMessage(nullptr);
        }
      }
    }
    pc.onLocalDescription(nullptr);
    pc.onLocalCandidate(nullptr);
    pc.onStateChange(nullptr);
    pc.onDataChannel(nullptr);
    pc.close();
  }

  void installChannel(const std::shared_ptr<rtc::DataChannel> &channel) {
    const auto label = channel->label();
    {
      std::lock_guard lock(mutex);
      channels[label] = channel;
    }
    channel->onOpen([this, label]() {
      Event event;
      event.type = EventType::ChannelOpen;
      event.channel = label;
      events.push(std::move(event));
    });
    channel->onClosed([this, label]() {
      Event event;
      event.type = EventType::ChannelClosed;
      event.channel = label;
      events.push(std::move(event));
    });
    channel->onError([this, label](std::string error) {
      events.push(errorEvent("datachannel_error", label + ": " + error));
    });
    channel->onMessage([this, label](rtc::message_variant message) {
      if (std::holds_alternative<rtc::string>(message)) {
        const auto &text = std::get<rtc::string>(message);
        if (text.size() > maxPayloadBytes) {
          events.push(errorEvent("message_too_large", label));
          return;
        }
        Event event;
        event.type = EventType::Message;
        event.channel = label;
        event.text = text;
        events.push(std::move(event));
        return;
      }
      const auto &binary = std::get<rtc::binary>(message);
      if (binary.size() > maxPayloadBytes) {
        events.push(errorEvent("message_too_large", label));
        return;
      }
      Event event;
      event.type = EventType::BinaryMessage;
      event.channel = label;
      event.binary = binary;
      events.push(std::move(event));
    });
  }

  std::shared_ptr<rtc::DataChannel> channel(const std::string &label) {
    std::lock_guard lock(mutex);
    const auto found = channels.find(label);
    return found == channels.end() ? nullptr : found->second;
  }

  void close() {
    std::lock_guard lock(mutex);
    if (closed) {
      return;
    }
    closed = true;
    for (auto &[label, channel] : channels) {
      channel->close();
    }
    channels.clear();
    pc.close();
  }

  rtc::PeerConnection pc;
  EventQueue events;
  std::mutex mutex;
  std::unordered_map<std::string, std::shared_ptr<rtc::DataChannel>> channels;
  bool offerCreated = false;
  bool closed = false;
};

Peer::Peer(const std::string &stunUrl) : impl_(std::make_unique<Impl>(stunUrl)) {}
Peer::~Peer() { close(); }

void Peer::createOffer() {
  {
    std::lock_guard lock(impl_->mutex);
    if (impl_->closed || impl_->offerCreated) {
      return;
    }
    impl_->offerCreated = true;
  }
  auto control = impl_->pc.createDataChannel("control");
  impl_->installChannel(control);

  rtc::DataChannelInit init;
  init.reliability.unordered = true;
  init.reliability.maxRetransmits = 0;
  auto game = impl_->pc.createDataChannel("game", init);
  impl_->installChannel(game);
}

void Peer::acceptOffer(const std::string &sdp) {
  impl_->pc.setRemoteDescription(rtc::Description(sdp));
}

void Peer::setRemoteAnswer(const std::string &sdp) {
  impl_->pc.setRemoteDescription(rtc::Description(sdp));
}

void Peer::addRemoteCandidate(const std::string &candidate, const std::string &mid) {
  impl_->pc.addRemoteCandidate(rtc::Candidate(candidate, mid));
}

bool Peer::sendText(const std::string &channel, const std::string &message) {
  if (message.size() > maxPayloadBytes) {
    return false;
  }
  auto target = impl_->channel(channel);
  if (!target || !target->isOpen()) {
    return false;
  }
  try {
    // libdatachannel returns false when the message is queued rather than
    // handed to SCTP; queued messages are still delivered.
    target->send(message);
    return true;
  } catch (const std::exception &) {
    return false;
  }
}

bool Peer::sendBinary(const std::string &channel, const std::vector<std::byte> &message) {
  if (message.size() > maxPayloadBytes) {
    return false;
  }
  auto target = impl_->channel(channel);
  if (!target || !target->isOpen()) {
    return false;
  }
  try {
    target->send(message);
    return true;
  } catch (const std::exception &) {
    return false;
  }
}

Event Peer::pollEvent() { return impl_->events.poll(); }
void Peer::close() { impl_->close(); }

} // namespace hcr

#include "event_queue.hpp"

#include <nlohmann/json.hpp>
#include <rtc/rtc.hpp>

#include <condition_variable>
#include <mutex>
#include <stdexcept>
#include <utility>

namespace hcr {

using Json = nlohmann::json;

struct SignalingClient::Impl {
  Impl(std::string url_, std::string room_, std::string peer_, std::string token_)
      : url(std::move(url_)), room(std::move(room_)), peer(std::move(peer_)),
        token(std::move(token_)) {
    rtc::WebSocketConfiguration config;
    config.maxMessageSize = maxPayloadBytes;
    config.pingInterval = std::chrono::seconds(20);
    config.maxOutstandingPings = 3;
    ws = std::make_shared<rtc::WebSocket>(config);
    ws->onOpen([this]() {
      Event event;
      event.type = EventType::SignalingOpen;
      events.push(std::move(event));
      send(Json{{"type", "join"}, {"room", room}, {"peer", peer}, {"token", token}});
    });
    ws->onClosed([this]() {
      Event event;
      event.type = EventType::SignalingClosed;
      events.push(std::move(event));
    });
    ws->onError([this](std::string error) {
      events.push(errorEvent("signaling_error", std::move(error)));
    });
    ws->onMessage([this](rtc::message_variant message) {
      if (!std::holds_alternative<rtc::string>(message)) {
        events.push(errorEvent("invalid_signaling_message", "binary signaling message"));
        return;
      }
      receive(std::get<rtc::string>(message));
    });
  }

  void receive(const std::string &text) {
    try {
      const auto message = Json::parse(text);
      const auto type = message.at("type").get<std::string>();
      Event event;
      event.peer = message.value("from", "");
      event.room = message.value("room", room);
      if (type == "joined") {
        event.type = EventType::Joined;
        event.peer = message.at("peer").get<std::string>();
        event.role = message.at("role").get<std::string>();
      } else if (type == "ready") {
        event.type = EventType::Ready;
        event.initiator = message.at("initiator").get<bool>();
      } else if (type == "description") {
        event.type = EventType::RemoteDescription;
        event.description = message.at("description").get<std::string>();
      } else if (type == "candidate") {
        event.type = EventType::RemoteCandidate;
        event.candidate = message.at("candidate").get<std::string>();
        event.mid = message.at("mid").get<std::string>();
      } else if (type == "peer-left") {
        event.type = EventType::PeerLeft;
      } else if (type == "error") {
        event = errorEvent(message.value("code", "signaling_error"),
                           message.value("message", "signaling server error"));
      } else {
        event = errorEvent("unknown_signaling_message", type);
      }
      events.push(std::move(event));
    } catch (const std::exception &error) {
      events.push(errorEvent("invalid_signaling_message", error.what()));
    }
  }

  void send(const Json &message) {
    std::lock_guard lock(sendMutex);
    if (ws->isOpen()) {
      ws->send(message.dump());
    }
  }

  void close() {
    std::lock_guard lock(sendMutex);
    if (!ws->isClosed()) {
      ws->close();
    }
  }

  std::string url;
  std::string room;
  std::string peer;
  std::string token;
  std::shared_ptr<rtc::WebSocket> ws;
  EventQueue events;
  std::mutex sendMutex;
};

SignalingClient::SignalingClient(std::string url, std::string room, std::string peer,
                                 std::string token)
    : impl_(std::make_unique<Impl>(std::move(url), std::move(room), std::move(peer),
                                   std::move(token))) {}
SignalingClient::~SignalingClient() { close(); }

void SignalingClient::connect() { impl_->ws->open(impl_->url); }

void SignalingClient::sendDescription(const std::string &description) {
  impl_->send(Json{{"type", "description"}, {"room", impl_->room}, {"peer", impl_->peer},
                   {"description", description}});
}

void SignalingClient::sendCandidate(const std::string &candidate, const std::string &mid) {
  impl_->send(Json{{"type", "candidate"}, {"room", impl_->room}, {"peer", impl_->peer},
                   {"candidate", candidate}, {"mid", mid}});
}

Event SignalingClient::pollEvent() { return impl_->events.poll(); }
void SignalingClient::close() { impl_->close(); }

int probeRoom(const std::string &url, const std::string &room,
              const std::string &token, int timeoutMs) {
  struct ProbeState {
    std::mutex mutex;
    std::condition_variable cv;
    bool done = false;
    int peers = -1;
  };
  auto state = std::make_shared<ProbeState>();

  rtc::WebSocketConfiguration config;
  config.maxMessageSize = maxPayloadBytes;
  config.pingInterval = std::chrono::seconds(20);
  auto ws = std::make_shared<rtc::WebSocket>(config);

  ws->onOpen([ws, state, room, token]() {
    ws->send(Json{{"type", "probe"}, {"room", room}, {"token", token}}.dump());
  });
  ws->onMessage([state](rtc::message_variant message) {
    if (!std::holds_alternative<rtc::string>(message)) {
      return;
    }
    try {
      const auto json = Json::parse(std::get<rtc::string>(message));
      if (json.at("type").get<std::string>() == "probe") {
        std::lock_guard lock(state->mutex);
        state->peers = json.at("peers").get<int>();
        state->done = true;
      } else {
        std::lock_guard lock(state->mutex);
        state->done = true;
      }
    } catch (const std::exception &) {
      std::lock_guard lock(state->mutex);
      state->done = true;
    }
    state->cv.notify_all();
  });
  ws->onError([state](std::string) {
    {
      std::lock_guard lock(state->mutex);
      state->done = true;
    }
    state->cv.notify_all();
  });
  ws->onClosed([state]() {
    {
      std::lock_guard lock(state->mutex);
      state->done = true;
    }
    state->cv.notify_all();
  });

  try {
    ws->open(url);
  } catch (const std::exception &) {
    return -1;
  }

  {
    std::unique_lock lock(state->mutex);
    state->cv.wait_for(lock, std::chrono::milliseconds(timeoutMs),
                       [&] { return state->done; });
  }
  ws->close();
  std::lock_guard lock(state->mutex);
  return state->done ? state->peers : -1;
}

} // namespace hcr

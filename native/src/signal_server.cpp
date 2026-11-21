#include <nlohmann/json.hpp>
#include <rtc/rtc.hpp>

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <iostream>
#include <map>
#include <mutex>
#include <optional>
#include <regex>
#include <string>
#include <thread>
#include <utility>

using Json = nlohmann::json;
using WebSocketPtr = std::shared_ptr<rtc::WebSocket>;

namespace {

std::atomic<bool> stopping = false;

void onSignal(int) { stopping = true; }

bool validId(const std::string &value) {
  static const std::regex pattern("[A-Za-z0-9_-]{1,64}");
  return std::regex_match(value, pattern);
}

class Server {
public:
  Server(uint16_t port, std::optional<std::string> token) : token_(std::move(token)) {
    rtc::WebSocketServerConfiguration config;
    config.port = port;
    config.maxMessageSize = 256 * 1024;
    config.connectionTimeout = std::chrono::seconds(15);
    server_ = std::make_unique<rtc::WebSocketServer>(config);
    server_->onClient([this](WebSocketPtr ws) { accept(std::move(ws)); });
  }

  uint16_t port() const { return server_->port(); }
  void stop() { server_->stop(); }

private:
  struct Session {
    std::string room;
    std::string peer;
    std::string role;
  };
  struct Member {
    WebSocketPtr ws;
    std::string role;
  };
  struct Room {
    std::map<std::string, Member> members;
  };

  void accept(WebSocketPtr ws) {
    ws->onMessage([this, ws](rtc::message_variant message) {
      if (!std::holds_alternative<rtc::string>(message)) {
        sendError(ws, "invalid_message", "binary messages are not allowed");
        return;
      }
      receive(ws, std::get<rtc::string>(message));
    });
    ws->onError([this, ws](std::string) { remove(ws); });
    ws->onClosed([this, ws]() { remove(ws); });
  }

  void send(const WebSocketPtr &ws, const Json &message) {
    try {
      if (ws->isOpen()) {
        ws->send(message.dump());
      }
    } catch (const std::exception &error) {
      std::cerr << "send failed: " << error.what() << '\n';
    }
  }

  void sendError(const WebSocketPtr &ws, const std::string &code, const std::string &message) {
    send(ws, Json{{"type", "error"}, {"code", code}, {"message", message}});
  }

  void receive(const WebSocketPtr &ws, const std::string &text) {
    Json message;
    try {
      message = Json::parse(text);
      const auto type = message.at("type").get<std::string>();
      if (type == "join") {
        join(ws, message);
      } else if (type == "probe") {
        probe(ws, message);
      } else if (type == "description" || type == "candidate") {
        forward(ws, message);
      } else if (type == "leave") {
        remove(ws);
      } else {
        sendError(ws, "unknown_type", "unsupported message type");
      }
    } catch (const std::exception &error) {
      sendError(ws, "invalid_message", error.what());
    }
  }

  void probe(const WebSocketPtr &ws, const Json &message) {
    const auto room = message.value("room", "");
    const auto token = message.value("token", "");
    if (!validId(room)) {
      sendError(ws, "invalid_identity", "room must match [A-Za-z0-9_-]{1,64}");
      return;
    }
    if (token_ && token != *token_) {
      sendError(ws, "unauthorized", "invalid token");
      ws->close();
      return;
    }
    std::lock_guard lock(mutex_);
    const auto found = rooms_.find(room);
    const int peers =
        found == rooms_.end() ? 0 : static_cast<int>(found->second.members.size());
    send(ws, Json{{"type", "probe"}, {"room", room}, {"peers", peers}});
  }

  void join(const WebSocketPtr &ws, const Json &message) {
    const auto room = message.value("room", "");
    const auto peer = message.value("peer", "");
    const auto token = message.value("token", "");
    if (!validId(room) || !validId(peer)) {
      sendError(ws, "invalid_identity", "room and peer must match [A-Za-z0-9_-]{1,64}");
      return;
    }
    if (token_ && token != *token_) {
      sendError(ws, "unauthorized", "invalid token");
      ws->close();
      return;
    }

    std::lock_guard lock(mutex_);
    if (sessions_.contains(ws.get())) {
      sendError(ws, "already_joined", "connection already joined a room");
      return;
    }
    auto &members = rooms_[room].members;
    if (members.contains(peer)) {
      sendError(ws, "peer_exists", "peer id is already in use");
      return;
    }
    if (members.size() >= 2) {
      sendError(ws, "room_full", "room already has two peers");
      return;
    }
    const auto role = members.empty() ? "offerer" : "answerer";
    members.emplace(peer, Member{ws, role});
    sessions_[ws.get()] = Session{room, peer, role};
    send(ws, Json{{"type", "joined"}, {"room", room}, {"peer", peer}, {"role", role}});
    std::cout << "joined room=" << room << " peer=" << peer << " role=" << role << '\n';
    if (members.size() == 2) {
      for (const auto &[id, member] : members) {
        send(member.ws, Json{{"type", "ready"}, {"room", room},
                             {"initiator", member.role == "offerer"}});
      }
    }
  }

  void forward(const WebSocketPtr &ws, Json message) {
    std::lock_guard lock(mutex_);
    const auto session = sessions_.find(ws.get());
    if (session == sessions_.end()) {
      sendError(ws, "not_joined", "join a room before signaling");
      return;
    }
    const auto &identity = session->second;
    auto &members = rooms_[identity.room].members;
    if (message.at("room").get<std::string>() != identity.room ||
        message.at("peer").get<std::string>() != identity.peer) {
      sendError(ws, "identity_mismatch", "message identity does not match joined session");
      return;
    }
    if (message["type"] == "description" && message.at("description").get<std::string>().size() > 256 * 1024) {
      sendError(ws, "message_too_large", "description is too large");
      return;
    }
    if (message["type"] == "candidate" && message.at("candidate").get<std::string>().size() > 64 * 1024) {
      sendError(ws, "message_too_large", "candidate is too large");
      return;
    }
    message["from"] = identity.peer;
    message.erase("token");
    for (const auto &[id, member] : members) {
      if (member.ws != ws) {
        send(member.ws, message);
      }
    }
  }

  void remove(const WebSocketPtr &ws) {
    std::optional<Session> removed;
    WebSocketPtr other;
    {
      std::lock_guard lock(mutex_);
      const auto session = sessions_.find(ws.get());
      if (session == sessions_.end()) {
        return;
      }
      removed = session->second;
      sessions_.erase(session);
      auto room = rooms_.find(removed->room);
      if (room != rooms_.end()) {
        room->second.members.erase(removed->peer);
        for (const auto &[id, member] : room->second.members) {
          other = member.ws;
        }
        if (room->second.members.empty()) {
          rooms_.erase(room);
        }
      }
    }
    if (other) {
      send(other, Json{{"type", "peer-left"}, {"room", removed->room}, {"from", removed->peer}});
    }
    std::cout << "left room=" << removed->room << " peer=" << removed->peer << '\n';
  }

  std::optional<std::string> token_;
  std::unique_ptr<rtc::WebSocketServer> server_;
  std::mutex mutex_;
  std::map<const rtc::WebSocket *, Session> sessions_;
  std::map<std::string, Room> rooms_;
};

int portFromArgs(int argc, char **argv) {
  int port = 8080;
  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    if (arg == "--help") {
      std::cout << "Usage: hc-remote-signal [--port 8080]\n";
      std::exit(0);
    }
    if (arg == "--port" && i + 1 < argc) {
      port = std::stoi(argv[++i]);
      if (port < 1 || port > 65535) {
        throw std::invalid_argument("invalid port");
      }
    } else if (arg != "--port") {
      throw std::invalid_argument("unknown argument: " + arg);
    }
  }
  return port;
}

} // namespace

int main(int argc, char **argv) {
  std::cout << std::unitbuf;
  try {
    const auto port = portFromArgs(argc, argv);
    std::optional<std::string> token;
    if (const char *value = std::getenv("HCR_SIGNAL_TOKEN"); value && *value) {
      token = value;
    }
    std::signal(SIGINT, onSignal);
    std::signal(SIGTERM, onSignal);
    Server server(static_cast<uint16_t>(port), token);
    std::cout << "hc-remote-signal listening on port " << server.port() << '\n';
    while (!stopping) {
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    server.stop();
    return 0;
  } catch (const std::exception &error) {
    std::cerr << "hc-remote-signal: " << error.what() << '\n';
    return 1;
  }
}

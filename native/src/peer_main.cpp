#include "hcr/hcr.hpp"

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {

std::atomic<bool> stopping = false;

void onSignal(int) { stopping = true; }

struct Options {
  std::string server = "ws://127.0.0.1:8080";
  std::string room = "demo";
  std::string peer;
  std::string stun;
  std::string token;
  std::string message = "hello";
  int timeoutSeconds = 60;
  int quitAfter = 0;
  bool binaryDemo = false;
};

Options parseOptions(int argc, char **argv) {
  Options options;
  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    auto next = [&]() -> std::string {
      if (i + 1 >= argc) {
        throw std::invalid_argument("missing value for " + arg);
      }
      return argv[++i];
    };
    if (arg == "--server") options.server = next();
    else if (arg == "--room") options.room = next();
    else if (arg == "--peer") options.peer = next();
    else if (arg == "--stun") options.stun = next();
    else if (arg == "--token") options.token = next();
    else if (arg == "--message") options.message = next();
    else if (arg == "--timeout") options.timeoutSeconds = std::stoi(next());
    else if (arg == "--quit-after") options.quitAfter = std::stoi(next());
    else if (arg == "--binary-demo") options.binaryDemo = true;
    else if (arg == "--help") {
      std::cout << "Usage: hc-remote-peer --peer ID [--server ws://127.0.0.1:8080] "
                   "[--room demo] [--stun stun:host:3478] [--message text] "
                   "[--binary-demo] [--quit-after N] [--timeout seconds]\n";
      std::exit(0);
    } else {
      throw std::invalid_argument("unknown argument: " + arg);
    }
  }
  if (options.peer.empty()) {
    throw std::invalid_argument("--peer is required");
  }
  if (options.timeoutSeconds < 1 || options.quitAfter < 0) {
    throw std::invalid_argument("invalid timeout or message count");
  }
  if (const char *token = std::getenv("HCR_SIGNAL_TOKEN"); options.token.empty() && token) {
    options.token = token;
  }
  return options;
}

} // namespace

int main(int argc, char **argv) {
  try {
    const auto options = parseOptions(argc, argv);
    std::signal(SIGINT, onSignal);
    std::signal(SIGTERM, onSignal);

    hcr::Session session({options.server, options.room, options.peer, options.token, options.stun});
    bool fatal = false;
    int received = 0;

    session.connect();
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(options.timeoutSeconds);
    std::cout << "peer=" << options.peer << " room=" << options.room << '\n';

    auto handleEvent = [&](const hcr::Event &event) {
      switch (event.type) {
      case hcr::EventType::SignalingOpen:
        std::cout << "signaling connected\n";
        break;
      case hcr::EventType::Joined:
        std::cout << "joined role=" << event.role << '\n';
        break;
      case hcr::EventType::PeerLeft:
        std::cout << "remote peer left\n";
        stopping = true;
        break;
      case hcr::EventType::PeerState:
        std::cout << "peer state=" << event.state << '\n';
        if (event.state == "failed" || event.state == "closed") {
          stopping = true;
        }
        break;
      case hcr::EventType::ChannelOpen:
        std::cout << "channel open: " << event.channel << '\n';
        session.sendText(event.channel, options.message);
        if (options.binaryDemo && event.channel == "game") {
          const std::vector<std::byte> payload{std::byte{0}, std::byte{1}, std::byte{2}, std::byte{255}};
          session.sendBinary("game", payload);
        }
        break;
      case hcr::EventType::ChannelClosed:
        std::cout << "channel closed: " << event.channel << '\n';
        break;
      case hcr::EventType::Message:
        std::cout << "received channel=" << event.channel << " text=" << event.text << '\n';
        ++received;
        break;
      case hcr::EventType::BinaryMessage:
        std::cout << "received channel=" << event.channel << " bytes=" << event.binary.size() << '\n';
        ++received;
        break;
      case hcr::EventType::Error:
      case hcr::EventType::QueueOverflow:
        std::cerr << "error: " << event.code << " " << event.text << '\n';
        fatal = true;
        stopping = true;
        break;
      default:
        break;
      }
    };

    while (!stopping && std::chrono::steady_clock::now() < deadline) {
      bool progressed = false;
      for (;;) {
        auto event = session.pollEvent();
        if (event.type == hcr::EventType::None) {
          break;
        }
        handleEvent(event);
        progressed = true;
      }
      if (options.quitAfter > 0 && received >= options.quitAfter) {
        break;
      }
      if (!progressed) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
      }
    }

    session.close();
    if (fatal) {
      return 1;
    }
    if (options.quitAfter > 0 && received < options.quitAfter) {
      std::cerr << "timed out: received " << received << "/" << options.quitAfter << " messages\n";
      return 2;
    }
    return 0;
  } catch (const std::exception &error) {
    std::cerr << "hc-remote-peer: " << error.what() << '\n';
    return 1;
  }
}

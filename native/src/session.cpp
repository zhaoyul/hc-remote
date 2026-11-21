#include "hcr/hcr.hpp"

#include "event_queue.hpp"
#include "file_transfer.hpp"
#include "frame_codec.hpp"

#include <nlohmann/json.hpp>

#include <filesystem>
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
  FileReceivers fileReceivers;
  std::unique_ptr<FileSender> fileSender;
  std::string downloadDir = ".";
  std::uint32_t transferCounter = 0;
  std::uint64_t senderProgressMark = 0;
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
    pumpFileSender();
  }

  void pumpFileSender() {
    if (!fileSender) {
      return;
    }
    const bool done = fileSender->pump(
        [this](const std::string &channel, const std::vector<std::byte> &chunk) {
          // libdatachannel returns false when the message is queued rather
          // than handed to SCTP; queued messages are still delivered.
          try {
            peer.sendBinary(channel, chunk);
            return true;
          } catch (const std::exception &) {
            return false;
          }
        });
    if (fileSender->offset() - senderProgressMark >= fileProgressInterval) {
      senderProgressMark = fileSender->offset();
      Event event;
      event.type = EventType::FileProgress;
      event.frameId = fileSender->id();
      event.text = fileSender->name();
      event.fileSize = fileSender->offset();
      output.push(std::move(event));
    }
    if (done) {
      auto finish = encodeFileChunk(fileSender->id(), fileChunkTypeFinish,
                                    fileSender->offset(), nullptr, 0);
      peer.sendBinary("control", finish);
      Event event;
      event.type = EventType::FileComplete;
      event.frameId = fileSender->id();
      event.text = fileSender->name();
      event.fileSize = fileSender->totalSize();
      event.channel = "sent";
      output.push(std::move(event));
      senderProgressMark = 0;
      fileSender.reset();
    }
  }

  bool startFileTransfer(const std::string &path, const std::string &name) {
    std::error_code error;
    const auto size = std::filesystem::file_size(path, error);
    if (error) {
      Event event;
      event.type = EventType::FileError;
      event.code = "file_open_failed";
      event.text = path;
      output.push(std::move(event));
      return false;
    }
    const auto id = ++transferCounter;
    const auto baseName = name.empty()
                              ? std::filesystem::path(path).filename().string()
                              : name;
    fileSender = std::make_unique<FileSender>(path, sanitizeFileName(baseName),
                                              id, size);
    senderProgressMark = 0;

    nlohmann::json offer;
    offer["type"] = "file-offer";
    offer["id"] = id;
    offer["name"] = fileSender->name();
    offer["size"] = size;
    peer.sendText("control", offer.dump());
    return true;
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
      Event sub;
      auto rest = reassembler.offer(event.binary, sub);
      if (!rest) {
        if (sub.type == EventType::FrameMessage) {
          output.push(std::move(sub));
        }
        break;
      }
      auto rest2 = fileReceivers.offer(*rest, downloadDir, sub);
      if (!rest2) {
        if (sub.type == EventType::FileComplete) {
          nlohmann::json ack;
          ack["type"] = "file-done";
          ack["id"] = sub.frameId;
          peer.sendText("control", ack.dump());
        }
        if (sub.type != EventType::None) {
          output.push(std::move(sub));
        }
        break;
      }
      output.push(event);
      break;
    }
    case EventType::Message: {
      try {
        const auto json = nlohmann::json::parse(event.text);
        const auto type = json.at("type").get<std::string>();
        if (type == "file-offer") {
          Event offer;
          fileReceivers.announce(json.value("id", 0u),
                                 json.value("name", std::string("file")),
                                 json.value("size", std::uint64_t{0}),
                                 downloadDir, offer);
          output.push(std::move(offer));
          break;
        }
        if (type == "file-done") {
          Event ack;
          ack.type = EventType::FileComplete;
          ack.frameId = json.value("id", 0u);
          ack.channel = "acked";
          output.push(std::move(ack));
          break;
        }
      } catch (const std::exception &) {
        // Not protocol JSON: fall through as a plain chat message.
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

bool Session::sendFile(const std::string &path, const std::string &name) {
  return impl_->startFileTransfer(path, name);
}

void Session::setDownloadDir(const std::string &dir) {
  impl_->downloadDir = dir;
}

} // namespace hcr

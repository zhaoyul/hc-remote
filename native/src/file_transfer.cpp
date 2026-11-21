#include "file_transfer.hpp"

#include <cstring>
#include <filesystem>

namespace hcr {

namespace {

constexpr std::uint16_t fileMagic = 0x4846;
constexpr std::uint8_t fileVersion = 1;

void putU16(std::vector<std::byte> &buffer, std::size_t offset, std::uint16_t value) {
  buffer[offset] = static_cast<std::byte>(value & 0xff);
  buffer[offset + 1] = static_cast<std::byte>((value >> 8) & 0xff);
}

void putU32(std::vector<std::byte> &buffer, std::size_t offset, std::uint32_t value) {
  for (int i = 0; i < 4; ++i) {
    buffer[offset + i] = static_cast<std::byte>((value >> (8 * i)) & 0xff);
  }
}

void putU64(std::vector<std::byte> &buffer, std::size_t offset, std::uint64_t value) {
  for (int i = 0; i < 8; ++i) {
    buffer[offset + i] = static_cast<std::byte>((value >> (8 * i)) & 0xff);
  }
}

std::uint16_t getU16(const std::byte *data, std::size_t offset) {
  return static_cast<std::uint16_t>(std::to_integer<unsigned char>(data[offset])) |
         (static_cast<std::uint16_t>(std::to_integer<unsigned char>(data[offset + 1])) << 8);
}

std::uint32_t getU32(const std::byte *data, std::size_t offset) {
  std::uint32_t value = 0;
  for (int i = 0; i < 4; ++i) {
    value |= static_cast<std::uint32_t>(std::to_integer<unsigned char>(data[offset + i]))
             << (8 * i);
  }
  return value;
}

std::uint64_t getU64(const std::byte *data, std::size_t offset) {
  std::uint64_t value = 0;
  for (int i = 0; i < 8; ++i) {
    value |= static_cast<std::uint64_t>(std::to_integer<unsigned char>(data[offset + i]))
             << (8 * i);
  }
  return value;
}

} // namespace

std::string sanitizeFileName(const std::string &name) {
  std::string clean;
  for (char ch : name) {
    if (ch == '/' || ch == '\\' || ch == ':') {
      continue;
    }
    clean.push_back(ch);
  }
  if (clean.empty() || clean == "." || clean == "..") {
    clean = "received.bin";
  }
  return clean;
}

std::vector<std::byte> encodeFileChunk(std::uint32_t transferId, std::uint8_t type,
                                       std::uint64_t offset,
                                       const std::byte *payload, std::size_t size) {
  std::vector<std::byte> chunk(fileHeaderBytes + size);
  putU16(chunk, 0, fileMagic);
  chunk[2] = static_cast<std::byte>(fileVersion);
  chunk[3] = static_cast<std::byte>(type);
  putU32(chunk, 4, transferId);
  putU64(chunk, 8, offset);
  if (size > 0 && payload != nullptr) {
    std::memcpy(chunk.data() + fileHeaderBytes, payload, size);
  }
  return chunk;
}

bool isFileChunk(const std::vector<std::byte> &message) {
  return message.size() >= fileHeaderBytes &&
         getU16(message.data(), 0) == fileMagic &&
         std::to_integer<unsigned char>(message[2]) == fileVersion;
}

FileSender::FileSender(std::string path, std::string name,
                       std::uint32_t transferId, std::uint64_t totalSize)
    : name_(std::move(name)), transferId_(transferId), totalSize_(totalSize) {
  input_.open(path, std::ios::binary);
}

bool FileSender::pump(
    const std::function<bool(const std::string &,
                             const std::vector<std::byte> &)> &sendBinary) {
  if (!input_.is_open()) {
    return true;
  }
  std::vector<std::byte> buffer(fileChunkPayloadBytes);
  std::uint64_t budget = 256 * 1024;
  while (offset_ < totalSize_ && budget > 0) {
    input_.seekg(static_cast<std::streamoff>(offset_));
    const std::size_t want = static_cast<std::size_t>(
        std::min<std::uint64_t>(fileChunkPayloadBytes, totalSize_ - offset_));
    input_.read(reinterpret_cast<char *>(buffer.data()),
                static_cast<std::streamsize>(want));
    const std::size_t got = static_cast<std::size_t>(input_.gcount());
    if (got == 0) {
      return true;
    }
    auto chunk = encodeFileChunk(transferId_, fileChunkTypeData, offset_,
                                 buffer.data(), got);
    if (!sendBinary("control", chunk)) {
      return false;  // transient send failure: retry this chunk on next pump
    }
    offset_ += got;
    budget -= got;
  }
  return offset_ >= totalSize_;
}

std::optional<std::vector<std::byte>>
FileReceivers::offer(const std::vector<std::byte> &message,
                     const std::string &downloadDir, Event &out) {
  if (!isFileChunk(message)) {
    return message;
  }

  const auto *data = message.data();
  const auto type = static_cast<std::uint8_t>(std::to_integer<unsigned char>(data[3]));
  const std::uint32_t transferId = getU32(data, 4);
  const std::uint64_t offset = getU64(data, 8);

  auto found = receivers_.find(transferId);
  if (found == receivers_.end()) {
    out.type = EventType::FileError;
    out.code = "file_unknown_transfer";
    out.frameId = transferId;
    return std::nullopt;
  }

  Receiver &receiver = found->second;

  if (type == fileChunkTypeFinish) {
    receiver.output.close();
    Event event;
    event.type = EventType::FileComplete;
    event.frameId = transferId;
    event.text = receiver.path;
    event.fileSize = receiver.received;
    out = std::move(event);
    receivers_.erase(found);
    return std::nullopt;
  }

  if (type != fileChunkTypeData) {
    receiver.output.close();
    Event event;
    event.type = EventType::FileError;
    event.code = "file_chunk_type";
    event.text = receiver.name;
    event.frameId = transferId;
    out = std::move(event);
    receivers_.erase(found);
    return std::nullopt;
  }
  if (offset < receiver.received) {
    return std::nullopt;  // duplicate chunk: ignore
  }
  if (offset != receiver.received) {
    // Ordered channel: a gap means something went wrong.
    receiver.output.close();
    Event event;
    event.type = EventType::FileError;
    event.code = "file_offset_mismatch";
    event.text = receiver.name;
    event.frameId = transferId;
    out = std::move(event);
    receivers_.erase(found);
    return std::nullopt;
  }

  const std::size_t payloadSize = message.size() - fileHeaderBytes;
  if (payloadSize > 0) {
    receiver.output.write(reinterpret_cast<const char *>(data + fileHeaderBytes),
                          static_cast<std::streamsize>(payloadSize));
    receiver.received += payloadSize;
  }

  if (receiver.received - receiver.lastProgressMark >= fileProgressInterval) {
    receiver.lastProgressMark = receiver.received;
    Event event;
    event.type = EventType::FileProgress;
    event.frameId = transferId;
    event.text = receiver.name;
    event.fileSize = receiver.received;
    out = std::move(event);
    return std::nullopt;
  }
  return std::nullopt;
}

void FileReceivers::announce(std::uint32_t transferId, const std::string &name,
                             std::uint64_t size, const std::string &downloadDir,
                             Event &out) {
  const std::string safeName = sanitizeFileName(name);
  std::filesystem::create_directories(downloadDir);
  const std::string path = (std::filesystem::path(downloadDir) / safeName).string();

  Receiver receiver;
  receiver.name = safeName;
  receiver.path = path;
  receiver.expected = size;
  receiver.output.open(path, std::ios::binary | std::ios::trunc);

  if (!receiver.output.is_open()) {
    out.type = EventType::FileError;
    out.code = "file_open_failed";
    out.text = path;
    out.frameId = transferId;
    return;
  }

  receivers_[transferId] = std::move(receiver);

  out.type = EventType::FileOffer;
  out.frameId = transferId;
  out.text = safeName;
  out.fileSize = size;
  out.channel = path;
}

} // namespace hcr

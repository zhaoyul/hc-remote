#include "frame_codec.hpp"

#include <cstring>

namespace hcr {

namespace {

constexpr std::uint16_t frameMagic = 0x4855;
constexpr std::uint8_t frameVersion = 1;

void putU16(std::vector<std::byte> &buffer, std::size_t offset, std::uint16_t value) {
  buffer[offset] = static_cast<std::byte>(value & 0xff);
  buffer[offset + 1] = static_cast<std::byte>((value >> 8) & 0xff);
}

void putU32(std::vector<std::byte> &buffer, std::size_t offset, std::uint32_t value) {
  for (int i = 0; i < 4; ++i) {
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

bool isFrameChunk(const std::vector<std::byte> &message) {
  return message.size() >= frameHeaderBytes &&
         getU16(message.data(), 0) == frameMagic &&
         std::to_integer<unsigned char>(message[2]) == frameVersion;
}

} // namespace

std::vector<std::vector<std::byte>>
encodeFrameChunks(std::uint32_t frameId, bool keyframe, std::uint32_t timestampMs,
                  const std::vector<std::byte> &payload) {
  const std::size_t chunkCount =
      payload.empty() ? 1 : (payload.size() + frameChunkPayloadBytes - 1) / frameChunkPayloadBytes;
  std::vector<std::vector<std::byte>> chunks;
  chunks.reserve(chunkCount);
  for (std::size_t index = 0; index < chunkCount; ++index) {
    const std::size_t begin = index * frameChunkPayloadBytes;
    const std::size_t end = std::min(payload.size(), begin + frameChunkPayloadBytes);
    std::vector<std::byte> chunk(frameHeaderBytes + (end - begin));
    putU16(chunk, 0, frameMagic);
    chunk[2] = static_cast<std::byte>(frameVersion);
    chunk[3] = static_cast<std::byte>(keyframe ? 1 : 0);
    putU32(chunk, 4, frameId);
    putU32(chunk, 8, timestampMs);
    putU16(chunk, 12, static_cast<std::uint16_t>(index));
    putU16(chunk, 14, static_cast<std::uint16_t>(chunkCount));
    std::memcpy(chunk.data() + frameHeaderBytes, payload.data() + begin, end - begin);
    chunks.push_back(std::move(chunk));
  }
  return chunks;
}

std::optional<std::vector<std::byte>>
FrameReassembler::offer(const std::vector<std::byte> &message, Event &out) {
  if (!isFrameChunk(message)) {
    return message;
  }

  const auto *data = message.data();
  const bool keyframe = std::to_integer<unsigned char>(data[3]) != 0;
  const std::uint32_t frameId = getU32(data, 4);
  const std::uint32_t timestampMs = getU32(data, 8);
  const std::uint16_t chunkIndex = getU16(data, 12);
  const std::uint16_t chunkCount = getU16(data, 14);

  if (chunkCount == 0 || chunkIndex >= chunkCount) {
    return std::nullopt;
  }

  auto found = partials_.find(frameId);
  if (found == partials_.end()) {
    if (partials_.size() >= maxInflightFrames) {
      partials_.erase(partials_.begin());
    }
    Partial fresh;
    fresh.keyframe = keyframe;
    fresh.timestampMs = timestampMs;
    fresh.chunkCount = chunkCount;
    fresh.chunks.resize(chunkCount);
    found = partials_.emplace(frameId, std::move(fresh)).first;
  }

  Partial &partial = found->second;
  if (partial.chunkCount != chunkCount) {
    partials_.erase(found);
    return std::nullopt;
  }

  const std::size_t payloadSize = message.size() - frameHeaderBytes;
  if (partial.totalBytes + payloadSize > maxFrameBytes) {
    partials_.erase(found);
    return std::nullopt;
  }

  if (partial.chunks[chunkIndex].empty()) {
    partial.chunks[chunkIndex].assign(data + frameHeaderBytes, data + message.size());
    partial.totalBytes += payloadSize;
    ++partial.received;
  }

  if (partial.received < partial.chunkCount) {
    return std::nullopt;
  }

  std::vector<std::byte> frame;
  frame.reserve(partial.totalBytes);
  for (const auto &chunk : partial.chunks) {
    frame.insert(frame.end(), chunk.begin(), chunk.end());
  }

  out.type = EventType::FrameMessage;
  out.frameId = frameId;
  out.timestampMs = partial.timestampMs;
  out.keyframe = partial.keyframe;
  out.binary = std::move(frame);
  partials_.erase(found);
  return std::nullopt;
}

} // namespace hcr

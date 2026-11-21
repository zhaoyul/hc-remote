#pragma once

#include "hcr/hcr.hpp"

#include <cstddef>
#include <cstdint>
#include <map>
#include <optional>
#include <vector>

namespace hcr {

constexpr std::size_t frameChunkPayloadBytes = 16 * 1024;
constexpr std::size_t frameHeaderBytes = 16;
constexpr std::size_t maxInflightFrames = 32;
constexpr std::size_t maxFrameBytes = 8 * 1024 * 1024;

// Chunk wire format (little endian):
//   0  u16 magic = 0x4855
//   2  u8  version = 1
//   3  u8  flags (bit0 = keyframe)
//   4  u32 frame id
//   8  u32 timestamp ms
//   12 u16 chunk index
//   14 u16 chunk count
//   16 payload

std::vector<std::vector<std::byte>>
encodeFrameChunks(std::uint32_t frameId, bool keyframe, std::uint32_t timestampMs,
                  const std::vector<std::byte> &payload);

class FrameReassembler {
public:
  // Consumes game-channel binary messages. Returns the message back when it
  // does not belong to the frame protocol (raw binary passthrough). Returns
  // std::nullopt when consumed; when a frame completes, `out` is set.
  std::optional<std::vector<std::byte>> offer(const std::vector<std::byte> &message,
                                              Event &out);

private:
  struct Partial {
    bool keyframe = false;
    std::uint32_t timestampMs = 0;
    std::uint16_t chunkCount = 0;
    std::uint16_t received = 0;
    std::vector<std::vector<std::byte>> chunks;
    std::size_t totalBytes = 0;
  };

  std::map<std::uint32_t, Partial> partials_;
};

} // namespace hcr

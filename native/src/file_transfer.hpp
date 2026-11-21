#pragma once

#include "hcr/hcr.hpp"

#include <cstddef>
#include <cstdint>
#include <fstream>
#include <functional>
#include <map>
#include <optional>
#include <string>
#include <vector>

namespace hcr {

constexpr std::size_t fileChunkPayloadBytes = 32 * 1024;
constexpr std::size_t fileHeaderBytes = 16;
constexpr std::uint64_t fileProgressInterval = 8 * 1024 * 1024;
constexpr std::uint8_t fileChunkTypeData = 1;
constexpr std::uint8_t fileChunkTypeFinish = 2;

// Chunk wire format on the control channel (little endian):
//   0  u16 magic = 0x4846
//   2  u8  version = 1
//   3  u8  type (1 = data, 2 = finish)
//   4  u32 transfer id
//   8  u64 payload offset
//   16 payload (data only)

std::vector<std::byte> encodeFileChunk(std::uint32_t transferId, std::uint8_t type,
                                       std::uint64_t offset,
                                       const std::byte *payload, std::size_t size);

bool isFileChunk(const std::vector<std::byte> &message);

class FileSender {
public:
  FileSender(std::string path, std::string name, std::uint32_t transferId,
             std::uint64_t totalSize);

  std::uint32_t id() const { return transferId_; }
  const std::string &name() const { return name_; }
  std::uint64_t offset() const { return offset_; }
  std::uint64_t totalSize() const { return totalSize_; }

  // Streams up to 256 KiB of file data. Returns true once fully sent.
  bool pump(const std::function<bool(const std::string &,
                                     const std::vector<std::byte> &)> &sendBinary);

private:
  std::ifstream input_;
  std::string name_;
  std::uint32_t transferId_;
  std::uint64_t totalSize_;
  std::uint64_t offset_ = 0;
};

class FileReceivers {
public:
  // Consumes control-channel binary messages. Returns the message back when
  // it does not belong to the file protocol. On file events, `out` is set
  // (FileOffer/FileProgress/FileComplete/FileError).
  std::optional<std::vector<std::byte>> offer(const std::vector<std::byte> &message,
                                              const std::string &downloadDir,
                                              Event &out);

  // Registers a transfer announced by a file-offer text message.
  void announce(std::uint32_t transferId, const std::string &name,
                std::uint64_t size, const std::string &downloadDir, Event &out);

private:
  struct Receiver {
    std::string name;
    std::string path;
    std::ofstream output;
    std::uint64_t expected = 0;
    std::uint64_t received = 0;
    std::uint64_t lastProgressMark = 0;
  };

  std::map<std::uint32_t, Receiver> receivers_;
};

std::string sanitizeFileName(const std::string &name);

} // namespace hcr

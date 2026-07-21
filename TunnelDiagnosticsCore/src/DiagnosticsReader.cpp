#include "DiagnosticsReader.hpp"
#include "PosixFile.hpp"

#include <algorithm>

namespace fptn::diag {

std::size_t ReadValidEvents(const char* path, Event* output,
                            std::size_t capacity) noexcept {
  const int fd = ::open(path, O_RDONLY);
  if (fd < 0) return 0;
  PosixFile file(fd);

  // Validate header.
  std::array<std::byte, kFlightRingHeaderSize> header_bytes{};
  if (!PreadAll(fd, header_bytes.data(), header_bytes.size(), 0)) {
    return 0;
  }

  const std::uint32_t magic =
      static_cast<std::uint32_t>(static_cast<std::uint8_t>(header_bytes[0])) |
      (static_cast<std::uint32_t>(static_cast<std::uint8_t>(header_bytes[1])) << 8) |
      (static_cast<std::uint32_t>(static_cast<std::uint8_t>(header_bytes[2])) << 16) |
      (static_cast<std::uint32_t>(static_cast<std::uint8_t>(header_bytes[3])) << 24);
  if (magic != kFlightRingMagic) {
    return 0;
  }

  // Read all slots, validate, collect.
  std::size_t count = 0;
  for (std::size_t slot = 0;
       slot < kFlightRingCapacity && count < capacity; ++slot) {
    const std::size_t offset =
        kFlightRingHeaderSize + slot * kFlightRecordSize;
    std::array<std::byte, kFlightRecordSize> record_bytes{};
    if (!PreadAll(fd, record_bytes.data(), record_bytes.size(),
                  static_cast<off_t>(offset))) {
      continue;
    }

    Event event;
    if (DecodeEvent(record_bytes, event) && event.sequence > 0) {
      output[count++] = event;
    }
  }

  // Sort by sequence.
  std::sort(output, output + count,
            [](const Event& a, const Event& b) {
              return a.sequence < b.sequence;
            });

  return count;
}

bool ReadLatestSnapshot(const char* path, Snapshot& output) noexcept {
  const int fd = ::open(path, O_RDONLY);
  if (fd < 0) return false;
  PosixFile file(fd);

  bool found = false;
  std::uint64_t best_seq = 0;

  for (int slot = 0; slot < static_cast<int>(kSnapshotSlotCount); ++slot) {
    const std::size_t offset =
        static_cast<std::size_t>(slot) * kSnapshotMaxSize;
    std::array<std::byte, kSnapshotMaxSize> bytes{};
    if (!PreadAll(fd, bytes.data(), bytes.size(),
                  static_cast<off_t>(offset))) {
      continue;
    }

    Snapshot snap;
    if (DecodeSnapshot(bytes, kSnapshotMaxSize, snap)) {
      if (!found || snap.write_sequence > best_seq) {
        best_seq = snap.write_sequence;
        output = snap;
        found = true;
      }
    }
  }

  return found;
}

}  // namespace fptn::diag

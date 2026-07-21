#include "DiagnosticsReader.hpp"
#include "DiskFormat.hpp"
#include "PosixFile.hpp"

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <sys/stat.h>

namespace fptn::diag {

namespace {

std::uint32_t ReadU32LE(const std::byte* p) noexcept {
  return static_cast<std::uint32_t>(static_cast<std::uint8_t>(p[0])) |
         (static_cast<std::uint32_t>(static_cast<std::uint8_t>(p[1])) << 8) |
         (static_cast<std::uint32_t>(static_cast<std::uint8_t>(p[2])) << 16) |
         (static_cast<std::uint32_t>(static_cast<std::uint8_t>(p[3])) << 24);
}

std::uint16_t ReadU16LE(const std::byte* p) noexcept {
  return static_cast<std::uint16_t>(
      static_cast<std::uint16_t>(static_cast<std::uint8_t>(p[0])) |
      (static_cast<std::uint16_t>(static_cast<std::uint8_t>(p[1])) << 8));
}

}  // namespace

ReadStatus ReadValidEvents(const char* path, Event* output,
                           std::size_t capacity,
                           std::size_t* output_count) noexcept {
  *output_count = 0;

  const int fd = ::open(path, O_RDONLY);
  if (fd < 0) return errno == ENOENT ? ReadStatus::kFileNotFound : ReadStatus::kIoError;
  PosixFile file(fd);

  // Validate complete header.
  std::array<std::byte, kFlightRingHeaderSize> header_bytes{};
  if (!PreadAll(fd, header_bytes.data(), header_bytes.size(), 0)) {
    return ReadStatus::kIoError;
  }

  const std::uint32_t magic = ReadU32LE(&header_bytes[0]);
  if (magic != kFlightRingMagic) {
    return ReadStatus::kInvalidHeader;
  }

  const std::uint16_t schema = ReadU16LE(&header_bytes[4]);
  const std::uint16_t header_size = ReadU16LE(&header_bytes[6]);
  const std::uint16_t record_size = ReadU16LE(&header_bytes[8]);
  const std::uint16_t ring_capacity = ReadU16LE(&header_bytes[10]);
  const std::uint32_t header_crc = ReadU32LE(&header_bytes[12]);

  if (schema != kSchemaVersion || header_size != kFlightRingHeaderSize ||
      record_size != kFlightRecordSize || ring_capacity != kFlightRingCapacity) {
    return ReadStatus::kInvalidHeader;
  }

  // Validate header CRC (over bytes 0..11).
  const std::uint32_t computed_crc = Crc32(header_bytes.data(), 12);
  if (header_crc != computed_crc) {
    return ReadStatus::kInvalidHeader;
  }

  // Validate file size.
  const std::size_t expected_size =
      kFlightRingHeaderSize + kFlightRingCapacity * kFlightRecordSize;
  struct stat st;
  if (::fstat(fd, &st) != 0 ||
      static_cast<std::size_t>(st.st_size) < expected_size) {
    return ReadStatus::kInvalidHeader;
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

  if (count == 0) {
    return ReadStatus::kEmpty;
  }

  // Sort by sequence.
  std::sort(output, output + count,
            [](const Event& a, const Event& b) {
              return a.sequence < b.sequence;
            });

  *output_count = count;
  return ReadStatus::kOk;
}

ReadStatus ReadLatestSnapshot(const char* path, Snapshot& output) noexcept {
  const int fd = ::open(path, O_RDONLY);
  if (fd < 0) return errno == ENOENT ? ReadStatus::kFileNotFound : ReadStatus::kIoError;
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

  return found ? ReadStatus::kOk : ReadStatus::kEmpty;
}

}  // namespace fptn::diag

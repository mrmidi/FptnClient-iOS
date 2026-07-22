#include "FlightRecorder.hpp"

#include <cstring>
#include <new>

namespace fptn::diag {

namespace {

// Ring file layout:
//   [0..63]   FptnFlightRingHeader (64 bytes)
//   [64..]    120 records × 72 bytes = 8,640 bytes
//   Total: 8,704 bytes

inline constexpr std::size_t kRingFileSize =
    kFlightRingHeaderSize + kFlightRingCapacity * kFlightRecordSize;

std::size_t SlotOffset(std::uint64_t sequence) noexcept {
  const std::size_t slot =
      static_cast<std::size_t>((sequence - 1) % kFlightRingCapacity);
  return kFlightRingHeaderSize + slot * kFlightRecordSize;
}

}  // namespace

FlightRecorder* FlightRecorder::Open(const char* path) noexcept {
  auto* rec = new (std::nothrow) FlightRecorder();
  if (!rec) return nullptr;

  const int fd = ::open(path, O_RDWR | O_CREAT, 0644);
  if (fd < 0) {
    delete rec;
    return nullptr;
  }
  rec->file_.Reset(fd);

  // Check if the file already has a valid header.
  if (!rec->InitFromExisting()) {
    if (!rec->WriteHeader()) {
      delete rec;
      return nullptr;
    }
  }

  return rec;
}

bool FlightRecorder::InitFromExisting() noexcept {
  // Read the header.
  std::array<std::byte, kFlightRingHeaderSize> header_bytes{};
  if (!PreadAll(file_.Get(), header_bytes.data(), header_bytes.size(), 0)) {
    return false;
  }

  // Validate magic.
  const std::uint32_t magic =
      static_cast<std::uint32_t>(static_cast<std::uint8_t>(header_bytes[0])) |
      (static_cast<std::uint32_t>(static_cast<std::uint8_t>(header_bytes[1])) << 8) |
      (static_cast<std::uint32_t>(static_cast<std::uint8_t>(header_bytes[2])) << 16) |
      (static_cast<std::uint32_t>(static_cast<std::uint8_t>(header_bytes[3])) << 24);
  if (magic != kFlightRingMagic) {
    return false;
  }

  // Scan all slots for the highest valid sequence.
  std::uint64_t max_sequence = 0;
  for (std::size_t slot = 0; slot < kFlightRingCapacity; ++slot) {
    const std::size_t offset = kFlightRingHeaderSize + slot * kFlightRecordSize;
    std::array<std::byte, kFlightRecordSize> record_bytes{};
    if (!PreadAll(file_.Get(), record_bytes.data(), record_bytes.size(),
                  static_cast<off_t>(offset))) {
      continue;
    }

    Event event;
    if (DecodeEvent(record_bytes, event)) {
      if (event.sequence > max_sequence) {
        max_sequence = event.sequence;
      }
    }
  }

  next_sequence_ = max_sequence + 1;
  return true;
}

bool FlightRecorder::WriteHeader() noexcept {
  std::array<std::byte, kFlightRingHeaderSize> header{};

  // magic
  header[0] = static_cast<std::byte>(kFlightRingMagic & 0xFF);
  header[1] = static_cast<std::byte>((kFlightRingMagic >> 8) & 0xFF);
  header[2] = static_cast<std::byte>((kFlightRingMagic >> 16) & 0xFF);
  header[3] = static_cast<std::byte>((kFlightRingMagic >> 24) & 0xFF);
  // schema_version
  header[4] = static_cast<std::byte>(kSchemaVersion & 0xFF);
  header[5] = static_cast<std::byte>((kSchemaVersion >> 8) & 0xFF);
  // header_size
  header[6] = static_cast<std::byte>(kFlightRingHeaderSize & 0xFF);
  header[7] = static_cast<std::byte>((kFlightRingHeaderSize >> 8) & 0xFF);
  // record_size
  header[8] = static_cast<std::byte>(kFlightRecordSize & 0xFF);
  header[9] = static_cast<std::byte>((kFlightRecordSize >> 8) & 0xFF);
  // capacity
  header[10] = static_cast<std::byte>(kFlightRingCapacity & 0xFF);
  header[11] = static_cast<std::byte>((kFlightRingCapacity >> 8) & 0xFF);
  // checksum over bytes 0..11
  const std::uint32_t crc = Crc32(header.data(), 12);
  header[12] = static_cast<std::byte>(crc & 0xFF);
  header[13] = static_cast<std::byte>((crc >> 8) & 0xFF);
  header[14] = static_cast<std::byte>((crc >> 16) & 0xFF);
  header[15] = static_cast<std::byte>((crc >> 24) & 0xFF);
  // rest is reserved (zero)

  if (!PwriteAll(file_.Get(), header.data(), header.size(), 0)) {
    return false;
  }

  // Extend file to full ring size.
  if (::ftruncate(file_.Get(), static_cast<off_t>(kRingFileSize)) != 0) {
    return false;
  }

  next_sequence_ = 1;
  return true;
}

std::uint64_t FlightRecorder::Record(const Event& event,
                                     bool synchronize) noexcept {
  std::lock_guard<std::mutex> lock(mutex_);

  const std::uint64_t seq = next_sequence_;

  // Build the record with the assigned sequence.
  Event committed = event;
  committed.sequence = seq;

  const RecordBytes bytes = EncodeEvent(committed);
  const std::size_t offset = SlotOffset(seq);

  // Write payload (bytes 8..71) first, then sequence (bytes 0..7)
  // as the commit marker.
  if (!PwriteAll(file_.Get(), &bytes[8], kFlightRecordSize - 8,
                 static_cast<off_t>(offset + 8))) {
    return 0;
  }

  // Commit: write sequence.
  if (!PwriteAll(file_.Get(), &bytes[0], 8,
                 static_cast<off_t>(offset))) {
    return 0;
  }

  if (synchronize) {
    ::fsync(file_.Get());
  }

  next_sequence_ = seq + 1;
  return seq;
}

bool FlightRecorder::Flush() noexcept {
  std::lock_guard<std::mutex> lock(mutex_);
  return ::fsync(file_.Get()) == 0;
}

}  // namespace fptn::diag

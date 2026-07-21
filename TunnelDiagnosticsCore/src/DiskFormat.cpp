#include "DiskFormat.hpp"

#include <cstring>

namespace fptn::diag {

namespace {

// Little-endian write helpers.
void WriteU16(std::byte* dst, std::uint16_t v) noexcept {
  dst[0] = static_cast<std::byte>(v & 0xFF);
  dst[1] = static_cast<std::byte>((v >> 8) & 0xFF);
}

void WriteU32(std::byte* dst, std::uint32_t v) noexcept {
  dst[0] = static_cast<std::byte>(v & 0xFF);
  dst[1] = static_cast<std::byte>((v >> 8) & 0xFF);
  dst[2] = static_cast<std::byte>((v >> 16) & 0xFF);
  dst[3] = static_cast<std::byte>((v >> 24) & 0xFF);
}

void WriteU64(std::byte* dst, std::uint64_t v) noexcept {
  for (int i = 0; i < 8; ++i) {
    dst[i] = static_cast<std::byte>((v >> (i * 8)) & 0xFF);
  }
}

std::uint16_t ReadU16(const std::byte* src) noexcept {
  return static_cast<std::uint16_t>(
      static_cast<std::uint8_t>(src[0]) |
      (static_cast<std::uint16_t>(static_cast<std::uint8_t>(src[1])) << 8));
}

std::uint32_t ReadU32(const std::byte* src) noexcept {
  return static_cast<std::uint32_t>(static_cast<std::uint8_t>(src[0])) |
         (static_cast<std::uint32_t>(static_cast<std::uint8_t>(src[1])) << 8) |
         (static_cast<std::uint32_t>(static_cast<std::uint8_t>(src[2])) << 16) |
         (static_cast<std::uint32_t>(static_cast<std::uint8_t>(src[3])) << 24);
}

std::uint64_t ReadU64(const std::byte* src) noexcept {
  std::uint64_t v = 0;
  for (int i = 7; i >= 0; --i) {
    v = (v << 8) | static_cast<std::uint64_t>(static_cast<std::uint8_t>(src[i]));
  }
  return v;
}

// Record layout (72 bytes, little-endian):
//   [0..7]   sequence        (commit marker, written last)
//   [8..15]  mach_continuous_time
//   [16..23] process_token
//   [24..31] tunnel_session_token
//   [32..33] event_code
//   [34..35] flags
//   [36..39] websocket_generation
//   [40..47] value_0
//   [48..55] value_1
//   [56..63] value_2
//   [64..67] checksum (CRC32 over bytes 8..63 with checksum=0)
//   [68..71] reserved

inline constexpr std::size_t kChecksumOffset = 64;
inline constexpr std::size_t kCrcStart = 8;
inline constexpr std::size_t kCrcEnd = 64;

}  // namespace

std::uint32_t Crc32(const std::byte* data, std::size_t length) noexcept {
  std::uint32_t crc = 0xFFFFFFFF;
  for (std::size_t i = 0; i < length; ++i) {
    crc ^= static_cast<std::uint32_t>(static_cast<std::uint8_t>(data[i]));
    for (int bit = 0; bit < 8; ++bit) {
      crc = (crc >> 1) ^ (0xEDB88320 & (~(crc & 1) + 1));
    }
  }
  return crc ^ 0xFFFFFFFF;
}

RecordBytes EncodeEvent(const Event& event) noexcept {
  RecordBytes bytes{};  // zero-init (reserved fields = 0)

  // Fill fields 8..63 first (sequence written last as commit).
  WriteU64(&bytes[8], event.mach_continuous_time);
  WriteU64(&bytes[16], event.process_token);
  WriteU64(&bytes[24], event.tunnel_session_token);
  WriteU16(&bytes[32], event.event_code);
  WriteU16(&bytes[34], event.flags);
  WriteU32(&bytes[36], event.websocket_generation);
  WriteU64(&bytes[40], event.value_0);
  WriteU64(&bytes[48], event.value_1);
  WriteU64(&bytes[56], event.value_2);

  // CRC32 over bytes 8..63 (checksum field at 64..67 is zero).
  const std::uint32_t crc = Crc32(&bytes[kCrcStart], kCrcEnd - kCrcStart);
  WriteU32(&bytes[kChecksumOffset], crc);

  // Commit marker: sequence written last.
  WriteU64(&bytes[0], event.sequence);

  return bytes;
}

bool DecodeEvent(std::span<const std::byte, kFlightRecordSize> bytes,
                 Event& output) noexcept {
  // Validate checksum.
  const std::uint32_t stored_crc = ReadU32(&bytes[kChecksumOffset]);
  const std::uint32_t computed_crc = Crc32(&bytes[kCrcStart], kCrcEnd - kCrcStart);
  if (stored_crc != computed_crc) {
    return false;
  }

  output.sequence = ReadU64(&bytes[0]);
  output.mach_continuous_time = ReadU64(&bytes[8]);
  output.process_token = ReadU64(&bytes[16]);
  output.tunnel_session_token = ReadU64(&bytes[24]);
  output.event_code = ReadU16(&bytes[32]);
  output.flags = ReadU16(&bytes[34]);
  output.websocket_generation = ReadU32(&bytes[36]);
  output.value_0 = ReadU64(&bytes[40]);
  output.value_1 = ReadU64(&bytes[48]);
  output.value_2 = ReadU64(&bytes[56]);

  return true;
}

SnapshotBytes EncodeSnapshot(const Snapshot& snap) noexcept {
  SnapshotBytes bytes{};  // zero-init

  // Layout (all little-endian):
  //   [0..3]   magic
  //   [4..5]   schema_version
  //   [6..7]   byte_size (actual used)
  //   [8..15]  write_sequence
  //   [16..19] checksum (filled after all other fields)
  //   [20..23] pid
  //   [24..31] process_token
  //   [32..39] process_sequence
  //   [40..47] process_started_mach_time
  //   [48..55] tunnel_session_token
  //   [56..63] tunnel_started_mach_time
  //   [64..67] provider_stop_reason
  //   [68..69] local_stop_initiator
  //   [70..71] native_disconnect_code
  //   [72..73] native_stop_origin
  //   [74..75] reserved_terminal
  //   [76..83] snapshot_mach_continuous_time
  //   [84..91] snapshot_wall_time_ns
  //   [92..95] flags
  //   [96..99] lifecycle_state
  //   [100..103] websocket_generation
  //   [104..107] reconnect_attempt
  //   [108..115] physical_footprint_bytes
  //   [116..123] physical_footprint_peak_bytes
  //   [124..131] resident_bytes
  //   [132..135] active_bridges
  //   [136..139] active_native_clients
  //   [140..143] native_active_operations
  //   [144..147] active_reader_coroutines
  //   [148..151] active_sender_coroutines
  //   [152..155] active_read_loops
  //   [156..163] outbound_queued_bytes
  //   [164..171] outbound_queued_bytes_peak
  //   [172..179] latest_event_sequence

  constexpr std::uint16_t kUsedBytes = 180;

  WriteU32(&bytes[0], kSnapshotMagic);
  WriteU16(&bytes[4], kSchemaVersion);
  WriteU16(&bytes[6], kUsedBytes);
  WriteU64(&bytes[8], snap.write_sequence);
  // checksum at [16..19] filled below
  WriteU32(&bytes[20], snap.pid);
  WriteU64(&bytes[24], snap.process_token);
  WriteU64(&bytes[32], snap.process_sequence);
  WriteU64(&bytes[40], snap.process_started_mach_time);
  WriteU64(&bytes[48], snap.tunnel_session_token);
  WriteU64(&bytes[56], snap.tunnel_started_mach_time);
  WriteU32(&bytes[64], snap.provider_stop_reason);
  WriteU16(&bytes[68], snap.local_stop_initiator);
  WriteU16(&bytes[70], snap.native_disconnect_code);
  WriteU16(&bytes[72], snap.native_stop_origin);
  // [74..75] reserved_terminal = 0
  WriteU64(&bytes[76], snap.snapshot_mach_continuous_time);
  WriteU64(&bytes[84], snap.snapshot_wall_time_ns);
  WriteU32(&bytes[92], snap.flags);
  WriteU32(&bytes[96], snap.lifecycle_state);
  WriteU32(&bytes[100], snap.websocket_generation);
  WriteU32(&bytes[104], snap.reconnect_attempt);
  WriteU64(&bytes[108], snap.physical_footprint_bytes);
  WriteU64(&bytes[116], snap.physical_footprint_peak_bytes);
  WriteU64(&bytes[124], snap.resident_bytes);
  WriteU32(&bytes[132], snap.active_bridges);
  WriteU32(&bytes[136], snap.active_native_clients);
  WriteU32(&bytes[140], snap.native_active_operations);
  WriteU32(&bytes[144], snap.active_reader_coroutines);
  WriteU32(&bytes[148], snap.active_sender_coroutines);
  WriteU32(&bytes[152], snap.active_read_loops);
  WriteU64(&bytes[156], snap.outbound_queued_bytes);
  WriteU64(&bytes[164], snap.outbound_queued_bytes_peak);
  WriteU64(&bytes[172], snap.latest_event_sequence);

  // CRC32 over bytes 20..179 (skipping magic/version/size/sequence/checksum).
  const std::uint32_t crc = Crc32(&bytes[20], kUsedBytes - 20);
  WriteU32(&bytes[16], crc);

  return bytes;
}

bool DecodeSnapshot(std::span<const std::byte> bytes, std::size_t length,
                    Snapshot& output) noexcept {
  if (length < 180) {
    return false;
  }

  const std::uint32_t magic = ReadU32(&bytes[0]);
  if (magic != kSnapshotMagic) {
    return false;
  }

  const std::uint16_t version = ReadU16(&bytes[4]);
  if (version != kSchemaVersion) {
    return false;
  }

  const std::uint16_t used_bytes = ReadU16(&bytes[6]);
  if (used_bytes < 180 || static_cast<std::size_t>(used_bytes) > length) {
    return false;
  }

  // Validate checksum.
  const std::uint32_t stored_crc = ReadU32(&bytes[16]);
  const std::uint32_t computed_crc = Crc32(&bytes[20], used_bytes - 20);
  if (stored_crc != computed_crc) {
    return false;
  }

  output.write_sequence = ReadU64(&bytes[8]);
  output.pid = ReadU32(&bytes[20]);
  output.process_token = ReadU64(&bytes[24]);
  output.process_sequence = ReadU64(&bytes[32]);
  output.process_started_mach_time = ReadU64(&bytes[40]);
  output.tunnel_session_token = ReadU64(&bytes[48]);
  output.tunnel_started_mach_time = ReadU64(&bytes[56]);
  output.provider_stop_reason = ReadU32(&bytes[64]);
  output.local_stop_initiator = ReadU16(&bytes[68]);
  output.native_disconnect_code = ReadU16(&bytes[70]);
  output.native_stop_origin = ReadU16(&bytes[72]);
  output.snapshot_mach_continuous_time = ReadU64(&bytes[76]);
  output.snapshot_wall_time_ns = ReadU64(&bytes[84]);
  output.flags = ReadU32(&bytes[92]);
  output.lifecycle_state = ReadU32(&bytes[96]);
  output.websocket_generation = ReadU32(&bytes[100]);
  output.reconnect_attempt = ReadU32(&bytes[104]);
  output.physical_footprint_bytes = ReadU64(&bytes[108]);
  output.physical_footprint_peak_bytes = ReadU64(&bytes[116]);
  output.resident_bytes = ReadU64(&bytes[124]);
  output.active_bridges = ReadU32(&bytes[132]);
  output.active_native_clients = ReadU32(&bytes[136]);
  output.native_active_operations = ReadU32(&bytes[140]);
  output.active_reader_coroutines = ReadU32(&bytes[144]);
  output.active_sender_coroutines = ReadU32(&bytes[148]);
  output.active_read_loops = ReadU32(&bytes[152]);
  output.outbound_queued_bytes = ReadU64(&bytes[156]);
  output.outbound_queued_bytes_peak = ReadU64(&bytes[164]);
  output.latest_event_sequence = ReadU64(&bytes[172]);

  return true;
}

}  // namespace fptn::diag

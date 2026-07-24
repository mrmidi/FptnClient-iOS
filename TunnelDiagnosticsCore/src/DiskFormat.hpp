#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>

namespace fptn::diag {

// PR3: flight event codes. Numeric, no strings in the provider.
enum class EventCode : std::uint16_t {
  kProcessStarted = 1,
  kStartTunnel = 2,
  kTunnelConnected = 3,
  kStopTunnelEntered = 4,
  kTunnelStopped = 5,
  kBridgeCreated = 6,
  kBridgeStartRequested = 7,
  kBridgeConnected = 8,
  kBridgeStopRequested = 9,
  kBridgeTeardownCompleted = 10,
  kReaderStarted = 11,
  kReaderStopped = 12,
  kSenderStarted = 13,
  kSenderStopped = 14,
  kReconnectScheduled = 15,
  kReconnectStarted = 16,
  kTransportDisconnected = 17,
  kPathChanged = 18,
  kMemorySample = 19,
  kMemoryWarning = 20,
  kMemoryCritical = 21,
  kQueueHighWater = 22,
  kInvariantViolation = 23,
  kSnapshotWriteFailed = 24,
};

// PR3: lifecycle state codes for the snapshot.
enum class LifecycleState : std::uint32_t {
  kIdle = 0,
  kStarting = 1,
  kConnected = 2,
  kReasserting = 3,
  kWaitingForNetwork = 4,
  kStopping = 5,
  kFailed = 6,
};

// PR3: snapshot flags (bitfield).
enum SnapshotFlags : std::uint32_t {
  kFlagShutdownRequested = 1u << 0,
  kFlagReasserting = 1u << 1,
  kFlagPathSatisfied = 1u << 2,
  kFlagReadLoopActive = 1u << 3,
  kFlagPacketReadPending = 1u << 4,
  kFlagNativeStopCleanupCompleted = 1u << 5,
  kFlagRecorderError = 1u << 6,
};

// PR3: in-memory event representation (not written directly to disk).
struct Event {
  std::uint64_t sequence = 0;
  std::uint64_t mach_continuous_time = 0;
  std::uint64_t process_token = 0;
  std::uint64_t tunnel_session_token = 0;
  std::uint16_t event_code = 0;
  std::uint16_t flags = 0;
  std::uint32_t websocket_generation = 0;
  std::uint64_t value_0 = 0;
  std::uint64_t value_1 = 0;
  std::uint64_t value_2 = 0;
};

// PR3: in-memory snapshot representation.
struct Snapshot {
  std::uint64_t write_sequence = 0;
  std::uint32_t pid = 0;
  std::uint64_t process_token = 0;
  std::uint64_t process_sequence = 0;
  std::uint64_t process_started_mach_time = 0;
  std::uint64_t tunnel_session_token = 0;
  std::uint64_t tunnel_started_mach_time = 0;
  std::uint32_t provider_stop_reason = 0;
  std::uint16_t local_stop_initiator = 0;
  std::uint16_t native_disconnect_code = 0;
  std::uint16_t native_stop_origin = 0;
  std::uint64_t snapshot_mach_continuous_time = 0;
  std::uint64_t snapshot_wall_time_ns = 0;
  std::uint32_t flags = 0;
  std::uint32_t lifecycle_state = 0;
  std::uint32_t websocket_generation = 0;
  std::uint32_t reconnect_attempt = 0;
  std::uint64_t physical_footprint_bytes = 0;
  std::uint64_t physical_footprint_peak_bytes = 0;
  std::uint64_t resident_bytes = 0;
  std::uint32_t active_bridges = 0;
  std::uint32_t active_native_clients = 0;
  std::uint32_t native_active_operations = 0;
  std::uint32_t active_reader_coroutines = 0;
  std::uint32_t active_sender_coroutines = 0;
  std::uint32_t active_read_loops = 0;
  std::uint64_t outbound_queued_bytes = 0;
  std::uint64_t outbound_queued_bytes_peak = 0;
  std::uint64_t latest_event_sequence = 0;
  // Schema v2: exact session traffic totals (provider-computed, see
  // PacketTunnelProvider's generation-finalization accounting), sampled
  // peak bandwidth, and tunnel-health counters not previously persisted.
  std::uint64_t session_accepted_upload_bytes = 0;
  std::uint64_t session_accepted_download_bytes = 0;
  std::uint64_t peak_upload_bytes_per_second = 0;
  std::uint64_t peak_download_bytes_per_second = 0;
  std::uint64_t queue_full_count = 0;
  std::uint64_t live_packet_leases = 0;
  std::uint64_t peak_packet_leases = 0;
  std::uint32_t peak_bandwidth_nominal_window_seconds = 0;
};

// PR3: disk format constants.
inline constexpr std::uint32_t kFlightRingMagic = 0x46505452;  // "FPTR"
inline constexpr std::uint32_t kSnapshotMagic = 0x4650544E;    // "FPTN"
// Schema v2: added session traffic totals/peaks and queue/lease health
// counters (see Snapshot fields above). No dual-decode path — a v1 record
// left over from before this change simply fails DecodeSnapshot's version
// check and is treated the same as "no snapshot yet."
inline constexpr std::uint16_t kSchemaVersion = 2;
inline constexpr std::size_t kFlightRecordSize = 72;
inline constexpr std::size_t kFlightRingHeaderSize = 64;
inline constexpr std::size_t kFlightRingCapacity = 120;
inline constexpr std::size_t kSnapshotMaxSize = 512;
inline constexpr std::size_t kSnapshotSlotCount = 2;

// PR3: CRC32 (bitwise, no lookup table — records are tiny).
std::uint32_t Crc32(const std::byte* data, std::size_t length) noexcept;

// PR3: explicit little-endian encode/decode. Never dump structs.
using RecordBytes = std::array<std::byte, kFlightRecordSize>;

RecordBytes EncodeEvent(const Event& event) noexcept;
bool DecodeEvent(std::span<const std::byte, kFlightRecordSize> bytes,
                 Event& output) noexcept;

using SnapshotBytes = std::array<std::byte, kSnapshotMaxSize>;

SnapshotBytes EncodeSnapshot(const Snapshot& snap) noexcept;
bool DecodeSnapshot(std::span<const std::byte> bytes, std::size_t length,
                    Snapshot& output) noexcept;

}  // namespace fptn::diag

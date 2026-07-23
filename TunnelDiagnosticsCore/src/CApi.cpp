#include "../include/FptnTunnelDiagnostics.h"

#include <new>

#include "DiagnosticsReader.hpp"
#include "DiskFormat.hpp"
#include "FlightRecorder.hpp"
#include "LifecycleStore.hpp"

// ── Schema constants ─────────────────────────────────────────────────

extern "C" uint16_t fptn_diagnostics_schema_version(void) {
    return fptn::diag::kSchemaVersion;
}

extern "C" size_t fptn_flight_recorder_capacity(void) {
    return fptn::diag::kFlightRingCapacity;
}

extern "C" size_t fptn_flight_recorder_record_size(void) {
    return fptn::diag::kFlightRecordSize;
}

extern "C" size_t fptn_flight_ring_file_size(void) {
    return fptn::diag::kFlightRingHeaderSize +
           fptn::diag::kFlightRingCapacity * fptn::diag::kFlightRecordSize;
}

// ── Flight Recorder ──────────────────────────────────────────────────

struct FptnFlightRecorderHandle {
  explicit FptnFlightRecorderHandle(fptn::diag::FlightRecorder* r)
      : recorder(r) {}
  ~FptnFlightRecorderHandle() { delete recorder; }

  fptn::diag::FlightRecorder* recorder;
};

extern "C" void*
fptn_flight_recorder_create(const char* path) {
  auto* recorder = fptn::diag::FlightRecorder::Open(path);
  if (!recorder) return nullptr;
  auto* handle = new (std::nothrow) FptnFlightRecorderHandle(recorder);
  return static_cast<void*>(handle);
}

extern "C" void
fptn_flight_recorder_destroy(void* handle) {
  delete static_cast<FptnFlightRecorderHandle*>(handle);
}

extern "C" uint64_t
fptn_flight_recorder_record(
    void* handle,
    uint16_t event_code,
    uint16_t flags,
    uint32_t generation,
    uint64_t process_token,
    uint64_t session_token,
    uint64_t mach_continuous_time,
    uint64_t value_0,
    uint64_t value_1,
    uint64_t value_2,
    int synchronize) {
  auto* rec = static_cast<FptnFlightRecorderHandle*>(handle); if (!rec || !rec->recorder) return 0;

  fptn::diag::Event event;
  event.event_code = event_code;
  event.flags = flags;
  event.websocket_generation = generation;
  event.process_token = process_token;
  event.tunnel_session_token = session_token;
  event.mach_continuous_time = mach_continuous_time;
  event.value_0 = value_0;
  event.value_1 = value_1;
  event.value_2 = value_2;

  return rec->recorder->Record(event, synchronize);
}

extern "C" int
fptn_flight_recorder_flush(void* handle) {
  auto* rec = static_cast<FptnFlightRecorderHandle*>(handle); if (!rec || !rec->recorder) return false;
  return rec->recorder->Flush() ? 1 : 0;
}

extern "C" FptnReadStatus
fptn_flight_recorder_read_valid(
    const char* path,
    FptnDecodedFlightEvent* output,
    size_t output_capacity,
    size_t* output_count) {
  if (!output_count) return FPTN_READ_IO_ERROR;
  *output_count = 0;
  if (!path || !output || output_capacity == 0) return FPTN_READ_IO_ERROR;

  static constexpr size_t kMaxStackEvents = 256;
  fptn::diag::Event events[kMaxStackEvents];
  const size_t cap =
      output_capacity < kMaxStackEvents ? output_capacity : kMaxStackEvents;

  size_t count = 0;
  const auto status = fptn::diag::ReadValidEvents(path, events, cap, &count);

  for (size_t i = 0; i < count; ++i) {
    output[i].sequence = events[i].sequence;
    output[i].mach_continuous_time = events[i].mach_continuous_time;
    output[i].process_token = events[i].process_token;
    output[i].tunnel_session_token = events[i].tunnel_session_token;
    output[i].event_code = events[i].event_code;
    output[i].flags = events[i].flags;
    output[i].websocket_generation = events[i].websocket_generation;
    output[i].value_0 = events[i].value_0;
    output[i].value_1 = events[i].value_1;
    output[i].value_2 = events[i].value_2;
  }

  *output_count = count;
  return static_cast<FptnReadStatus>(status);
}

// ── Lifecycle Snapshot Store ─────────────────────────────────────────

struct FptnLifecycleStoreHandle {
  explicit FptnLifecycleStoreHandle(fptn::diag::LifecycleStore* s)
      : store(s) {}
  ~FptnLifecycleStoreHandle() { delete store; }

  fptn::diag::LifecycleStore* store;
};

extern "C" void*
fptn_lifecycle_store_create(const char* path) {
  auto* store = fptn::diag::LifecycleStore::Open(path);
  if (!store) return nullptr;
  auto* handle = new (std::nothrow) FptnLifecycleStoreHandle(store);
  return static_cast<void*>(handle);
}

extern "C" void
fptn_lifecycle_store_destroy(void* handle) {
  delete static_cast<FptnLifecycleStoreHandle*>(handle);
}

extern "C" int
fptn_lifecycle_store_write(
    void* handle,
    uint32_t pid,
    uint64_t process_token,
    uint64_t process_sequence,
    uint64_t process_started_mach_time,
    uint64_t tunnel_session_token,
    uint64_t tunnel_started_mach_time,
    uint32_t provider_stop_reason,
    uint16_t local_stop_initiator,
    uint16_t native_disconnect_code,
    uint16_t native_stop_origin,
    uint64_t snapshot_mach_continuous_time,
    uint64_t snapshot_wall_time_ns,
    uint32_t flags,
    uint32_t lifecycle_state,
    uint32_t websocket_generation,
    uint32_t reconnect_attempt,
    uint64_t physical_footprint_bytes,
    uint64_t physical_footprint_peak_bytes,
    uint64_t resident_bytes,
    uint32_t active_bridges,
    uint32_t active_native_clients,
    uint32_t native_active_operations,
    uint32_t active_reader_coroutines,
    uint32_t active_sender_coroutines,
    uint32_t active_read_loops,
    uint64_t outbound_queued_bytes,
    uint64_t outbound_queued_bytes_peak,
    uint64_t latest_event_sequence,
    int synchronize) {
  auto* st = static_cast<FptnLifecycleStoreHandle*>(handle); if (!st || !st->store) return false;

  fptn::diag::Snapshot snap;
  snap.pid = pid;
  snap.process_token = process_token;
  snap.process_sequence = process_sequence;
  snap.process_started_mach_time = process_started_mach_time;
  snap.tunnel_session_token = tunnel_session_token;
  snap.tunnel_started_mach_time = tunnel_started_mach_time;
  snap.provider_stop_reason = provider_stop_reason;
  snap.local_stop_initiator = local_stop_initiator;
  snap.native_disconnect_code = native_disconnect_code;
  snap.native_stop_origin = native_stop_origin;
  snap.snapshot_mach_continuous_time = snapshot_mach_continuous_time;
  snap.snapshot_wall_time_ns = snapshot_wall_time_ns;
  snap.flags = flags;
  snap.lifecycle_state = lifecycle_state;
  snap.websocket_generation = websocket_generation;
  snap.reconnect_attempt = reconnect_attempt;
  snap.physical_footprint_bytes = physical_footprint_bytes;
  snap.physical_footprint_peak_bytes = physical_footprint_peak_bytes;
  snap.resident_bytes = resident_bytes;
  snap.active_bridges = active_bridges;
  snap.active_native_clients = active_native_clients;
  snap.native_active_operations = native_active_operations;
  snap.active_reader_coroutines = active_reader_coroutines;
  snap.active_sender_coroutines = active_sender_coroutines;
  snap.active_read_loops = active_read_loops;
  snap.outbound_queued_bytes = outbound_queued_bytes;
  snap.outbound_queued_bytes_peak = outbound_queued_bytes_peak;
  snap.latest_event_sequence = latest_event_sequence;

  return st->store->Write(snap, synchronize != 0) ? 1 : 0;
}

extern "C" FptnReadStatus
fptn_lifecycle_store_read_latest(
    const char* path,
    FptnDecodedLifecycleSnapshot* output) {
  if (!path || !output) return FPTN_READ_IO_ERROR;

  fptn::diag::Snapshot snap;
  const auto status = fptn::diag::ReadLatestSnapshot(path, snap);
  if (status != fptn::diag::ReadStatus::kOk) {
    return static_cast<FptnReadStatus>(status);
  }

  output->write_sequence = snap.write_sequence;
  output->pid = snap.pid;
  output->process_token = snap.process_token;
  output->process_sequence = snap.process_sequence;
  output->process_started_mach_time = snap.process_started_mach_time;
  output->tunnel_session_token = snap.tunnel_session_token;
  output->tunnel_started_mach_time = snap.tunnel_started_mach_time;
  output->provider_stop_reason = snap.provider_stop_reason;
  output->local_stop_initiator = snap.local_stop_initiator;
  output->native_disconnect_code = snap.native_disconnect_code;
  output->native_stop_origin = snap.native_stop_origin;
  output->snapshot_mach_continuous_time = snap.snapshot_mach_continuous_time;
  output->snapshot_wall_time_ns = snap.snapshot_wall_time_ns;
  output->flags = snap.flags;
  output->lifecycle_state = snap.lifecycle_state;
  output->websocket_generation = snap.websocket_generation;
  output->reconnect_attempt = snap.reconnect_attempt;
  output->physical_footprint_bytes = snap.physical_footprint_bytes;
  output->physical_footprint_peak_bytes = snap.physical_footprint_peak_bytes;
  output->resident_bytes = snap.resident_bytes;
  output->active_bridges = snap.active_bridges;
  output->active_native_clients = snap.active_native_clients;
  output->native_active_operations = snap.native_active_operations;
  output->active_reader_coroutines = snap.active_reader_coroutines;
  output->active_sender_coroutines = snap.active_sender_coroutines;
  output->active_read_loops = snap.active_read_loops;
  output->outbound_queued_bytes = snap.outbound_queued_bytes;
  output->outbound_queued_bytes_peak = snap.outbound_queued_bytes_peak;
  output->latest_event_sequence = snap.latest_event_sequence;

  return FPTN_READ_OK;
}

// FptnTunnelDiagnostics.h — C-compatible public ABI.
// This is the ONLY header visible to Swift.
// Implementation is C++23 with RAII; Swift sees opaque handles.

#ifndef FPTN_TUNNEL_DIAGNOSTICS_H
#define FPTN_TUNNEL_DIAGNOSTICS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ── Flight Recorder ──────────────────────────────────────────────────



// Opens or creates a flight recorder ring file.
// Returns NULL on failure.
void *
fptn_flight_recorder_create(const char *path);

// Destroys the recorder and closes the file.
void
fptn_flight_recorder_destroy(void *handle);

// Flushes the ring file to disk.
int
fptn_flight_recorder_flush(void *handle);

// Records an event. Returns the assigned sequence (0 on failure).
uint64_t
fptn_flight_recorder_record(
    void *handle,
    uint16_t event_code,
    uint16_t flags,
    uint32_t generation,
    uint64_t process_token,
    uint64_t session_token,
    uint64_t mach_continuous_time,
    uint64_t value_0,
    uint64_t value_1,
    uint64_t value_2,
    int synchronize);

// ── Lifecycle Snapshot Store ─────────────────────────────────────────



// Opens or creates a double-buffered snapshot file.
void *
fptn_lifecycle_store_create(const char *path);

void
fptn_lifecycle_store_destroy(void *handle);

// Writes a snapshot. If synchronize is true, fsyncs after the write.
int
fptn_lifecycle_store_write(
    void *handle,
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
    int synchronize);

// ── Decoded snapshot (returned by reader) ────────────────────────────

typedef struct {
    uint64_t write_sequence;
    uint32_t pid;
    uint64_t process_token;
    uint64_t process_sequence;
    uint64_t process_started_mach_time;
    uint64_t tunnel_session_token;
    uint64_t tunnel_started_mach_time;
    uint32_t provider_stop_reason;
    uint16_t local_stop_initiator;
    uint16_t native_disconnect_code;
    uint16_t native_stop_origin;
    uint64_t snapshot_mach_continuous_time;
    uint64_t snapshot_wall_time_ns;
    uint32_t flags;
    uint32_t lifecycle_state;
    uint32_t websocket_generation;
    uint32_t reconnect_attempt;
    uint64_t physical_footprint_bytes;
    uint64_t physical_footprint_peak_bytes;
    uint64_t resident_bytes;
    uint32_t active_bridges;
    uint32_t active_native_clients;
    uint32_t native_active_operations;
    uint32_t active_reader_coroutines;
    uint32_t active_sender_coroutines;
    uint32_t active_read_loops;
    uint64_t outbound_queued_bytes;
    uint64_t outbound_queued_bytes_peak;
    uint64_t latest_event_sequence;
} FptnDecodedLifecycleSnapshot;

// Reads the latest valid snapshot from a double-buffered file.
int
fptn_lifecycle_store_read_latest(
    const char *path,
    FptnDecodedLifecycleSnapshot *output);

// ── Decoded types and reader functions ───────────────────────────────

typedef struct {
    uint64_t sequence;
    uint64_t mach_continuous_time;
    uint64_t process_token;
    uint64_t tunnel_session_token;
    uint16_t event_code;
    uint16_t flags;
    uint32_t websocket_generation;
    uint64_t value_0;
    uint64_t value_1;
    uint64_t value_2;
} FptnDecodedFlightEvent;

size_t
fptn_flight_recorder_read_valid(
    const char *path,
    FptnDecodedFlightEvent *output,
    size_t output_capacity);

#ifdef __cplusplus
}
#endif

#endif  // FPTN_TUNNEL_DIAGNOSTICS_H

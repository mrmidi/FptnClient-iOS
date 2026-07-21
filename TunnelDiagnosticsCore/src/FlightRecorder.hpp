#pragma once

#include <mutex>
#include <string_view>

#include "DiskFormat.hpp"
#include "PosixFile.hpp"

namespace fptn::diag {

// PR3: bounded flight recorder. Fixed 8,704-byte ring file.
// Allocation-free on the Record() path. Thread-safe via internal mutex.
class FlightRecorder final {
 public:
  // Opens or creates the ring file. Scans existing records to resume
  // from the highest valid sequence (no truncation of old evidence).
  static FlightRecorder* Open(const char* path) noexcept;

  ~FlightRecorder() noexcept = default;

  FlightRecorder(FlightRecorder&&) noexcept = default;
  FlightRecorder& operator=(FlightRecorder&&) noexcept = default;
  FlightRecorder(const FlightRecorder&) = delete;
  FlightRecorder& operator=(const FlightRecorder&) = delete;

  // Records an event. Returns the assigned sequence (0 on failure).
  // If synchronize is true, calls fsync after the write.
  std::uint64_t Record(const Event& event, bool synchronize) noexcept;

  // Flushes the ring file to disk.
  bool Flush() noexcept;

 private:
  FlightRecorder() noexcept = default;

  bool InitFromExisting() noexcept;
  bool WriteHeader() noexcept;

  PosixFile file_;
  std::mutex mutex_;
  std::uint64_t next_sequence_ = 1;
};

}  // namespace fptn::diag

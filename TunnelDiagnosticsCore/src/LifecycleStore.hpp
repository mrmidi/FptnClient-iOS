#pragma once

#include <mutex>

#include "DiskFormat.hpp"
#include "PosixFile.hpp"

namespace fptn::diag {

// PR3: double-buffered lifecycle snapshot store.
// Two 512-byte slots (A and B). Writes alternate; a torn write
// cannot destroy both copies. Reader picks the valid slot with
// the highest write_sequence.
class LifecycleStore final {
 public:
  static LifecycleStore* Open(const char* path) noexcept;

  ~LifecycleStore() noexcept = default;

  LifecycleStore(LifecycleStore&&) noexcept = default;
  LifecycleStore& operator=(LifecycleStore&&) noexcept = default;
  LifecycleStore(const LifecycleStore&) = delete;
  LifecycleStore& operator=(const LifecycleStore&) = delete;

  // Writes a snapshot to the older slot. If synchronize is true,
  // calls fsync after the write.
  bool Write(const Snapshot& snap, bool synchronize) noexcept;

 private:
  LifecycleStore() noexcept = default;

  PosixFile file_;
  std::mutex mutex_;
  std::uint64_t next_sequence_ = 1;
  int next_slot_ = 0;  // alternates 0/1
};

}  // namespace fptn::diag

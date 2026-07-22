#include "LifecycleStore.hpp"

#include <new>

namespace fptn::diag {

namespace {

inline constexpr std::size_t kSnapshotFileSize =
    kSnapshotMaxSize * kSnapshotSlotCount;

std::size_t SlotOffset(int slot) noexcept {
  return static_cast<std::size_t>(slot) * kSnapshotMaxSize;
}

}  // namespace

LifecycleStore* LifecycleStore::Open(const char* path) noexcept {
  auto* store = new (std::nothrow) LifecycleStore();
  if (!store) return nullptr;

  const int fd = ::open(path, O_RDWR | O_CREAT, 0644);
  if (fd < 0) {
    delete store;
    return nullptr;
  }
  store->file_.Reset(fd);

  // Extend to full size.
  if (::ftruncate(fd, static_cast<off_t>(kSnapshotFileSize)) != 0) {
    delete store;
    return nullptr;
  }

  // Scan both slots for the highest valid sequence.
  std::uint64_t max_seq = 0;
  int max_slot = 0;
  for (int slot = 0; slot < static_cast<int>(kSnapshotSlotCount); ++slot) {
    std::array<std::byte, kSnapshotMaxSize> bytes{};
    if (!PreadAll(fd, bytes.data(), bytes.size(),
                  static_cast<off_t>(SlotOffset(slot)))) {
      continue;
    }
    Snapshot snap;
    if (DecodeSnapshot(bytes, kSnapshotMaxSize, snap)) {
      if (snap.write_sequence > max_seq) {
        max_seq = snap.write_sequence;
        max_slot = slot;
      }
    }
  }

  store->next_sequence_ = max_seq + 1;
  store->next_slot_ = (max_slot + 1) % static_cast<int>(kSnapshotSlotCount);

  return store;
}

bool LifecycleStore::Write(const Snapshot& snap, bool synchronize) noexcept {
  std::lock_guard<std::mutex> lock(mutex_);

  Snapshot committed = snap;
  committed.write_sequence = next_sequence_;

  const SnapshotBytes bytes = EncodeSnapshot(committed);
  const std::size_t offset = SlotOffset(next_slot_);

  if (!PwriteAll(file_.Get(), bytes.data(), kSnapshotMaxSize,
                 static_cast<off_t>(offset))) {
    return false;
  }

  if (synchronize) {
    ::fsync(file_.Get());
  }

  next_sequence_ += 1;
  next_slot_ = (next_slot_ + 1) % static_cast<int>(kSnapshotSlotCount);
  return true;
}

}  // namespace fptn::diag

#pragma once

#include <cerrno>
#include <fcntl.h>
#include <unistd.h>

#include <utility>

namespace fptn::diag {

// PR3: move-only RAII file descriptor. Closes automatically.
// No exceptions, no allocation.
class PosixFile final {
 public:
  PosixFile() noexcept = default;

  explicit PosixFile(int fd) noexcept : fd_(fd) {}

  ~PosixFile() noexcept {
    if (fd_ >= 0) {
      ::close(fd_);
    }
  }

  PosixFile(PosixFile&& other) noexcept
      : fd_(std::exchange(other.fd_, -1)) {}

  PosixFile& operator=(PosixFile&& other) noexcept {
    if (this != &other) {
      Reset(std::exchange(other.fd_, -1));
    }
    return *this;
  }

  PosixFile(const PosixFile&) = delete;
  PosixFile& operator=(const PosixFile&) = delete;

  int Get() const noexcept { return fd_; }
  bool IsValid() const noexcept { return fd_ >= 0; }

  void Reset(int newFd = -1) noexcept {
    if (fd_ >= 0) {
      ::close(fd_);
    }
    fd_ = newFd;
  }

  int Release() noexcept { return std::exchange(fd_, -1); }

 private:
  int fd_ = -1;
};

// PR3: pwrite with EINTR retry and partial-write handling.
inline bool PwriteAll(int fd, const void* buf, std::size_t count,
                      off_t offset) noexcept {
  const auto* ptr = static_cast<const char*>(buf);
  std::size_t written = 0;
  while (written < count) {
    const ssize_t n = ::pwrite(fd, ptr + written, count - written,
                               offset + static_cast<off_t>(written));
    if (n < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    written += static_cast<std::size_t>(n);
  }
  return true;
}

// PR3: pread with EINTR retry and partial-read handling.
inline bool PreadAll(int fd, void* buf, std::size_t count,
                     off_t offset) noexcept {
  auto* ptr = static_cast<char*>(buf);
  std::size_t total = 0;
  while (total < count) {
    const ssize_t n = ::pread(fd, ptr + total, count - total,
                              offset + static_cast<off_t>(total));
    if (n < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    if (n == 0) break;  // EOF
    total += static_cast<std::size_t>(n);
  }
  return total == count;
}

}  // namespace fptn::diag

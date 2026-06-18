// SPDX-License-Identifier: Apache-2.0
// Minimal host-side Android FEC encoder for avbtool add_hashtree_footer.

#include <fcntl.h>
#include <getopt.h>
#include <openssl/sha.h>
#include <sys/stat.h>
#include <unistd.h>

#include <array>
#include <cerrno>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

extern "C" {
void *init_rs_char(int symsize, int gfpoly, int fcr, int prim, int nroots,
                   int pad);
void encode_rs_char(void *p, unsigned char *data, unsigned char *parity);
void free_rs_char(void *p);
}

namespace {

constexpr uint32_t kBlockSize = 4096;
constexpr int kRsSymbols = 255;
constexpr uint32_t kFecMagic = 0xfecfecfe;
constexpr uint32_t kFecVersion = 0;

struct __attribute__((packed)) FecHeader {
  uint32_t magic;
  uint32_t version;
  uint32_t size;
  uint32_t roots;
  uint32_t fec_size;
  uint64_t input_size;
  uint8_t hash[SHA256_DIGEST_LENGTH];
};

uint64_t DivRoundUp(uint64_t value, uint64_t divisor) {
  return value / divisor + (value % divisor != 0);
}

uint64_t FecOutputSize(uint64_t input_size, int roots) {
  return DivRoundUp(DivRoundUp(input_size, kBlockSize), kRsSymbols - roots) *
             roots * kBlockSize +
         kBlockSize;
}

uint64_t InterleavedOffset(uint64_t offset, int rs_n, uint64_t rounds) {
  return offset / rs_n + (offset % rs_n) * rounds * kBlockSize;
}

[[noreturn]] void Fail(const char *message) {
  std::fprintf(stderr, "fec: %s: %s\n", message, std::strerror(errno));
  std::exit(1);
}

void WriteFully(int fd, const void *buffer, size_t size) {
  const auto *cursor = static_cast<const uint8_t *>(buffer);
  while (size > 0) {
    ssize_t written = write(fd, cursor, size);
    if (written < 0) {
      if (errno == EINTR) continue;
      Fail("write failed");
    }
    cursor += written;
    size -= static_cast<size_t>(written);
  }
}

std::vector<uint8_t> ReadImage(const std::string &path) {
  int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
  if (fd < 0) Fail("open input failed");

  struct stat st {};
  if (fstat(fd, &st) != 0) Fail("stat input failed");
  if (st.st_size <= 0 || st.st_size % kBlockSize != 0) {
    std::fprintf(stderr,
                 "fec: input size must be a positive multiple of %u bytes\n",
                 kBlockSize);
    std::exit(1);
  }

  std::vector<uint8_t> image(static_cast<size_t>(st.st_size));
  size_t offset = 0;
  while (offset < image.size()) {
    ssize_t count = read(fd, image.data() + offset, image.size() - offset);
    if (count < 0) {
      if (errno == EINTR) continue;
      Fail("read input failed");
    }
    if (count == 0) {
      std::fprintf(stderr, "fec: unexpected end of input\n");
      std::exit(1);
    }
    offset += static_cast<size_t>(count);
  }
  close(fd);
  return image;
}

void Encode(const std::string &input_path, const std::string &output_path,
            int roots) {
  std::vector<uint8_t> image = ReadImage(input_path);
  const int rs_n = kRsSymbols - roots;
  const uint64_t blocks = DivRoundUp(image.size(), kBlockSize);
  const uint64_t rounds = DivRoundUp(blocks, rs_n);
  const uint64_t fec_size64 = rounds * roots * kBlockSize;
  if (fec_size64 > UINT32_MAX) {
    std::fprintf(stderr, "fec: output exceeds Android FEC header limit\n");
    std::exit(1);
  }

  std::vector<uint8_t> fec(static_cast<size_t>(fec_size64));
  std::vector<uint8_t> data(static_cast<size_t>(rs_n));
  void *rs = init_rs_char(8, 0x11d, 0, 1, roots, 0);
  if (rs == nullptr) {
    std::fprintf(stderr, "fec: failed to initialize Reed-Solomon encoder\n");
    std::exit(1);
  }

  uint64_t fec_pos = 0;
  const uint64_t end = rounds * rs_n * kBlockSize;
  for (uint64_t i = 0; i < end; i += rs_n) {
    for (int j = 0; j < rs_n; ++j) {
      const uint64_t source = InterleavedOffset(i + j, rs_n, rounds);
      data[static_cast<size_t>(j)] =
          source < image.size() ? image[static_cast<size_t>(source)] : 0;
    }
    encode_rs_char(rs, data.data(), fec.data() + fec_pos);
    fec_pos += static_cast<uint64_t>(roots);
  }
  free_rs_char(rs);

  std::array<uint8_t, kBlockSize> header_block {};
  FecHeader header {};
  header.magic = kFecMagic;
  header.version = kFecVersion;
  header.size = sizeof(header);
  header.roots = static_cast<uint32_t>(roots);
  header.fec_size = static_cast<uint32_t>(fec.size());
  header.input_size = image.size();
  SHA256(fec.data(), fec.size(), header.hash);
  std::memcpy(header_block.data(), &header, sizeof(header));
  std::memcpy(header_block.data() + header_block.size() - sizeof(header),
              &header, sizeof(header));

  int fd = open(output_path.c_str(),
                O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
  if (fd < 0) Fail("open output failed");
  WriteFully(fd, fec.data(), fec.size());
  WriteFully(fd, header_block.data(), header_block.size());
  if (close(fd) != 0) Fail("close output failed");
}

uint64_t ParseSize(const char *value, const char *name) {
  char *end = nullptr;
  errno = 0;
  unsigned long long parsed = std::strtoull(value, &end, 0);
  if (errno != 0 || end == value || *end != '\0') {
    std::fprintf(stderr, "fec: invalid %s: %s\n", name, value);
    std::exit(1);
  }
  return static_cast<uint64_t>(parsed);
}

}  // namespace

int main(int argc, char **argv) {
  bool encode = false;
  bool print_size = false;
  uint64_t input_size = 0;
  int roots = 2;

  const option options[] = {
      {"encode", no_argument, nullptr, 'e'},
      {"print-fec-size", required_argument, nullptr, 's'},
      {"roots", required_argument, nullptr, 'r'},
      {nullptr, 0, nullptr, 0},
  };

  int option = 0;
  while ((option = getopt_long(argc, argv, "es:r:", options, nullptr)) != -1) {
    switch (option) {
      case 'e':
        encode = true;
        break;
      case 's':
        print_size = true;
        input_size = ParseSize(optarg, "input size");
        break;
      case 'r':
        roots = static_cast<int>(ParseSize(optarg, "roots"));
        break;
      default:
        return 1;
    }
  }

  if (roots <= 0 || roots >= kRsSymbols) {
    std::fprintf(stderr, "fec: roots must be between 1 and 254\n");
    return 1;
  }
  if (print_size && !encode) {
    std::printf("%" PRIu64 "\n", FecOutputSize(input_size, roots));
    return 0;
  }
  if (encode && !print_size && argc - optind == 2) {
    Encode(argv[optind], argv[optind + 1], roots);
    return 0;
  }

  std::fprintf(stderr,
               "usage: fec --print-fec-size SIZE --roots N\n"
               "       fec --encode --roots N INPUT OUTPUT\n");
  return 1;
}

// Clean C++ through libc++ (containers, strings, a thrown and caught exception). Must run
// without any sanitizer report.
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>

int main() {
  std::vector<std::string> xs;
  for (int i = 0; i < 100; i++) xs.push_back(std::string(40, char('0' + i % 10)));
  std::string s;
  for (const auto &x : xs) s += x;
  std::size_t caught = 0;
  try {
    throw std::runtime_error(std::string(64, 'x'));
  } catch (const std::exception &e) {
    caught = std::string(e.what()).size();
  }
  std::printf("%zu %zu\n", s.size(), caught);
  return s.size() == 4000 && caught == 64 ? 0 : 1;
}

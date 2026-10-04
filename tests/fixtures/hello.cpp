#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>

int main() {
  std::string msg;
  std::thread worker([&] {
    try {
      throw std::runtime_error("hello from elide-toolchain");
    } catch (const std::exception& e) {
      msg = e.what();
    }
  });
  worker.join();
  std::cout << msg << std::endl;
  return msg.empty() ? 1 : 0;
}

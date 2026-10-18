#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>

// A thread_local with a destructor needs __cxa_thread_atexit (libc's _impl, or libc++abi's own).
thread_local std::string tls;

int main() {
  std::string msg;
  std::thread worker([&] {
    try {
      throw std::runtime_error("hello from elide-toolchain");
    } catch (const std::exception& e) {
      tls = e.what();
      msg = tls;
    }
  });
  worker.join();
  std::cout << msg << std::endl;
  return msg.empty() ? 1 : 0;
}

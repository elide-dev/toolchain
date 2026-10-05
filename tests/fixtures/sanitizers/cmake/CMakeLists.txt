# Sanitizer add-on CMake consumer: under share/elide-toolchain/cmake/<triple>-<san>.cmake,
# find_package/find_library must resolve the add-on's instrumented archives (sysroot/<triple>+<san>).
cmake_minimum_required(VERSION 3.20)
project(sanitizer_cmake_consumer C CXX)
find_package(ZLIB REQUIRED)
find_library(ZSTD_LIB zstd REQUIRED)
message(STATUS "ELIDE_ZLIB=${ZLIB_LIBRARIES}")
message(STATUS "ELIDE_ZSTD=${ZSTD_LIB}")
add_executable(consumer ../workload.c)
target_compile_definitions(consumer PRIVATE HAVE_ZLIB HAVE_ZSTD)
target_link_libraries(consumer PRIVATE ZLIB::ZLIB ${ZSTD_LIB})
set_target_properties(consumer PROPERTIES LINKER_LANGUAGE CXX)

# shellcheck shell=bash
# Cap'n Proto v1 (static).
build_capnp() {
  local t="$1" prefix="$2" src
  require_cmd autoreconf libtoolize
  src="$(stage_source capnp "$t")"
  (
    cd "$src/c++" || exit 1
    target_env "$t" "$prefix"
    # dynamic.h uses std::nullptr_t without <cstddef>; libc++ does not provide it transitively.
    CXXFLAGS="$CXXFLAGS -include cstddef"
    export CXXFLAGS
    autoreconf -i
    ./configure --prefix="$prefix" --disable-shared --with-zlib --with-openssl
    make -j"$JOBS"
    make install
  )
}

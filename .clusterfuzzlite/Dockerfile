FROM gcr.io/oss-fuzz-base/base-builder:v1@sha256:1f9cf74bc3d7029b528494542f9d9851b256dceed38d3f420989434dc5ae0760
COPY src/elidealloc-shim $SRC/toolchain/src/elidealloc-shim
COPY .clusterfuzzlite $SRC/toolchain/.clusterfuzzlite
WORKDIR $SRC/toolchain
COPY .clusterfuzzlite/build.sh $SRC/build.sh

# shellcheck shell=bash
# Stage 50: build every enabled component for each target into its sysroot (Linux) or
# overlay sysroot (macOS), using the bundle's own <triple>-clang.

stage_main() {
  local t c
  check_component_conflicts
  for t in $TARGETS; do
    mkdir -p "$(target_prefix "$t")"
    for c in "${COMPONENTS[@]}"; do
      component_enabled "$c" || continue
      log "component $c -> $t"
      "$(component_fn "$c")" "$t" "$(target_prefix "$t")"
    done
  done
}

#!/usr/bin/env bash
# Test-only PipeWire graph: one virtual sink, no hardware or session manager.
section "private audio graph for bar hover checks"
if ! command -v pipewire >/dev/null || ! command -v wpctl >/dev/null || ! command -v pw-metadata >/dev/null; then
  fail "pipewire, wpctl and pw-metadata are required for the audio widget check"
  exit 1
fi
export PIPEWIRE_RUNTIME_DIR="$runtime"
export PIPEWIRE_REMOTE=pipewire-0
cat >"$runtime/tooltip-pipewire.conf" <<'EOF'
context.properties = { core.daemon = true core.name = pipewire-0 }
context.spa-libs = {
  audio.convert.* = audioconvert/libspa-audioconvert
  support.* = support/libspa-support
}
context.modules = [
  { name = libpipewire-module-protocol-native }
  { name = libpipewire-module-metadata }
  { name = libpipewire-module-spa-node-factory }
  { name = libpipewire-module-client-node }
  { name = libpipewire-module-access }
  { name = libpipewire-module-adapter }
]
context.objects = [
  { factory = metadata args = {
    metadata.name = default
    metadata.values = [ { key = default.audio.sink value = { name = cornice-tooltip-output } } ]
  } }
  { factory = adapter args = {
    factory.name = support.null-audio-sink
    node.name = cornice-tooltip-output
    node.description = "Private tooltip test output"
    media.class = Audio/Sink
    audio.position = [ FL FR ]
    node.param.Props = { volume = 0.42 mute = false }
  } }
]
EOF
pipewire -c "$runtime/tooltip-pipewire.conf" >"$runtime/tooltip-pipewire.log" 2>&1 &
tooltip_audio_pid=$!
for _ in $(seq 1 40); do
  [[ -S "$runtime/pipewire-0" ]] && break
  sleep .1
done
if [[ -S "$runtime/pipewire-0" ]]; then
  pw-metadata -n default 0 default.audio.sink '{"name":"cornice-tooltip-output"}' Spa:String:JSON >"$runtime/tooltip-metadata.log" 2>&1
  pass "virtual sink listens only on the private runtime socket"
else
  fail "private PipeWire failed to start"
  cat "$runtime/tooltip-pipewire.log"
  exit 1
fi

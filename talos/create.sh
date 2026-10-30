#!/usr/bin/env bash
set -euo pipefail

directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
schematic_id=$(curl --fail --silent --show-error --request POST --data-binary "@${directory}/schematic.yaml" https://factory.talos.dev/schematics | jq --raw-output .id)

talosctl cluster create qemu \
  --name talos-hermes-isolation \
  --controlplanes 1 \
  --workers 0 \
  --cpus-controlplanes 8 \
  --memory-controlplanes 10GiB \
  --disks virtio:40GiB \
  --presets iso \
  --schematic-id "${schematic_id}" \
  --talos-version v1.14.5 \
  --kubernetes-version 1.37.2 \
  --config-patch-controlplanes "@${directory}/config-patch.yaml"

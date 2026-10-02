// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// ESP-IDF creates an INTERFACE component when no source files are registered.
// The Swift integration applies PRIVATE target options, so keep this concrete
// component target even though AxolotyZenohCore itself is pure Swift over the
// Core-owned facade ABI.
void axoloty_zenoh_core_component_anchor(void) {}

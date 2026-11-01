# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
#
# The zenoh-pico reassembly limit for a pair of composed carrier bounds.
#
# FRAG_MAX_SIZE is the largest message zenoh-pico reassembles from fragments
# (src/transport/unicast/rx.c drops anything longer, silently, and reserves this
# many bytes of heap while a fragmented message arrives). It must hold the
# largest legal frame: a payload and a key at the composed bounds, and message
# headers. The headers are a few tens of bytes; the allowance below is 1 KiB, and
# the sum is rounded up to a whole KiB. A 2,048-byte payload with a 256-byte key
# comes to 4,096, zenoh-pico's own default, and a 512-byte payload with a
# 128-byte key to 2,048. The 1024 starting point silently lost every frame
# above about 1 KB on hardware (carrier scenario step maximum_payload), so a
# value is never chosen below the sum.
#
# Kept in its own file so a host check can evaluate it: Tests/embedded/
# check-carrier-bounds.sh runs it under `cmake -P`.

set(AXOLOTY_FRAME_OVERHEAD_ALLOWANCE_BYTES 1024)

# Sets `out_variable` in the caller's scope.
function(axoloty_zenoh_pico_frag_max_size payload_bytes key_bytes out_variable)
    math(EXPR minimum "${payload_bytes} + ${key_bytes} + ${AXOLOTY_FRAME_OVERHEAD_ALLOWANCE_BYTES}")
    math(EXPR rounded "(${minimum} + 1023) / 1024 * 1024")
    math(EXPR largest_legal_frame "${payload_bytes} + ${key_bytes}")
    if(rounded LESS largest_legal_frame)
        message(FATAL_ERROR
            "FRAG_MAX_SIZE ${rounded} cannot hold the largest legal frame "
            "(${largest_legal_frame} bytes before headers)")
    endif()
    set(${out_variable} ${rounded} PARENT_SCOPE)
endfunction()

# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.triggers import ReadOnly, RisingEdge


MAX_WAIT_CYCLES = 120


def encode_feature(value):
    if value < -64 or value > 63:
        raise ValueError(f"Audio feature out of 7-bit signed range: {value}")
    return value & 0x7F


def pack_ui(audio_feature, data_valid):
    return ((data_valid & 0x1) << 7) | (encode_feature(audio_feature) & 0x7F)


def busy(dut):
    return (int(dut.uo_out.value) >> 7) & 0x1


def confidence(dut):
    return (int(dut.uo_out.value) >> 1) & 0x3F


def trigger(dut):
    return int(dut.uo_out.value) & 0x1


def busy_echo(dut):
    return (int(dut.uio_out.value) >> 7) & 0x1


async def wait_cycles(dut, count):
    for _ in range(count):
        await RisingEdge(dut.clk)


async def wait_for_busy_state(dut, expected_state, max_cycles=MAX_WAIT_CYCLES):
    for cycle in range(max_cycles):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if busy(dut) == expected_state:
            return cycle + 1
    assert False, f"Timed out waiting for busy={expected_state} after {max_cycles} cycles"


async def apply_resets(dut):
    # Use both global rst_n and local uio reset to guarantee deterministic startup.
    dut.ena.value = 0
    dut.ui_in.value = pack_ui(0, 0)
    dut.uio_in.value = 0x01  # local reset bit
    dut.rst_n.value = 0
    await wait_cycles(dut, 6)

    dut.rst_n.value = 1
    await wait_cycles(dut, 4)

    dut.uio_in.value = 0x00
    dut.ena.value = 1
    await wait_cycles(dut, 4)


async def send_feature_and_capture(dut, feature):
    # Ensure the pipeline is idle before starting a new sample.
    if busy(dut):
        await wait_for_busy_state(dut, 0)

    dut.ui_in.value = pack_ui(feature, 1)
    await RisingEdge(dut.clk)

    # Deassert data_valid after one cycle.
    dut.ui_in.value = pack_ui(feature, 0)

    # Wait for processing window using busy handshake.
    await wait_for_busy_state(dut, 1, max_cycles=20)
    await wait_for_busy_state(dut, 0, max_cycles=MAX_WAIT_CYCLES)
    await ReadOnly()

    return {
        "feature": feature,
        "confidence": confidence(dut),
        "trigger": trigger(dut),
        "busy": busy(dut),
        "busy_echo": busy_echo(dut),
    }


async def capture_samples(dut, feature_sequence, minimum=2):
    samples = []
    for feature in feature_sequence:
        samples.append(await send_feature_and_capture(dut, feature))
        if len(samples) >= minimum:
            break

    assert len(samples) >= minimum, (
        f"Did not capture enough NN output samples (got {len(samples)}, expected at least {minimum})"
    )
    return samples


@cocotb.test()
async def test_project(dut):
    dut._log.info("Start NN-LSTM wake-word behavior test")

    await apply_resets(dut)

    # Idle checks: no data_valid means no busy pulse.
    dut.ui_in.value = pack_ui(0, 0)
    for _ in range(12):
        await RisingEdge(dut.clk)
        await ReadOnly()
        assert busy(dut) == 0, "Busy asserted while data_valid is low"
        assert busy_echo(dut) == 0, "Busy echo asserted while data_valid is low"

    # Capture low-amplitude sequence.
    low_samples = await capture_samples(dut, [0, 1, -1, 2, -2], minimum=2)
    for sample in low_samples:
        assert 0 <= sample["confidence"] <= 63, "Confidence out of 6-bit range"
        assert sample["busy"] == sample["busy_echo"], "Busy echo mismatch"
        assert sample["trigger"] in (0, 1), "Trigger is not a single-bit value"

    # Capture higher-amplitude sequence and expect confidence to not regress.
    high_samples = await capture_samples(dut, [48, 56, 60, 63], minimum=2)
    low_peak = max(s["confidence"] for s in low_samples)
    high_peak = max(s["confidence"] for s in high_samples)
    assert high_peak >= low_peak, (
        f"High-amplitude confidence did not improve: low_peak={low_peak}, high_peak={high_peak}"
    )

    # Debug mode bypass: uo_out[6:0] mirrors ui_in[6:0], uo_out[7] forced low.
    debug_feature = 0x35
    dut.uio_in.value = 0x02  # debug_mode=1
    dut.ui_in.value = (1 << 7) | debug_feature
    await RisingEdge(dut.clk)
    await ReadOnly()
    debug_out = int(dut.uo_out.value)
    assert debug_out == debug_feature, (
        f"Debug bypass mismatch: expected 0x{debug_feature:02x}, got 0x{debug_out:02x}"
    )

    # Return to normal mode.
    dut.uio_in.value = 0x00
    dut.ui_in.value = pack_ui(0, 0)
    await wait_cycles(dut, 2)

    # Local reset should clear output state.
    dut.uio_in.value = 0x01
    await wait_cycles(dut, 3)
    await ReadOnly()
    assert int(dut.uo_out.value) == 0, "Output not cleared by local reset"
    assert int(dut.uio_out.value) == 0, "uio_out not cleared by local reset"

    dut.uio_in.value = 0x00
    await wait_cycles(dut, 2)

    dut._log.info("NN-LSTM cocotb checks passed")

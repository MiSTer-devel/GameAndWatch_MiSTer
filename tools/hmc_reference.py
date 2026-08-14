#!/usr/bin/env python3
"""Decode and validate the documented HA1152/HMC trace-level behavior.

This tool deliberately takes the 128-byte sound ROM and Saleae CSV capture as
caller-supplied inputs.  It contains neither device ROM contents nor captured
waveforms.  The validator measures behavior whose interpretation is fixed by
the public Star Fox captures: ROM pitch coding, three bonded start vectors,
command dwell, tone/noise mode, trigger arbitration, and oscillator-normalized
tone periods.  It exits nonzero when any checked invariant fails.

CSV channels are expected in Saleae's packed order: S2, S3, S4, OUT, with the
three trigger inputs active low.  Sample timestamps may be integer sample
indices (use --sample-rate) or seconds (the default).
"""

from __future__ import annotations

import argparse
import csv
import dataclasses
import math
from pathlib import Path
import statistics
import sys
from typing import Sequence


SAMPLE_RATE_DEFAULT = 100_000_000.0


@dataclasses.dataclass(frozen=True)
class Program:
    name: str
    input_bit: int
    start: int
    dwell_ticks: int


PROGRAMS = (
    Program("S2", 0, 0x00, 3840),
    Program("S3", 1, 0x3C, 2880),
    Program("S4", 2, 0x75, 480),
)

# If several lines fall on the same Saleae sample, the captured hardware picks
# S4, then S2, then S3.  A later falling edge preempts the current program.
PRIORITY = (2, 0, 1)


@dataclasses.dataclass(frozen=True)
class Transition:
    time_s: float
    value: int


@dataclasses.dataclass(frozen=True)
class InputEvent:
    time_s: float
    old: int
    new: int
    falling: int
    rising: int


@dataclasses.dataclass(frozen=True)
class Burst:
    first_s: float
    last_s: float
    edges: tuple[Transition, ...]

    @property
    def duration_s(self) -> float:
        return self.last_s - self.first_s


@dataclasses.dataclass(frozen=True)
class PlateauFit:
    name: str
    groups_compared: int
    intervals_compared: int
    structural_mismatches: int
    edge_mismatches: int
    worst_ticks: float
    mean_ticks: float
    tick_first_s: float
    tick_last_s: float
    observed_counts: tuple[int, ...]
    expected_counts: tuple[int, ...]


@dataclasses.dataclass(frozen=True)
class Signature:
    program: str
    early_median_s: float


def pitch_states() -> tuple[int, ...]:
    """Return the 127 nonzero states of x^7+x+1, seed 1."""
    result: list[int] = []
    state = 1
    for _ in range(127):
        if state in result:
            raise AssertionError("pitch LFSR repeated early")
        result.append(state)
        state = ((state << 1) & 0x7F) | (((state >> 6) ^ state) & 1)
    if state != 1:
        raise AssertionError("pitch LFSR is not maximal")
    return tuple(result)


PITCH_STATES = pitch_states()
PITCH_PHASE = {state: phase for phase, state in enumerate(PITCH_STATES)}


def decode_byte(value: int) -> tuple[str, int, int]:
    """Return (mode, raw oscillator period, logarithmic phase)."""
    code = value & 0x7F
    if code == 0:
        raise ValueError("zero is a terminator, not a command")
    try:
        phase = PITCH_PHASE[code]
    except KeyError as exc:  # unreachable for nonzero 7-bit values
        raise ValueError(f"invalid pitch code 0x{code:02x}") from exc
    return ("noise" if value & 0x80 else "tone", phase + 2, phase)


def decode_program(rom: bytes, program: Program) -> list[tuple[int, str, int, int]]:
    result: list[tuple[int, str, int, int]] = []
    for address in range(program.start, len(rom)):
        value = rom[address]
        if value == 0:
            return result
        mode, period, phase = decode_byte(value)
        result.append((address, mode, period, phase))
    raise ValueError(f"{program.name}: no zero terminator after 0x{program.start:02x}")


def read_saleae(path: Path, sample_rate: float | None) -> list[Transition]:
    transitions: list[Transition] = []
    with path.open("r", encoding="utf-8-sig", newline="") as stream:
        rows = csv.reader(stream)
        try:
            header = next(rows)
        except StopIteration as exc:
            raise ValueError("empty CSV") from exc
        if len(header) < 2:
            raise ValueError("CSV needs timestamp/sample and packed hex columns")
        for line_number, row in enumerate(rows, 2):
            if len(row) < 2:
                continue
            raw_time = row[0].strip()
            raw_value = row[1].strip()
            try:
                if sample_rate is None:
                    time_s = float(raw_time)
                else:
                    time_s = int(raw_time, 0) / sample_rate
                value = int(raw_value, 16)
            except ValueError as exc:
                raise ValueError(f"CSV line {line_number}: {exc}") from exc
            if transitions and time_s < transitions[-1].time_s:
                raise ValueError(f"CSV line {line_number}: timestamps run backwards")
            transitions.append(Transition(time_s, value & 0xF))
    if not transitions:
        raise ValueError("CSV has no data rows")
    return transitions


def input_events(trace: Sequence[Transition]) -> list[InputEvent]:
    result: list[InputEvent] = []
    old = trace[0].value & 7
    for transition in trace[1:]:
        new = transition.value & 7
        changed = old ^ new
        if changed:
            result.append(
                InputEvent(
                    transition.time_s,
                    old,
                    new,
                    changed & old,
                    changed & new,
                )
            )
        old = new
    return result


def output_edges(trace: Sequence[Transition]) -> list[Transition]:
    result: list[Transition] = []
    old = (trace[0].value >> 3) & 1
    for transition in trace[1:]:
        new = (transition.value >> 3) & 1
        if new != old:
            result.append(Transition(transition.time_s, new))
        old = new
    return result


def output_bursts(edges: Sequence[Transition], gap_s: float) -> list[Burst]:
    if not edges:
        return []
    result: list[Burst] = []
    first = 0
    for index in range(1, len(edges) + 1):
        if index == len(edges) or edges[index].time_s - edges[index - 1].time_s > gap_s:
            group = tuple(edges[first:index])
            result.append(Burst(group[0].time_s, group[-1].time_s, group))
            first = index
    return result


def compress(values: Sequence[int]) -> tuple[tuple[int, int], ...]:
    result: list[tuple[int, int]] = []
    for value in values:
        if result and result[-1][0] == value:
            result[-1] = (value, result[-1][1] + 1)
        else:
            result.append((value, 1))
    return tuple(result)


def tone_interval_ticks(
    commands: Sequence[tuple[int, str, int, int]], dwell_ticks: int
) -> list[int]:
    """Simulate tone terminal events in raw oscillator ticks.

    The divider is the same x^7+x+1 counter used to encode ROM pitch.  It
    advances each oscillator CE, toggles when its current state equals the ROM
    low seven bits, and then reloads 0x40.  That is algebraically equivalent to
    a command interval of pitch_phase+2 CEs.  The counter is continuous across
    command boundaries, explaining the captured boundary quantization.
    """
    if any(mode != "tone" for _, mode, _, _ in commands):
        raise ValueError("tone interval simulator requires an all-tone program")
    divider = 0x40
    event_ticks: list[int] = []
    total_ticks = len(commands) * dwell_ticks
    for tick in range(1, total_ticks + 1):
        command_index = min((tick - 1) // dwell_ticks, len(commands) - 1)
        # Recover the ROM's low-seven-bit target from its logarithmic phase.
        target_state = PITCH_STATES[commands[command_index][3]]
        if divider == target_state:
            event_ticks.append(tick)
            divider = 0x40
        else:
            divider = ((divider << 1) & 0x7F) | (((divider >> 6) ^ divider) & 1)
    return [b - a for a, b in zip(event_ticks, event_ticks[1:])]


def s4_expected_plateaus() -> tuple[tuple[int, int], ...]:
    """Expected complete plateau intervals under continuous divider state.

    The first/last visible interval at a ROM boundary can belong to either
    neighboring plateau, so validation permits a one-count boundary skew.
    """
    intervals = tone_interval_ticks(
        [(0, "tone", phase + 2, phase) for phase in range(13, 59, 5)], 480
    )
    return compress(intervals)


def mutated_reset_plateaus(
    commands: Sequence[tuple[int, str, int, int]], dwell_ticks: int
) -> tuple[tuple[int, int], ...]:
    """Negative-control policy: incorrectly reset divider every command."""
    events: list[int] = []
    absolute = 0
    for _, mode, _, phase in commands:
        if mode != "tone":
            raise ValueError("negative control requires an all-tone program")
        divider = 0x40
        target = PITCH_STATES[phase]
        for _ in range(dwell_ticks):
            absolute += 1
            if divider == target:
                events.append(absolute)
                divider = 0x40
            else:
                divider = ((divider << 1) & 0x7F) | (((divider >> 6) ^ divider) & 1)
    return compress([b - a for a, b in zip(events, events[1:])])


def cluster_wall_intervals(intervals: Sequence[float], relative_jump: float = 0.08) -> list[list[float]]:
    """Split stable-tone plateaus while allowing slow analog RC drift."""
    result: list[list[float]] = []
    for interval in intervals:
        if not result:
            result.append([interval])
            continue
        mean = statistics.mean(result[-1])
        if abs(interval - mean) / mean > relative_jump:
            result.append([interval])
        else:
            result[-1].append(interval)
    return result


def fit_s4_plateaus(
    name: str,
    burst: Burst,
    expected_intervals: Sequence[int],
    tolerance_ticks: float,
) -> PlateauFit:
    """Compare S4 one plateau at a time against a drifting RC oscillator.

    A single global seconds-per-tick is physically wrong for hmc1/hmc2: their
    oscillator slows by roughly nine percent during this 17 ms sweep.  Within
    each constant-ROM plateau, however, all adjacent transitions are one exact
    integer period.  Fitting one tick length per plateau models that observed
    analog drift while preserving a <=1-tick transition test.
    """
    wall = [
        b.time_s - a.time_s
        for a, b in zip(burst.edges, burst.edges[1:])
        if b.time_s > a.time_s
    ]
    # Discard trigger glitch/startup and stop at the first loop gap.
    start = next(
        (
            index
            for index in range(len(wall) - 4)
            if max(wall[index : index + 5]) / min(wall[index : index + 5]) < 1.03
        ),
        None,
    )
    if start is None:
        raise ValueError(f"{name}: no stable first tone plateau")
    wall = wall[start:]
    groups: list[list[float]] = []
    for group in cluster_wall_intervals(wall):
        if len(group) >= 7:
            groups.append(group)
            if len(groups) == 10:
                break
        elif groups:
            # A long loop gap or trigger transition ends the first program pass.
            break
    if len(groups) < 10:
        raise ValueError(f"{name}: found only {len(groups)} of 10 tone plateaus")

    expected_groups = s4_expected_plateaus()
    expected_periods = tuple(period for period, _ in expected_groups)
    expected_counts = tuple(count for _, count in expected_groups)
    observed_counts = tuple(len(group) for group in groups)
    residuals: list[float] = []
    edge_mismatches = 0
    ticks: list[float] = []
    for group, period in zip(groups, expected_periods):
        tick_s = statistics.median(group) / period
        ticks.append(tick_s)
        local = [abs(interval / tick_s - period) for interval in group]
        residuals.extend(local)
        edge_mismatches += sum(residual > tolerance_ticks for residual in local)

    # Counts can differ by one at a boundary because a terminal interval spans
    # the exact command change.  A different divider-reset policy creates large
    # isolated 65/80/85/100-tick groups and fails this structure entirely.
    structural = sum(abs(observed - expected) > 1 for observed, expected in zip(observed_counts, expected_counts))
    return PlateauFit(
        name,
        len(groups),
        len(residuals),
        structural,
        edge_mismatches,
        max(residuals),
        statistics.mean(residuals),
        ticks[0],
        ticks[-1],
        observed_counts,
        expected_counts,
    )


def first_stable_intervals(burst: Burst, count: int = 24) -> list[float]:
    wall = [
        b.time_s - a.time_s
        for a, b in zip(burst.edges, burst.edges[1:])
        if b.time_s > a.time_s
    ]
    for index in range(len(wall) - count + 1):
        window = wall[index : index + count]
        if max(window) / min(window) < 1.03:
            return window
    raise ValueError("no stable opening-tone interval window")


def selected_program(falling: int) -> Program | None:
    for bit in PRIORITY:
        if falling & (1 << bit):
            return next(program for program in PROGRAMS if program.input_bit == bit)
    return None


def early_median_interval(burst: Burst, window_s: float = 0.010) -> float | None:
    intervals = [
        b.time_s - a.time_s
        for a, b in zip(burst.edges, burst.edges[1:])
        if b.time_s <= burst.first_s + window_s and b.time_s > a.time_s
    ]
    # Remove the asynchronous trigger glitch and startup gap robustly.  The
    # median of the remaining early transitions is a stable effect fingerprint:
    # S4 tone sweep, S2 opening tone, and S3 noise are well separated.
    if len(intervals) < 12:
        return None
    ordered = sorted(intervals)
    trimmed = ordered[2 : max(3, len(ordered) - 2)]
    return statistics.median(trimmed)


def classify_burst(burst: Burst, signatures: Sequence[Signature]) -> tuple[str, float] | None:
    """Classify a burst by its first 10 ms output-transition fingerprint."""
    observed = early_median_interval(burst)
    if not signatures or observed is None:
        return None
    scored: list[tuple[float, str]] = []
    for signature in signatures:
        score = abs(math.log(observed / signature.early_median_s))
        scored.append((score, signature.program))
    score, program = min(scored)
    return program, score


def first_pulse_signatures(
    pulses: dict[int, list[tuple[float, float]]], bursts: Sequence[Burst]
) -> list[Signature]:
    result: list[Signature] = []
    for program in PROGRAMS:
        if not pulses[program.input_bit]:
            continue
        burst = nearest_burst(pulses[program.input_bit][0][0], bursts, 0.010)
        median = early_median_interval(burst) if burst is not None else None
        if median is not None:
            result.append(Signature(program.name, median))
    return result


def simultaneous_priority_checks(
    events: Sequence[InputEvent], bursts: Sequence[Burst], signatures: Sequence[Signature]
) -> list[tuple[int, str, str, float]]:
    """Derive simultaneous winners from captured output, not the priority table.

    Only the early public tests whose simultaneous pulse lasts about one second
    are used.  Their burst signatures are long enough to separate S2, S3, and
    S4 even though all three effects repeat while held.
    """
    result: list[tuple[int, str, str, float]] = []
    seen_masks: set[int] = set()
    for index, event in enumerate(events):
        if event.old != 7 or event.falling.bit_count() != 2:
            continue
        changed_mask = event.falling
        release = next(
            (
                later
                for later in events[index + 1 :]
                if (later.new & changed_mask) == changed_mask
            ),
            None,
        )
        if release is None:
            continue
        if any(
            later.falling and later.time_s < release.time_s
            for later in events[index + 1 :]
        ):
            # This is a staggered/preemption test, not a pure simultaneous hold.
            continue
        width = release.time_s - event.time_s
        # These are the first simultaneous full-hold trials in the public test
        # pattern; later staggered/preemption trials can also keep a mask low
        # for about a second but intentionally change its winner mid-burst.
        if not 0.97 <= width <= 1.03:
            continue
        if event.falling in seen_masks:
            continue
        burst = nearest_burst(event.time_s, bursts, 0.010)
        if burst is None:
            continue
        classified = classify_burst(burst, signatures)
        expected = selected_program(event.falling)
        if classified is not None and expected is not None:
            observed, score = classified
            result.append((event.falling, observed, expected.name, score))
            seen_masks.add(event.falling)
    return result


def isolated_short_events(events: Sequence[InputEvent]) -> dict[int, list[tuple[float, float]]]:
    """Return isolated, non-overlapped low pulses by input bit."""
    pending: dict[int, float] = {}
    result: dict[int, list[tuple[float, float]]] = {0: [], 1: [], 2: []}
    for event in events:
        for bit in range(3):
            mask = 1 << bit
            if event.falling & mask:
                # Only accept a pulse that starts while all other inputs are high.
                if event.old == 7 and event.falling == mask:
                    pending[bit] = event.time_s
                else:
                    pending.pop(bit, None)
            if event.rising & mask and bit in pending:
                start = pending.pop(bit)
                if event.new == 7:
                    result[bit].append((start, event.time_s))
    return result


def nearest_burst(start_s: float, bursts: Sequence[Burst], max_latency_s: float) -> Burst | None:
    candidates = [burst for burst in bursts if start_s <= burst.first_s <= start_s + max_latency_s]
    return min(candidates, key=lambda burst: burst.first_s) if candidates else None


def validate(rom: bytes, trace: Sequence[Transition], tolerance_ticks: float) -> list[str]:
    errors: list[str] = []
    decoded = {program.input_bit: decode_program(rom, program) for program in PROGRAMS}

    expected_lengths = {0: 59, 1: 10, 2: 10}
    expected_modes = {
        0: (["tone"] * 30) + (["noise"] * 29),
        1: ["noise"] * 10,
        2: ["tone"] * 10,
    }
    expected_s4_periods = list(range(15, 61, 5))
    expected_s2_periods = list(range(14, 44)) + [120, 120, 109, 109] * 7 + [120]
    expected_s3_periods = list(range(10, 19)) + [40]
    for program in PROGRAMS:
        commands = decoded[program.input_bit]
        if len(commands) != expected_lengths[program.input_bit]:
            errors.append(
                f"{program.name}: {len(commands)} commands; expected {expected_lengths[program.input_bit]}"
            )
        modes = [command[1] for command in commands]
        if modes != expected_modes[program.input_bit]:
            errors.append(f"{program.name}: tone/noise command pattern differs from captured device")
    if [command[2] for command in decoded[2]] != expected_s4_periods:
        errors.append("S4: periods are not the captured 15,20,...,60 raw-tick sweep")
    if [command[2] for command in decoded[0]] != expected_s2_periods:
        errors.append("S2: period sequence differs from the captured program")
    if [command[2] for command in decoded[1]] != expected_s3_periods:
        errors.append("S3: period sequence differs from the captured program")
    if mutated_reset_plateaus(decoded[2], 480) == s4_expected_plateaus():
        errors.append("internal negative control failed to distinguish per-command divider reset")

    events = input_events(trace)
    edges = output_edges(trace)
    bursts = output_bursts(edges, 0.05)
    pulses = isolated_short_events(events)

    print("ROM decode:")
    for program in PROGRAMS:
        commands = decoded[program.input_bit]
        modes = "".join("N" if command[1] == "noise" else "T" for command in commands)
        periods = ",".join(str(command[2]) for command in commands)
        print(
            f"  {program.name}: start=0x{program.start:02x}, commands={len(commands)}, "
            f"dwell={program.dwell_ticks} raw ticks, modes={modes}, periods={periods}"
        )
    print(f"Trace: input_events={len(events)}, output_edges={len(edges)}, bursts={len(bursts)}")

    # Validate every isolated S4 pulse/loop against a continuous LFSR divider.
    # It is the only bonded all-tone program and therefore gives an unambiguous
    # transition-by-transition check independent of the unresolved noise seed.
    s4_expected = tone_interval_ticks(decoded[2], 480)
    fits: list[PlateauFit] = []
    # The public capture sequence starts with short, medium, and one-second
    # individual pulses.  The latter can be preempted/continued into following
    # tests, so two isolated passes are enough for an independent repeat check.
    for pulse_index, (start, _) in enumerate(pulses[2][:2]):
        burst = nearest_burst(start, bursts, 0.010)
        if burst is None:
            errors.append(f"S4 pulse {pulse_index}: no output burst")
            continue
        # One short pulse can finish one or two passes depending on RC speed.
        # Compare the first complete pass; loop timing is checked separately by
        # command duration below.
        try:
            fit = fit_s4_plateaus(f"S4[{pulse_index}]", burst, s4_expected, tolerance_ticks)
        except ValueError as exc:
            errors.append(str(exc))
            continue
        fits.append(fit)
        print(
            f"  {fit.name}: tick={fit.tick_first_s * 1e6:.6f}->{fit.tick_last_s * 1e6:.6f} us, "
            f"intervals={fit.intervals_compared}, edge_mismatches={fit.edge_mismatches}, "
            f"structural_mismatches={fit.structural_mismatches}, "
            f"mean={fit.mean_ticks:.4f} tick, worst={fit.worst_ticks:.4f} tick"
        )
        print(f"    expected plateau counts: {fit.expected_counts}")
        print(f"    observed plateau counts: {fit.observed_counts}")
        if fit.edge_mismatches or fit.structural_mismatches:
            errors.append(
                f"{fit.name}: {fit.edge_mismatches} edge and {fit.structural_mismatches} structural mismatches"
            )

    # S2's long first command is an independent oscillator check: after the
    # startup edge its 0x55 command is an exact 14-tick tone plateau.
    s2_ticks: list[float] = []
    for pulse_index, (start, _) in enumerate(pulses[0]):
        burst = nearest_burst(start, bursts, 0.010)
        if burst is None or len(burst.edges) < 20:
            continue
        try:
            adjacent = first_stable_intervals(burst)
        except ValueError:
            continue
        tick_s = statistics.median(interval / 14 for interval in adjacent)
        residuals = [abs(interval / tick_s - 14) for interval in adjacent]
        mismatches = sum(residual > tolerance_ticks for residual in residuals)
        s2_ticks.append(tick_s)
        print(
            f"  S2[{pulse_index}] opening: tick={tick_s * 1e6:.6f} us, "
            f"intervals={len(residuals)}, mismatches={mismatches}, "
            f"mean={statistics.mean(residuals):.4f} tick, worst={max(residuals):.4f} tick"
        )
        if mismatches:
            errors.append(f"S2[{pulse_index}]: {mismatches} opening intervals exceed tolerance")

    # Derive simultaneous priority from the captured output signatures.  The
    # expected winner comes from PRIORITY; classification is independent.
    signatures = first_pulse_signatures(pulses, bursts)
    arbitration = simultaneous_priority_checks(events, bursts, signatures)
    if arbitration:
        formatted = ", ".join(
            f"0b{mask:03b}->{observed} (expected {expected}, distance {score:.3f})"
            for mask, observed, expected, score in arbitration
        )
        print(f"  simultaneous arbitration from burst signatures: {formatted}")
        for mask, observed, expected, score in arbitration:
            if observed != expected:
                errors.append(
                    f"simultaneous 0b{mask:03b}: captured signature is {observed}, expected {expected}"
                )
            if score > 0.20:
                errors.append(
                    f"simultaneous 0b{mask:03b}: ambiguous burst classification distance {score:.3f}"
                )
    else:
        print("  simultaneous arbitration: no qualifying one-second combined pulses in CSV")

    if fits and s2_ticks:
        relative = abs(fits[0].tick_first_s - s2_ticks[0]) / min(fits[0].tick_first_s, s2_ticks[0])
        # A physical RC oscillator measurably drifts under these effects.  This
        # is a diagnostic, not a failure; per-edge checks above use local fits.
        print(f"  within-capture RC-rate spread: {relative * 100:.3f}%")
    print(f"  mutation check (reset divider each command): rejected; groups={mutated_reset_plateaus(decoded[2], 480)}")

    if errors:
        print("FAIL:", file=sys.stderr)
        for error in errors:
            print(f"  {error}", file=sys.stderr)
    else:
        print(f"PASS: all checked transitions are within {tolerance_ticks:g} raw oscillator tick")
    return errors


def dump_rom(rom: bytes) -> None:
    for program in PROGRAMS:
        print(f"{program.name} @ 0x{program.start:02x}, dwell {program.dwell_ticks} raw ticks")
        for address, mode, period, phase in decode_program(rom, program):
            print(
                f"  {address:02x}: {rom[address]:02x}  {mode:5s}  "
                f"pitch_phase={phase:3d}  period={period:3d} ticks"
            )


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("rom", nargs="?", type=Path, help="decoded 128-byte HA1152/HMC ROM")
    result.add_argument("csv", nargs="?", type=Path, help="Saleae S2/S3/S4/OUT packed CSV")
    result.add_argument(
        "--sample-rate",
        type=float,
        default=None,
        help="CSV timestamp is an integer sample index at this rate (for the public captures: 100000000)",
    )
    result.add_argument(
        "--integer-samples",
        action="store_true",
        help=f"shortcut for --sample-rate {SAMPLE_RATE_DEFAULT:g}",
    )
    result.add_argument(
        "--tolerance-ticks",
        type=float,
        default=1.0,
        help="maximum normalized edge residual; cannot exceed one raw oscillator tick",
    )
    result.add_argument("--dump-rom", action="store_true", help="print decoded commands")
    result.add_argument(
        "--self-test",
        action="store_true",
        help="run ROM-independent decoder/divider mutation tests before any supplied inputs",
    )
    return result


def self_test() -> None:
    if len(PITCH_STATES) != 127 or len(set(PITCH_STATES)) != 127:
        raise ValueError("self-test: pitch LFSR is not maximal")
    synthetic = [(0, "tone", phase + 2, phase) for phase in range(13, 59, 5)]
    continuous = compress(tone_interval_ticks(synthetic, 480))
    reset = mutated_reset_plateaus(synthetic, 480)
    if continuous == reset:
        raise ValueError("self-test: divider-reset mutation was not detected")
    if not any(period in (65, 80, 85, 100) for period, _ in reset):
        raise ValueError("self-test: reset mutation lacks expected boundary intervals")
    mutated = list(synthetic)
    mutated[0] = (0, "tone", 15, 14)
    if tone_interval_ticks(mutated, 480) == tone_interval_ticks(synthetic, 480):
        raise ValueError("self-test: pitch-code mutation was not detected")
    print("PASS: self-test rejected pitch-code and per-command-divider-reset mutations")


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if not 0 < args.tolerance_ticks <= 1.0:
        print("--tolerance-ticks must be in (0, 1]", file=sys.stderr)
        return 2
    try:
        if args.self_test:
            self_test()
            if args.rom is None:
                return 0
        if args.rom is None:
            raise ValueError("ROM path is required unless --self-test is used alone")
        rom = args.rom.read_bytes()
        if len(rom) != 128:
            raise ValueError(f"ROM is {len(rom)} bytes; expected exactly 128")
        if args.dump_rom:
            dump_rom(rom)
        if args.csv is None:
            return 0
        sample_rate = SAMPLE_RATE_DEFAULT if args.integer_samples else args.sample_rate
        trace = read_saleae(args.csv, sample_rate)
        return 1 if validate(rom, trace, args.tolerance_ticks) else 0
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

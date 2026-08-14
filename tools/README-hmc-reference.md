# HA1152/HMC trace reference

`hmc_reference.py` is a preservation-oriented decoder and trace validator for
the HA1152/HMC sound-effect ASIC used by Nelsonic Star Fox. It does not include
the copyrighted 128-byte device ROM or any captured waveform. Supply those
files explicitly:

```text
python tools/hmc_reference.py path/to/hmc.bin path/to/hmc1allsigs.csv --integer-samples
```

For a Saleae CSV whose first column is already seconds, omit
`--integer-samples`. The packed data column must contain `S2,S3,S4,OUT` in bits
0 through 3. Validation exits nonzero if a checked ROM or transition invariant
does not match.

Run the ROM-independent mutation controls with:

```text
python tools/hmc_reference.py --self-test
```

This deliberately mutates the pitch sequence and command-boundary divider
policy internally and fails unless both incorrect models are rejected.

The mechanically established model used by the validator is:

- Active-low `S2`, `S3`, and `S4` start ROM vectors `0x00`, `0x3c`, and `0x75`.
- Simultaneous priority is `S4 > S2 > S3`; any new falling edge preempts. The
  validator derives the three pairwise winners independently from the first
  10 ms output-transition signature of each combined-input capture.
- Trigger raises the physical output immediately, resets sequencing, and starts
  a 256-oscillator-CE delay. The first command step follows that delay.
- Per-command dwell is 3840, 2880, or 480 raw oscillator CEs for S2, S3, or S4.
- ROM bit 7 selects noise (one) versus tone (zero); zero is the terminator.
- The low seven bits are a logarithmic pitch code. Starting from state 1,
  `next=((state<<1)&0x7f)|((state>>6)^state)&1`; if the code occurs at zero-based
  phase `p`, its terminal period is `p+2` raw oscillator CEs.
- Equivalently, hardware can run that same 7-bit LFSR divider, compare its
  current state with the ROM code each oscillator CE, act on equality, and
  reload `0x40`. The divider remains continuous across ROM command boundaries.
- The noise stream is a maximal 9-bit LFSR. In chronological output-bit form,
  after compensating for the bonded output inversion,
  `b[n] = b[n-4] XOR b[n-9]`, i.e. polynomial `x^9+x^5+1` (the reciprocal
  shift-register orientation is equivalent).
- A concrete recurrence-correct realization with `state[0]` as the newest bit
  is `next={state[7:0],state[8]^state[3]}` and physical output `~next[0]`.
  Preserve this noise state across trigger, idle, and command changes.
- At a zero terminator, a still-low selected input repeats; otherwise the output
  returns low.

The public captures use an analog RC oscillator. Two captures slow from about
3.21 to 3.50 microseconds per raw tick during the S4 sweep, while the third is
near 2.166 microseconds and stable. The validator therefore fits tick length
locally inside each constant-ROM tone plateau. It still requires every compared
edge to land within one raw oscillator tick and checks plateau structure
separately. Resetting the pitch divider at every command is retained as an
internal negative control; it creates uncaptured 65/80/85/100-tick boundary
intervals and is rejected.

## Remaining phase ambiguity

The captures prove the 9-bit polynomial and inversion, but not a unique
power-on seed: every nonzero seed is a rotation of the same 511-bit maximal
sequence, and the ASIC's noise register persists between effects. They also do
not resolve whether RTL names the terminal noise bit as the old or newly shifted
state; those forms differ only by a one-step seed rotation. The tool therefore
does not claim a unique absolute noise phase or compare noise edges as though
one were known. The tone transition checks, ROM decoding, dwell, trigger
mapping, and divider-boundary policy are independent of that ambiguity.

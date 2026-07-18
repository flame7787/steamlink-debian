# Steam Link NAND bring-up

## Current milestone

Linux 6.1.115 now describes the BG2CD (Armada 1500-mini SoC) NAND
controller and enables the Marvell NAND driver at boot. The new compatible is
deliberately **probe-only**:

- it may reset the NAND, issue READID and read the parameter page;
- it does not register an MTD device;
- page reads, erase and program operations are unavailable;
- `/proc/mtd` is expected to remain empty after a successful probe.

This guard is required because the Valve 3.8 driver shows that production page
access also depends on the pBridge descriptor engine, explicit BCH strength
selection, a software randomizer and, for some flashes, read-retry handling.
The pBridge function channel is not a generic memcpy DMA channel, so it must not
be exposed as one merely to satisfy the generic NAND driver's DMA request.

## First hardware boot

Boot the new `zImage` and `berlin2cd-valve-steamlink.dtb` from USB. Do not alter
the internal NAND boot flow. Capture:

```sh
uname -a
dmesg | grep -Ei 'nand|marvell|nfc|timeout|error'
cat /proc/mtd
```

A successful milestone identifies the manufacturer/model or reports the raw ID,
then prints the probe-only warning. `/proc/mtd` should contain only its header.
No `nanddump` package is required at this stage because no MTD character device
is intentionally created.

The first hardware test reached `nand_scan` but reported `No NAND device found`.
After probe unwound, debugfs showed the expected NFC clocks at 212.5 MHz and
NFC-ECC clock at 283.33 MHz. The platform device was left unbound, with the
clocks disabled and IRQ released, as expected for a failed probe.

The follow-up diagnostic patch forces the timing values used by Valve's driver
before the first RESET/READID and prevents the generic NAND timing setup from
overwriting them:

```text
NDTR0CS0 = 0x84840a12
NDTR1CS0 = 0x00208662
```

It logs both READID transfers. Hardware testing produced matching, stable
results and confirmed that the timing, chip-select and PIO command path work:

```text
READID data (2 bytes): 2c 68
READID data (8 bytes): 2c 68 04 4a a9 00 00 ff
READID data (4 bytes): 4f 4e 46 49
```

The third result is the `ONFI` (Open NAND Flash Interface) signature read from
address `0x20`. Identification then failed with `-ENODEV` because the Berlin2CD
identification parser did not accept the ONFI `PARAM` command. The NAND core
consequently tried its JEDEC fallback at address `0x40`, which returned the
ordinary Micron ID rather than a JEDEC parameter signature.

Patch `0003-mtd-nand-read-berlin2cd-onfi-parameters.patch` adds only the
missing 256-byte ONFI parameter-page operation. Hardware returned a matching
CRC and identified the exact device:

```text
ONFI parameter CRC: calculated=6bca expected=6bca (valid)
nand: Micron MT29F32G08CBACAWP
nand: 4096 MiB, MLC, erase size: 1024 KiB, page size: 4096, OOB size: 224
```

The controller remained bound and printed the probe-only warning, while
`/proc/mtd` remained empty. Patch
`0004-mtd-nand-harden-berlin2cd-identification.patch` now restricts the
Berlin2CD operation parser to RESET, READID, STATUS and this exact ONFI read. It
also reports the ONFI reliability fields needed to compare the chip's ECC
requirements with Valve's configuration before page access is implemented.

The hardened hardware run reported `ecc-bits-per-512=255`, three parameter-page
copies and a 48-byte extended parameter page. In ONFI this `0xff` ECC value is
not a strength: it directs the host to the ECC information block in the
extended page. The reported decimal endurance value `771` was likewise the raw
encoded bytes `03 03`, meaning 3 x 10^3 cycles.

Linux then printed `Failed to detect ONFI extended param page` because the
probe-only filter correctly rejected the core's CHANGE READ COLUMN operation.
Patch `0005-mtd-nand-read-berlin2cd-onfi-extended-parameters.patch` permits only
the operation required by this confirmed geometry: `RNDOUT`, column `0x0300`,
`RNDOUTSTART`, and exactly 48 input bytes. It validates the extended CRC and
`EPPS` signature and logs the ECC strength and codeword size. The operation is
still PIO-only and identification-only; ordinary NAND page access remains
blocked.

Expected new output includes:

```text
ONFI reliability: ecc=extended-parameter-page ... block-endurance=3 x 10^3 cycles ... extended-page-bytes=48
ONFI extended parameter data (48 bytes): ...
ONFI extended parameter CRC: calculated=.... expected=.... (valid), signature="EPPS"
ONFI extended ECC: strength=... bits step-size=... bytes ...
```

Hardware returned a valid extended page and confirmed the production ECC
requirement:

```text
ONFI extended parameter CRC: calculated=71bc expected=71bc (valid), signature="EPPS"
ONFI extended ECC: strength=24 bits step-size=1024 bytes
```

This is the same correction density as Valve's setting. The vendor driver uses
48-bit BCH while processing a 4 KiB page as two independent 2 KiB chunks, so
its effective requirement is 48 bits per 2048 bytes, equivalent to the ONFI
24 bits per 1024 bytes.

If the extended read times out, retain the named controller stage and final
register dump. If its CRC or signature is invalid, do not broaden the operation
filter or proceed to page reads; first compare repeated 48-byte captures.

For earlier READID failures, a matching Micron result is expected to begin with
either `2c 68 04 4a` or `2c 68 04 46`. Interpret failures as follows:

- all `ff`: check chip select, pin mux, power and external signaling;
- all `00` or repeated words: check FIFO and controller mode;
- different first and second IDs: check timing stability;
- a controller timeout: use the named WRCMDREQ, RDDREQ, CMDD or ready/busy
  stage to investigate that handshake;
- a stable but unknown ID: add its confirmed geometry in a later patch.

Retain the complete `dmesg` from each test. Do not use `devmem` to write NFC,
pBridge or clock registers.

## Evidence already available

The Valve 3.8 flash table contains Micron IDs beginning with `2c 68` for a 4 GiB,
8-bit, 4 KiB-page device and selects 48-bit ECC. Its page loop operates on two
2 KiB chunks, making that setting consistent with ONFI's 24-bit-per-1-KiB
requirement. ONFI identification confirms an MT29F32G08CBACAWP with 4 KiB
pages, 224-byte OOB, 256 pages per erase block and a 4 GiB capacity.

The final vendor flash-table field is a dual-plane flag, not a randomizer flag.
The separate vendor randomizer table contains the exact ID
`2c 68 04 46 89`; its five-byte lookup does not match this unit's
`2c 68 04 4a a9` ID. The vendor implementation also bypasses randomization for
blocks 0 through 8. Raw-read experiments must therefore determine whether this
chip's production data is randomized instead of assuming that it is.

The supplied `steamlink-stock.dtb` has now been inspected. Despite its filename,
it is the live device tree passed to the running 6.1.115 kernel, not an original
Valve 3.8 device tree: its `/chosen` node contains the current kernel command
line and initrd addresses. Apart from that runtime data, it matches the upstream
Steam Link DTS and contains no NAND node. The patched DTB differs by the new NFC
controller and NAND child only.

This confirms that mainline Linux was missing the NAND description. It does not
independently prove the wiring. The controller address (`0xf7f00000`), pBridge
address (`0xf7d70000`) and SPI 18 interrupt still come from Valve's 3.8 DTS. The
mainline Berlin2CD clock driver confirms separate NFC, NFC-ECC and pBridge
clocks. Before patch `0006`, hardware showed the NFC clocks enabled and owned
by the NAND controller, while the 212.5 MHz pBridge clock was present but
deviceless and disabled. IRQ 50 (DT SPI 18) was registered as `marvell-nfc`,
and the platform device remained bound to the driver.

Patch `0006-mtd-nand-map-berlin2cd-pbridge-passively.patch` adds Valve's second
resource at physical address `0xf7d70000`, claims the pBridge clock and reads
only side-effect-free status/configuration registers. Expected output begins:

```text
passive pBridge status: clock=212500000 Hz sem-empty=... sem-full=... dHub-busy=... dHub-pending=...
passive pBridge control: bus-reset-enable=... bus-reset-done=... BCM-error=... BCM-base=...
```

This patch does not initialize channels or semaphores, access pBridge TCM,
submit descriptors, or read NAND pages. After boot, capture those two lines and
repeat the clock, interrupt and driver-binding checks. The pBridge clock should
then show one enabled consumer owned by `f7f00000.nand-controller`.

Hardware produced the following inherited state:

```text
passive pBridge status: clock=212500000 Hz sem-empty=ffffffff sem-full=00003000 dHub-busy=00000000 dHub-pending=00000000
passive pBridge control: bus-reset-enable=00000000 bus-reset-done=00000000 BCM-error=00000000 BCM-base=f0000000
```

The dHub is idle, no reset or BCM error is active, and the BCM aperture matches
Valve's expected high address bits for NFC at `0xf7f00000`. Bits 12 and 13 in
the full-condition latch correspond to Valve's NFC command and NFC data
handshake semaphores. The empty/full registers are write-one-to-clear condition
latches, not direct semaphore counters, so the apparently overlapping values
are not contradictory.

Patch `0007-mtd-nand-inventory-berlin2cd-pbridge-queries.patch` now reads the
documented query windows for dHub channels 0 through 3, their eight HBO queues,
and NFC-related semaphores 0-3, 12, 13, 19, 24 and 25. It reports producer and
consumer counts and pointers without modifying them. Channel configuration,
FIFO base/depth, semaphore depth and interrupt-mask registers are intentionally
excluded because the vendor register specification marks them write-only.

Retrieve the complete early output from the journal if the 16 KiB kernel ring
buffer has wrapped:

```sh
sudo journalctl -k -b --no-pager | grep -E 'passive pBridge|READID'
```

The probe patch treats Berlin2CD as NFCv2 for timing and register capabilities,
but deliberately uses the explicit NFCv1 command parser for READID and RESET.
It also has a dedicated identification-only cleanup path, since the ordinary
NAND cleanup assumes that later manufacturer initialization already happened.

## Next implementation stages

1. Boot patch `0007` and record all channel, queue and semaphore query results.
2. Decide whether the inherited pBridge state can be reused or needs a bounded
   reset and explicit Valve-compatible initialization.
3. Port the pBridge channel/semaphore/BCM descriptor primitives with bounded
   polling, but initially execute only a read-only READID transfer.
4. Implement repeated raw page reads with BCH disabled and explicitly test
   randomizer behavior before decoding production data.
5. Add 48-bit-per-2-KiB BCH handling and compare corrected reads against the
   raw captures before registering any MTD.
6. Register a read-only MTD and validate full-device hashes, bad-block markers
   and ECC statistics.
7. Add read-retry support if the confirmed ID requires it.
8. Put erase/program support behind an explicit Kconfig opt-in, then test only
   on disposable blocks after verified USB recovery.

GPU work is separate. Etnaviv is already upstream in modern Linux and the GC1000
register block does not replace the NAND pBridge engine.

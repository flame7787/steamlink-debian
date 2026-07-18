# Steam Link NAND bring-up

## Current milestone

Linux 6.1.115 now describes the BG2CD NAND controller and enables the Marvell
NAND driver at boot. The new compatible is deliberately **probe-only**:

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

It logs both READID transfers. A matching Micron result is expected to begin
with either `2c 68 04 4a` or `2c 68 04 46`. Interpret failures as follows:

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
8-bit, 4 KiB-page device. It records 48-bit ECC per 4 KiB codeword and marks the
device randomized. This is consistent with the reported MT29F32G08CBAC, but the
actual Steam Link part remains unconfirmed until the new kernel logs READID.

The supplied `steamlink-stock.dtb` has now been inspected. Despite its filename,
it is the live device tree passed to the running 6.1.115 kernel, not an original
Valve 3.8 device tree: its `/chosen` node contains the current kernel command
line and initrd addresses. Apart from that runtime data, it matches the upstream
Steam Link DTS and contains no NAND node. The patched DTB differs by the new NFC
controller and NAND child only.

This confirms that mainline Linux was missing the NAND description. It does not
independently prove the wiring. The controller address (`0xf7f00000`), pBridge
address (`0xf7d70000`) and SPI 18 interrupt still come from Valve's 3.8 DTS. The
mainline Berlin2CD clock driver confirms separate NFC and NFC-ECC clocks; the
pBridge clock should be added when that data path is implemented.

The probe patch treats Berlin2CD as NFCv2 for timing and register capabilities,
but deliberately uses the explicit NFCv1 command parser for READID and RESET.
It also has a dedicated identification-only cleanup path, since the ordinary
NAND cleanup assumes that later manufacturer initialization already happened.

## Next implementation stages

1. Confirm READID and controller clock/interrupt behavior on hardware.
2. Port the pBridge channel/semaphore/BCM descriptor primitives with bounded
   polling and descriptor unit tests.
3. Implement raw page reads, BCH strength programming and the vendor-compatible
   randomizer; compare repeated dumps before registering MTD.
4. Register a read-only MTD and validate full-device hashes and ECC statistics.
5. Add read-retry support if the confirmed ID requires it.
6. Put erase/program support behind an explicit Kconfig opt-in, then test only
   on disposable blocks after verified USB recovery.

GPU work is separate. Etnaviv is already upstream in modern Linux and the GC1000
register block does not replace the NAND pBridge engine.

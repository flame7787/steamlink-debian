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
sudo journalctl -k -b --no-pager | grep -E 'pBridge|READID|ONFI'
```

On hardware, patch `0007` produced enough early output to wrap the 16 KiB
kernel log before journald started, leaving only the later semaphore queries.
Linux 6.1 now uses a 128 KiB log buffer (`CONFIG_LOG_BUF_SHIFT=17`) so the next
normal boot retains the complete channel, queue and semaphore inventory.

The retained inventory confirmed that the dHub is quiescent: busy and pending
were zero, all four channels reported state `0002`, and all eight HBO busy bits
were clear. Every queue had zero producer and consumer availability. Its
matching producer/consumer pointers retained the values `0/16`, `1/5`, `0/0`
and `0/7` for the four command/data pairs. Those residues are compatible with
Valve's queue depths but do not prove configuration because FIFO base and
depth registers are write-only.

The dHub semaphores likewise usually had zero producer and consumer counts.
Semaphore 24 reported producer count 1 and consumer count 0 on one boot, then
zero on a later boot. Valve's HBO helpers treat these query counts as queue
occupancy visible to each side, not free capacity. The one-sided value and
changing FIFO pointers are therefore bootloader residue rather than a
verifiable empty configuration. No active NAND transaction was visible, so
explicit bounded reinitialization is safer than reusing that state.

Patch `0009-mtd-nand-initialize-berlin2cd-pbridge.patch` records that inherited
state, refuses to proceed if dHub or HBO is active, and then reproduces Valve's
four-channel setup. It clears all eight FIFOs with a 100 ms bounded wait,
programs the BCM base, 32-byte MTUs, FIFO bases/depths and nine depth-one dHub
semaphores, then records the initialized state. It does not touch TCM, enable
the completion interrupt, submit descriptors or transfer NAND data.

Expected output includes:

```text
inherited pBridge status: ... dHub-busy=00000000 dHub-pending=00000000
pBridge initialized: four 32-byte-MTU channels, eight Valve-layout FIFOs, nine depth-one semaphores
initialized pBridge HBO busy: 00000000
```

Hardware completed initialization without a timeout. All producer and consumer
counts were zero, all FIFO pointers reset to zero, and dHub/HBO remained idle.
That is the correct empty state; configured depths are write-only and do not
appear as free-slot counts in the query windows. NAND READID and both ONFI CRCs
remained unchanged, and `/proc/mtd` remained empty.

Patch `0010-mtd-nand-test-berlin2cd-pbridge-internally.patch` validates the
internal TCM, FIFO semaphore and query paths before any descriptor is used. It
uses queue 31, outside Valve's NFC queues 0 through 7, at depth one and the
final 64-bit TCM word at offset `0x07f8`. The test saves and restores that word,
requires a `0 -> 1 -> 0` producer/consumer count transition, and disables,
clears and resets the test queue on every exit path. It does not start a dHub
channel or access NAND.

The first hardware run rejected TCM readback at `0x07f8` before pushing a
token. The failure path cleaned up correctly, normal PIO identification still
found the Micron device, both ONFI CRCs remained valid and `/proc/mtd` stayed
empty. This indicates that the generic 2 KiB TCM description cannot yet be
assumed for Berlin2CD's extreme tail.

Patch `0011-mtd-nand-retry-berlin2cd-tcm-after-valve-layout.patch` moves the
same reversible test to `0x0440`, the first 64-bit word after Valve's queue
allocation ends at `0x043f`. It also reports the exact expected and actual
words if readback fails again.

Hardware advanced past TCM readback at `0x0440`, confirming that this word is
writable, but queue 31 ignored the push and both query counts stayed zero.
This suggests that Berlin2CD implements only Valve's queues 0 through 7 rather
than all 32 queues in the generic HBO description. Cleanup, PIO identification
and both ONFI CRCs still completed normally.

Patch `0012-mtd-nand-test-berlin2cd-implemented-fifo.patch` repeats the test on
implemented queue 7. It first stops channel 3, temporarily configures its data
queue at depth one, and restores the exact Valve queue base/depth before
restarting the channel.

Hardware confirmed that queue 7 and TCM offset `0x0440` are implemented, but
the diagnostic reported a producer-side timeout. That result did not establish
that the consumer stayed at zero: the helper returned after polling the
producer and never sampled the consumer output. PIO READID, both ONFI CRCs and
cleanup remained healthy, and `/proc/mtd` stayed empty.

Patch `0013-mtd-nand-poll-berlin2cd-fifo-consumer.patch` follows Valve's HBO
access pattern. It polls the consumer query that indicates readable FIFO data,
then samples the producer query for diagnostics. Expected successful output is:

```text
pBridge internal queue after push: producer=<diagnostic>/... consumer=1/... data=a5c35a3c:534c5042
pBridge internal TCM/FIFO test passed: queue=7 offset=0440
```

If the patch reports that the consumer did not observe the push or pop, retain
the complete boot log. A zero consumer count after this patch is conclusive,
rather than an uninitialized diagnostic value. PIO READID and both ONFI CRCs
should still complete, but descriptor work must not proceed.

Hardware running patch `0013` reported zero for both queue 7 queries after the
push. The failure is therefore real, not a stale diagnostic. TCM remained
writable, cleanup completed, PIO identification remained stable, both ONFI
CRCs were valid and `/proc/mtd` stayed empty. A fresh audit also confirmed the
vendor register layout and command encoding: the HBO SemaHub PUSH register is
at `0x0f80`, with the ID in bits 0 through 7 and delta in bits 8 through 15.

Patch `0014-mtd-nand-test-berlin2cd-dhub-semaphore.patch` tests the other
SemaHub inside pBridge before repeating the HBO queue test. It borrows the
already configured depth-one dHub semaphore 25, performs a bounded `0 -> 1 ->
0` push/pop transition and clears its latched empty/full status afterward. It
also clears and samples the dHub and HBO test bits in the condition registers
around each operation. It does not submit a descriptor or issue a NAND
command. Expected dHub success is:

```text
pBridge dHub semaphore after push: id=25 producer=1/... consumer=1/... events empty=1 full=1
pBridge dHub semaphore push/pop test passed: id=25 events empty=1 full=1
```

If dHub semaphore 25 passes while queue 7 still fails, the fault is confined
to the HBO FIFO controller or its configuration. If both pushes fail, focus on
the common SemaHub write path, clock/reset state or access semantics.

Hardware running patch `0014` completed the dHub semaphore transition with
matching producer and consumer counts of one after PUSH and zero after POP.
This proves the shared pBridge clock, MMIO write path, PUSH/POP encoding and
query-map interpretation. HBO queue 7 still ended with both query counts at
zero, but both its empty and full conditions were set after PUSH. That pattern
is compatible with a token becoming full and then being consumed before the
100 ms poll ended.

The patch's two "condition latches did not clear" warnings are not evidence of
a failed write. The empty condition immediately reasserts while a depth-one
semaphore has a zero count, so requiring both empty and full to remain clear
was invalid. The full condition must be cleared and checked independently
before it can prove a post-PUSH transition.

Patch `0015-mtd-nand-isolate-berlin2cd-hbo-queue.patch` corrects that check and
tests the transient-consumption hypothesis. It follows Valve's full channel 3
stop sequence: disable command queue 6, disable and clear the channel, wait
for dHub busy and pending to clear, then clear queues 6 and 7. It captures both
HBO query windows immediately after PUSH and again after the bounded poll,
then restores both FIFOs and the channel. Expected output now contains:

```text
pBridge dHub semaphore after push: id=25 producer=1/... consumer=1/... events empty=1 full=1
pBridge internal queue after push: first producer=1/... consumer=1/...; final producer=1/... consumer=1/... ...
```

If the first HBO counts are one but the final counts are zero, a consumer is
draining queue 7. If the isolated test passes, the earlier START=0 write did
not fully quiesce channel 3 without a channel CLEAR. If both first and final
counts remain zero while `full=1` and no pre-PUSH full-condition warning
appears, the PUSH reached HBO but either vanished before the first MMIO read or
the HBO count-query semantics differ on Berlin2CD. A full-condition warning
makes the post-PUSH full bit ambiguous and should be retained in the log.

Hardware running patch `0015` completed the full channel-clear sequence with
no dHub, pending, or HBO timeout. Both immediate and delayed HBO queries still
reported zero, while the independently cleared full condition asserted after
the PUSH. The channel-consumer hypothesis is therefore disproved. The same
boot again produced stable Micron ID and ONFI data with both CRCs valid.

Valve's HAL uses depth one for the separate dHub completion semaphores, but its
HBO command/data queues use depths two and 32. Patch
`0016-mtd-nand-test-berlin2cd-hbo-depth-two.patch` repeats the isolated queue 7
test at depth two. One pushed token should not fill a depth-two queue. Expected
success is:

```text
pBridge internal queue after push at depth 2: first producer=1/... consumer=1/...; final producer=1/... consumer=1/... events empty=... full=0 data=a5c35a3c:534c5042
pBridge internal TCM/FIFO test passed: queue=7 depth=2 offset=0440
```

If this passes, depth one is not usable for Berlin2CD's HBO FiFoCtl even though
it works in the dHub SemaHub. If counts remain zero and `full=1`, the configured
depth was not accepted or the HBO full/query semantics differ from the common
SemaHub. If counts become one but `full=1`, retain the dedicated warning: the
query path works, but the full-condition behavior needs separate handling.

Hardware running patch `0016` reported `producer=0/1 consumer=0/1` in both the
immediate and final samples, with `full=0`. Compared with patch `0015`, changing
the depth from one to two changed the full condition exactly as expected. Both
pointers also advanced from zero to one. The HBO therefore accepted the depth
and PUSH; matching advanced pointers with zero counts indicate that a consumer
also performed a POP before the first CPU query.

Patch `0017-mtd-nand-test-disabled-berlin2cd-hbo-queue.patch` leaves FIFO
`START=0` after configuring queue 7. It exercises only the queue's SemaHub and
records channel 3 state before, immediately after, and at the end of the poll.
Expected retained-token output is:

```text
pBridge disabled queue retained push at depth 2: first producer=1/1 consumer=1/0; final producer=1/1 consumer=1/0 states=... events empty=... full=0 data=a5c35a3c:534c5042
pBridge internal TCM/FIFO test passed: queue=7 depth=2 offset=0440
```

If the disabled queue retains the token, FIFO `START=1` allowed the unexpected
consumer and descriptor work can use the normal producer/consumer protocol. If
both pointers again advance to one with zero counts, consumption is independent
of the FIFO enable and the next diagnostic must isolate the HBO SemaHub from
the dHub/2D channel block. If neither pointer advances, HBO ignores PUSH while
the FIFO is disabled and the test must instead hold the associated channel in
a stronger reset state.

Hardware running patch `0017` retained the token exactly as expected:
producer count/pointer `1/1`, consumer count/pointer `1/0`, channel state
`0001` throughout and no full condition at depth two. Cleanup restored the
normal queue and channel configuration, after which PIO READID and both ONFI
parameter-page CRCs remained valid. This confirms the HBO queue and dHub
consumer path are behaving normally.

Patch `0018-mtd-nand-test-berlin2cd-null-descriptor.patch` is the first
coherent-memory fetch test. It submits one four-byte BCM `NULL` instruction on
channel 3's normal command queue 6, requests completion on dHub semaphore 3,
and verifies that the four NAND control/timing registers did not change.
Expected success is:

```text
pBridge submitting NULL descriptor: dma=... descriptor=0000000f queue=6 slot=0 command=10000004:...
pBridge NULL descriptor completed: dma=... queue producer=0/1 consumer=0/1 semaphore producer=0/0 consumer=1/0 events empty=1 full=1
pBridge coherent NULL descriptor test passed without NAND access
```

The descriptor is `0x0000000f`, matching the generated vendor `BCMINSFMT`
definition: `NULL` is a four-byte instruction with its header in bits 3
through 0. The dHub command is still one 64-bit queue entry and requests a
four-byte transfer. The test runs only if patch `0017`'s disabled-queue test
passes, uses bounded polling, never accesses NAND media and leaves MTD
registration disabled.

Hardware running patch `0018` produced all three success messages, returned
both queue 6 pointers at slot one with zero queued entries, asserted the
completion semaphore's full condition, and left `BCM-error`, all busy bits and
the NAND registers clear or unchanged. The completion semaphore's producer
query remained at count/pointer `0/0` while its consumer query reported
`1/0`; this is the observed dHub-generated completion representation, not a
missing completion. Popping it returned the consumer count to zero. PIO
READID and both ONFI CRCs remained valid afterward.

Patch `0019-mtd-nand-test-berlin2cd-cfgw-descriptor.patch` validates the first
peripheral instruction before combining it with NAND request semaphores. It
uses one eight-byte `CFGW` descriptor to toggle `NDTR0` bit zero while the NFC
is idle, verifies that `NDCR`, `NDSR`, and `NDTR1` did not change, and submits
the same descriptor again to restore the original `NDTR0`. The address is
derived from the NFC platform resource and checked against pBridge's
`BCM-base`; it is not a duplicated physical-address constant.

The shared submit helper changes patch `0019`'s NULL submission message to
`pBridge submitting NULL descriptor: dma=... size=4 ...`; the descriptor
contents remain `0x0000000f`.

Expected success after the patch `0018` messages is:

```text
pBridge submitting CFGW timing-test descriptor: dma=... size=8 queue=6 slot=1 command=10000008:...
pBridge CFGW timing-test descriptor completed: ... queue producer=0/0 consumer=0/0 ...
pBridge CFGW timing test observed NDTR0 transition: 84840a12 -> 84840a13
pBridge submitting CFGW timing-restore descriptor: dma=... size=8 queue=6 slot=0 command=10000008:...
pBridge CFGW timing-restore descriptor completed: ... queue producer=0/1 consumer=0/1 ...
pBridge reversible CFGW register test passed without a NAND command
```

This is still a controller-register transport test. It does not set `ND_RUN`,
write an NDCB register, issue a NAND command, access NAND data or register an
MTD. If the pBridge restore cannot be submitted after an idle failure, the
driver restores `NDTR0` through the CPU. If any transport diagnostic fails,
the driver remains bound with its clocks and IRQ available for inspection but
skips all subsequent PIO NAND identification, avoiding a race with a late
descriptor.

Do not hot-unbind the experimental controller. Writing the Berlin2CD platform
device name to the driver's sysfs `unbind` file hard-locked the Steam Link
without an Oops or timeout reaching the persistent journal. Patch `0008`
suppresses the generic bind/unbind controls; normal boot probing remains
unchanged.

The probe patch treats Berlin2CD as NFCv2 for timing and register capabilities,
but deliberately uses the explicit NFCv1 command parser for READID and RESET.
It also has a dedicated identification-only cleanup path, since the ordinary
NAND cleanup assumes that later manufacturer initialization already happened.

## Next implementation stages

1. Boot patch `0019` and verify both reversible `CFGW` descriptors complete
   without changing any register except the temporary `NDTR0` bit.
2. Port the first pBridge NAND descriptor with bounded polling, initially
   executing only a read-only READID transfer.
3. Implement repeated raw page reads with BCH disabled and explicitly test
   randomizer behavior before decoding production data.
4. Add 48-bit-per-2-KiB BCH handling and compare corrected reads against the
   raw captures before registering any MTD.
5. Register a read-only MTD and validate full-device hashes, bad-block markers
   and ECC statistics.
6. Add read-retry support if the confirmed ID requires it.
7. Put erase/program support behind an explicit Kconfig opt-in, then test only
   on disposable blocks after verified USB recovery.

The staged transport implementation, beginning with a NAND-independent BCM
`NULL` descriptor, is detailed in
[pbridge-descriptor-plan.md](pbridge-descriptor-plan.md).

GPU work is separate. Etnaviv is already upstream in modern Linux and the GC1000
register block does not replace the NAND pBridge engine.

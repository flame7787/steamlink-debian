# Berlin2CD pBridge descriptor plan

This plan starts only after the disabled queue test in patch `0017` explains
the unexpected queue 7 consumer. The first descriptor milestone deliberately
does not access the NAND controller or flash.

## Confirmed vendor layout

Valve configures four 32-byte-MTU dHub channels. Channel 3 is the NFC device
control channel:

| Item | ID | TCM base | Depth |
| --- | ---: | ---: | ---: |
| Channel 3 command queue | 6 | `0x330` | 2 entries |
| Channel 3 data queue | 7 | `0x340` | 32 entries |
| Channel 3 completion semaphore | 3 | n/a | 1 |
| NFC command-request semaphore | 12 | n/a | 1 |
| NFC data-request semaphore | 13 | n/a | 1 |
| NFC data-complete semaphore | 24 | n/a | 1 |

A dHub command is one 64-bit queue entry:

```text
word 0: 32-bit descriptor physical address
word 1: size[15:0], sizeMTU[16], semOpMTU[17],
        chkSemId[22:18], updSemId[27:23], interrupt[28]
```

The command and descriptor addresses are full 32-bit physical addresses.
BCM peripheral instructions use a 28-bit device address combined with the
top nibble programmed in `BCM_base`. For the NFC at `0xf7f00000`, the current
`BCM_base=f0000000` and low-28-bit register offsets are correct.

## Milestone 1: NULL descriptor fetch

Allocate one coherent, 4-byte-aligned descriptor after setting a 32-bit DMA
mask. Encode fields explicitly as a little-endian word instead of importing
Valve's compiler-dependent C bitfields. The generated vendor `pBridge.h`
defines `BCMINSFMT` as a four-byte instruction whose header occupies bits
3 through 0.

The descriptor contains one BCM `NULL` instruction:

```text
descriptor word 0 = 0x0000000f
```

The queue 6 dHub command remains one 64-bit queue entry and requests a
four-byte descriptor fetch:

```text
command word 0 = lower_32_bits(descriptor_dma_address)
command word 1 = 0x10000004
```

`0x10000004` requests byte size 4 and channel completion notification. It does
not use a check or update semaphore and does not encode size in MTUs.

Before submission:

1. Require dHub busy/pending and HBO busy to be zero.
2. Require queue 6 and channel semaphore 3 counts to be zero.
3. Clear their stale full-condition bits and record the empty conditions.
4. Require `BCM-error=0`.
5. Verify the coherent address fits in 32 bits and is 4-byte aligned.

Submit by writing the two command words to queue 6's current producer slot,
publishing them with `dma_wmb()`, and pushing one token to the HBO SemaHub.
Use bounded polling only.

Success requires:

1. Queue 6 producer and consumer pointers each advance once.
2. Channel semaphore 3 reaches count one.
3. dHub busy and pending return to zero.
4. HBO busy returns to zero.
5. `BCM-error` remains zero.
6. Popping semaphore 3 returns its count to zero.
7. NAND `NDCR`, `NDSR`, `NDTR0`, and `NDTR1` remain unchanged.

On a completion timeout, log queue 6, queue 7, channel 3, dHub busy/pending,
HBO busy, BCM error/address, and all four NAND registers. Do not retry, clear
the channel or issue a pBridge bus reset automatically after submission. The
descriptor uses managed coherent memory so its address remains valid if the
engine completes late. Keep MTD registration disabled and reboot into the
previous image if the engine remains active.

Hardware running patch `0018` completed the NULL descriptor repeatably. Queue
6 producer and consumer pointers advanced from zero to one, every engine
returned idle, `BCM-error` stayed zero and the NAND register snapshot was
unchanged. The completion semaphore's consumer query reached count one and
the full condition asserted, while its producer query stayed at zero. This is
the stable hardware representation for a dHub-generated channel completion;
the consumer count and full event are therefore authoritative.

## Milestone 1b: reversible CFGW descriptor

Before issuing the multi-instruction READID function, validate BCM peripheral
addressing and the generated `CFGW` encoding in isolation. A `CFGW` is two
little-endian words:

```text
word 0: 32-bit value to write
word 1 bits 27:0: low 28 bits of the peripheral address
word 1 bits 31:28: CFGW header 0
```

Resolve the NFC physical base from its named platform resource. Require its
top nibble to match `BCM_base`, then encode `NFC_base + NDTR0` in the low 28
bits. Do not hard-code the NFC physical address in the descriptor builder.

With the controller idle, snapshot `NDCR`, `NDSR`, `NDTR0`, and `NDTR1`.
Submit an eight-byte descriptor that changes only bit zero of `NDTR0`, verify
the exact transition, then reuse the descriptor to restore the snapshot and
verify all four registers. The bit changes the inactive controller's timing
value only; neither descriptor sets `ND_RUN`, writes an NDCB register or
accesses NAND.

Each submission uses the bounded Milestone 1 transport checks. Queue 6 starts
at the current producer slot, so the first `CFGW` wraps both pointers from one
to zero and the restore advances them back to one. On a failed restore, use a
CPU register write only if all pBridge engines have returned idle. If any
transport milestone fails, keep the probe-only platform driver bound for
diagnostics but skip PIO NAND identification so a late descriptor cannot race
with a NAND command.

## Milestone 2: read-only READID descriptor

Only after the NULL descriptor completes repeatably should channel 3 execute a
BCM function that accesses NAND. Valve's original READID function is seven
instructions:

1. `SEMA`: wait as consumer on semaphore 12 (`dHub_NFCCmd`).
2. `CFGW`: write READID `NDCB0`.
3. `CFGW`: write `NDCB1`.
4. `CFGW`: write `NDCB2`.
5. `SEMA`: wait as consumer on semaphore 13 (`dHub_NFCDat`).
6. `WCMD`: describe an eight-byte write into coherent memory and update
   semaphore 24 (`NFC_DATA_CP`) on completion.
7. `WDAT`: move eight bytes from `NDDB` into the write-data channel.

Do not copy Valve's READID command word verbatim. Build the four NDCB words
with the modern driver's already validated NFCv1 parser, including `LEN_OVRD`
and `NDCB3=8`. This requires a fourth `CFGW`, making the modern descriptor
eight instructions. Compare the DMA result against a PIO READID in the same
boot and require two matching `2c 68 04 4a` prefixes.

The first READID implementation remains probe-only:

- no MTD registration;
- no page, OOB, erase, program, ECC, or randomizer operation;
- no interrupt dependency;
- no unbounded waits or automatic retries;
- no runtime bind/unbind controls.

## Deferred work

Raw page reads need a separate design for 4 KiB page transfers, randomizer
state, BCH-24-per-1024-byte correction, OOB layout, bad-block markers, and read
retry. None of those should be mixed into descriptor transport validation.

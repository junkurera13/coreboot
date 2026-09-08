/* SPDX-License-Identifier: GPL-2.0-only */

#include <acpi/acpi.h>
#include <arch/io.h>
#include <arch/ioapic.h>
#include <assert.h>
#include <bootmode.h>
#include <device/pci_ops.h>
#include <device/pci_type.h>
#include <halt.h>
#include <stdint.h>

#include "pmbase.h"
#include "pmutil.h"

/* LPC PM Base Address Register */
#define PMBASE		0x40
#define PMSIZE		0x80

u16 lpc_get_pmbase(void)
{
#ifdef __SIMPLE_DEVICE__
	/* Don't assume PMBASE is still the same */
	return pci_read_config16(PCI_DEV(0, 0x1f, 0), PMBASE) & 0xfffc;
#else
	static u16 pmbase;

	if (pmbase)
		return pmbase;

	pmbase = pci_read_config16(pcidev_on_root(0x1f, 0), PMBASE) & 0xfffc;

	return pmbase;
#endif
}

void write_pmbase32(const u8 addr, const u32 val)
{
	ASSERT(addr <= (PMSIZE - sizeof(u32)));

	outl(val, lpc_get_pmbase() + addr);
}

void write_pmbase16(const u8 addr, const u16 val)
{
	ASSERT(addr <= (PMSIZE - sizeof(u16)));

	outw(val, lpc_get_pmbase() + addr);
}

void write_pmbase8(const u8 addr, const u8 val)
{
	ASSERT(addr <= (PMSIZE - sizeof(u8)));

	outb(val, lpc_get_pmbase() + addr);
}

u32 read_pmbase32(const u8 addr)
{
	ASSERT(addr <= (PMSIZE - sizeof(u32)));

	return inl(lpc_get_pmbase() + addr);
}

u16 read_pmbase16(const u8 addr)
{
	ASSERT(addr <= (PMSIZE - sizeof(u16)));

	return inw(lpc_get_pmbase() + addr);
}

u8 read_pmbase8(const u8 addr)
{
	ASSERT(addr <= (PMSIZE - sizeof(u8)));

	return inb(lpc_get_pmbase() + addr);
}

int acpi_get_sleep_type(void)
{
	/*
	 * QEMU's ACPI PM (hw/acpi/core.c) maps SLP_TYP 1 to S3 and 0 to S5,
	 * unlike ICH9 (5 and 7). On wake it also resets PM1_CNT, so SLP_TYP is
	 * no longer S3, while PM1_STS.WAK_STS remains set. Treat WAK_STS as
	 * S3 once PMBASE is programmed; real ICH9 still uses SLP_TYP below.
	 */
	if (CONFIG(BOARD_EMULATION_QEMU_X86_Q35)) {
		if (lpc_get_pmbase() && (read_pmbase16(PM1_STS) & WAK_STS))
			return ACPI_S3;
	}

	return acpi_sleep_from_pm1(read_pmbase32(PM1_CNT));
}

/*
 * Note that southbridge_detect_s3_resume clears the sleep state,
 * so this may not be used reliable throughout romstage.
 */
int platform_is_resuming(void)
{
	u16 reg16;

	if (!lpc_get_pmbase())
		return 0;

	reg16 = read_pmbase16(PM1_STS);
	if (!(reg16 & WAK_STS))
		return 0;

	return acpi_get_sleep_type() == ACPI_S3;
}

void poweroff(void)
{
	uint32_t pm1_cnt;

	pm1_cnt = read_pmbase32(PM1_CNT);
	if (CONFIG(BOARD_EMULATION_QEMU_X86_Q35)) {
		/* QEMU ACPI PM: SLP_TYP 0 + SLP_EN is soft-off. */
		pm1_cnt &= ~SLP_TYP;
		pm1_cnt |= SLP_EN;
	} else {
		/* Go to S5 (SLP_TYP=7 | SLP_EN). */
		pm1_cnt |= (0xf << 10);
	}
	write_pmbase32(PM1_CNT, pm1_cnt);
}

#define ACPI_SCI_IRQ	9

void ioapic_get_sci_pin(u8 *gsi, u8 *irq, u8 *flags)
{
	*gsi = ACPI_SCI_IRQ;
	*irq = ACPI_SCI_IRQ;
	*flags = MP_IRQ_TRIGGER_LEVEL | MP_IRQ_POLARITY_HIGH;
}

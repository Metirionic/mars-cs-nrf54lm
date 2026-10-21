/*
 * Copyright (c) 2026 Metirionic
 *
 * SPDX-License-Identifier: MIT
 */

/** @file
 *  @brief Shared native USB bring-up module (device-next + CDC ACM)
 */

#ifndef MARS_USB_H
#define MARS_USB_H

#include <stdbool.h>

/**
 * @brief Initialize the shared USB device context.
 *
 * Builds the device context, string descriptors, full-speed and high-speed
 * configurations, and CDC ACM class registrations, then initializes the
 * device-next stack. It does not connect the device: the UDC is enabled from
 * the VBUS-ready message and disabled on VBUS removal, so boot never blocks
 * on USB and CDC ACM serial initialization never runs at boot (NCSDK-38624).
 *
 * Must be called after bt_enable(), so MPSL and the shared HFCLK24M are
 * already initialized (DRGN-29129 / DRGN-29277).
 *
 * @return 0 on success, negative errno on failure.
 */
int mars_usb_init(void);

/**
 * @brief Whether the host has configured (enumerated) the device.
 *
 * Output produced while this is false is dropped and counted by the USB COBS
 * backend rather than buffered without bound.
 *
 * @return true once a non-zero configuration has been selected by the host.
 */
bool mars_usb_is_configured(void);

#endif /* MARS_USB_H */

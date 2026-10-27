/*
 * Copyright (c) 2026 Metirionic
 *
 * SPDX-License-Identifier: MIT
 */

/** @file
 *  @brief CS liveness watchdog — recovers from permanent CS abort-storms (#116)
 *
 *  During the #116 abort-storm every procedure's subevents abort at the LL
 *  while the BLE ACL + RAS GATT path stays healthy: empty Ranging Data frames
 *  keep flowing at ~5/s, so a watchdog keyed on link state or frame flow never
 *  fires. This watchdog instead keys on *completed procedures with step data*
 *  and forces the existing disconnect -> reboot-on-disconnect recovery when
 *  none arrive within CONFIG_MARS_CS_LIVENESS_WATCHDOG_TIMEOUT_MS.
 *
 *  The watchdog is inert until the first pet (lazy arm), so the connection
 *  handshake and any pre-CS gaps never false-trigger it.
 */

#ifndef CS_WATCHDOG_H
#define CS_WATCHDOG_H

#include <zephyr/bluetooth/hci_types.h>

/**
 * @brief Disconnect reason the role recovery callbacks pass to bt_conn_disconnect().
 *
 * The semantically correct value is BT_HCI_ERR_LOCALHOST_TERM_CONN (0x16), but
 * the SoftDevice Controller rejects it: the host logs `opcode 0x0406 status
 * 0x12` (Invalid HCI Command Parameters) and bt_conn_disconnect() returns
 * -EINVAL, so the disconnect never happens. Reason 0x13 is accepted, returns
 * 0, and the resulting Disconnection Complete is reported as 0x16 anyway.
 * Observed on the pinned NCS v3.4.1 release (and its predecessor).
 */
#define CS_WATCHDOG_DISCONNECT_REASON BT_HCI_ERR_REMOTE_USER_TERM_CONN

/**
 * @brief Recovery callback invoked on watchdog expiry.
 *
 * Invoked from system-workqueue thread context, never from an ISR, so it may
 * block. Must force recovery: disconnect the connection (both boards reboot
 * via the existing disconnected_cb -> sys_reboot path) or reboot directly.
 *
 * The timer expiry itself runs in the system clock interrupt. It arms a hard
 * backstop reboot and dispatches this callback to the system workqueue; the
 * backstop fires if the work never starts.
 */
typedef void (*cs_watchdog_recovery_t)(void);

/**
 * @brief Initialize the CS liveness watchdog.
 *
 * @param recovery  Callback invoked on expiry from the system workqueue;
 *                  may be NULL (log-only).
 */
void cs_watchdog_init(cs_watchdog_recovery_t recovery);

/**
 * @brief Pet the watchdog — restart the timeout.
 *
 * Called once per completed CS procedure with step data. The first pet arms
 * the timer; every pet re-arms it. Must stay non-blocking and ISR-callable.
 *
 * With CONFIG_MARS_CS_LIVENESS_WATCHDOG_TEST_NO_PET=y the timer is armed once
 * on the first pet and never re-armed; later pets leave it running, so the
 * watchdog fires ~timeout after the first healthy procedure (test hook for
 * deterministically exercising the recovery loop).
 */
void cs_watchdog_pet(void);

#endif /* CS_WATCHDOG_H */

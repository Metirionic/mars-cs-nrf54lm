/*
 * Copyright (c) 2026 Metirionic
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef COBS_TX_H__
#define COBS_TX_H__

#include <stddef.h>
#include <stdint.h>
#include <zephyr/kernel.h>

/**
 * @brief Largest complete serialization run the seam accepts.
 *
 * Two worst-case serialized events (see CHUNK_SIZE in serialize.c) plus a
 * standalone log frame and margin. The serializer sizes its run buffer with
 * this value and the USB backend sizes its full-run ring with it, so a run
 * can always be enqueued atomically.
 *
 * The size is independent of CONFIG_BT_CTLR_SDC_CS_MAX_ANTENNA_PATHS: the
 * mars-bluetooth-hci wire format's Mode2 tone arrays are fixed at
 * MAX_ANTENNA_PATH_COUNT + 1 entries (four paths plus the extension slot), so
 * the four-path product policy leaves this buffer unchanged. See the
 * antenna-path policy in docs/hardware.md.
 */
#define COBS_TX_RUN_MAX_SIZE 29000u

/**
 * @brief Worst-case drain time a backend may need for a small submitted run.
 *
 * The bounded terminal-frame path reserves this much of its budget for the
 * drain, so the acquisition wait cannot starve it and leave the reboot to cut
 * a submitted frame. The USB backend also uses it as its settle window: the
 * CDC ACM UART API exposes no TX-complete signal, so the class ring and the
 * USB IN transfer that follow the backend's full-run ring get this much time.
 */
#define COBS_TX_IDLE_BOUND_MS 50

/**
 * @brief Reserve the COBS transmit path for the next serialization run.
 *
 * Waits until the transport can accept a run and the run buffer may be filled
 * again: the previously submitted run must have completed transmission before
 * its bytes are overwritten. Must be called before writing into the run
 * buffer; a successful call is either consumed by cobs_tx_write() or given
 * back with cobs_tx_release().
 *
 * A backend may impose its own bound even when timeout is K_FOREVER. The USB
 * backend does, so a stalled host turns into a counted run drop and -EAGAIN
 * instead of blocking the consumer.
 *
 * @param timeout  Wait limit for the previous run to complete.
 * @return 0 on success, -EAGAIN on timeout, or another negative errno when the
 *         transport could not be initialized.
 */
int cobs_tx_acquire(k_timeout_t timeout);

/**
 * @brief Submit one complete serialization run to the transport.
 *
 * The buffer must hold a complete COBS-encoded run. The transport never
 * splits or re-frames it. On success it owns the run until transmission
 * completes; the caller must not touch the buffer until the next successful
 * cobs_tx_acquire().
 *
 * On failure nothing was submitted and the caller keeps the acquisition: the
 * buffer is still writable, and the caller must either retry or call
 * cobs_tx_release().
 *
 * @param p_data   Complete COBS-encoded run.
 * @param size     Run size in bytes.
 * @param timeout  Wait limit for transport-specific transmit space. The
 *                 acquisition already reserved the run buffer; a transport
 *                 whose submission is asynchronous ignores this.
 * @return 0 if the run was accepted, negative errno otherwise.
 */
int cobs_tx_write(const uint8_t * p_data, size_t size, k_timeout_t timeout);

/**
 * @brief Give back an acquired run that was never submitted.
 *
 * Releases the path reserved by cobs_tx_acquire() when no run was submitted
 * (for example after a serialization failure). Must not be called after a
 * successful cobs_tx_write() — that run releases the path on completion.
 */
void cobs_tx_release(void);

/**
 * @brief Wait, bounded, for a submitted run to leave the firmware's buffers.
 *
 * The terminal-frame path (the initiator's disconnect emission) calls this
 * after a successful cobs_tx_write() and before sys_reboot(): the write path
 * is asynchronous, so without the wait the reset can cut the frame. "Left the
 * buffers" is backend-defined: the VCOM backend waits for the UART async
 * TX-done signal; the USB backend waits for its full-run ring to be handed to
 * the CDC ACM driver and then gives that driver's own ring and the USB IN
 * transfer a bounded settle window. With nothing in flight the wait completes
 * without blocking on a transfer; the USB backend still spends its settle
 * window, because the driver ring and the IN transfer are part of what it
 * drains.
 *
 * @param timeout  Wait limit. A backend may apply its own bound even when
 *                 timeout is K_FOREVER (the USB backend does), so a stalled
 *                 host cannot hold the caller past that bound.
 * @return 0 if no submitted run is still in the backend's buffers, -EAGAIN if
 *         one remained when the wait expired.
 */
int cobs_tx_idle(k_timeout_t timeout);

#endif /* COBS_TX_H__ */

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
 * @brief Reserve the COBS transmit path for the next serialization run.
 *
 * Waits until the transport can accept a run and the run buffer may be filled
 * again: the previously submitted run must have completed transmission before
 * its bytes are overwritten. Must be called before writing into the run
 * buffer; a successful call is either consumed by cobs_tx_write() or given
 * back with cobs_tx_release().
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

#endif /* COBS_TX_H__ */

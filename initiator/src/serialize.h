/*
 * Copyright (c) 2024 Nordic Semiconductor ASA
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef SERIALIZE_H__
#define SERIALIZE_H__

#include <zephyr/kernel.h>

#include "mars_bluetooth_hci.h"

/**
 * @brief Serialize populated SubeventResultEvents and transmit them.
 *
 * Hands each complete serialization run to the COBS transmit seam; the
 * build-selected backend owns the actual transport.
 *
 * @param p_local_event  Populated initiator SubeventResultEvent.
 * @param p_peer_event   Populated reflector SubeventResultEvent.
 */
void serialize_run(SubeventResultEvent_t * p_local_event, SubeventResultEvent_t * p_peer_event);

/**
 * @brief Serialize a log message and transmit it as a standalone run.
 *
 * Fault-path diagnostic entry point for events outside serialize_run
 * (e.g. the ranging data error path): the stall trigger that stops the
 * event stream is emitted here so a host capturing only the COBS stream can
 * see it. Honors the same transmit-path gate as serialize_run.
 *
 * @param p_message  NUL-terminated message.
 * @return 0 on success, negative errno on error.
 */
int serialize_send_log_message(const char * p_message);

/**
 * @brief Close the ranging stream: refuse every later run.
 *
 * The terminal disconnect frame (serialize_send_log_message_bounded) is the
 * one writer allowed after this call. serialize_run() and
 * serialize_send_log_message() return immediately once the stream is closed,
 * and serialize_run() re-checks after it acquires the path, so a consumer
 * that was waiting on the seam cannot submit a ranging run behind the
 * terminal frame. Any run already holding the path finishes first — the
 * bounded send waits for it.
 *
 * Called once, from the initiator's disconnect path, before the reboot.
 */
void serialize_close_stream(void);

/**
 * @brief Send a standalone log frame and wait, bounded, for it to drain.
 *
 * Terminal-frame variant of serialize_send_log_message(): acquires the seam,
 * serializes the message as one complete run, submits it, and waits for it to
 * leave the transport's buffers. The whole sequence — acquire, serialize,
 * submit, drain — is bounded by @p timeout; a ranging run in flight, a stalled
 * host, or a wedged transport consumes the budget and this returns without
 * the frame being complete. The caller (the disconnect path) reboots either
 * way, so the frame is best effort and the reboot wins. K_FOREVER removes the
 * bound; the disconnect path always passes a finite one.
 *
 * Not gated by serialize_close_stream(): this is the frame that closes the
 * stream. Call serialize_close_stream() first so no run can follow it.
 *
 * @param p_message  NUL-terminated message.
 * @param timeout    Bound on the whole emission.
 * @return 0 if the frame was submitted and drained within the bound, negative
 *         errno otherwise (-EAGAIN when a wait expired).
 */
int serialize_send_log_message_bounded(const char * p_message, k_timeout_t timeout);

#endif /* SERIALIZE_H__ */

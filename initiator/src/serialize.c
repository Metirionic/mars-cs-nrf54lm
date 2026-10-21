/*
 * Copyright (c) 2024 Nordic Semiconductor ASA
 *
 * SPDX-License-Identifier: MIT
 */

/** @file
 *  @brief Channel Sounding data serializer
 */

#include "serialize.h"

#include <string.h>
#include <zephyr/logging/log.h>

#include "cobs_tx.h"
#include "subevent.h"

LOG_MODULE_DECLARE(app_main, LOG_LEVEL_INF);

#include "mars_bluetooth_hci.h"

/** @brief Max COBS-serialized size of ONE SubeventResultEvent (160 steps).
 *
 * Sized for mars-bluetooth-hci 0.13.2: ModeRoleSpecificInfo serializes a
 * mode0 field (quality, RSSI, antenna, measured_freq_offset u16) on EVERY
 * step alongside the mode1/mode2 fields, so sizes now depend on values
 * (postcard varints: the freq offset is 1 B when 0, 3 B for the 0xC000
 * sentinel). Measured per-event COBS sizes (host harness, 160 steps):
 *   13,302 B  zeroed (lower bound)
 *   13,955 B  realistic FW population (real MACs, populated mode0 + mode2)
 *   13,968 B  worst case (every varint maximized)
 * 14,000 B keeps headroom over the measured worst case; g_serialized below
 * holds two events plus a log message plus ~1 KB margin. 0.8.0 was ~8,640
 * B/event with no mode1 field; 0.12.0 was 12,502 B/event zeroed.
 */
#define CHUNK_SIZE 14000u

BUILD_ASSERT((CHUNK_SIZE * 2u + 1000u) == COBS_TX_RUN_MAX_SIZE,
             "CHUNK_SIZE sizing must match the COBS TX seam's full-run size");

/** @brief TX buffer for COBS-encoded serialized data. Leave margin for log messages. */
static uint8_t g_serialized[COBS_TX_RUN_MAX_SIZE];
/** @brief Total bytes written to g_serialized for the current run. */
static size_t g_total_written_size = 0u;

/**
 * @brief Append data to the global COBS run buffer.
 *
 * @return 0 on success, -ENOMEM if the data would overflow the buffer.
 */
static int serialize_cb(void * p_data, size_t size)
{
    if (g_total_written_size + size >= sizeof(g_serialized))
    {
        LOG_ERR("Serialization buffer overflow: %u + %u >= %u", g_total_written_size, size, sizeof(g_serialized));
        return -ENOMEM;
    }
    memcpy(&g_serialized[g_total_written_size], p_data, size);
    g_total_written_size += size;
    return 0;
}

/** @brief Reset serialization state for a new run. */
static void serialize_init(void)
{
    g_total_written_size = 0u;
}

/**
 * @brief Serialize a log message and append to the global TX buffer.
 *
 * @return 0 on success, negative errno on error.
 */
static int serialize_append_log_message(const char * p_message)
{
    SerializedData_t result = serialize_log_message((int8_t const *)p_message, true);

    if (result.p_data != NULL && result.size != 0u)
    {
        int err = serialize_cb(result.p_data, result.size);
        drop_bin(result);
        return err;
    }

    drop_bin(result);
    return 0;
}

/**
 * @brief Serialize a SubeventResultEvent and append to the global TX buffer.
 *
 * @return 0 on success, negative errno on error.
 */
static int serialize_append_event(SubeventResultEvent_t * p_event)
{
    SerializedData_t result = serialize_subevent_result_event(p_event, true);

    if (result.p_data != NULL && result.size != 0u)
    {
        int err = serialize_cb(result.p_data, result.size);
        drop_bin(result);
        return err;
    }

    drop_bin(result);
    return 0;
}

/**
 * @brief Replace the in-flight buffer with a single log frame and transmit.
 *
 * Called while the run buffer is acquired (from serialize_run's failure
 * paths). The buffer may hold an unusable partial frame, so it is reset
 * before appending the marker. Returns the cobs_tx_write result: on success
 * the backend releases the path when the transfer completes; on failure
 * the caller still holds the acquisition and must release it.
 */
static int serialize_send_log_message_locked(const char * p_message)
{
    serialize_init();
    (void)serialize_append_log_message(p_message);
    return cobs_tx_write(g_serialized, g_total_written_size, K_FOREVER);
}

int serialize_send_log_message(const char * p_message)
{
    int err = cobs_tx_acquire(K_FOREVER);
    if (err)
    {
        return err;
    }

    serialize_init();

    err = serialize_append_log_message(p_message);
    if (err)
    {
        cobs_tx_release();
        return err;
    }

    err = cobs_tx_write(g_serialized, g_total_written_size, K_FOREVER);
    if (err)
    {
        /* Nothing was submitted: release the path so the next run does not
         * hang (the write contract leaves the acquisition with the caller). */
        cobs_tx_release();
    }

    return err;
}

/**
 * @brief Serialize populated SubeventResultEvents and transmit them.
 *
 * COBS-encodes two SubeventResultEvent structures (initiator + reflector)
 * via the Rust FFI and hands the complete run to the transport's COBS
 * transmit seam. The events must already be populated (via subevent_populate
 * or subevent_populate_inline) before calling this function.
 *
 * @param p_local_event  Populated initiator SubeventResultEvent.
 * @param p_peer_event   Populated reflector SubeventResultEvent.
 */
void serialize_run(SubeventResultEvent_t * p_local_event, SubeventResultEvent_t * p_peer_event)
{
    /* Gate: do not reuse g_serialized until the previous async TX completed.
     * In steady state the prior TX finishes ~1-16 ms before the next procedure
     * completes, so this returns immediately; under jitter it blocks only for
     * the brief overshoot, in the quiet gap before the next procedure's first
     * subevent. The path is released by the backend when the transfer
     * completes (or via cobs_tx_release() when submission failed).
     */
    if (cobs_tx_acquire(K_FOREVER))
    {
        return;
    }

    serialize_init();

    LOG_INF("Run serialization for procedure %u", p_local_event->initial_meta.procedure_counter);

    int err;

    err = serialize_append_event(p_local_event);
    if (err)
    {
        LOG_ERR("Failed to serialize local event (err %d)", err);
        /* Fault-path diagnostic: the buffer holds a partial event frame
         * that would not decode on the host, so replace it with a standalone
         * log frame (e.g. the -12 overflow from a wire-format size mismatch).
         */
        if (serialize_send_log_message_locked("Serialize error: local event") < 0)
        {
            cobs_tx_release();
        }
        return;
    }

    err = serialize_append_event(p_peer_event);
    if (err)
    {
        LOG_ERR("Failed to serialize peer event (err %d)", err);
        if (serialize_send_log_message_locked("Serialize error: peer event") < 0)
        {
            cobs_tx_release();
        }
        return;
    }

    err = serialize_append_log_message("Processing finished");
    if (err)
    {
        LOG_ERR("Failed to serialize log (err %d)", err);
        if (serialize_send_log_message_locked("Serialize error: log") < 0)
        {
            cobs_tx_release();
        }
        return;
    }

    err = cobs_tx_write(g_serialized, g_total_written_size, K_FOREVER);

    LOG_INF("Sending %u bytes", g_total_written_size);

    if (err)
    {
        LOG_ERR("UART TX failed (err %d)", err);
        /* Nothing was submitted: the buffer still holds valid frames — append
         * a failure marker and retry once so the host sees the cause instead
         * of a silent gap. The acquisition is retained on a failed write, so
         * the buffer is still ours to extend. */
        (void)serialize_append_log_message("UART TX error");
        err = cobs_tx_write(g_serialized, g_total_written_size, K_FOREVER);
        if (err)
        {
            /* Second failure: release the path so the next run does not hang. */
            cobs_tx_release();
        }
    }
}

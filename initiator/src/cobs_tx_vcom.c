/*
 * Copyright (c) 2026 Metirionic
 *
 * SPDX-License-Identifier: MIT
 */

/** @file
 *  @brief VCOM COBS transmit backend (asynchronous UART)
 */

#include <zephyr/drivers/uart.h>
#include <zephyr/logging/log.h>

#include "cobs_tx.h"

LOG_MODULE_DECLARE(app_main, LOG_LEVEL_INF);

/** @brief UART device used for COBS output. */
static const struct device * gp_cobs_uart_dev = DEVICE_DT_GET(DT_CHOSEN(cobs_uart));

/** @brief UART TX-done gate: count 1 when no async TX is in progress.
 *
 * Taken by cobs_tx_acquire() before the caller reuses the run buffer; given by
 * the UART async callback on UART_TX_DONE / UART_TX_ABORTED, or by the caller's
 * cobs_tx_release() when no run was submitted (serialization failure or a
 * failed uart_tx()). Mirrors the sem_local_steps "buffer available" pattern in
 * common/cs_initiator.c, keeping uart_tx from ever being called while a
 * previous transfer is still DMA-ing out of the run buffer.
 */
static K_SEM_DEFINE(sem_tx_done, 1, 1);

/** @brief One-time UART async init guard (callback registered on first use). */
static bool g_uart_async_init_done;

/**
 * @brief UART async callback: signals TX completion to release sem_tx_done.
 *
 * TX-only path: only UART_TX_DONE and UART_TX_ABORTED are handled (RX events
 * are unused). k_sem_give() is ISR-safe, so the give from the UARTE ISR cannot
 * deadlock against the k_sem_take() performed in cobs_tx_acquire() by any
 * caller (BT RX thread, main loop thread, or system workqueue). UART_TX_ABORTED
 * is not expected in practice (no hardware flow control on the COBS UART
 * overlays and uart_tx() uses SYS_FOREVER_MS), but is handled defensively so
 * the gate never sticks.
 */
static void cobs_uart_async_cb(const struct device * p_dev, struct uart_event * p_evt, void * p_user_data)
{
    ARG_UNUSED(p_dev);
    ARG_UNUSED(p_user_data);

    switch (p_evt->type)
    {
    case UART_TX_DONE:
        k_sem_give(&sem_tx_done);
        break;
    case UART_TX_ABORTED:
        LOG_WRN("COBS UART TX aborted (%u bytes sent)", (unsigned)p_evt->data.tx.len);
        k_sem_give(&sem_tx_done);
        break;
    default:
        /* RX events unused (TX-only path). */
        break;
    }
}

/**
 * @brief Register the async UART callback once, on first use.
 *
 * @return 0 on success, negative errno on error.
 */
static int cobs_tx_vcom_init(void)
{
    if (g_uart_async_init_done)
    {
        return 0;
    }

    if (!device_is_ready(gp_cobs_uart_dev))
    {
        LOG_ERR("COBS UART device not ready");
        return -ENODEV;
    }

    int cb_err = uart_callback_set(gp_cobs_uart_dev, cobs_uart_async_cb, NULL);
    if (cb_err)
    {
        LOG_ERR("uart_callback_set failed (err %d)", cb_err);
        return cb_err;
    }

    g_uart_async_init_done = true;
    return 0;
}

int cobs_tx_acquire(k_timeout_t timeout)
{
    int err = cobs_tx_vcom_init();
    if (err)
    {
        return err;
    }

    return k_sem_take(&sem_tx_done, timeout);
}

int cobs_tx_write(const uint8_t * p_data, size_t size, k_timeout_t timeout)
{
    /* The acquisition already waited for the previous transfer, so the
     * submission cannot block; keep the pre-seam driver timeout unchanged. */
    ARG_UNUSED(timeout);

    return uart_tx(gp_cobs_uart_dev, p_data, size, SYS_FOREVER_MS);
}

void cobs_tx_release(void)
{
    k_sem_give(&sem_tx_done);
}

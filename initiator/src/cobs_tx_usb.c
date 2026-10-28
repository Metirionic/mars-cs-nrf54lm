/*
 * Copyright (c) 2026 Metirionic
 *
 * SPDX-License-Identifier: MIT
 */

/** @file
 *  @brief USB COBS transmit backend (CDC ACM, interrupt-driven UART API)
 *
 * The CDC ACM data UART is fed from a full-run ring owned by this backend.
 * A complete serialization run is copied into the ring in one operation once
 * the previous run has been fully handed to the CDC ACM driver, so runs never
 * interleave and a host stall cannot leave a partially enqueued run.
 *
 * The CDC ACM UART is drained from its IRQ callback, which is also the only
 * context that calls uart_fifo_fill() — the CDC ACM UART API requires the
 * driver's workqueue context. The initiator USB fragment moves that work to
 * the dedicated CDC ACM thread (CONFIG_USBD_CDC_ACM_WORKQUEUE), so the callback
 * can give the path back while the CS liveness watchdog's recovery work waits
 * on it from the system workqueue. The callback gives the path back when the
 * full-run ring empties.
 *
 * Host-stall policy: the acquire wait is bounded (CONFIG_MARS_CS_USB_TX_TIMEOUT_MS)
 * even when the serializer passes K_FOREVER. A run that does not fit in that
 * time is dropped and counted; the run already being drained keeps its place,
 * so the wire never sees a truncated run followed by a new one.
 */

#include <zephyr/drivers/uart.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/ring_buffer.h>

#include "cobs_tx.h"
#include "mars_usb.h"

LOG_MODULE_DECLARE(app_main, LOG_LEVEL_INF);

#if IS_ENABLED(CONFIG_MARS_CS_TRANSPORT_USB)

#define DT_DRV_COMPAT zephyr_cdc_acm_uart
#include <zephyr/devicetree.h>

/**
 * The role overlay declares the CDC ACM functions in interface order. The
 * initiator's data function must be instance 0 (chosen cobs-uart) and the
 * console instance 1, because the descriptor order is what the host's stable
 * by-id names (if00 data, if02 console) expose.
 *
 * The non-release debug posture (CONFIG_MARS_CS_USB_DEBUG_CONSOLE_VCOM) moves only
 * the log console to the J-Link VCOM: the data function stays instance 0 and
 * must still be the chosen cobs-uart, while the chosen console must not be a
 * CDC ACM function at all. The USB console function remains instance 1 in the
 * descriptor but nothing writes to it.
 */
#if IS_ENABLED(CONFIG_MARS_CS_ROLE_INITIATOR)
BUILD_ASSERT(DT_DEP_ORD(DT_CHOSEN(cobs_uart)) == DT_DEP_ORD(DT_DRV_INST(0)),
             "cobs-uart must be the first CDC ACM function (data first, console second)");
#if IS_ENABLED(CONFIG_MARS_CS_USB_DEBUG_CONSOLE_VCOM)
BUILD_ASSERT(!DT_NODE_HAS_COMPAT(DT_CHOSEN(zephyr_console), zephyr_cdc_acm_uart),
             "The USB debug console must be a non-CDC-ACM UART (the J-Link VCOM on the DK)");
#else
BUILD_ASSERT(DT_DEP_ORD(DT_CHOSEN(zephyr_console)) == DT_DEP_ORD(DT_DRV_INST(1)),
             "zephyr,console must be the second CDC ACM function (data first, console second)");
#endif
#endif

/** @brief CDC ACM data UART (the cobs-uart chosen node). */
static const struct device * gp_cobs_usb_dev = DEVICE_DT_GET(DT_CHOSEN(cobs_uart));

/** @brief One worst-case serialization run; the whole run is enqueued at once. */
RING_BUF_DECLARE(cobs_usb_tx_ring, COBS_TX_RUN_MAX_SIZE);

/** @brief Serializes producer (acquire/write/release) and IRQ-callback ring access. */
static struct k_spinlock g_tx_lock;

/** @brief Run-path gate: count 1 when no run is queued or draining. */
static K_SEM_DEFINE(sem_tx_free, 1, 1);

/** @brief Runs dropped because the host was absent/stalled or not enumerated. */
static atomic_t g_drop_count;

static bool g_initialized;

/**
 * @brief Count one dropped run and log the first and every 128th drop.
 *
 * Mirrors the RX-thread handoff gate's drop reporting so a host stall is
 * visible on the console without flooding it.
 */
static void cobs_usb_note_drop(const char * p_reason)
{
    uint32_t drops = (uint32_t)atomic_inc(&g_drop_count) + 1u;

    if ((drops == 1u) || ((drops % 128u) == 0u))
    {
        LOG_WRN("COBS USB: dropped run (%s), %u dropped", p_reason, drops);
    }
}

/**
 * @brief CDC ACM UART IRQ callback: drain the full-run ring into the driver.
 *
 * Runs on the CDC ACM workqueue — the driver's dedicated thread with
 * CONFIG_USBD_CDC_ACM_WORKQUEUE, the only context allowed to call
 * uart_fifo_fill(). It copies as much as the CDC ACM TX ring accepts and
 * stops when either the run ring is empty or the TX ring is full. The driver
 * resubmits this callback on the next TX completion, so no polling is needed.
 */
static void cobs_usb_irq_cb(const struct device * p_dev, void * p_user_data)
{
    ARG_UNUSED(p_user_data);

    k_spinlock_key_t key = k_spin_lock(&g_tx_lock);

    while (!ring_buf_is_empty(&cobs_usb_tx_ring))
    {
        uint8_t * p_data;
        uint32_t  len = ring_buf_get_claim(&cobs_usb_tx_ring, &p_data, ring_buf_size_get(&cobs_usb_tx_ring));

        if (len == 0u)
        {
            break;
        }

        int written = uart_fifo_fill(p_dev, p_data, (int)len);

        if (written < 0)
        {
            written = 0;
        }

        (void)ring_buf_get_finish(&cobs_usb_tx_ring, (uint32_t)written);

        if ((uint32_t)written < len)
        {
            /* CDC ACM TX ring is full; the next completion calls us again. */
            break;
        }
    }

    if (ring_buf_is_empty(&cobs_usb_tx_ring))
    {
        /* Disable unconditionally: a queued callback may have drained the
         * run before the producer enabled the IRQ, so the driver's
         * "IRQ enabled with space" condition must not be left set — it would
         * resubmit this callback forever on an empty ring. */
        uart_irq_tx_disable(p_dev);

        /* The run has been handed to the driver; the path is free. */
        k_sem_give(&sem_tx_free);
    }

    k_spin_unlock(&g_tx_lock, key);
}

/**
 * @brief One-time backend initialization (callback registration).
 *
 * @return 0 on success, negative errno on error.
 */
static int cobs_usb_init(void)
{
    if (g_initialized)
    {
        return 0;
    }

    if (!device_is_ready(gp_cobs_usb_dev))
    {
        LOG_ERR("COBS USB data UART not ready");
        return -ENODEV;
    }

    ring_buf_reset(&cobs_usb_tx_ring);
    uart_irq_callback_set(gp_cobs_usb_dev, cobs_usb_irq_cb);
    g_initialized = true;

    return 0;
}

/**
 * @brief Apply the bounded stall timeout to an acquire wait.
 *
 * The serializer asks for K_FOREVER because the VCOM backend only waits for
 * the previous DMA transfer. The USB backend must bound the wait so a host
 * stall cannot park the consumer thread forever.
 */
static k_timeout_t cobs_usb_acquire_timeout(k_timeout_t timeout)
{
    if (K_TIMEOUT_EQ(timeout, K_FOREVER))
    {
        return K_MSEC(CONFIG_MARS_CS_USB_TX_TIMEOUT_MS);
    }

    return timeout;
}

int cobs_tx_acquire(k_timeout_t timeout)
{
    int err = cobs_usb_init();

    if (err)
    {
        return err;
    }

    err = k_sem_take(&sem_tx_free, cobs_usb_acquire_timeout(timeout));
    if (err)
    {
        cobs_usb_note_drop("transport busy");
        return err;
    }

    return 0;
}

int cobs_tx_write(const uint8_t * p_data, size_t size, k_timeout_t timeout)
{
    /* The acquisition reserved the run path; enqueueing is a bounded copy
     * into the run ring, so the transport-specific wait is not used here. */
    ARG_UNUSED(timeout);

    if ((size == 0u) || (size > COBS_TX_RUN_MAX_SIZE))
    {
        LOG_ERR("COBS USB run has invalid size %u", (unsigned)size);
        return -EMSGSIZE;
    }

    if (!mars_usb_is_configured())
    {
        /* Nothing is buffered before the host enumerates: the output would be
         * stale by the time a capture opens. Count it like any other drop and
         * give the path back; the caller treats the run as handled. */
        cobs_usb_note_drop("not enumerated");
        k_sem_give(&sem_tx_free);
        return 0;
    }

    k_spinlock_key_t key     = k_spin_lock(&g_tx_lock);
    uint32_t         written = ring_buf_put(&cobs_usb_tx_ring, p_data, (uint32_t)size);

    if (written != size)
    {
        /* The ring is empty on entry, so this is a sizing bug, not backpressure. */
        ring_buf_reset(&cobs_usb_tx_ring);
        k_spin_unlock(&g_tx_lock, key);
        LOG_ERR("COBS USB run ring overflow (%u of %u bytes)", written, (unsigned)size);
        return -ENOSPC;
    }

    k_spin_unlock(&g_tx_lock, key);

    /* Enable after the run is in the ring: a callback that runs before this
     * point can already have drained the run, so the disable in the callback
     * must be unconditional. */
    uart_irq_tx_enable(gp_cobs_usb_dev);

    return 0;
}

void cobs_tx_release(void)
{
    k_spinlock_key_t key = k_spin_lock(&g_tx_lock);

    if (!ring_buf_is_empty(&cobs_usb_tx_ring))
    {
        /* Defensive: release must only follow a failed submission. */
        ring_buf_reset(&cobs_usb_tx_ring);
    }

    uart_irq_tx_disable(gp_cobs_usb_dev);
    k_sem_give(&sem_tx_free);
    k_spin_unlock(&g_tx_lock, key);
}

int cobs_tx_idle(k_timeout_t timeout)
{
    if (!g_initialized)
    {
        return 0;
    }

    if (!mars_usb_is_configured())
    {
        /* An unenumerated device's run is dropped in cobs_tx_write(), which
         * already gave the gate back, so nothing was buffered. */
        return 0;
    }

    int64_t start = k_uptime_get();
    int     err   = k_sem_take(&sem_tx_free, cobs_usb_acquire_timeout(timeout));

    if (err)
    {
        return -EAGAIN;
    }

    /* The full-run ring is empty: every byte is in the CDC ACM class ring or
     * already on the bus. Give the driver's ring and the IN transfer their
     * settle window (COBS_TX_IDLE_BOUND_MS), bounded by what is left of the
     * caller's budget. */
    int64_t settle_ms = COBS_TX_IDLE_BOUND_MS;

    if (!K_TIMEOUT_EQ(timeout, K_FOREVER))
    {
        int64_t left_ms = (int64_t)k_ticks_to_ms_ceil64(timeout.ticks) - (k_uptime_get() - start);

        if (left_ms < settle_ms)
        {
            settle_ms = left_ms;
        }
    }

    if (settle_ms > 0)
    {
        k_msleep((int32_t)settle_ms);
    }

    k_sem_give(&sem_tx_free);
    return 0;
}

#endif /* CONFIG_MARS_CS_TRANSPORT_USB */

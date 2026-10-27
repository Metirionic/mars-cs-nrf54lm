/*
 * Copyright (c) 2026 Metirionic
 *
 * SPDX-License-Identifier: MIT
 */

#include "cs_watchdog.h"

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/logging/log_ctrl.h>
#include <zephyr/sys/reboot.h>

LOG_MODULE_DECLARE(app_main, LOG_LEVEL_INF);

/** @brief Hard backstop: reboot if the recovery work has not started by then. */
#define WATCHDOG_BACKSTOP_TIMEOUT_MS 3000u

static cs_watchdog_recovery_t gp_recovery;

/**
 * @brief Hard backstop — runs in the system clock interrupt.
 *
 * Covers a wedged or permanently blocked system workqueue: the recovery work
 * never stops this timer, so the board reboots here instead of stalling the
 * recovery indefinitely. The log is flushed first because sys_reboot resets
 * the SoC without draining the deferred log queue.
 */
static void backstop_handler(struct k_timer * p_timer)
{
    ARG_UNUSED(p_timer);

    LOG_ERR("CS liveness watchdog: recovery did not start within %u ms; rebooting", WATCHDOG_BACKSTOP_TIMEOUT_MS);
    LOG_PANIC();

    sys_reboot(SYS_REBOOT_COLD);
}

static K_TIMER_DEFINE(backstop_timer, backstop_handler, NULL);

/**
 * @brief Recovery dispatch — runs on the system workqueue thread.
 *
 * The expiry ISR only submits this work, so the registered recovery runs in
 * thread context and may block: the initiator takes the COBS transmit gate
 * before emitting its banner, and both roles wait for the HCI disconnect
 * command. Both waits would assert inside the timer expiry (z_impl_k_sem_take
 * rejects a non-zero timeout in ISR context).
 *
 * Stopping the backstop is the first statement: the recovery is now running,
 * so the ISR must no longer reset the board underneath it.
 */
static void recovery_work_handler(struct k_work * p_work)
{
    ARG_UNUSED(p_work);

    k_timer_stop(&backstop_timer);

    LOG_ERR("CS liveness watchdog: no completed procedure with step data for %u ms; forcing recovery",
            CONFIG_MARS_CS_LIVENESS_WATCHDOG_TIMEOUT_MS);

    if (gp_recovery)
    {
        gp_recovery();
    }
}

static K_WORK_DEFINE(recovery_work, recovery_work_handler);

/**
 * @brief Watchdog expiry — runs in the system clock interrupt.
 *
 * Must not block: it arms the backstop and dispatches the recovery to the
 * system workqueue. The backstop guarantees a reboot even if that work never
 * gets to run.
 */
static void timeout_handler(struct k_timer * p_timer)
{
    ARG_UNUSED(p_timer);

    k_timer_start(&backstop_timer, K_MSEC(WATCHDOG_BACKSTOP_TIMEOUT_MS), K_NO_WAIT);

    (void)k_work_submit(&recovery_work);
}

static K_TIMER_DEFINE(watchdog_timer, timeout_handler, NULL);

void cs_watchdog_init(cs_watchdog_recovery_t recovery)
{
    gp_recovery = recovery;
}

void cs_watchdog_pet(void)
{
    if (!IS_ENABLED(CONFIG_MARS_CS_LIVENESS_WATCHDOG))
    {
        return;
    }

    if (IS_ENABLED(CONFIG_MARS_CS_LIVENESS_WATCHDOG_TEST_NO_PET))
    {
        /* Test hook (#116 desk bring-up): arm once on the first pet, never
         * re-arm — the watchdog fires ~timeout after the first healthy
         * procedure, deterministically exercising the recovery loop. */
        static bool armed;

        if (!armed)
        {
            armed = true;
            k_timer_start(&watchdog_timer, K_MSEC(CONFIG_MARS_CS_LIVENESS_WATCHDOG_TIMEOUT_MS), K_NO_WAIT);
        }
        return;
    }

    /* One-shot restart: lazy arm on the first pet, re-armed per pet. */
    k_timer_start(&watchdog_timer, K_MSEC(CONFIG_MARS_CS_LIVENESS_WATCHDOG_TIMEOUT_MS), K_NO_WAIT);
}

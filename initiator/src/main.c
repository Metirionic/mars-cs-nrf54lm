/*
 * Copyright (c) 2024 Nordic Semiconductor ASA
 *
 * SPDX-License-Identifier: MIT
 */

/** @file
 *  @brief Channel Sounding initiator with ranging requester sample
 */

#include <stdarg.h>
#include <stdio.h>
#include <zephyr/bluetooth/cs.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/reboot.h>

#if !defined(CONFIG_MARS_CS_INLINE_PCT)
#include <bluetooth/services/ras.h>
#endif

#include "addr_utils.h"
#include "antenna.h"
#include "ble_callbacks.h"
#include "cs_initiator.h"
#include "cs_watchdog.h"
#include "serialize.h"
#include "subevent.h"

LOG_MODULE_REGISTER(app_main, LOG_LEVEL_INF);

/** @brief Saved CS config from config creation callback (used for role in serialization). */
static struct bt_conn_le_cs_config cs_config;

/**
 * @brief Process a populated event pair by serializing it over the COBS UART.
 *
 * Called on the main loop thread from cs_initiator_consume_pending_event(); the RX thread only populates the shared
 * event pair — RAS from ranging_data_cb, IPT from the shared procedure-completion skeleton. The blocking serialize +
 * UART TX path must stay off the RX thread, where it would delay the SDC's step-data delivery until the controller
 * aborts the surplus subevents (#173 — numbers in docs/architecture.md).
 */
static void process_subevent_cb(SubeventResultEvent_t * p_local_event, SubeventResultEvent_t * p_peer_event)
{
#if IS_ENABLED(CONFIG_MARS_CS_INLINE_PCT)
    /* CS liveness watchdog (#116): the IPT skeleton hands over completed procedures with step data, and this thread
     * consumes them at the wire rate — so the pet paces at the consume rate, not the completion rate, and holds the
     * link while the wire keeps up (see #173). RAS keeps its v0.1.0 pet on the completion signal itself, in
     * ranging_data_cb, so a transport stall cannot turn into a watchdog recovery it did not have before. */
    cs_watchdog_pet();
#endif

    serialize_run(p_local_event, p_peer_event);
}

#if !IS_ENABLED(CONFIG_MARS_CS_INLINE_PCT)
/** @brief Emit a diagnostic message queued by the RX thread (consumer thread). */
static void process_log_cb(const char * p_message)
{
    (void)serialize_send_log_message(p_message);
}

/** @brief Queue a formatted COBS diagnostic frame for the consumer thread. */
static void queue_diagnostic(const char * p_format, ...)
{
    char    msg[CS_INITIATOR_LOG_MESSAGE_MAX_LEN];
    va_list args;

    va_start(args, p_format);
    vsnprintf(msg, sizeof(msg), p_format, args);
    va_end(args);

    cs_initiator_queue_log_message(msg);
}

/**
 * @brief Callback for ranging data received from peer (realtime or on-demand).
 *
 * Checks counter match, validates step data, populates the shared
 * SubeventResultEvents via subevent_populate, and hands them to the consumer
 * thread, which serializes and transmits — no serialize or transmit work runs
 * in this RX callback (#15). Fault-path diagnostics are queued for the same
 * consumer through cs_initiator_queue_log_message().
 */
static void ranging_data_cb(struct bt_conn * p_conn, uint16_t ranging_counter, int err)
{
    ARG_UNUSED(p_conn);

    if (err)
    {
        LOG_ERR("Error when receiving ranging data with ranging counter %d (err %d)", ranging_counter, err);
        /* Fault-path diagnostic: make the stall trigger visible on the COBS
         * UART — the host's only window into the initiator. */
        queue_diagnostic("RD error: counter %u, err %d", ranging_counter, err);

        /* Mirror the mismatch/aborted recovery below: the sem was taken at
         * the new-procedure gate in cs_initiator.c, and without this give
         * every subsequent procedure drops at the gate — the data path (and
         * COBS stream) stalls permanently (see #109). */
        net_buf_simple_reset(cs_initiator_get_local_steps());

        if (!(cs_initiator_get_ras_feature_bits() & RAS_FEAT_REALTIME_RD))
        {
            net_buf_simple_reset(cs_initiator_get_peer_steps());
        }

        cs_initiator_give_sem_local_steps();
        return;
    }

    int32_t local_ranging_counter = cs_initiator_get_local_ranging_counter();

    if (ranging_counter != local_ranging_counter)
    {
        LOG_INF(
            "Ranging data dropped as peer ranging counter doesn't match local ranging "
            "data counter. (peer: %u, local: %u)",
            ranging_counter,
            local_ranging_counter);

        queue_diagnostic("RD dropped: peer %u, local %u", ranging_counter, local_ranging_counter);

        net_buf_simple_reset(cs_initiator_get_local_steps());

        if (!(cs_initiator_get_ras_feature_bits() & RAS_FEAT_REALTIME_RD))
        {
            net_buf_simple_reset(cs_initiator_get_peer_steps());
        }

        cs_initiator_give_sem_local_steps();
        return;
    }

    LOG_DBG("Ranging data received for ranging counter %d", ranging_counter);

    struct net_buf_simple * latest_local_steps = cs_initiator_get_local_steps();

    if (latest_local_steps->len == 0)
    {
        LOG_WRN("All subevents in ranging counter %u were aborted", local_ranging_counter);

        queue_diagnostic("All subevents aborted: counter %u", local_ranging_counter);

        net_buf_simple_reset(latest_local_steps);
        cs_initiator_give_sem_local_steps();

        if (!(cs_initiator_get_ras_feature_bits() & RAS_FEAT_REALTIME_RD))
        {
            net_buf_simple_reset(cs_initiator_get_peer_steps());
        }
        return;
    }

    /* CS liveness watchdog (#116): the pet trigger is unchanged — a completed
     * procedure with step data, on the RX thread at the completion rate. The
     * blocking TX no longer runs on this thread, though, so a stalled consumer
     * no longer shows up as suppressed pets; it shows up as procedures dropped
     * at the handoff gate below (counted). The len==0 branch above deliberately
     * does NOT pet — during the abort-storm RDs keep arriving at 5/s but never
     * reach this point. */
    cs_watchdog_pet();

    /* The RX thread only populates and publishes the shared event pair; the
     * consumer thread runs the blocking serialize + TX (see
     * process_subevent_cb). The len==0 branch above deliberately does not
     * publish — there is nothing to consume. */
    SubeventResultEvent_t * p_local_event;
    SubeventResultEvent_t * p_peer_event;

    if (cs_initiator_claim_event_pair(&p_local_event, &p_peer_event))
    {
        subevent_populate(p_local_event,
                          p_peer_event,
                          cs_initiator_get_local_mac(),
                          cs_initiator_get_peer_mac(),
                          cs_initiator_get_latest_subevent_header(),
                          latest_local_steps,
                          cs_initiator_get_peer_steps(),
                          cs_config.role);

        cs_initiator_publish_event_pair();
    }
    /* else: the consumer is still busy with the previous item; the claim
     * counted the dropped procedure. */

    net_buf_simple_reset(latest_local_steps);

    if (!(cs_initiator_get_ras_feature_bits() & RAS_FEAT_REALTIME_RD))
    {
        net_buf_simple_reset(cs_initiator_get_peer_steps());
    }

    cs_initiator_give_sem_local_steps();
}

/** @brief Callback for RAS "data ready" — requests on-demand ranging data from peer. */
static void ranging_data_ready_cb(struct bt_conn * p_conn, uint16_t ranging_counter)
{
    LOG_DBG("Ranging data ready %i", ranging_counter);

    if (ranging_counter == cs_initiator_get_local_ranging_counter())
    {
        int err = bt_ras_rreq_cp_get_ranging_data(cs_initiator_get_connection(),
                                                  cs_initiator_get_peer_steps(),
                                                  ranging_counter,
                                                  ranging_data_cb);
        if (err)
        {
            LOG_ERR("Get ranging data failed (err %d)", err);
            net_buf_simple_reset(cs_initiator_get_local_steps());
            net_buf_simple_reset(cs_initiator_get_peer_steps());
            cs_initiator_give_sem_local_steps();
        }
    }
}
#endif /* CONFIG_MARS_CS_INLINE_PCT */

/** @brief Hook that saves the negotiated CS config for later use. */
static void config_create_hook(struct bt_conn_le_cs_config * config)
{
    cs_config = *config;
}

/** @brief Fallback reboot if the watchdog's forced disconnect never completes. */
static void reboot_fallback_handler(struct k_timer * timer)
{
    ARG_UNUSED(timer);

    sys_reboot(SYS_REBOOT_COLD);
}

static K_TIMER_DEFINE(reboot_fallback, reboot_fallback_handler, NULL);

/**
 * @brief CS liveness watchdog recovery (#116) — runs on the system workqueue.
 *
 * Emits a COBS banner (the host's only window into the initiator), then
 * forces a disconnect so the existing disconnected_cb -> sys_reboot path
 * recovers both boards. The 2 s fallback timer covers a wedged controller
 * that never completes the HCI disconnect command (bt_hci_disconnect has no
 * timeout); a failed disconnect means the link is already gone, so reboot.
 */
static void cs_watchdog_recovery_cb(void)
{
    (void)serialize_send_log_message("CS watchdog: no completed procedure, forcing disconnect");

    struct bt_conn * conn = ble_callbacks_get_connection();

    if (conn != NULL && bt_conn_disconnect(conn, BT_HCI_ERR_LOCALHOST_TERM_CONN) == 0)
    {
        k_timer_start(&reboot_fallback, K_MSEC(2000), K_NO_WAIT);
        return;
    }

    sys_reboot(SYS_REBOOT_COLD);
}

/*
 * Optional RF-switch supply rail. Boards whose antenna switch needs a supply
 * GPIO driven high add an app-owned property to the `zephyr,user` devicetree
 * node in their board overlay:
 *
 *     / {
 *         zephyr,user {
 *             rf-switch-supply-gpios = <&gpio2 5 GPIO_ACTIVE_HIGH>;
 *         };
 *     };
 *
 * Boards without the property skip this block. The port and pin are entirely
 * board-owned — no model-specific assignment lives in shared code.
 */
#define ZEPHYR_USER_NODE DT_PATH(zephyr_user)

#if DT_NODE_EXISTS(ZEPHYR_USER_NODE) && DT_NODE_HAS_PROP(ZEPHYR_USER_NODE, rf_switch_supply_gpios)
static const struct gpio_dt_spec rf_switch_supply = GPIO_DT_SPEC_GET(ZEPHYR_USER_NODE, rf_switch_supply_gpios);
#endif

int main(void)
{
    int err;

#if DT_NODE_EXISTS(ZEPHYR_USER_NODE) && DT_NODE_HAS_PROP(ZEPHYR_USER_NODE, rf_switch_supply_gpios)
    if (!gpio_is_ready_dt(&rf_switch_supply))
    {
        LOG_ERR("RF switch supply is not ready");
        return 0;
    }

    err = gpio_pin_configure_dt(&rf_switch_supply, GPIO_OUTPUT_ACTIVE);
    if (err)
    {
        LOG_ERR("Failed to configure RF switch supply high (err %d)", err);
        return 0;
    }
#endif

    LOG_INF("Starting Mars Channel Sounding Initiator");

    err = bt_enable(NULL);
    if (err)
    {
        LOG_ERR("Bluetooth init failed (err %d)", err);
        return 0;
    }

    /* CS liveness watchdog (#116): inert until the first completed procedure
     * with step data pets it, so the handshake never false-triggers it. */
    cs_watchdog_init(cs_watchdog_recovery_cb);

    /* Both modes populate on the RX thread and serialize on this thread: RAS
     * from ranging_data_cb, IPT from the shared procedure-completion skeleton. */
    cs_initiator_set_process_subevent_cb(process_subevent_cb);
#if !IS_ENABLED(CONFIG_MARS_CS_INLINE_PCT)
    /* RAS fault-path diagnostics are the only log frames queued through the handoff. */
    cs_initiator_set_process_log_cb(process_log_cb);
    cs_initiator_set_ranging_data_cb(ranging_data_cb);
    cs_initiator_set_ranging_data_ready_cb(ranging_data_ready_cb);
#endif
    cs_initiator_set_config_created_cb(config_create_hook);

    const struct cs_initiator_config config = {
        /* Procedure cadence applies to ALL builds (RAS + IPT): this is
         * intentional, not an IPT leak — the new cadence speeds up
         * measurements across every antenna configuration (see #41).
         * It supersedes the prior RAS-only defaults (procedure_phy=1M,
         * min/max_procedure_interval=20/50, max_procedure_len=1000); any
         * RAS fixture/calibration/range baseline assuming those must be
         * re-baselined. The interval is CONFIG_MARS_CS_PROCEDURE_INTERVAL
         * (default 10, matching the Nordic ras_initiator sample); the bench
         * sets it to 1 for the transport-headroom run.
         * The subevent length and connection interval are computed
         * dynamically in cs_initiator_start from the negotiated config
         * timings, channel map, and antenna paths; the connect-time
         * interval in ble_scanning.c is intentionally conservative and is
         * tightened after the capabilities exchange.
         */
        .cs_sync_phy            = BT_CONN_LE_CS_SYNC_1M_PHY,
        .procedure_phy          = BT_LE_CS_PROCEDURE_PHY_2M,
        .min_procedure_interval = CONFIG_MARS_CS_PROCEDURE_INTERVAL,
        .max_procedure_interval = CONFIG_MARS_CS_PROCEDURE_INTERVAL,
    };

    err = cs_initiator_start(&config);
    if (err)
    {
        LOG_ERR("CS initiator start failed (err %d)", err);
        return 0;
    }

    while (true)
    {
        /* RAS and IPT: this thread is the serialize consumer — this call runs the process callback on the next item
         * the RX thread handed over (see process_subevent_cb and docs/architecture.md for why this must stay off the
         * BT RX thread; #173). */
        cs_initiator_consume_pending_event();
    }

    return 0;
}

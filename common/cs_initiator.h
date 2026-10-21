/*
 * Copyright (c) 2024 Nordic Semiconductor ASA
 *
 * SPDX-License-Identifier: MIT
 */

/** @file
 *  @brief Shared Channel Sounding initiator connection and configuration flow
 */

#ifndef CS_INITIATOR_H
#define CS_INITIATOR_H

#include <stdint.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/cs.h>
#include <zephyr/kernel.h>
#include <zephyr/net_buf.h>

#include "antenna.h"
#include "mars_bluetooth_hci.h"

#if defined(CONFIG_BT_RAS_RREQ) || defined(CONFIG_BT_RAS_RRSP)
#include <bluetooth/services/ras.h>
#endif  // defined(CONFIG_BT_RAS_RREQ) || defined(CONFIG_BT_RAS_RRSP)

/** @brief CS configuration identifier used for procedure setup. */
#define CS_CONFIG_ID 0
/** @brief Number of Mode-0 calibration steps per CS procedure. */
#define NUM_MODE_0_STEPS 3
/** @brief Sentinel value indicating no valid procedure counter. */
#define PROCEDURE_COUNTER_NONE (-1)
/** @brief Per-step framing in the local IPT step buffer: mode | channel | data_len.
 *
 * Hoisted out of the RAS/IPT @c #if below so the walk loop in cs_step_parse.c
 * (compiled unconditionally) can share this single source of truth with
 * @ref LOCAL_PROCEDURE_MEM, instead of hardcoding the literal 3.
 */
#define MARS_CS_IPT_STEP_FRAMING_LEN 3

/** @brief Max antenna paths the controller is built for (CS Kconfig).
 *
 * Hoisted out of the RAS/IPT @c #if below so the parse loop in cs_step_parse.c
 * (compiled unconditionally) and the IPT buffer sizing share one source of
 * truth, instead of each hardcoding the literal.
 */
#define MARS_CS_MAX_ANTENNA_PATHS (CONFIG_BT_CTLR_SDC_CS_MAX_ANTENNA_PATHS)

/** @brief Max tone_info entries per mode-2 step: n_ap paths + 1 extension slot.
 *
 * This is both the IPT local step buffer tone count (see @ref
 * MARS_CS_IPT_MODE_2_MAX_LEN) and the cap on the mode-2 parse loop in
 * cs_step_parse.c, which indexes Mode2_t's idx[] arrays. Kept unsigned to match
 * the former literal `5u` and avoid -Wsign-compare in MIN/MAX/loop usage.
 */
#define MARS_CS_MAX_TONE_COUNT ((unsigned int)(MARS_CS_MAX_ANTENNA_PATHS + 1))

#if defined(CONFIG_BT_RAS_RREQ) || defined(CONFIG_BT_RAS_RRSP)
/** @brief Memory required for the local step data net buffer (RAS sizing). */
#define LOCAL_PROCEDURE_MEM                                                     \
    ((BT_RAS_MAX_STEPS_PER_PROCEDURE * sizeof(struct bt_le_cs_subevent_step)) + \
     (BT_RAS_MAX_STEPS_PER_PROCEDURE * BT_RAS_MAX_STEP_DATA_LEN))
#else  // defined(CONFIG_BT_RAS_RREQ) || defined(CONFIG_BT_RAS_RRSP)
/* IPT-mode local step buffer sizing.
 *
 * The negotiated CS mode is MAIN_MODE_2 with no sub-mode or with sub-mode-1
 * (which inserts mode-0 steps), so the local buffer only ever holds mode-0 and
 * mode-2 step data. Mode-1 / mode-3 / sounding-sequence RTT are never produced.
 *
 * Mirrors the RAS sizing in bluetooth/services/ras.h, but parameterises it on
 * the controller's antenna-path Kconfig and accounts for the IPT step framing
 * (3 bytes: mode | channel | data_len) instead of the RAS 1-byte mode tag.
 *
 * tone_info count per mode-2 step is (n_ap + 1): the +1 is the extension slot
 * (see cs.h: tone_index = n_ap corresponds to extension slot), matching
 * BT_RAS_STEP_MODE_2_3_ANT_DEPENDENT_LEN(antenna_paths) in ras.h.
 */
#define MARS_CS_IPT_MAX_STEPS_PER_PROCEDURE 256

#define MARS_CS_IPT_MODE_0_MAX_LEN \
    MAX(sizeof(struct bt_hci_le_cs_step_data_mode_0_initiator), sizeof(struct bt_hci_le_cs_step_data_mode_0_reflector))
#define MARS_CS_IPT_MODE_2_MAX_LEN                  \
    (sizeof(struct bt_hci_le_cs_step_data_mode_2) + \
     MARS_CS_MAX_TONE_COUNT * sizeof(struct bt_hci_le_cs_step_data_tone_info))

#define MARS_CS_IPT_MAX_STEP_DATA_LEN MAX(MARS_CS_IPT_MODE_0_MAX_LEN, MARS_CS_IPT_MODE_2_MAX_LEN)

#define LOCAL_PROCEDURE_MEM \
    (MARS_CS_IPT_MAX_STEPS_PER_PROCEDURE * (MARS_CS_IPT_STEP_FRAMING_LEN + MARS_CS_IPT_MAX_STEP_DATA_LEN))
#endif  // defined(CONFIG_BT_RAS_RREQ) || defined(CONFIG_BT_RAS_RRSP)

/**
 * @brief Target-specific CS initiator configuration parameters.
 *
 * Passed to cs_initiator_start() to control PHY selection and procedure
 * cadence. Subevent length, CS event length, and connection interval are
 * computed dynamically from the negotiated capabilities (antenna paths,
 * timings, channel map) and are no longer configured here.
 */
struct cs_initiator_config
{
    uint8_t  cs_sync_phy;            /**< CS sync PHY (e.g. BT_CONN_LE_CS_SYNC_1M_PHY). */
    uint8_t  procedure_phy;          /**< Procedure PHY (e.g. BT_LE_CS_PROCEDURE_PHY_2M). */
    uint32_t min_procedure_interval; /**< Minimum interval between CS procedures (in connection events). */
    uint32_t max_procedure_interval; /**< Maximum interval between CS procedures (in connection events). */
};

/**
 * @brief Callback type for ranging data received from peer (realtime or on-demand).
 *
 * @param p_conn            BLE connection reference.
 * @param ranging_counter Ranging counter of the delivered data.
 * @param err             0 on success, negative errno on error.
 */
typedef void (*cs_initiator_ranging_data_cb)(struct bt_conn * p_conn, uint16_t ranging_counter, int err);

/**
 * @brief Callback type for RAS "data ready" notification (on-demand RD mode).
 *
 * @param p_conn            BLE connection reference.
 * @param ranging_counter Ranging counter of the ready data.
 */
typedef void (*cs_initiator_ranging_data_ready_cb)(struct bt_conn * p_conn, uint16_t ranging_counter);

/**
 * @brief Callback type for CS config creation notification.
 *
 * Called after a CS config is successfully created, allowing the caller
 * to save the config struct for later use (e.g., to obtain the role).
 *
 * @param p_config  The negotiated CS configuration.
 */
typedef void (*cs_initiator_config_created_cb)(struct bt_conn_le_cs_config * p_config);

/**
 * @brief Callback type for processing populated SubeventResultEvents.
 *
 * Called on the consumer thread by cs_initiator_consume_pending_event() after
 * the RX thread has populated the shared event pair — RAS: from the
 * ranging-data callback; IPT: from the shared procedure-completion skeleton.
 * The app does its blocking work here — serialize and transmit over the COBS
 * TX seam — never on the BT RX thread. Called only on a successful,
 * non-empty procedure.
 *
 * @param p_local_event  Populated initiator SubeventResultEvent.
 * @param p_peer_event   Populated reflector SubeventResultEvent.
 */
typedef void (*cs_initiator_process_subevent_cb)(SubeventResultEvent_t * p_local_event,
                                                 SubeventResultEvent_t * p_peer_event);

/**
 * @brief Callback type for a diagnostic log message queued by the RX thread.
 *
 * RAS fault-path diagnostics are queued by the RX thread and emitted on the
 * consumer thread, so the RX thread never serializes or transmits.
 *
 * @param p_message  NUL-terminated message to serialize and transmit.
 */
typedef void (*cs_initiator_process_log_cb)(const char * p_message);

/**
 * @brief Claim the RX-thread → consumer-thread handoff slot for an event pair.
 *
 * The slot is one static event pair shared by RAS and IPT. The RX thread
 * fills the claimed pair and publishes it with
 * cs_initiator_publish_event_pair(). A failed claim means the consumer thread
 * is still working on the previous item: the procedure must be dropped, and
 * the drop is counted and reported (LOG_WRN on the first drop and every
 * 128th).
 *
 * @param pp_local_event  Output: local event to populate (set on success).
 * @param pp_peer_event   Output: peer event to populate (set on success).
 * @return true when the pair was claimed, false when the consumer is busy.
 */
bool cs_initiator_claim_event_pair(SubeventResultEvent_t ** pp_local_event, SubeventResultEvent_t ** pp_peer_event);

/** @brief Publish the event pair claimed above to the consumer thread. */
void cs_initiator_publish_event_pair(void);

/**
 * @brief Queue a diagnostic log message for the consumer thread.
 *
 * Fault-path diagnostics (RAS ranging-data errors, dropped or empty
 * procedures) must not serialize or transmit on the RX thread. They go into a
 * small dedicated queue drained by cs_initiator_consume_pending_event(); the
 * queue is separate from the event-pair handoff so a queued diagnostic cannot
 * make the next completed procedure fail its claim. When the queue is full
 * the message is dropped, counted, and reported (LOG_WRN on the first drop and
 * every 128th).
 *
 * @param p_message  NUL-terminated message (copied before return).
 * @return true when queued, false when the queue is full.
 */
bool cs_initiator_queue_log_message(const char * p_message);

void                                   cs_initiator_set_ranging_data_cb(cs_initiator_ranging_data_cb cb);
void                                   cs_initiator_set_ranging_data_ready_cb(cs_initiator_ranging_data_ready_cb cb);
void                                   cs_initiator_set_config_created_cb(cs_initiator_config_created_cb cb);
void                                   cs_initiator_set_process_subevent_cb(cs_initiator_process_subevent_cb cb);
void                                   cs_initiator_set_process_log_cb(cs_initiator_process_log_cb cb);
int                                    cs_initiator_start(const struct cs_initiator_config * p_config);
struct bt_conn *                       cs_initiator_get_connection(void);
uint32_t                               cs_initiator_get_ras_feature_bits(void);
uint64_t                               cs_initiator_get_local_mac(void);
uint64_t                               cs_initiator_get_peer_mac(void);
struct net_buf_simple *                cs_initiator_get_local_steps(void);
struct net_buf_simple *                cs_initiator_get_peer_steps(void);
int32_t                                cs_initiator_get_local_ranging_counter(void);
struct bt_conn_le_cs_subevent_result * cs_initiator_get_latest_subevent_header(void);
void                                   cs_initiator_give_sem_local_steps(void);

/** @brief Consume pending work on the caller's thread (RAS and IPT).
 *
 * The main loop calls this as its only wait: it blocks until the RX thread
 * has published an event pair or queued a diagnostic log message, drains the
 * diagnostic queue, runs the app's process callback on a pending event pair
 * (serialize + COBS TX), and releases the handoff slot. Keeps the blocking
 * serialize path off the BT RX thread (#173).
 */
void cs_initiator_consume_pending_event(void);

#endif  // CS_INITIATOR_H

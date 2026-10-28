/*
 * Copyright (c) 2024 Nordic Semiconductor ASA
 *
 * SPDX-License-Identifier: MIT
 */

/** @file
 *  @brief Shared BLE connection and Channel Sounding callbacks
 */

#ifndef BLE_CALLBACKS_H
#define BLE_CALLBACKS_H

#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/cs.h>
#include <zephyr/kernel.h>

/**
 * @brief Disconnect-reason text shared by the console line and the COBS frame.
 *
 * The initiator's disconnect emission serializes this exact format, so a
 * console capture and the COBS data stream read the reason the same way.
 */
#define BLE_CALLBACKS_DISCONNECT_REASON_FORMAT "Disconnected (reason 0x%02X)"

struct bt_conn * ble_callbacks_get_connection(void);

/**
 * @brief Disconnect hook: called with the Disconnection Complete reason.
 *
 * Runs on the BT RX thread from the disconnected callback, before the reboot.
 * Timed semaphore takes are legal there, so the hook may wait (bounded).
 */
typedef void (*ble_disconnected_hook_t)(uint8_t reason);

/**
 * @brief Callback type for CS subevent data available notifications.
 */
typedef void (*bt_le_cs_subevent_data_available_cb)(struct bt_conn *                       p_conn,
                                                    struct bt_conn_le_cs_subevent_result * p_result);

/**
 * @brief Callback type for CS config creation notifications.
 *
 * Called with the negotiated CS config after a successful config creation.
 * Allows the caller to save the config for later use.
 */
typedef void (*bt_le_cs_config_created_cb)(struct bt_conn_le_cs_config * p_config);

void ble_callbacks_register(struct k_sem * p_sem_connected,
                            struct k_sem * p_sem_security,
                            struct k_sem * p_sem_remote_capabilities_obtained,
                            struct k_sem * p_sem_config_created,
                            struct k_sem * p_sem_cs_security_enabled);

void ble_callbacks_set_subevent_data_cb(bt_le_cs_subevent_data_available_cb p_cb);

void ble_callbacks_set_config_created_cb(bt_le_cs_config_created_cb p_cb);

/**
 * @brief Set the disconnect hook.
 *
 * The shared callbacks carry no serializer dependency: the initiator registers
 * a hook that emits the terminal COBS log frame before the reboot. The
 * reflector leaves it unset and is unchanged.
 */
void ble_callbacks_set_disconnected_hook(ble_disconnected_hook_t p_hook);

#endif /* BLE_CALLBACKS_H */

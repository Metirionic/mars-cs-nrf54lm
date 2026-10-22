/*
 * Copyright (c) 2026 Metirionic
 *
 * SPDX-License-Identifier: MIT
 */

/** @file
 *  @brief Shared native USB bring-up module (device-next + CDC ACM)
 *
 * Owns the single USB device context, its string descriptors, the full-speed
 * and high-speed configurations, the CDC ACM class registrations, and the
 * VBUS policy. Both roles use it; the role symbols select the product string
 * and product ID, while the role's board overlay selects how many CDC ACM
 * functions exist (initiator: data + console, reflector: console).
 *
 * The device is initialized after bt_enable() (MPSL/HFCLK24M hazard,
 * DRGN-29129 / DRGN-29277) and is never enabled at boot: the UDC connects on
 * the VBUS-ready message and disconnects on removal. That is the
 * NCSDK-38624 posture — CDC ACM serial initialization at boot is disabled and
 * a missing host cannot hang the firmware.
 */

#include "mars_usb.h"

#include <errno.h>
#include <zephyr/kernel.h>

#if IS_ENABLED(CONFIG_MARS_CS_TRANSPORT_USB)

#define DT_DRV_COMPAT zephyr_cdc_acm_uart
#include <zephyr/devicetree.h>
#include <zephyr/logging/log.h>
#include <zephyr/usb/usbd.h>

LOG_MODULE_REGISTER(mars_usb, LOG_LEVEL_INF);

#if IS_ENABLED(CONFIG_MARS_CS_ROLE_INITIATOR) == IS_ENABLED(CONFIG_MARS_CS_ROLE_REFLECTOR)
#error "A USB build must set exactly one of CONFIG_MARS_CS_ROLE_INITIATOR / CONFIG_MARS_CS_ROLE_REFLECTOR"
#endif

/** @brief Nordic development vendor ID (a USB-IF VID remains pre-product work). */
#define MARS_USB_VID 0x1915

#if IS_ENABLED(CONFIG_MARS_CS_ROLE_INITIATOR)
#define MARS_USB_PID               0x0001
#define MARS_USB_PRODUCT           "Mars CS Initiator"
#define MARS_USB_NUM_CDC_FUNCTIONS 2
#else
#define MARS_USB_PID               0x0002
#define MARS_USB_PRODUCT           "Mars CS Reflector"
#define MARS_USB_NUM_CDC_FUNCTIONS 1
#endif

#define MARS_USB_MANUFACTURER "Metirionic"

BUILD_ASSERT(DT_NUM_INST_STATUS_OKAY(DT_DRV_COMPAT) == MARS_USB_NUM_CDC_FUNCTIONS,
             "The USB role's devicetree overlay must provide exactly the role's CDC ACM functions");

USBD_DEVICE_DEFINE(mars_usbd, DEVICE_DT_GET(DT_NODELABEL(zephyr_udc0)), MARS_USB_VID, MARS_USB_PID);

USBD_DESC_LANG_DEFINE(mars_usb_lang);
USBD_DESC_MANUFACTURER_DEFINE(mars_usb_manufacturer, MARS_USB_MANUFACTURER);
USBD_DESC_PRODUCT_DEFINE(mars_usb_product, MARS_USB_PRODUCT);
/* Derives the serial number from the SoC's unique device ID via HWINFO. */
USBD_DESC_SERIAL_NUMBER_DEFINE(mars_usb_serial_number);

USBD_DESC_CONFIG_DEFINE(mars_usb_fs_config_desc, "FS Configuration");

/* Bus-powered, no remote wake-up, 500 mA (bMaxPower is in 2 mA units). */
#define MARS_USB_ATTRIBUTES 0
#define MARS_USB_MAX_POWER  250

USBD_CONFIGURATION_DEFINE(mars_usb_fs_config, MARS_USB_ATTRIBUTES, MARS_USB_MAX_POWER, &mars_usb_fs_config_desc);

#if USBD_SUPPORTS_HIGH_SPEED
USBD_DESC_CONFIG_DEFINE(mars_usb_hs_config_desc, "HS Configuration");
USBD_CONFIGURATION_DEFINE(mars_usb_hs_config, MARS_USB_ATTRIBUTES, MARS_USB_MAX_POWER, &mars_usb_hs_config_desc);
#endif

/** @brief Host-selected configuration state; drives the pre-enumeration drop policy. */
static atomic_t g_configured;

/** @brief Whether this module enabled the UDC (guards usbd_disable()). */
static atomic_t g_udc_enabled;

static bool g_initialized;

/**
 * @brief Register the role's CDC ACM functions in descriptor order.
 *
 * The overlay declares the functions in interface order: instance 0 is the
 * COBS data function for the initiator (chosen `cobs-uart`) and instance 1
 * the console (chosen `zephyr,console`). The reflector has only the console.
 */
static int mars_usb_register_classes(struct usbd_context * p_ctx, enum usbd_speed speed)
{
    int err = usbd_register_class(p_ctx, "cdc_acm_0", speed, 1);

    if (err)
    {
        LOG_ERR("Failed to register CDC ACM data function (err %d)", err);
        return err;
    }

#if IS_ENABLED(CONFIG_MARS_CS_ROLE_INITIATOR)
    err = usbd_register_class(p_ctx, "cdc_acm_1", speed, 1);
    if (err)
    {
        LOG_ERR("Failed to register CDC ACM console function (err %d)", err);
        return err;
    }
#endif

    return 0;
}

/**
 * @brief Device-next message callback (system workqueue when deferred mode is on).
 *
 * Implements the VBUS policy and tracks host configuration:
 *  - VBUS ready: enable the UDC (never at boot).
 *  - VBUS removed: disable the UDC without a reboot.
 *  - set-configuration: the host enumerated us; output may flow.
 *  - bus reset: the host deconfigured us; output is dropped again until the
 *    next set-configuration.
 */
static void mars_usb_msg_cb(struct usbd_context * p_ctx, const struct usbd_msg * p_msg)
{
    switch (p_msg->type)
    {
    case USBD_MSG_VBUS_READY:
        if (usbd_can_detect_vbus(p_ctx) && !atomic_get(&g_udc_enabled))
        {
            int err = usbd_enable(p_ctx);

            if (err && err != -EALREADY)
            {
                LOG_ERR("Failed to enable USB device (err %d)", err);
                break;
            }

            atomic_set(&g_udc_enabled, 1);
            LOG_INF("USB connected, waiting for host enumeration");
        }
        break;

    case USBD_MSG_VBUS_REMOVED:
        atomic_clear(&g_configured);

        if (atomic_get(&g_udc_enabled))
        {
            int err = usbd_disable(p_ctx);

            atomic_clear(&g_udc_enabled);

            if (err && err != -EALREADY)
            {
                LOG_ERR("Failed to disable USB device (err %d)", err);
            }
            else
            {
                LOG_INF("USB disconnected");
            }
        }
        break;

    case USBD_MSG_CONFIGURATION:
        atomic_set(&g_configured, p_msg->status != 0);

        if (p_msg->status != 0)
        {
            LOG_INF("USB enumerated at %s speed",
                    usbd_bus_speed(p_ctx) == USBD_SPEED_HS ? "high (480 Mbit/s)" : "full (12 Mbit/s)");
        }
        else
        {
            LOG_INF("USB deconfigured");
        }
        break;

    case USBD_MSG_RESET:
        atomic_clear(&g_configured);
        break;

    case USBD_MSG_UDC_ERROR:
    case USBD_MSG_STACK_ERROR:
        atomic_clear(&g_configured);
        LOG_ERR("USB %s error (%d)", p_msg->type == USBD_MSG_UDC_ERROR ? "controller" : "stack", p_msg->status);
        break;

    default:
        break;
    }
}

static int mars_usb_add_descriptors(struct usbd_context * p_ctx)
{
    int err;

    err = usbd_add_descriptor(p_ctx, &mars_usb_lang);
    if (err)
    {
        return err;
    }

    err = usbd_add_descriptor(p_ctx, &mars_usb_manufacturer);
    if (err)
    {
        return err;
    }

    err = usbd_add_descriptor(p_ctx, &mars_usb_product);
    if (err)
    {
        return err;
    }

    return usbd_add_descriptor(p_ctx, &mars_usb_serial_number);
}

static int mars_usb_add_configuration(struct usbd_context *     p_ctx,
                                      enum usbd_speed           speed,
                                      struct usbd_config_node * p_config)
{
    int err = usbd_add_configuration(p_ctx, speed, p_config);

    if (err)
    {
        LOG_ERR("Failed to add %s configuration (err %d)", speed == USBD_SPEED_HS ? "HS" : "FS", err);
        return err;
    }

    err = mars_usb_register_classes(p_ctx, speed);
    if (err)
    {
        return err;
    }

    /* Composite device: the CDC ACM functions use Interface Association
     * Descriptors, so the device descriptor must declare the IAD triple. */
    err = usbd_device_set_code_triple(p_ctx, speed, USB_BCC_MISCELLANEOUS, 0x02, 0x01);
    if (err)
    {
        LOG_ERR("Failed to set device code triple (err %d)", err);
        return err;
    }

    return 0;
}

int mars_usb_init(void)
{
    int err;

    if (g_initialized)
    {
        return 0;
    }

    atomic_clear(&g_configured);
    atomic_clear(&g_udc_enabled);

    err = mars_usb_add_descriptors(&mars_usbd);
    if (err)
    {
        LOG_ERR("Failed to add USB descriptors (err %d)", err);
        return err;
    }

#if USBD_SUPPORTS_HIGH_SPEED
    err = mars_usb_add_configuration(&mars_usbd, USBD_SPEED_HS, &mars_usb_hs_config);
    if (err)
    {
        return err;
    }
#endif

    /* Full speed remains a supported fallback on a full-speed-only host. */
    err = mars_usb_add_configuration(&mars_usbd, USBD_SPEED_FS, &mars_usb_fs_config);
    if (err)
    {
        return err;
    }

    err = usbd_msg_register_cb(&mars_usbd, mars_usb_msg_cb);
    if (err)
    {
        LOG_ERR("Failed to register USB message callback (err %d)", err);
        return err;
    }

    err = usbd_init(&mars_usbd);
    if (err)
    {
        LOG_ERR("Failed to initialize USB device support (err %d)", err);
        return err;
    }

    /* Controllers without VBUS detection cannot wait for a message; connect
     * immediately. The nRF54LM20 USBHS reports can_detect_vbus=true, so this
     * path is not taken on the DK. */
    if (!usbd_can_detect_vbus(&mars_usbd))
    {
        err = usbd_enable(&mars_usbd);
        if (err)
        {
            LOG_ERR("Failed to enable USB device (err %d)", err);
            return err;
        }

        atomic_set(&g_udc_enabled, 1);
    }

    g_initialized = true;
    LOG_INF("USB device initialized");

    return 0;
}

bool mars_usb_is_configured(void)
{
    return atomic_get(&g_configured) != 0;
}

#else /* CONFIG_MARS_CS_TRANSPORT_USB */

int mars_usb_init(void)
{
    return -ENOTSUP;
}

bool mars_usb_is_configured(void)
{
    return false;
}

#endif /* CONFIG_MARS_CS_TRANSPORT_USB */

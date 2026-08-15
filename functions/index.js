const {
  onValueUpdated,
  onValueWritten,
} = require("firebase-functions/v2/database");
const {onRequest} = require("firebase-functions/v2/https");
const {logger} = require("firebase-functions");
const admin = require("firebase-admin");

admin.initializeApp({
  databaseURL:
    "https://smart-home-monitoring-sy-48629-default-rtdb.asia-southeast1.firebasedatabase.app",
});

const db = admin.database();

/**
 * Server-side safety cutoff for Safety devices (e.g. the Safety Iron).
 *
 * Watches every device under /devices/{deviceId} whose type is
 * "Safety device". When one changes from OFF to ON:
 * 1. Reads the maximum active duration.
 * 2. Waits for that duration on the server.
 * 3. Checks the latest Firebase state.
 * 4. If the device is still ON, turns it OFF automatically.
 */
exports.safetyIronCutoff = onValueUpdated(
    {
      ref: "/devices/{deviceId}",
      region: "asia-southeast1",
    },

    async (event) => {
      const deviceId = event.params.deviceId;
      const before = event.data.before.val();
      const after = event.data.after.val();

      // Stop if the device was deleted.
      if (!after) {
        return null;
      }

      // Only react to Safety devices changing from OFF to ON.
      if (
        after.type !== "Safety device" ||
        (before && before.status === "ON") ||
        after.status !== "ON"
      ) {
        return null;
      }

      // Get the maximum allowed ON duration.
      const maxDuration =
        Number(after.maxOnDurationSeconds) || 30;

      // Get the activation timestamp.
      const activatedAt = Number(after.activatedAt);

      // Activation time is required for the safety check.
      if (!activatedAt) {
        logger.warn(
            `${deviceId} is ON but activatedAt is missing.`,
        );

        return null;
      }

      logger.info(
          `${deviceId} activated. Server cutoff set for ` +
          `${maxDuration} seconds.`,
      );

      // Wait for the configured maximum duration.
      await new Promise((resolve) => {
        setTimeout(resolve, maxDuration * 1000);
      });

      // Read the latest device state.
      const currentSnapshot = await db
          .ref(`/devices/${deviceId}`)
          .get();

      const current = currentSnapshot.val();

      // Stop if the device no longer exists.
      if (!current) {
        return null;
      }

      // Stop if the user already turned the device OFF.
      if (current.status !== "ON") {
        logger.info(
            `${deviceId} was turned OFF before the cutoff.`,
        );

        return null;
      }

      // Make sure this is still the same activation.
      if (Number(current.activatedAt) !== activatedAt) {
        logger.info(
            "A newer activation was detected. " +
            "Skipping the old cutoff.",
        );

        return null;
      }

      const now = Date.now();

      const safetyMessage =
        "Safety alert: " +
        `${current.name || deviceId} was automatically turned OFF ` +
        `after ${maxDuration} seconds.`;

      // Automatically turn the device OFF.
      await db.ref(`/devices/${deviceId}`).update({
        status: "OFF",
        safetyAlert: safetyMessage,
        safetyTriggeredAt: now,
        updatedAt: now,
      });

      logger.info(
          `${deviceId} automatically turned OFF after ` +
          `${maxDuration} seconds.`,
      );

      return null;
    },
);

/**
 * Server-side event logger that powers the Reports tab.
 *
 * Watches /devices/{deviceId} and appends a history entry to /logs
 * whenever a device's status (or a sub-switch status) changes.
 *
 * This is the authoritative record used by the Flutter Reports screen
 * and by the reportsSummary HTTP endpoint.
 */
exports.recordDeviceEvents = onValueWritten(
    {
      ref: "/devices/{deviceId}",
      region: "asia-southeast1",
    },

    async (event) => {
      const deviceId = event.params.deviceId;
      const before = event.data.before.val();
      const after = event.data.after.val();

      // Ignore creates and deletes; only track transitions.
      if (!before || !after) {
        return null;
      }

      const changes = [];

      if (before.status !== after.status) {
        changes.push({
          field: "status",
          from: before.status,
          to: after.status,
        });
      }

      const beforeSwitches = before.switches || {};
      const afterSwitches = after.switches || {};
      const switchIds = new Set([
        ...Object.keys(beforeSwitches),
        ...Object.keys(afterSwitches),
      ]);

      for (const switchId of switchIds) {
        const prev = beforeSwitches[switchId];
        const next = afterSwitches[switchId];

        if (prev && next && prev.status !== next.status) {
          changes.push({
            field: "switch.status",
            switchId,
            switchName: next.name || prev.name || switchId,
            from: prev.status,
            to: next.status,
          });
        }
      }

      if (changes.length === 0) {
        return null;
      }

      const floor =
      typeof after.floor === "number" ?
        after.floor :
        typeof before.floor === "number" ?
            before.floor :
            0;

      await db.ref("/logs").push({
        deviceId,
        deviceName: after.name || before.name || deviceId,
        room: after.room || before.room || "",
        type: after.type || before.type || "Device",
        floor,
        events: changes,
        timestamp: Date.now(),
      });

      return null;
    },
);

/**
 * HTTP endpoint that returns aggregated report data as JSON.
 * Used by external/backend consumers (e.g. dashboards, cron jobs).
 *
 * GET /reportsSummary?days=7
 * days=0 means "all time".
 */
exports.reportsSummary = onRequest(
    {
      region: "asia-southeast1",
      cors: true,
    },

    async (req, res) => {
      const days = Number(req.query.days);
      const validDays = Number.isFinite(days) && days >= 0 ? days : 7;

      const cutoff =
      validDays > 0 ? Date.now() - validDays * 24 * 60 * 60 * 1000 : 0;

      const devicesSnap = await db.ref("/devices").get();
      const logsSnap = await db
          .ref("/logs")
          .orderByChild("timestamp")
          .startAt(cutoff)
          .get();

      const devices = devicesSnap.val() || {};
      const logs = logsSnap.val() || {};

      const byStatus = {};
      const byType = {};
      let total = 0;

      Object.values(devices).forEach((device) => {
        total += 1;
        const status = device.status || "UNKNOWN";
        const type = device.type || "Device";
        byStatus[status] = (byStatus[status] || 0) + 1;
        byType[type] = (byType[type] || 0) + 1;
      });

      const activity = {eventCount: 0, perDevice: {}};

      Object.values(logs).forEach((entry) => {
        const events = entry.events || [];
        const deviceName = entry.deviceName || entry.deviceId || "Unknown";
        activity.eventCount += events.length;
        activity.perDevice[deviceName] =
        (activity.perDevice[deviceName] || 0) + events.length;
      });

      res.json({
        generatedAt: Date.now(),
        rangeDays: validDays,
        devices: {total, byStatus, byType},
        activity,
      });
    },
);

/**
 * Server-side enforcement of the Safety device auto-off setting.
 *
 * Watches /settings/safety/ironMaxOnSeconds and keeps every device of type
 * "Safety device" (e.g. /devices/safety_iron) in sync, so the
 * safetyIronCutoff watchdog always honors the configured duration.
 */
exports.syncIronSetting = onValueWritten(
    {
      ref: "/settings/safety/ironMaxOnSeconds",
      region: "asia-southeast1",
    },

    async (event) => {
      const raw = event.data.after.val();

      // Ignore deletes and non-numeric writes.
      if (typeof raw !== "number" || Number.isNaN(raw)) {
        return null;
      }

      // Clamp to the allowed range (5-120 seconds).
      const clamped = Math.min(120, Math.max(5, Math.round(raw)));

      // Update every safety device so the watchdog honors the duration.
      const safetyDevices = await db
          .ref("/devices")
          .orderByChild("type")
          .equalTo("Safety device")
          .once("value");

      if (safetyDevices.exists()) {
        const updates = {};
        safetyDevices.forEach((child) => {
          updates[`/devices/${child.key}/maxOnDurationSeconds`] = clamped;
        });
        await db.ref().update(updates);
      }

      // Persist the normalized value so this function is not re-triggered.
      if (clamped !== raw) {
        await db.ref("/settings/safety/ironMaxOnSeconds").set(clamped);
      }

      return null;
    },
);

/**
 * HTTP endpoint returning the current settings as JSON for backend or
 * automation consumers.
 * GET /settingsSummary
 */
exports.settingsSummary = onRequest(
    {
      region: "asia-southeast1",
      cors: true,
    },

    async (req, res) => {
      const settingsSnap = await db.ref("/settings").get();
      const ironSnap = await db.ref("/devices/safety_iron").get();

      const settings = settingsSnap.val() || {};
      const iron = ironSnap.val() || {};

      const saved = iron.maxOnDurationSeconds;
      const configured = settings.safety ?
        settings.safety.ironMaxOnSeconds :
        undefined;

      let ironMaxOnSeconds = 30;
      if (typeof saved === "number") {
        ironMaxOnSeconds = saved;
      } else if (typeof configured === "number") {
        ironMaxOnSeconds = configured;
      }

      res.json({
        generatedAt: Date.now(),
        settings,
        applied: {ironMaxOnSeconds},
      });
    },
);

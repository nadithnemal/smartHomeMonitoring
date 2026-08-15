# Smart Home Monitor — Codebase Analysis

A cross-platform **Smart Home Monitor** application built with Flutter, backed by
Google Firebase (Realtime Database, Cloud Functions, and Hosting). It lets a
homeowner monitor and control devices (lights, outlets, cameras, multi-switch
gang boxes, and a safety device) across a ground floor and a first floor, with a
server-side safety auto-off mechanism for a "Safety Iron."

---

## 1. Overview

The system is split into three cooperating parts:

| Component | Location | Role |
|---|---|---|
| **Flutter App** | `lib/` | Mobile/desktop/web UI for monitoring, controlling & reporting |
| **Cloud Functions** | `functions/` | Safety Iron watchdog, event logging, HTTP report endpoint |
| **Hardware Simulator** | `hardware-simulator/` | Standalone web page simulating physical devices, hosted by Firebase Hosting |

All device state lives in the **Firebase Realtime Database** under the
`/devices` node. The Flutter app subscribes to real-time updates; the simulator
writes directly to the database; and Cloud Functions react to changes.

---

## 2. Tech Stack

| Layer | Technology |
|---|---|
| App | Flutter (Dart SDK `^3.12.2`), Material 3 |
| Backend | Firebase Realtime Database + Cloud Functions (Node 24) |
| Functions SDK | `firebase-functions` v7 (`onValueUpdated` trigger) |
| Admin SDK | `firebase-admin` v13 |
| Frontend simulator | Vanilla HTML/CSS/JS, polls the RTDB REST API every 2 s |
| Linting | `flutter_lints` v6 (Dart), `eslint` (JS) |
| Deployment | Firebase CLI (`firebase.json`, `.firebaserc`) |

Key Dart dependencies (`pubspec.yaml`):

- `firebase_core: ^4.12.1`
- `firebase_database: ^12.4.6`
- `cupertino_icons: ^1.0.8`

Dev dependencies: `flutter_test`, `flutter_lints: ^6.0.0`.

---

## 3. Project Structure

```
smart_home_monitor/
├── lib/                        # Flutter application source
│   ├── main.dart               # App shell, models, dashboard, cards, floor plan
│   ├── reports_screen.dart     # Responsive Reports tab (stats + activity log)
│   ├── settings_screen.dart    # Responsive Settings tab (app/safety/data)
│   └── firebase_options.dart   # Generated Firebase config (FlutterFire CLI)
├── functions/                  # Cloud Functions for Firebase
│   ├── index.js                # safetyIronCutoff, recordDeviceEvents, reportsSummary
│   ├── package.json            # Node 24, firebase-functions v7
│   └── .eslintrc.js
├── hardware-simulator/         # Static site served by Firebase Hosting
│   ├── index.html              # Full hardware simulator UI + logic
│   └── 404.html
├── test/
│   └── widget_test.dart        # Unit tests for device/report models
├── android/ ios/ windows/ web/ linux/ macos/   # Platform scaffolding
├── firebase.json               # Hosting, functions & emulator config
├── .firebaserc                 # Default project mapping
├── pubspec.yaml
├── analysis_options.yaml
└── README.md                   # Default Flutter README (not updated)
```

> Note: `lib/main.dart` contains the dashboard UI, models, and the floor plan
> in a single ~1,000-line file — the Reports screen is the only screen split out
> into its own file (`lib/reports_screen.dart`).

---

## 4. Firebase Setup

- **Project ID:** `smart-home-monitoring-sy-48629`
- **Database:** Realtime Database at
  `https://smart-home-monitoring-sy-48629-default-rtdb.asia-southeast1.firebasedatabase.app`
- **Platforms registered:** android, ios, macos, web, windows
- **Hosting:** serves the `hardware-simulator/` directory
- **Functions region:** `asia-southeast1`

`firebase.json` also defines **local emulators**:

| Emulator | Port |
|---|---|
| Functions | 5001 |
| Database | 9000 |
| Hosting | 5000 |
| UI (Emulator Suite) | enabled |

Firebase credentials for each platform are auto-generated in
`lib/firebase_options.dart` (do not edit by hand — regenerate with FlutterFire
CLI). Note that Linux is **not** configured and will throw an `UnsupportedError`.

---

## 5. Data Model

### 5.1 Realtime Database structure

```
/devices
├── living_room_light        { name, room, type, floor, status, details, updatedAt }
├── tv_power_outlet          { ... }
├── main_camera              { ... }
├── kitchen_switch_unit      { ... , switches: { sw1: {...}, sw2: {...}, sw3: {...} } }
├── bedroom_light            { ... }
├── safety_iron              { ... , maxOnDurationSeconds, activatedAt, safetyAlert?, safetyTriggeredAt? }
├── study_outlet             { ... }
└── upstairs_camera          { ... }
```

### 5.2 Common device fields

| Field | Type | Notes |
|---|---|---|
| `name` | string | Display name |
| `room` | string | Room the device lives in |
| `type` | string | `Light`, `Outlet`, `Camera`, `Multi-switch`, `Safety device` |
| `floor` | number | `0` = ground, `1` = first |
| `status` | string | `ON`, `OFF`, `ERROR`, `DISCONNECTED` |
| `details` | string | Free-text description / schedule |
| `updatedAt` | timestamp | `ServerValue.timestamp` |

### 5.3 Multi-switch units (`switches` map)

A `Multi-switch` device (e.g. `kitchen_switch_unit`) holds an object map of
individual switches. Each sub-switch:

| Field | Type | Notes |
|---|---|---|
| `sw1` | object | `{ name: "Fridge Outlet", status: "ON" }` |
| `sw2` | object | `{ name: "Counter Lights", status: "OFF" }` |
| `sw3` | object | `{ name: "Exhaust Fan", status: "ON" }` |

**Derived status:** a multi-switch unit's overall `status` is **derived** — it is
`ON` if any sub-switch is `ON`, `OFF` otherwise — **unless** the stored status is
explicitly `ERROR` or `DISCONNECTED`. This derivation happens in
`HomeDevice.fromMap()` (`lib/main.dart:119-129`) and is mirrored in the
simulator's `loadDevices()` (`hardware-simulator/index.html:481-489`).

### 5.4 Seed data

On first run (empty database), the app seeds 8 devices via
`HomeDevice.seedDevices` (`lib/main.dart:159-237`):

| ID | Type | Floor | Default status |
|---|---|---|---|
| `living_room_light` | Light | 0 | ON |
| `tv_power_outlet` | Outlet | 0 | OFF |
| `main_camera` | Camera | 0 | ON |
| `kitchen_switch_unit` | Multi-switch | 0 | ON (sw1/sw3 on) |
| `bedroom_light` | Light | 1 | OFF |
| `safety_iron` | Safety device | 1 | OFF |
| `study_outlet` | Outlet | 1 | ON |
| `upstairs_camera` | Camera | 1 | ON |

### 5.5 Settings node (`/settings`)

App + safety preferences, seeded with defaults and kept in sync across web,
mobile, and the backend:

```
/settings
├── app
│   ├── defaultFloor          int  (0|1)
│   ├── themeMode             string ("light" | "dark" | "system")
│   └── notificationsEnabled  bool
└── safety
    └── ironMaxOnSeconds      int  (5-120, default 30)
```

Consumers:
- `SmartHomeApp` → app-wide theme via `/settings/app/themeMode`.
- Dashboard → default floor, iron auto-off duration, notifications toggle.
- `syncIronSetting` (Cloud Function) → mirrors `ironMaxOnSeconds` onto
  `/devices/safety_iron/maxOnDurationSeconds`.
- `settingsSummary` (Cloud Function) → exposes the settings as JSON.

---

## 6. Flutter App (`lib/main.dart`)

### 6.1 Bootstrap (`main.dart:9-17`)

```dart
await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
runApp(const SmartHomeApp());
```

`SmartHomeApp` (a `StatefulWidget` in `main.dart`) owns the top-level
`Scaffold` + `NavigationBar` with three tabs (Dashboard / Reports / Settings)
backed by an `IndexedStack` so each tab keeps its state when switching. The
app uses an indigo Material 3 color scheme and `debugShowCheckedModeBanner:
false`.

### 6.2 Models

- **`SwitchUnit`** (`:38-65`) — a single addressable switch; exposes `isOn`
  (`status == 'ON'`), `fromMap`/`toMap`.
- **`HomeDevice`** (`:67-238`) — the core device model with `id`, `name`,
  `room`, `type`, `floor`, `status`, `details`, and `switches` map. Helpers:
  - `isOn` — status is `ON`
  - `isMultiSwitch` — type is `Multi-switch`
  - `sortedSwitches` — switches ordered by id for stable display
  - `fromMap` / `toMap` — serialization, including derived multi-switch status
    and `ServerValue.timestamp` on write

### 6.3 `SmartHomeDashboard` (`:240-675`)

The main screen. Key behavior:

- **Realtime sync** (`startRealtimeSync`, `:269-308`):
  - Reads `/devices` once; seeds the database if empty.
  - Subscribes via `devicesRef.onValue`; parses, sorts by name, and `setState`s.
  - Shows a SnackBar on Firebase errors.
- **Sub-switch toggle** (`toggleSubSwitch`, `:313-322`): writes the new switch
  status and bumps `updatedAt`; overall device status re-derives through the
  stream.
- **Multi-switch sheet** (`showMultiSwitchSheet`, `:324-396`): a modal bottom
  sheet with a `StreamBuilder` on the single device node and a
  `SwitchListTile` per sub-switch.
- **Device toggle** (`toggleDevice`, `:398-438`):
  - Cameras just show a "mock feed" SnackBar.
  - `ERROR`/`DISCONNECTED` devices cannot be toggled.
  - Toggling the Safety Iron **ON** writes `maxOnDurationSeconds: 30` and
    `activatedAt`, then starts a local countdown timer.
- **Safety Iron local timer** (`startIronSafetyTimer`, `:440-485`): a 1-second
  `Timer.periodic` counts down from 30; at 0 it writes `status: OFF`,
  `safetyAlert`, `safetyTriggeredAt` and shows a SnackBar.
- **UI layout** (`build`, `:495-674`):
  - Home Overview card: counts active devices on the selected floor, floor
    selector (`DropdownButton`).
  - Live iron countdown + red safety-alert banner.
  - 2-column `GridView` of `DeviceCard`s.
  - AppBar actions: **floor plan** (opens `FloorPlanScreen`) and **notifications**
    (bell reflects the "Safety notifications" setting).
  - Reads **user settings** from `/settings` via a single subscription
    (`_subscribeSettings`): the Safety Iron auto-off duration
    (`ironMaxSeconds`), the default floor, and the notifications toggle. The
    floor dropdown also marks the user's manual choice so setting changes don't
    override it.

### 6.4 `ReportsScreen` (`lib/reports_screen.dart`)

The **Reports** tab — a responsive screen that works on mobile (narrow,
stacked) and web/desktop (wide, max-width 1100 centered). It subscribes to two
Firebase nodes:

- `/devices` — current device state (for summary + distribution stats)
- `/logs` — event history written by the `recordDeviceEvents` Cloud Function

Contents:

- **Range selector** — `ChoiceChip`s for Today / Last 7 days / Last 30 days /
  All time, filtering the activity log.
- **Summary cards** (`_SummaryCard`) — Total Devices, Devices ON, Devices OFF,
  Alerts (ERROR/DISCONNECTED), and Event count. Responsive layout: 4-up on wide
  screens, 2-up on narrow.
- **Device Distribution** (`_DistributionCard` + `_StatBarRow`) — custom bar
  charts (no chart dependency) for By Type, By Status, and By Floor.
- **Activity** — "Most Active Devices" top-5 list plus a timestamped log of
  status changes (`_ActivityTile`), with an empty state explaining how data is
  generated.

Supporting models live in the same file:

- `StatusChange` — one field change (`status` or `switch.status`) with `from` /
  `to`, `switchId`/`switchName`, and a human-readable `description`.
- `DeviceLogEntry` — one `/logs` record: device metadata, timestamp, and a list
  of `StatusChange`s.
- `ReportRange` — the four selectable ranges.

### 6.5 `SettingsScreen` (`lib/settings_screen.dart`)

The **Settings** tab — a responsive form (max-width 760 centered on
web/desktop, full width on mobile). All values live in the RTDB under
`/settings` and sync in realtime to the Dashboard, the app theme, and the
backend.

- **Appearance** (`_SectionCard`) — theme mode (Light / Dark / System), default
  floor (Ground / First), and a notifications toggle. Theme changes are applied
  app-wide by `SmartHomeApp`, which subscribes to
  `/settings/app/themeMode`.
- **Safety** — a `Slider` (5–120 s) for the Safety Iron auto-off duration,
  written to `/settings/safety/ironMaxOnSeconds`. The `syncIronSetting` Cloud
  Function keeps `/devices/safety_iron/maxOnDurationSeconds` in sync, so the
  server watchdog honors it.
- **Data management** — "Reset demo devices" (re-seeds `/devices`) and "Clear
  activity logs" (`/logs.remove()`), both with confirmation dialogs.
- **About** — app version, Firebase project, database URL, and server function
  list.

Supporting model `AppSettings` (same file) parses/validates/serializes the
settings node, with `copyWith`, `toMap`, and `clampIronSeconds`.

> The tab was previously a "Settings coming soon" placeholder.

### 6.6 `DeviceCard` (`:677-789`)

A tappable card showing an icon (`getDeviceIcon`, color by status
`getStatusColor`), name, room, detail/subtitle (`n/2 switches ON` for
multi-switch), and a status indicator. Shows a `Switch` for simple devices, a
chevron for multi-switch units, and "VIEW" for cameras. Status → color mapping:

| Status | Color |
|---|---|
| ON | green |
| ERROR | red |
| DISCONNECTED | orange |
| OFF | grey |

### 6.7 `FloorPlanScreen` (`:791-1005`)

An interactive SVG-like floor plan built with a `Stack` + `LayoutBuilder`:

- `SegmentedButton` to switch between Ground/First floor.
- Four `FloorRoom` containers positioned per floor; device icons overlaid at
  normalized `Offset` positions from `positionsForFloor()` (`:867-883`).
- Devices are draggable-free: tapping an icon calls `onToggle` (multi-switch
  units redirect the user to the Dashboard).
- Subscribes to the same `/devices` stream to stay in sync.
- Legend: `Green: ON   Grey: OFF   Red: ERROR   Orange: DISCONNECTED`.

### 6.8 `FloorRoom` (`:1007-1027`)

Simple bordered `Container` used to label rooms on the floor plan.

---

## 7. Cloud Functions (`functions/index.js`)

Three functions run in the `asia-southeast1` region:

**`safetyIronCutoff`** — a `v2/database` `onValueUpdated` trigger watching
`/devices/safety_iron`. This is the **server-side** safety mechanism that makes
the auto-off behavior work even if the app/simulator is not running.

Flow:

1. Ignore if the device was deleted or is not transitioning `OFF → ON`.
2. Read `maxOnDurationSeconds` (defaults to `30`) and `activatedAt`.
3. Wait `maxDuration` seconds server-side.
4. Re-read the device; abort if it no longer exists, was already turned off, or
   has a **different `activatedAt`** (a newer activation supersedes this one).
5. Otherwise write `status: OFF`, `safetyAlert`, `safetyTriggeredAt`,
   `updatedAt`, and log.

This guards against "stale" activations: only the most recent `activatedAt`
is allowed to cut off the iron.

**`recordDeviceEvents`** — a `v2/database` `onValueWritten` trigger watching
`/devices/{deviceId}`. It powers the Reports tab and the summary endpoint:

- Compares `before`/`after` snapshots and collects **status changes** (the
  device `status` field plus any sub-switch status in the `switches` map).
- Writes one entry to `/logs/<pushId>` with `deviceId`, `deviceName`, `room`,
  `type`, `floor`, the list of `events`, and a server `timestamp`.
- Ignores creates/deletes and writes that contain no status change (e.g. the
  `updatedAt` bumps that accompany every toggle).

**`syncIronSetting`** — a `v2/database` `onValueWritten` trigger watching
`/settings/safety/ironMaxOnSeconds`. Server-side enforcement of the Safety Iron
auto-off duration:

- Clamps the value to the 5–120 s range.
- Mirrors it onto `/devices/safety_iron/maxOnDurationSeconds` so the
  `safetyIronCutoff` watchdog honors the configured duration.
- Persists the normalized value back to settings only when it differs, so the
  function does not re-trigger in a loop.

**`reportsSummary`** — an HTTP (`v2/https`, CORS-enabled) endpoint returning
aggregate JSON for external/backend consumers:

```
GET /reportsSummary?days=7     # days=0 means all time
```

```json
{
  "generatedAt": 1720000000000,
  "rangeDays": 7,
  "devices": { "total": 8, "byStatus": {"ON": 4, "OFF": 4}, "byType": {...} },
  "activity": { "eventCount": 12, "perDevice": { "Safety Iron": 3 } }
}
```

**`settingsSummary`** — an HTTP (`v2/https`, CORS-enabled) endpoint returning
the current settings and the applied iron duration as JSON for backend /
automation consumers:

```
GET /settingsSummary
```

```json
{
  "generatedAt": 1720000000000,
  "settings": { "app": {...}, "safety": {"ironMaxOnSeconds": 60} },
  "applied": { "ironMaxOnSeconds": 60 }
}
```

---

## 8. Hardware Simulator (`hardware-simulator/index.html`)

A self-contained static page simulating real physical hardware, communicating
with the RTDB via its **REST API** (polling every 2 seconds).

- Reads `/devices.json`, computes summary stats (total devices, devices ON,
  safety status), renders a card per device grouped by floor.
- Mirrors app status derivation for multi-switch units and the safety-iron
  status icon (`Safe` vs `Iron Active`).
- Writes via `PATCH` to `/devices/<id>.json` and
  `/devices/<id>/switches/<switchId>.json`.
- Also implements a **client-side** 30 s iron timer (`startIronTimer`) and
  renders `safetyAlert` banners.
- Cameras show a "Mock camera feed" `alert()`.
- `ERROR`/`DISCONNECTED` devices disable their controls.

> Both the simulator and the app implement their own iron countdown, and the
> Cloud Function provides the authoritative server-side cutoff.

---

## 9. Tests

`test/widget_test.dart` contains pure unit tests (no Firebase required) for the
core models:

- `HomeDevice.fromMap` — field parsing, defaults, multi-switch **derived
  status**, `ERROR`/`DISCONNECTED` override, `toMap` server timestamp, seed
  data shape.
- `SwitchUnit.isOn`, `DeviceLogEntry.fromMap` (incl. sub-switch events),
  `ReportRange` labels.
- `AppSettings` — defaults, nested `app`/`safety` parsing, theme fallback,
  iron-duration clamping, `toMap`, `copyWith`.

> Note: the file was rewritten from the default Flutter counter smoke test,
> which referenced a `MyApp` class that no longer exists.

---

## 10. Configuration Files

| File | Purpose |
|---|---|
| `pubspec.yaml` | Dart package config, version `1.0.0+1`, SDK `^3.12.2` |
| `analysis_options.yaml` | `flutter_lints` defaults |
| `firebase.json` | Hosting, functions source, predeploy lint, emulator ports |
| `.firebaserc` | Default project: `smart-home-monitoring-sy-48629` |
| `lib/firebase_options.dart` | Auto-generated Firebase options per platform |
| `functions/package.json` | Node 24, `firebase-functions` v7, eslint scripts |
| `.eslintrc.js` | ESLint config (Google style) for functions |
| `hardware-simulator/404.html` | Firebase Hosting 404 page |

---

## 11. Common Commands

```bash
# Run the Flutter app
flutter run

# Analyze Dart code
flutter analyze

# Lint & deploy Cloud Functions
npm --prefix functions run lint
firebase deploy --only functions

# Deploy the hardware simulator to Hosting
firebase deploy --only hosting

# Run the Firebase Emulator Suite
firebase emulators:start
```

---

## 12. Notable Observations & Potential Improvements

1. **Monolithic `main.dart`** — models, business logic, and all widgets live in
   one file. Consider splitting into `models/`, `services/`, `screens/`,
   `widgets/`. (`reports_screen.dart` and `settings_screen.dart` are already
   separate files.)
2. **Security** — Realtime Database rules are not visible in the repo; the
   simulator and app write directly to the DB using public API keys. RTDB
   security rules should be reviewed before production.
3. **Polling simulator** — the simulator uses 2 s polling of the REST API
   instead of the realtime SDK; acceptable for a demo but not "live".
4. **Duplicated safety logic** — the auto-off is implemented in three places
   (app timer, simulator timer, Cloud Function). The CF is authoritative; the
   other two are client-side UX conveniences.
5. **Linux unsupported** — `DefaultFirebaseOptions` throws for Linux.
6. **Simulator ignores settings** — the hardware simulator still hardcodes a
   30 s iron duration; it does not read `/settings` like the Flutter app does.
7. **Reports data availability** — the activity log (`/logs`) only fills up
   *after* the `recordDeviceEvents` Cloud Function is deployed, so the Reports
   tab starts empty until devices are toggled. The whole `/logs` node is also
   streamed in one shot; for high-volume deployments a per-day path or query
   (`orderByChild("timestamp")`) should be used instead.
8. **README.md** — still the default Flutter README; does not describe this
   project.

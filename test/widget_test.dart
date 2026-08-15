// Unit tests for the core device models.
//
// These cover the pure serialization / status-derivation logic and do not
// require Firebase, so they run anywhere.

import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_database/firebase_database.dart';

import 'package:smart_home_monitor/main.dart';
import 'package:smart_home_monitor/reports_screen.dart';
import 'package:smart_home_monitor/settings_screen.dart';

void main() {
  group('HomeDevice', () {
    test('parses a basic device from the database map', () {
      final device = HomeDevice.fromMap(
        'living_room_light',
        {
          'name': 'Living Room Light',
          'room': 'Living Room',
          'type': 'Light',
          'floor': 0,
          'status': 'ON',
          'details': 'Schedule',
        },
      );

      expect(device.id, 'living_room_light');
      expect(device.name, 'Living Room Light');
      expect(device.room, 'Living Room');
      expect(device.type, 'Light');
      expect(device.floor, 0);
      expect(device.isOn, isTrue);
      expect(device.isMultiSwitch, isFalse);
    });

    test('uses defaults for missing fields', () {
      final device = HomeDevice.fromMap('missing', {});

      expect(device.name, 'Unknown Device');
      expect(device.room, 'Unknown Room');
      expect(device.type, 'Device');
      expect(device.floor, 0);
      expect(device.status, 'OFF');
      expect(device.isOn, isFalse);
    });

    test('multi-switch status is derived from its switches', () {
      final device = HomeDevice.fromMap(
        'kitchen_switch_unit',
        {
          'name': 'Kitchen Switch Unit',
          'type': 'Multi-switch',
          'floor': 0,
          'status': 'OFF',
          'switches': {
            'sw1': {'name': 'Fridge', 'status': 'OFF'},
            'sw2': {'name': 'Lights', 'status': 'ON'},
          },
        },
      );

      expect(device.isMultiSwitch, isTrue);
      expect(device.status, 'ON');
      expect(device.sortedSwitches.length, 2);
      expect(device.sortedSwitches.first.id, 'sw1');
    });

    test('multi-switch status respects explicit ERROR/DISCONNECTED', () {
      final errorDevice = HomeDevice.fromMap(
        'kitchen_switch_unit',
        {
          'type': 'Multi-switch',
          'status': 'ERROR',
          'switches': {
            'sw1': {'name': 'Fridge', 'status': 'ON'},
          },
        },
      );

      expect(errorDevice.status, 'ERROR');
    });

    test('toMap includes an updatedAt server timestamp', () {
      final device = HomeDevice.fromMap(
        'tv_power_outlet',
        {'name': 'TV', 'type': 'Outlet', 'floor': 0, 'status': 'OFF'},
      );

      final map = device.toMap();

      expect(map['status'], 'OFF');
      expect(map['updatedAt'], ServerValue.timestamp);
    });

    test('seed data contains eight devices across two floors', () {
      expect(HomeDevice.seedDevices.length, 8);
      expect(HomeDevice.seedDevices.where((d) => d.floor == 0).length, 4);
      expect(HomeDevice.seedDevices.where((d) => d.floor == 1).length, 4);
    });
  });

  group('HomeFloor', () {
    test('parses a floor from the database map', () {
      final floor = HomeFloor.fromMap('2', 2, {'name': 'Second Floor'});

      expect(floor.key, '2');
      expect(floor.level, 2);
      expect(floor.name, 'Second Floor');
    });

    test('falls back to a numbered name when missing', () {
      final floor = HomeFloor.fromMap('floor_3', 3, {});

      expect(floor.name, 'Floor 3');
    });

    test('toMap includes level and a server timestamp', () {
      final map = const HomeFloor(key: 'floor_1', level: 1, name: 'First Floor')
          .toMap();

      expect(map['name'], 'First Floor');
      expect(map['level'], 1);
      expect(map['updatedAt'], ServerValue.timestamp);
    });

    test('parseFloors handles a Map keyed by level', () {
      final floors = parseFloors({
        '0': {'name': 'Ground Floor', 'level': 0},
        '2': {'name': 'Second Floor', 'level': 2},
        '1': {'name': 'First Floor', 'level': 1},
      });

      expect(floors.length, 3);
      expect(floors.map((f) => f.key), ['0', '1', '2']);
      expect(floors.map((f) => f.level), [0, 1, 2]);
      expect(floors.first.name, 'Ground Floor');
    });

    test('parseFloors handles non-sequential string keys (floor_N)', () {
      final floors = parseFloors({
        'floor_0': {'name': 'ground'},
        'floor_2': {'name': 'second floor'},
        'floor_1': {'name': 'first floor'},
      });

      expect(floors.length, 3);
      expect(floors.map((f) => f.key), ['floor_0', 'floor_1', 'floor_2']);
      expect(floors.map((f) => f.level), [0, 1, 2]);
      expect(floors.first.name, 'ground');
    });

    test('parseFloors falls back to map level when the key has no digits', () {
      final floors = parseFloors({
        'ground': {'name': 'Ground Floor', 'level': 0},
        'first': {'name': 'First Floor', 'level': 1},
      });

      expect(floors.length, 2);
      expect(floors.map((f) => f.key), ['ground', 'first']);
      expect(floors.map((f) => f.level), [0, 1]);
    });

    test('parseFloors handles a List (web SDK array shape)', () {
      final floors = parseFloors([
        {'name': 'Ground Floor', 'level': 0},
        {'name': 'First Floor', 'level': 1},
        {'name': 'Second Floor', 'level': 2},
      ]);

      expect(floors.length, 3);
      expect(floors.map((f) => f.level), [0, 1, 2]);
      expect(floors[2].name, 'Second Floor');
    });

    test('parseFloors falls back to list index for missing levels', () {
      final floors = parseFloors([
        {'name': 'ground'},
        {'name': 'first floor'},
      ]);

      expect(floors.map((f) => f.level), [0, 1]);
      expect(floors.first.name, 'ground');
    });

    test('parseFloors returns an empty list for empty input', () {
      expect(parseFloors(null), isEmpty);
      expect(parseFloors({}), isEmpty);
      expect(parseFloors([]), isEmpty);
    });
  });

  group('slugify', () {
    test('produces a stable RTDB key', () {
      expect(slugify('Living Room Light'), 'living_room_light');
    });

    test('collapses non-alphanumeric runs and trims edges', () {
      expect(slugify('  Garage -- Light!! '), 'garage_light');
    });

    test('keeps digits and single underscores', () {
      expect(slugify('TV 2'), 'tv_2');
    });

    test('falls back for empty and blank input', () {
      expect(slugify(''), 'device');
      expect(slugify('   '), 'device');
    });
  });

  group('SwitchUnit', () {
    test('isOn reflects the status string', () {
      expect(const SwitchUnit(id: 'sw1', name: 'Fridge', status: 'ON').isOn,
          isTrue);
      expect(const SwitchUnit(id: 'sw2', name: 'Lights', status: 'OFF').isOn,
          isFalse);
    });
  });

  group('DeviceLogEntry', () {
    test('parses a log entry with multiple events', () {
      final entry = DeviceLogEntry.fromMap(
        '-log-id',
        {
          'deviceId': 'safety_iron',
          'deviceName': 'Safety Iron',
          'room': 'Laundry Room',
          'type': 'Safety device',
          'floor': 1,
          'timestamp': 1700000000000,
          'events': [
            {'field': 'status', 'from': 'OFF', 'to': 'ON'},
            {'field': 'status', 'from': 'ON', 'to': 'OFF'},
          ],
        },
      );

      expect(entry.id, '-log-id');
      expect(entry.deviceId, 'safety_iron');
      expect(entry.deviceName, 'Safety Iron');
      expect(entry.floor, 1);
      expect(entry.timestamp,
          DateTime.fromMillisecondsSinceEpoch(1700000000000));
      expect(entry.events.length, 2);
      expect(entry.events.first.description, 'Status: OFF -> ON');
    });

    test('parses sub-switch events with switch names', () {
      final entry = DeviceLogEntry.fromMap(
        '-log-id',
        {
          'deviceName': 'Kitchen Switch Unit',
          'timestamp': 1700000000000,
          'events': [
            {
              'field': 'switch.status',
              'switchId': 'sw1',
              'switchName': 'Fridge Outlet',
              'from': 'OFF',
              'to': 'ON',
            },
          ],
        },
      );

      expect(entry.events.single.description,
          'Fridge Outlet: OFF -> ON');
    });

    test('survives missing optional fields', () {
      final entry = DeviceLogEntry.fromMap('-log-id', {});

      expect(entry.deviceName, 'Unknown device');
      expect(entry.events, isEmpty);
    });
  });

  group('ReportRange', () {
    test('exposes friendly labels', () {
      expect(ReportRange.today.label, 'Today');
      expect(ReportRange.last7.label, 'Last 7 days');
      expect(ReportRange.last30.label, 'Last 30 days');
      expect(ReportRange.all.label, 'All time');
    });
  });

  group('AppSettings', () {
    test('applies defaults for an empty map', () {
      const settings = AppSettings();

      expect(settings.defaultFloor, 0);
      expect(settings.themeMode, 'system');
      expect(settings.notificationsEnabled, isTrue);
      expect(settings.ironMaxOnSeconds, 30);
    });

    test('parses nested app and safety maps', () {
      final settings = AppSettings.fromMap({
        'app': {
          'defaultFloor': 1,
          'themeMode': 'dark',
          'notificationsEnabled': false,
        },
        'safety': {'ironMaxOnSeconds': 60},
      });

      expect(settings.defaultFloor, 1);
      expect(settings.themeMode, 'dark');
      expect(settings.notificationsEnabled, isFalse);
      expect(settings.ironMaxOnSeconds, 60);
    });

    test('falls back to system theme for unknown values', () {
      final settings = AppSettings.fromMap({
        'app': {'themeMode': 'neon'},
      });

      expect(settings.themeMode, 'system');
    });

    test('clamps the iron auto-off duration', () {
      expect(AppSettings.clampIronSeconds(1), 5);
      expect(AppSettings.clampIronSeconds(500), 120);
      expect(AppSettings.clampIronSeconds(45), 45);
    });

    test('toMap writes nested app and safety nodes', () {
      final map = const AppSettings(
        defaultFloor: 1,
        themeMode: 'dark',
        notificationsEnabled: false,
        ironMaxOnSeconds: 60,
      ).toMap();

      expect(map['app'], {
        'defaultFloor': 1,
        'themeMode': 'dark',
        'notificationsEnabled': false,
      });
      expect(map['safety'], {'ironMaxOnSeconds': 60});
    });

    test('copyWith updates only provided fields', () {
      const settings = AppSettings();
      final next = settings.copyWith(defaultFloor: 1);

      expect(next.defaultFloor, 1);
      expect(next.themeMode, 'system');
      expect(next.notificationsEnabled, isTrue);
      expect(next.ironMaxOnSeconds, 30);
    });
  });
}

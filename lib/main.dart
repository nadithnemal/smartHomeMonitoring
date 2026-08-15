import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import 'firebase_options.dart';
import 'camera_video_screen.dart';
import 'reports_screen.dart';
import 'settings_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  runApp(const SmartHomeApp());
}

class SmartHomeApp extends StatefulWidget {
  const SmartHomeApp({super.key});

  @override
  State<SmartHomeApp> createState() => _SmartHomeAppState();
}

class _SmartHomeAppState extends State<SmartHomeApp> {
  int _selectedIndex = 0;
  ThemeMode _themeMode = ThemeMode.system;
  StreamSubscription<DatabaseEvent>? _settingsSubscription;

  @override
  void initState() {
    super.initState();

    _settingsSubscription = FirebaseDatabase.instance
        .ref('settings/app/themeMode')
        .onValue
        .listen(
          (event) {
            final value = event.snapshot.value;

            if (value is String) {
              setState(() {
                _themeMode = _parseThemeMode(value);
              });
            }
          },
          onError: (_) {},
        );
  }

  @override
  void dispose() {
    _settingsSubscription?.cancel();
    super.dispose();
  }

  ThemeMode _parseThemeMode(String value) {
    switch (value) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Smart Home Monitor',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: _themeMode,
      home: Scaffold(
        body: IndexedStack(
          index: _selectedIndex,
          children: const [
            SmartHomeDashboard(),
            ReportsScreen(),
            SettingsScreen(),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _selectedIndex,
          onDestinationSelected: (index) {
            setState(() {
              _selectedIndex = index;
            });
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: 'Dashboard',
            ),
            NavigationDestination(
              icon: Icon(Icons.bar_chart_outlined),
              selectedIcon: Icon(Icons.bar_chart),
              label: 'Reports',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }
}

/// One floor of the home, persisted in the Firebase Realtime Database
/// under `/floors/<key>` and referenced by each device's `floor` field.
class HomeFloor {
  /// The actual Realtime Database key of this floor (e.g. `floor_0`).
  final String key;
  final int level;
  final String name;

  const HomeFloor({
    required this.key,
    required this.level,
    required this.name,
  });

  factory HomeFloor.fromMap(String key, int level, Map<String, dynamic> map) {
    return HomeFloor(
      key: key,
      level: level,
      name: map['name'] as String? ?? 'Floor $level',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'level': level,
      'updatedAt': ServerValue.timestamp,
    };
  }
}

/// A single addressable switch inside a Multi-Switch gang-box unit
/// (e.g. one of 3 switches in "Kitchen Switch Unit").
class SwitchUnit {
  final String id;
  final String name;
  final String status;

  const SwitchUnit({
    required this.id,
    required this.name,
    required this.status,
  });

  bool get isOn => status == 'ON';

  factory SwitchUnit.fromMap(String id, Map<String, dynamic> map) {
    return SwitchUnit(
      id: id,
      name: map['name'] as String? ?? 'Switch',
      status: map['status'] as String? ?? 'OFF',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'status': status,
    };
  }
}

/// Converts a device name into a stable RTDB key, e.g.
/// "Living Room Light" -> "living_room_light".
String slugify(String value) {
  final cleaned = value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r"[^a-z0-9]+"), "_")
      .replaceAll(RegExp(r"^_+|_+$"), "");

  return cleaned.isEmpty ? 'device' : cleaned;
}

/// Parses the /floors node into a sorted list of floors.
///
/// The Realtime Database can return this node in two shapes:
///  - as a Map keyed by the floor key (all platforms once floors use
///    non-sequential keys like `floor_0`, and native Android/iOS SDK), or
///  - as a List, because the keys are sequential integers, which the JS web
///    SDK and REST convert to an array.
List<HomeFloor> parseFloors(dynamic value) {
  final result = <HomeFloor>[];

  if (value is Map) {
    for (final entry in value.entries) {
      final map = entry.value is Map
          ? Map<String, dynamic>.from(entry.value as Map)
          : <String, dynamic>{};
      final key = entry.key.toString();
      var level = int.tryParse(key.replaceAll(RegExp(r'[^0-9]'), ''));
      level ??= (map['level'] as num?)?.toInt();
      if (level == null) {
        continue;
      }
      result.add(HomeFloor.fromMap(key, level, map));
    }
  } else if (value is List) {
    for (var i = 0; i < value.length; i++) {
      final map = value[i] is Map
          ? Map<String, dynamic>.from(value[i] as Map)
          : <String, dynamic>{};
      final level = (map['level'] as num?)?.toInt() ??
          (map['index'] as num?)?.toInt() ??
          i;
      result.add(HomeFloor.fromMap('$i', level, map));
    }
  }

  result.sort((a, b) => a.level.compareTo(b.level));
  return result;
}

class HomeDevice {
  final String id;
  final String name;
  final String room;
  final String type;
  final int floor;
  final String status;
  final String details;
  final Map<String, SwitchUnit> switches;

  const HomeDevice({
    required this.id,
    required this.name,
    required this.room,
    required this.type,
    required this.floor,
    required this.status,
    required this.details,
    this.switches = const {},
  });

  bool get isOn => status == 'ON';

  bool get isMultiSwitch => type == 'Multi-switch';

  /// Switches sorted by id, for stable display order.
  List<SwitchUnit> get sortedSwitches {
    final list = switches.values.toList();
    list.sort((a, b) => a.id.compareTo(b.id));
    return list;
  }

  factory HomeDevice.fromMap(String id, Map<String, dynamic> map) {
    final savedStatus = map['status'];
    final type = map['type'] as String? ?? 'Device';

    final Map<String, SwitchUnit> parsedSwitches = {};
    final switchesRaw = map['switches'];
    if (switchesRaw is Map) {
      switchesRaw.forEach((key, value) {
        if (value is Map) {
          parsedSwitches[key.toString()] = SwitchUnit.fromMap(
            key.toString(),
            Map<String, dynamic>.from(value),
          );
        }
      });
    }

    // A multi-switch unit's overall status is DERIVED from its individual
    // switches (ON if any switch is ON), unless it's explicitly flagged as
    // ERROR/DISCONNECTED (e.g. simulating a hardware fault).
    String resolvedStatus;
    if (savedStatus == 'ERROR' || savedStatus == 'DISCONNECTED') {
      resolvedStatus = savedStatus as String;
    } else if (type == 'Multi-switch' && parsedSwitches.isNotEmpty) {
      resolvedStatus =
      parsedSwitches.values.any((s) => s.isOn) ? 'ON' : 'OFF';
    } else if (savedStatus is String) {
      resolvedStatus = savedStatus;
    } else {
      resolvedStatus = (map['isOn'] == true) ? 'ON' : 'OFF';
    }

    return HomeDevice(
      id: id,
      name: map['name'] as String? ?? 'Unknown Device',
      room: map['room'] as String? ?? 'Unknown Room',
      type: type,
      floor: (map['floor'] as num?)?.toInt() ?? 0,
      status: resolvedStatus,
      details: map['details'] as String? ?? '',
      switches: parsedSwitches,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'room': room,
      'type': type,
      'floor': floor,
      'status': status,
      'details': details,
      'updatedAt': ServerValue.timestamp,
      if (switches.isNotEmpty)
        'switches': {
          for (final s in switches.values) s.id: s.toMap(),
        },
    };
  }

  static const List<HomeDevice> seedDevices = [
    HomeDevice(
      id: 'living_room_light',
      name: 'Living Room Light',
      room: 'Living Room',
      type: 'Light',
      floor: 0,
      status: 'ON',
      details: 'Schedule: 6:00 PM - 11:00 PM',
    ),
    HomeDevice(
      id: 'tv_power_outlet',
      name: 'TV Power Outlet',
      room: 'Living Room',
      type: 'Outlet',
      floor: 0,
      status: 'OFF',
      details: 'Continuous power outlet',
    ),
    HomeDevice(
      id: 'main_camera',
      name: 'Main Camera',
      room: 'Entrance',
      type: 'Camera',
      floor: 0,
      status: 'ON',
      details: 'Mock camera feed available',
    ),
    HomeDevice(
      id: 'kitchen_switch_unit',
      name: 'Kitchen Switch Unit',
      room: 'Kitchen',
      type: 'Multi-switch',
      floor: 0,
      status: 'ON',
      details: '3 individually addressable switches',
      switches: {
        'sw1': SwitchUnit(id: 'sw1', name: 'Fridge Outlet', status: 'ON'),
        'sw2': SwitchUnit(id: 'sw2', name: 'Counter Lights', status: 'OFF'),
        'sw3': SwitchUnit(id: 'sw3', name: 'Exhaust Fan', status: 'ON'),
      },
    ),
    HomeDevice(
      id: 'bedroom_light',
      name: 'Bedroom Light',
      room: 'Bedroom',
      type: 'Light',
      floor: 1,
      status: 'OFF',
      details: 'Schedule: 7:00 PM - 6:00 AM',
    ),
    HomeDevice(
      id: 'safety_iron',
      name: 'Safety Iron',
      room: 'Laundry Room',
      type: 'Safety device',
      floor: 1,
      status: 'OFF',
      details: 'Demo auto-off after 30 seconds',
    ),
    HomeDevice(
      id: 'study_outlet',
      name: 'Study Outlet',
      room: 'Study Room',
      type: 'Outlet',
      floor: 1,
      status: 'ON',
      details: 'Continuous power outlet',
    ),
    HomeDevice(
      id: 'upstairs_camera',
      name: 'Upstairs Camera',
      room: 'Hallway',
      type: 'Camera',
      floor: 1,
      status: 'ON',
      details: 'Mock camera feed available',
    ),
  ];
}

class SmartHomeDashboard extends StatefulWidget {
  const SmartHomeDashboard({super.key});

  @override
  State<SmartHomeDashboard> createState() => _SmartHomeDashboardState();
}

class _SmartHomeDashboardState extends State<SmartHomeDashboard> {
  final DatabaseReference devicesRef =
  FirebaseDatabase.instance.ref('devices');
  final DatabaseReference floorsRef =
  FirebaseDatabase.instance.ref('floors');
  final DatabaseReference settingsRef =
  FirebaseDatabase.instance.ref('settings');

  StreamSubscription<DatabaseEvent>? deviceSubscription;
  StreamSubscription<DatabaseEvent>? floorsSubscription;
  StreamSubscription<DatabaseEvent>? settingsSubscription;
  Timer? ironSafetyTimer;

  int selectedFloor = 0;
  bool isLoading = true;
  int ironSecondsRemaining = 0;
  String? safetyAlert;
  String? activeSafetyDeviceId;

  List<HomeDevice> devices = [];
  List<HomeFloor> floors = [];

  static const int defaultIronMaxSeconds = 30;
  int ironMaxSeconds = defaultIronMaxSeconds;
  bool notificationsEnabled = true;
  bool _userSelectedFloor = false;

  @override
  void initState() {
    super.initState();
    startRealtimeSync();
  }

  void _subscribeSettings() {
    settingsSubscription = settingsRef.onValue.listen(
          (event) {
        final value = event.snapshot.value;

        if (value is! Map) {
          return;
        }

        final map = Map<String, dynamic>.from(value);
        final app = map['app'];
        final safety = map['safety'];

        int? defaultFloor;
        var notifications = true;
        var ironSeconds = defaultIronMaxSeconds;

        if (app is Map) {
          final appMap = Map<String, dynamic>.from(app);
          defaultFloor = (appMap['defaultFloor'] as num?)?.toInt();
          notifications = appMap['notificationsEnabled'] as bool? ?? true;
        }

        if (safety is Map) {
          final safetyMap = Map<String, dynamic>.from(safety);
          ironSeconds =
          (safetyMap['ironMaxOnSeconds'] as num?)?.toInt() ??
              defaultIronMaxSeconds;
        }

        setState(() {
          if (defaultFloor != null && !_userSelectedFloor) {
            selectedFloor = defaultFloor;
          }
          notificationsEnabled = notifications;
          ironMaxSeconds = ironSeconds;
        });
      },
      onError: (_) {},
    );
  }

  /// Seeds /floors from the distinct floor levels already present in the
  /// device data (Ground Floor = 0, First Floor = 1, otherwise "Floor N").
  Future<void> _seedFloorsIfMissing() async {
    final floorsSnapshot = await floorsRef.get();

    if (floorsSnapshot.exists) {
      return;
    }

    final deviceSnapshot = await devicesRef.get();
    final deviceValue = deviceSnapshot.value;

    final levels = <int>{};
    if (deviceValue is Map) {
      for (final entry in deviceValue.values) {
        if (entry is Map && entry['floor'] is num) {
          levels.add((entry['floor'] as num).toInt());
        }
      }
    }

    if (levels.isEmpty) {
      levels.addAll(const {0, 1});
    }

    final seed = <String, dynamic>{};
    for (final level in levels) {
      final name = switch (level) {
        0 => 'Ground Floor',
        1 => 'First Floor',
        2 => 'Second Floor',
        _ => 'Floor $level',
      };
      seed['floor_$level'] = {'name': name, 'level': level};
    }

    await floorsRef.set(seed);
  }

  void _subscribeFloors() {
    floorsSubscription = floorsRef.onValue.listen(
      (event) {
        final loadedFloors = parseFloors(event.snapshot.value);

        setState(() {
          floors = loadedFloors;

          if (!loadedFloors.any((floor) => floor.level == selectedFloor)) {
            selectedFloor =
            loadedFloors.isNotEmpty ? loadedFloors.first.level : 0;
          }
        });
      },
      onError: (_) {},
    );
  }

  String floorName(int level) {
    for (final floor in floors) {
      if (floor.level == level) {
        return floor.name;
      }
    }
    return 'Floor $level';
  }

  String _activeSafetyDeviceName() {
    final id = activeSafetyDeviceId;
    if (id == null) {
      return 'Safety device';
    }
    final matched = devices.where((device) => device.id == id);
    return matched.isNotEmpty ? matched.first.name : 'Safety device';
  }

  Future<void> startRealtimeSync() async {
    final firstSnapshot = await devicesRef.get();

    if (!firstSnapshot.exists) {
      await devicesRef.set({
        for (final device in HomeDevice.seedDevices) device.id: device.toMap(),
      });
    }

    await _seedFloorsIfMissing();

    _subscribeSettings();
    _subscribeFloors();

    deviceSubscription = devicesRef.onValue.listen(
          (event) {
        final value = event.snapshot.value;

        if (value is Map) {
          final loadedDevices = value.entries.map((entry) {
            final deviceMap = Map<String, dynamic>.from(entry.value as Map);
            return HomeDevice.fromMap(entry.key.toString(), deviceMap);
          }).toList();

          loadedDevices.sort((a, b) => a.name.compareTo(b.name));

          setState(() {
            devices = loadedDevices;
            isLoading = false;
          });
        }
      },
      onError: (error) {
        setState(() {
          isLoading = false;
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Firebase error: $error')),
          );
        }
      },
    );
  }

  /// Flips one individual switch inside a Multi-Switch unit.
  /// The parent device's overall status is re-derived automatically
  /// (see HomeDevice.fromMap) once this write comes back through the stream.
  Future<void> toggleSubSwitch(
      String deviceId, String switchId, bool turnOn) async {
    await devicesRef.child(deviceId).child('switches').child(switchId).update({
      'status': turnOn ? 'ON' : 'OFF',
    });

    await devicesRef.child(deviceId).update({
      'updatedAt': ServerValue.timestamp,
    });
  }

  void showMultiSwitchSheet(HomeDevice device) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return StreamBuilder<DatabaseEvent>(
          stream: devicesRef.child(device.id).onValue,
          builder: (context, snapshot) {
            final value = snapshot.data?.snapshot.value;

            if (value is! Map) {
              return const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              );
            }

            final current = HomeDevice.fromMap(
              device.id,
              Map<String, dynamic>.from(value),
            );

            return Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                20,
                20,
                MediaQuery.of(context).viewInsets.bottom + 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Text(
                    current.name,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    '${current.room} - ${current.sortedSwitches.length} switches',
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                  const Divider(height: 24),
                  ...current.sortedSwitches.map(
                        (sw) => SwitchListTile(
                      title: Text(sw.name),
                      value: sw.isOn,
                      onChanged: (val) =>
                          toggleSubSwitch(current.id, sw.id, val),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> toggleDevice(HomeDevice device) async {
    if (device.type == 'Camera') {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CameraVideoScreen(cameraName: device.name),
        ),
      );
      return;
    }

    if (device.status == 'ERROR' || device.status == 'DISCONNECTED') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${device.name} is ${device.status} - cannot toggle'),
        ),
      );
      return;
    }

    final newStatus = device.isOn ? 'OFF' : 'ON';

    await devicesRef.child(device.id).update({
      'status': newStatus,
      'updatedAt': ServerValue.timestamp,
    });

    if (device.type == 'Safety device') {
      if (newStatus == 'ON') {
        await devicesRef.child(device.id).update({
          'maxOnDurationSeconds': ironMaxSeconds,
          'activatedAt': ServerValue.timestamp,
        });

        startIronSafetyTimer(device.id);
      } else {
        ironSafetyTimer?.cancel();

        setState(() {
          ironSecondsRemaining = 0;
          activeSafetyDeviceId = null;
        });
      }
    }
  }

  void startIronSafetyTimer(String deviceId) {
    ironSafetyTimer?.cancel();

    setState(() {
      ironSecondsRemaining = ironMaxSeconds;
      safetyAlert = null;
      activeSafetyDeviceId = deviceId;
    });

    ironSafetyTimer = Timer.periodic(
      const Duration(seconds: 1),
      (timer) async {
        if (!mounted) {
          timer.cancel();
          return;
        }

        setState(() {
          ironSecondsRemaining--;
        });

        if (ironSecondsRemaining <= 0) {
          timer.cancel();

          final matched = devices.where((device) => device.id == deviceId);
          final deviceName =
          matched.isNotEmpty ? matched.first.name : 'Safety device';

          final message =
              'Safety alert: $deviceName was automatically turned OFF after $ironMaxSeconds seconds.';

          await devicesRef.child(deviceId).update({
            'status': 'OFF',
            'safetyAlert': message,
            'safetyTriggeredAt': ServerValue.timestamp,
            'updatedAt': ServerValue.timestamp,
          });

          if (mounted) {
            setState(() {
              safetyAlert = message;
              activeSafetyDeviceId = null;
            });

            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(message)),
            );
          }
        }
      },
    );
  }

  @override
  void dispose() {
    deviceSubscription?.cancel();
    floorsSubscription?.cancel();
    settingsSubscription?.cancel();
    ironSafetyTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final floorDevices =
    devices.where((device) => device.floor == selectedFloor).toList();

    final activeDevices = floorDevices.where((device) => device.isOn).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart Home Monitor'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.map_outlined),
            tooltip: 'Floor plan',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => FloorPlanScreen(
                    initialDevices: devices,
                    floors: floors,
                    devicesRef: devicesRef,
                    onToggle: (device) async {
                      if (device.isMultiSwitch) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Open ${device.name} from the Dashboard to control individual switches',
                            ),
                          ),
                        );
                      } else {
                        toggleDevice(device);
                      }
                    },
                  ),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.notifications_none_rounded),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    notificationsEnabled
                        ? 'No new safety alerts'
                        : 'Safety notifications are disabled in Settings',
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
        children: [
          Container(
            width: double.infinity,
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Home Overview',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '$activeDevices of ${floorDevices.length} devices are ON',
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    const Icon(Icons.layers_outlined),
                    const SizedBox(width: 10),
                    const Text('Selected floor: '),
                    DropdownButton<int>(
                      value: floors.any((floor) => floor.level == selectedFloor)
                          ? selectedFloor
                          : floors.isNotEmpty
                          ? floors.first.level
                          : 0,
                      items: [
                        for (final floor in floors)
                          DropdownMenuItem(
                            value: floor.level,
                            child: Text(floor.name),
                          ),
                      ],
                      onChanged: floors.isEmpty
                          ? null
                          : (value) {
                        if (value != null) {
                          setState(() {
                            selectedFloor = value;
                            _userSelectedFloor = true;
                          });
                        }
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (ironSecondsRemaining > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                '${_activeSafetyDeviceName()} auto-off in: '
                '$ironSecondsRemaining seconds',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          if (safetyAlert != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.red),
              ),
              child: Text(
                safetyAlert!,
                style: const TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              itemCount: floorDevices.length,
              gridDelegate:
              const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 14,
                mainAxisSpacing: 14,
                childAspectRatio: 0.75,
              ),
              itemBuilder: (context, index) {
                final device = floorDevices[index];

                return DeviceCard(
                  device: device,
                  onPressed: () {
                    if (device.isMultiSwitch) {
                      showMultiSwitchSheet(device);
                    } else {
                      toggleDevice(device);
                    }
                  },
                  onLongPress: () => _confirmDeleteDevice(device),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showManageSheet,
        icon: const Icon(Icons.add),
        label: const Text('Add'),
      ),
    );
  }

  void _showManageSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.layers_outlined),
                title: const Text('Add floor'),
                subtitle: const Text('Create a new level in the home'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showAddFloorDialog();
                },
              ),
              ListTile(
                leading: const Icon(Icons.lightbulb_outline),
                title: const Text('Add component'),
                subtitle: const Text('Add a light, switch, outlet or sensor'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showAddDeviceDialog();
                },
              ),
              ListTile(
                leading: const Icon(Icons.edit_location_alt_outlined),
                title: const Text('Manage floors'),
                subtitle: const Text('Rename or remove existing floors'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showManageFloorsDialog();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showAddFloorDialog() async {
    final nameController = TextEditingController();
    final nextLevel = floors.isEmpty
        ? 0
        : floors.map((floor) => floor.level).reduce((a, b) => a > b ? a : b) +
        1;
    final levelController = TextEditingController(text: '$nextLevel');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Add floor'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Floor name',
                  hintText: 'e.g. Second Floor',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: levelController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Floor level',
                  helperText: 'Number used to group devices',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Add'),
            ),
          ],
        );
      },
    );

    final name = nameController.text.trim();

    if (confirmed != true || name.isEmpty) {
      return;
    }

    final level = int.tryParse(levelController.text.trim());

    if (level == null) {
      _showSnack('Floor level must be a number.');
      return;
    }

    if (floors.any((floor) => floor.level == level)) {
      _showSnack('A floor with level $level already exists.');
      return;
    }

    await floorsRef.child('floor_$level').set({'name': name, 'level': level});

    if (floors.isEmpty) {
      settingsRef.child('app').update({'defaultFloor': level});
    }

    if (mounted) {
      setState(() => selectedFloor = level);
      _userSelectedFloor = true;
    }

    _showSnack('Added floor "$name".');
  }

  Future<void> _showAddDeviceDialog() async {
    final nameController = TextEditingController();
    final roomController = TextEditingController();
    final detailsController = TextEditingController();
    final switchNamesController = TextEditingController();

    var selectedType = 'Light';
    var selectedFloorLevel = selectedFloor;
    var switchCount = 2;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              title: const Text('Add component'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                        labelText: 'Name',
                        hintText: 'e.g. Garage Light',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: roomController,
                      decoration: const InputDecoration(
                        labelText: 'Room',
                        hintText: 'e.g. Garage',
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      initialValue: selectedFloorLevel,
                      decoration: const InputDecoration(labelText: 'Floor'),
                      items: [
                        for (final floor in floors)
                          DropdownMenuItem(
                            value: floor.level,
                            child: Text(floor.name),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => selectedFloorLevel = value);
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: selectedType,
                      decoration: const InputDecoration(labelText: 'Type'),
                      items: const [
                        DropdownMenuItem(value: 'Light', child: Text('Light')),
                        DropdownMenuItem(value: 'Outlet', child: Text('Outlet')),
                        DropdownMenuItem(value: 'Camera', child: Text('Camera')),
                        DropdownMenuItem(
                          value: 'Multi-switch',
                          child: Text('Multi-switch'),
                        ),
                        DropdownMenuItem(
                          value: 'Safety device',
                          child: Text('Safety device'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => selectedType = value);
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: detailsController,
                      decoration: const InputDecoration(
                        labelText: 'Details (optional)',
                      ),
                    ),
                    if (selectedType == 'Multi-switch') ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const Text('Number of switches: '),
                          DropdownButton<int>(
                            value: switchCount,
                            items: [
                              for (var i = 1; i <= 8; i++)
                                DropdownMenuItem(
                                  value: i,
                                  child: Text('$i'),
                                ),
                            ],
                            onChanged: (value) {
                              if (value != null) {
                                setDialogState(() => switchCount = value);
                              }
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      TextField(
                        controller: switchNamesController,
                        decoration: const InputDecoration(
                          labelText: 'Switch names',
                          hintText: 'Comma separated, e.g. Plug, Fan, Lights',
                          helperText:
                          'Optional - defaults to Switch 1, Switch 2, ...',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    final name = nameController.text.trim();
                    final room = roomController.text.trim();

                    if (name.isEmpty || room.isEmpty) {
                      _showSnack('Name and room are required.');
                      return;
                    }

                    if (floors.isEmpty) {
                      _showSnack('Add a floor before adding components.');
                      return;
                    }

                    Navigator.of(dialogContext).pop();
                    await _createDevice(
                      name: name,
                      room: room,
                      type: selectedType,
                      floor: selectedFloorLevel,
                      details: detailsController.text.trim(),
                      switchNames: switchNamesController.text,
                      switchCount: switchCount,
                    );
                  },
                  child: const Text('Add'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _createDevice({
    required String name,
    required String room,
    required String type,
    required int floor,
    required String details,
    required String switchNames,
    required int switchCount,
  }) async {
    var id = slugify(name);
    var suffix = 2;
    final existingIds = devices.map((device) => device.id).toSet();

    while (existingIds.contains(id)) {
      id = '${slugify(name)}_$suffix';
      suffix++;
    }

    final values = <String, dynamic>{
      'name': name,
      'room': room,
      'type': type,
      'floor': floor,
      'status': 'OFF',
      'details': details.isEmpty ? 'Added from the mobile app' : details,
      'updatedAt': ServerValue.timestamp,
    };

    if (type == 'Multi-switch') {
      final rawNames = switchNames
          .split(',')
          .map((part) => part.trim())
          .where((part) => part.isNotEmpty)
          .toList();

      final switches = <String, dynamic>{};
      for (var i = 1; i <= switchCount; i++) {
        final switchName = i <= rawNames.length ? rawNames[i - 1] : 'Switch $i';
        switches['sw$i'] = {'name': switchName, 'status': 'OFF'};
      }
      values['switches'] = switches;
    }

    await devicesRef.child(id).set(values);

    if (mounted) {
      setState(() => selectedFloor = floor);
      _userSelectedFloor = true;
    }

    _showSnack('Added component "$name".');
  }

  Future<void> _showManageFloorsDialog() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Manage floors'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final floor in floors)
                  ListTile(
                    leading: const Icon(Icons.layers_outlined),
                    title: Text(floor.name),
                    subtitle: Text('Level ${floor.level}'),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Delete floor',
                      onPressed: () async {
                        final floorDevices = devices
                            .where((device) => device.floor == floor.level)
                            .toList();

                        final message = floorDevices.isEmpty
                            ? 'Delete "${floor.name}"? This cannot be undone.'
                            : 'Delete "${floor.name}"? This will also delete '
                                'the ${floorDevices.length} component(s) on it. '
                                'This cannot be undone.';

                        final confirmed = await _confirm(
                          'Delete floor',
                          message,
                        );

                        if (confirmed && mounted) {
                          if (floorDevices.isNotEmpty) {
                            await devicesRef.update({
                              for (final device in floorDevices) device.id: null,
                            });
                          }
                          await floorsRef.child(floor.key).remove();
                          if (dialogContext.mounted) {
                            Navigator.of(dialogContext).pop();
                          }
                        }
                      },
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _confirmDeleteDevice(HomeDevice device) async {
    final confirmed = await _confirm(
      'Delete component',
      'Delete "${device.name}" from this home? This cannot be undone.',
    );

    if (!confirmed) {
      return;
    }

    await devicesRef.child(device.id).remove();
    _showSnack('Deleted "${device.name}".');
  }

  Future<bool> _confirm(String title, String message) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    return result ?? false;
  }

  void _showSnack(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }
}

class DeviceCard extends StatelessWidget {
  final HomeDevice device;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;

  const DeviceCard({
    super.key,
    required this.device,
    required this.onPressed,
    this.onLongPress,
  });

  IconData getDeviceIcon() {
    switch (device.type) {
      case 'Light':
        return Icons.lightbulb_rounded;
      case 'Outlet':
        return Icons.power_outlined;
      case 'Camera':
        return Icons.videocam_rounded;
      case 'Multi-switch':
        return Icons.tune_rounded;
      case 'Safety device':
        return Icons.local_laundry_service_rounded;
      default:
        return Icons.devices_other_rounded;
    }
  }

  Color getStatusColor() {
    switch (device.status) {
      case 'ON':
        return Colors.green;
      case 'ERROR':
        return Colors.red;
      case 'DISCONNECTED':
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCamera = device.type == 'Camera';
    final isMultiSwitch = device.isMultiSwitch;
    final statusColor = getStatusColor();
    final canToggle =
        device.status != 'ERROR' && device.status != 'DISCONNECTED';

    final onSwitchCount = device.sortedSwitches.where((s) => s.isOn).length;
    final subtitleText = isMultiSwitch && device.switches.isNotEmpty
        ? '$onSwitchCount/${device.switches.length} switches ON'
        : device.details;

    return Card(
      elevation: 2,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onPressed,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                backgroundColor: statusColor.withValues(alpha: 0.16),
                child: Icon(getDeviceIcon(), color: statusColor),
              ),
              const SizedBox(height: 14),
              Text(
                device.name,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                device.room,
                style: TextStyle(color: Colors.grey.shade700),
              ),
              const Spacer(),
              Text(
                subtitleText,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.circle, size: 10, color: statusColor),
                  const SizedBox(width: 5),
                  Text(
                    isCamera ? 'VIEW' : device.status,
                    style: TextStyle(
                      color: statusColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  if (isMultiSwitch && canToggle)
                    Icon(Icons.chevron_right, color: Colors.grey.shade600)
                  else if (!isCamera && canToggle)
                    Switch(
                      value: device.isOn,
                      onChanged: (_) => onPressed(),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class FloorPlanScreen extends StatefulWidget {
  final List<HomeDevice> initialDevices;
  final List<HomeFloor> floors;
  final DatabaseReference devicesRef;
  final Future<void> Function(HomeDevice) onToggle;

  const FloorPlanScreen({
    super.key,
    required this.initialDevices,
    required this.floors,
    required this.devicesRef,
    required this.onToggle,
  });

  @override
  State<FloorPlanScreen> createState() => _FloorPlanScreenState();
}

class _FloorPlanScreenState extends State<FloorPlanScreen> {
  StreamSubscription<DatabaseEvent>? subscription;
  int selectedFloor = 0;
  late List<HomeDevice> devices;
  late List<HomeFloor> floors;

  @override
  void initState() {
    super.initState();
    devices = widget.initialDevices;
    floors = widget.floors;

    if (floors.isNotEmpty) {
      selectedFloor = floors.first.level;
    }

    subscription = widget.devicesRef.onValue.listen((event) {
      final value = event.snapshot.value;

      if (value is Map) {
        setState(() {
          devices = value.entries.map((entry) {
            final map = Map<String, dynamic>.from(entry.value as Map);
            return HomeDevice.fromMap(entry.key.toString(), map);
          }).toList();
        });
      }
    });
  }

  @override
  void dispose() {
    subscription?.cancel();
    super.dispose();
  }

  IconData iconFor(HomeDevice device) {
    switch (device.type) {
      case 'Light':
        return Icons.lightbulb_rounded;
      case 'Outlet':
        return Icons.power_outlined;
      case 'Camera':
        return Icons.videocam_rounded;
      case 'Multi-switch':
        return Icons.tune_rounded;
      case 'Safety device':
        return Icons.local_laundry_service_rounded;
      default:
        return Icons.devices_other_rounded;
    }
  }

  Color colorFor(HomeDevice device) {
    switch (device.status) {
      case 'ON':
        return Colors.green;
      case 'ERROR':
        return Colors.red;
      case 'DISCONNECTED':
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  String floorName(int level) {
    for (final floor in floors) {
      if (floor.level == level) {
        return floor.name;
      }
    }
    return 'Floor $level';
  }

  @override
  Widget build(BuildContext context) {
    final floorDevices =
    devices.where((device) => device.floor == selectedFloor).toList();

    final rooms = <String, List<HomeDevice>>{};
    for (final device in floorDevices) {
      rooms.putIfAbsent(device.room, () => []).add(device);
    }

    final selectedLevel = floors.any((floor) => floor.level == selectedFloor)
        ? selectedFloor
        : floors.isNotEmpty
        ? floors.first.level
        : 0;

    return Scaffold(
      appBar: AppBar(title: const Text('Interactive Floor Plan')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Text('Floor: '),
                DropdownButton<int>(
                  value: selectedLevel,
                  items: [
                    for (final floor in floors)
                      DropdownMenuItem(
                        value: floor.level,
                        child: Text(floor.name),
                      ),
                  ],
                  onChanged: floors.isEmpty
                      ? null
                      : (value) {
                    if (value != null) {
                      setState(() {
                        selectedFloor = value;
                      });
                    }
                  },
                ),
              ],
            ),
          ),
          const Text('Tap a device icon to control or view it'),
          Expanded(
            child: rooms.isEmpty
                ? Center(
                    child: Text(
                      'No components on ${floorName(selectedLevel)} yet.\n'
                      'Add one from the Dashboard.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.all(16),
                    gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 14,
                      mainAxisSpacing: 14,
                      childAspectRatio: 0.9,
                    ),
                    itemCount: rooms.length,
                    itemBuilder: (context, index) {
                      final roomName = rooms.keys.elementAt(index);
                      final roomDevices = rooms[roomName]!;

                      return _RoomTile(
                        roomName: roomName,
                        devices: roomDevices,
                        iconFor: iconFor,
                        colorFor: colorFor,
                        onToggle: widget.onToggle,
                      );
                    },
                  ),
          ),
          const Padding(
            padding: EdgeInsets.only(bottom: 18),
            child: Text(
              'Green: ON   Grey: OFF   Red: ERROR   Orange: DISCONNECTED',
            ),
          ),
        ],
      ),
    );
  }
}

class _RoomTile extends StatelessWidget {
  final String roomName;
  final List<HomeDevice> devices;
  final IconData Function(HomeDevice) iconFor;
  final Color Function(HomeDevice) colorFor;
  final Future<void> Function(HomeDevice) onToggle;

  const _RoomTile({
    required this.roomName,
    required this.devices,
    required this.iconFor,
    required this.colorFor,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 1,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.meeting_room_outlined, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    roomName,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const Divider(height: 16),
            Expanded(
              child: _buildDeviceWrap(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceWrap() {
    return Wrap(
      spacing: 8,
      runSpacing: 10,
      children: [
        for (final device in devices)
          Tooltip(
            message: '${device.name} - ${device.status}',
            child: InkWell(
              onTap: () => onToggle(device),
              borderRadius: BorderRadius.circular(30),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor:
                    colorFor(device).withValues(alpha: 0.2),
                    child: Icon(
                      iconFor(device),
                      color: colorFor(device),
                    ),
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    width: 70,
                    child: Text(
                      device.name,
                      style: const TextStyle(fontSize: 11),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
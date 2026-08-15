import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import 'main.dart' show HomeDevice, HomeFloor, parseFloors;

/// User-configurable app + safety settings.
///
/// Persisted in the Firebase Realtime Database under /settings and kept in
/// sync in realtime across web, mobile, and desktop. The backend Cloud
/// Functions read/write these too (see syncIronSetting in functions/index.js).
class AppSettings {
  final int defaultFloor;
  final String themeMode;
  final bool notificationsEnabled;
  final int ironMaxOnSeconds;

  static const int minIronSeconds = 5;
  static const int maxIronSeconds = 120;

  const AppSettings({
    this.defaultFloor = 0,
    this.themeMode = 'system',
    this.notificationsEnabled = true,
    this.ironMaxOnSeconds = 30,
  });

  factory AppSettings.fromMap(Map<String, dynamic> map) {
    final app = map['app'];
    final safety = map['safety'];

    final appMap =
        app is Map ? Map<String, dynamic>.from(app) : <String, dynamic>{};
    final safetyMap =
        safety is Map ? Map<String, dynamic>.from(safety) : <String, dynamic>{};

    final rawTheme = appMap['themeMode'] as String? ?? 'system';
    final themeMode =
        const {'light', 'dark', 'system'}.contains(rawTheme)
            ? rawTheme
            : 'system';

    return AppSettings(
      defaultFloor: (appMap['defaultFloor'] as num?)?.toInt() ?? 0,
      themeMode: themeMode,
      notificationsEnabled:
          appMap['notificationsEnabled'] as bool? ?? true,
      ironMaxOnSeconds: clampIronSeconds(
        (safetyMap['ironMaxOnSeconds'] as num?)?.toInt() ?? 30,
      ),
    );
  }

  static int clampIronSeconds(int value) {
    return value.clamp(minIronSeconds, maxIronSeconds);
  }

  Map<String, dynamic> toMap() {
    return {
      'app': {
        'defaultFloor': defaultFloor,
        'themeMode': themeMode,
        'notificationsEnabled': notificationsEnabled,
      },
      'safety': {
        'ironMaxOnSeconds': ironMaxOnSeconds,
      },
    };
  }

  AppSettings copyWith({
    int? defaultFloor,
    String? themeMode,
    bool? notificationsEnabled,
    int? ironMaxOnSeconds,
  }) {
    return AppSettings(
      defaultFloor: defaultFloor ?? this.defaultFloor,
      themeMode: themeMode ?? this.themeMode,
      notificationsEnabled:
          notificationsEnabled ?? this.notificationsEnabled,
      ironMaxOnSeconds: ironMaxOnSeconds ?? this.ironMaxOnSeconds,
    );
  }
}

/// Settings tab: responsive controls for app, safety, and data.
///
/// Adapts to narrow (mobile) and wide (web/desktop, max-width 760 centered)
/// layouts. Every change is written straight to Firebase /settings and
/// propagates in realtime to the Dashboard, app theme, and the backend.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final DatabaseReference settingsRef =
      FirebaseDatabase.instance.ref('settings');
  final DatabaseReference floorsRef =
      FirebaseDatabase.instance.ref('floors');

  StreamSubscription<DatabaseEvent>? settingsSubscription;
  StreamSubscription<DatabaseEvent>? floorsSubscription;

  AppSettings settings = const AppSettings();
  List<HomeFloor> floors = [];
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _subscribe();
    _subscribeFloors();
  }

  void _subscribeFloors() {
    floorsSubscription = floorsRef.onValue.listen(
      (event) {
        setState(() => floors = parseFloors(event.snapshot.value));
      },
      onError: (_) {},
    );
  }

  void _subscribe() {
    settingsSubscription = settingsRef.onValue.listen(
      (event) {
        final snapshot = event.snapshot;
        final value = snapshot.value;

        setState(() => isLoading = false);

        if (snapshot.exists && value is Map) {
          setState(() {
            settings =
                AppSettings.fromMap(Map<String, dynamic>.from(value));
          });
        } else {
          _seedDefaults();
        }
      },
      onError: (error) {
        setState(() => isLoading = false);
        _showSnack('Firebase error: $error');
      },
    );
  }

  Future<void> _seedDefaults() async {
    await settingsRef.set(const AppSettings().toMap());
  }

  @override
  void dispose() {
    settingsSubscription?.cancel();
    floorsSubscription?.cancel();
    super.dispose();
  }

  void _showSnack(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
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
              child: const Text('Confirm'),
            ),
          ],
        );
      },
    );

    return result ?? false;
  }

  Future<void> _resetDevices() async {
    final confirmed = await _confirm(
      'Reset demo devices',
      'This restores the 8 seeded devices and overwrites the current '
      'device state. Continue?',
    );

    if (!confirmed || !mounted) {
      return;
    }

    final devicesRef = FirebaseDatabase.instance.ref('devices');

    await devicesRef.set({
      for (final device in HomeDevice.seedDevices) device.id: device.toMap(),
    });

    _showSnack('Demo devices restored.');
  }

  Future<void> _clearLogs() async {
    final confirmed = await _confirm(
      'Clear activity logs',
      'This permanently deletes all recorded activity in /logs used by '
      'the Reports tab. Continue?',
    );

    if (!confirmed || !mounted) {
      return;
    }

    await FirebaseDatabase.instance.ref('logs').remove();

    _showSnack('Activity logs cleared.');
  }

  void _onThemeModeChanged(String value) {
    setState(() => settings = settings.copyWith(themeMode: value));
    settingsRef.child('app').update({'themeMode': value});
  }

  void _onDefaultFloorChanged(int value) {
    setState(() => settings = settings.copyWith(defaultFloor: value));
    settingsRef.child('app').update({'defaultFloor': value});
  }

  void _onNotificationsChanged(bool value) {
    setState(
      () => settings = settings.copyWith(notificationsEnabled: value),
    );
    settingsRef.child('app').update({'notificationsEnabled': value});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _buildAppearanceCard(),
                    const SizedBox(height: 16),
                    _buildSafetyCard(),
                    const SizedBox(height: 16),
                    _buildDataCard(),
                    const SizedBox(height: 16),
                    _buildAboutCard(),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildAppearanceCard() {
    return _SectionCard(
      title: 'Appearance',
      icon: Icons.palette_outlined,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Theme'),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'light', label: Text('Light')),
                    ButtonSegment(value: 'dark', label: Text('Dark')),
                    ButtonSegment(value: 'system', label: Text('System')),
                  ],
                  selected: {settings.themeMode},
                  onSelectionChanged: (value) =>
                      _onThemeModeChanged(value.first),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Default floor'),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: DropdownButtonFormField<int>(
                  initialValue: floors.any(
                    (floor) => floor.level == settings.defaultFloor,
                  )
                      ? settings.defaultFloor
                      : floors.isNotEmpty
                      ? floors.first.level
                      : 0,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                  ),
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
                      _onDefaultFloorChanged(value);
                    }
                  },
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 24),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Safety notifications'),
          subtitle: const Text('Show safety alerts on the dashboard'),
          value: settings.notificationsEnabled,
          onChanged: _onNotificationsChanged,
        ),
        const SizedBox(height: 4),
        Text(
          'Settings sync live to every device via Firebase /settings.',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
      ],
    );
  }

  Widget _buildSafetyCard() {
    final ironSeconds = settings.ironMaxOnSeconds;

    return _SectionCard(
      title: 'Safety',
      icon: Icons.shield_outlined,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('Safety Iron auto-off'),
            ),
            Text(
              '$ironSeconds s',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        Slider(
          value: ironSeconds.toDouble().clamp(
                AppSettings.minIronSeconds.toDouble(),
                AppSettings.maxIronSeconds.toDouble(),
              ),
          min: AppSettings.minIronSeconds.toDouble(),
          max: AppSettings.maxIronSeconds.toDouble(),
          divisions: AppSettings.maxIronSeconds - AppSettings.minIronSeconds,
          label: '$ironSeconds s',
          onChanged: (value) {
            setState(
              () => settings = settings.copyWith(
                ironMaxOnSeconds: value.round(),
              ),
            );
          },
          onChangeEnd: (value) {
            settingsRef.child('safety').update({
              'ironMaxOnSeconds': value.round(),
            });
          },
        ),
        const SizedBox(height: 4),
        Text(
          'The server watchdog (safetyIronCutoff Cloud Function) turns the '
          'Safety Iron OFF after this many seconds. Changes apply on the '
          'next activation.',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
      ],
    );
  }

  Widget _buildDataCard() {
    return _SectionCard(
      title: 'Data management',
      icon: Icons.storage_outlined,
      children: [
        OutlinedButton.icon(
          icon: const Icon(Icons.restart_alt_rounded),
          label: const Text('Reset demo devices'),
          onPressed: _resetDevices,
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          icon: const Icon(Icons.delete_sweep_outlined),
          label: const Text('Clear activity logs'),
          onPressed: _clearLogs,
        ),
        const SizedBox(height: 4),
        Text(
          'Resetting restores the seeded devices. Clearing logs empties '
          'the /logs history shown in the Reports tab.',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
      ],
    );
  }

  Widget _buildAboutCard() {
    final options = Firebase.app().options;

    return _SectionCard(
      title: 'About',
      icon: Icons.info_outline,
      children: [
        _AboutRow(label: 'Version', value: '1.0.0+1'),
        _AboutRow(label: 'Firebase project', value: options.projectId),
        _AboutRow(label: 'Database', value: options.databaseURL ?? '-'),
        _AboutRow(
          label: 'Settings path',
          value: '/settings (Realtime Database)',
        ),
        _AboutRow(
          label: 'Server functions',
          value: 'safetyIronCutoff · recordDeviceEvents · syncIronSetting',
        ),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;

  const _SectionCard({
    required this.title,
    required this.icon,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 1,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: Colors.indigo),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _AboutRow extends StatelessWidget {
  final String label;
  final String value;

  const _AboutRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey.shade600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import 'main.dart' show HomeDevice, HomeFloor, parseFloors;

/// Time-range filters for the activity log.
enum ReportRange { today, last7, last30, all }

extension ReportRangeLabel on ReportRange {
  String get label {
    switch (this) {
      case ReportRange.today:
        return 'Today';
      case ReportRange.last7:
        return 'Last 7 days';
      case ReportRange.last30:
        return 'Last 30 days';
      case ReportRange.all:
        return 'All time';
    }
  }
}

/// A single recorded change inside a [DeviceLogEntry] (e.g. status OFF -> ON).
class StatusChange {
  final String field;
  final String? switchId;
  final String? switchName;
  final String from;
  final String to;

  const StatusChange({
    required this.field,
    this.switchId,
    this.switchName,
    required this.from,
    required this.to,
  });

  factory StatusChange.fromJson(Map<String, dynamic> json) {
    return StatusChange(
      field: json['field'] as String? ?? 'status',
      switchId: json['switchId'] as String?,
      switchName: json['switchName'] as String?,
      from: json['from'] as String? ?? 'UNKNOWN',
      to: json['to'] as String? ?? 'UNKNOWN',
    );
  }

  String get description {
    if (field == 'switch.status') {
      final subject = switchName ?? switchId ?? 'Switch';
      return '$subject: $from -> $to';
    }
    return 'Status: $from -> $to';
  }
}

/// One history entry persisted under /logs by the
/// recordDeviceEvents Cloud Function.
class DeviceLogEntry {
  final String id;
  final String deviceId;
  final String deviceName;
  final String room;
  final String type;
  final int floor;
  final DateTime timestamp;
  final List<StatusChange> events;

  const DeviceLogEntry({
    required this.id,
    required this.deviceId,
    required this.deviceName,
    required this.room,
    required this.type,
    required this.floor,
    required this.timestamp,
    required this.events,
  });

  factory DeviceLogEntry.fromMap(String id, Map<String, dynamic> map) {
    final eventsRaw = map['events'];
    final List<StatusChange> events = [];

    if (eventsRaw is List) {
      for (final item in eventsRaw) {
        if (item is Map) {
          events.add(StatusChange.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }

    return DeviceLogEntry(
      id: id,
      deviceId: map['deviceId'] as String? ?? '',
      deviceName: map['deviceName'] as String? ?? 'Unknown device',
      room: map['room'] as String? ?? '',
      type: map['type'] as String? ?? 'Device',
      floor: (map['floor'] as num?)?.toInt() ?? 0,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        (map['timestamp'] as num?)?.toInt() ?? 0,
      ),
      events: events,
    );
  }
}

/// Reports tab: responsive stats + activity log for the current home.
///
/// Designed to adapt between mobile (narrow, stacked) and web/desktop
/// (wide, max-width centered). Data streams live from Firebase:
///  - /devices -> current device state
///  - /logs    -> event history written by the backend Cloud Function
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  final DatabaseReference devicesRef =
      FirebaseDatabase.instance.ref('devices');
  final DatabaseReference logsRef = FirebaseDatabase.instance.ref('logs');
  final DatabaseReference floorsRef = FirebaseDatabase.instance.ref('floors');

  StreamSubscription<DatabaseEvent>? devicesSubscription;
  StreamSubscription<DatabaseEvent>? logsSubscription;
  StreamSubscription<DatabaseEvent>? floorsSubscription;

  List<HomeDevice> devices = [];
  List<DeviceLogEntry> logEntries = [];
  List<HomeFloor> floors = [];

  ReportRange selectedRange = ReportRange.all;

  bool isLoading = true;
  bool logsLoaded = false;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  void _subscribe() {
    devicesSubscription = devicesRef.onValue.listen(
      (event) {
        final value = event.snapshot.value;

        if (value is Map) {
          final list = value.entries.map((entry) {
            return HomeDevice.fromMap(
              entry.key.toString(),
              Map<String, dynamic>.from(entry.value as Map),
            );
          }).toList();

          list.sort((a, b) => a.name.compareTo(b.name));

          setState(() {
            devices = list;
            isLoading = false;
          });
        }
      },
      onError: (error) {
        setState(() => isLoading = false);
        _showError(error);
      },
    );

    floorsSubscription = floorsRef.onValue.listen(
      (event) {
        setState(() => floors = parseFloors(event.snapshot.value));
      },
      onError: (_) {},
    );

    logsSubscription = logsRef.onValue.listen(
      (event) {
        final value = event.snapshot.value;
        final entries = <DeviceLogEntry>[];

        if (value is Map) {
          value.forEach((key, item) {
            if (item is Map) {
              entries.add(
                DeviceLogEntry.fromMap(
                  key.toString(),
                  Map<String, dynamic>.from(item),
                ),
              );
            }
          });
        }

        entries.sort((a, b) => b.timestamp.compareTo(a.timestamp));

        setState(() {
          logEntries = entries;
          logsLoaded = true;
        });
      },
      onError: (error) {
        setState(() => logsLoaded = true);
        _showError(error);
      },
    );
  }

  void _refresh() {
    setState(() {
      isLoading = true;
      logsLoaded = false;
    });

    devicesSubscription?.cancel();
    logsSubscription?.cancel();
    _subscribe();
  }

  void _showError(Object error) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Firebase error: $error')),
      );
    }
  }

  @override
  void dispose() {
    devicesSubscription?.cancel();
    logsSubscription?.cancel();
    floorsSubscription?.cancel();
    super.dispose();
  }

  DateTime? _rangeStart() {
    final now = DateTime.now();

    switch (selectedRange) {
      case ReportRange.today:
        return DateTime(now.year, now.month, now.day);
      case ReportRange.last7:
        return now.subtract(const Duration(days: 7));
      case ReportRange.last30:
        return now.subtract(const Duration(days: 30));
      case ReportRange.all:
        return null;
    }
  }

  List<DeviceLogEntry> get _visibleLogs {
    final start = _rangeStart();

    if (start == null) {
      return logEntries;
    }

    return logEntries.where((l) => !l.timestamp.isBefore(start)).toList();
  }

  Map<String, int> _countByType() {
    final counts = <String, int>{};

    for (final device in devices) {
      counts[device.type] = (counts[device.type] ?? 0) + 1;
    }

    return counts;
  }

  Map<String, int> _countByStatus() {
    final counts = <String, int>{};

    for (final device in devices) {
      counts[device.status] = (counts[device.status] ?? 0) + 1;
    }

    return counts;
  }

  Map<int, int> _countByFloor() {
    final counts = <int, int>{};

    for (final device in devices) {
      counts[device.floor] = (counts[device.floor] ?? 0) + 1;
    }

    return counts;
  }

  Map<String, int> _mostActive() {
    final counts = <String, int>{};

    for (final entry in _visibleLogs) {
      final key = entry.deviceName.isEmpty ? entry.deviceId : entry.deviceName;
      counts[key] = (counts[key] ?? 0) + entry.events.length;
    }

    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return <String, int>{for (final e in sorted) e.key: e.value};
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _refresh,
          ),
        ],
      ),
      body: isLoading && !logsLoaded
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1100),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _buildRangeSelector(),
                    const SizedBox(height: 16),
                    _buildSummaryCards(),
                    const SizedBox(height: 24),
                    _buildDistributionSection(),
                    const SizedBox(height: 24),
                    _buildActivitySection(),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildRangeSelector() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final range in ReportRange.values)
          ChoiceChip(
            label: Text(range.label),
            selected: selectedRange == range,
            onSelected: (_) {
              setState(() => selectedRange = range);
            },
          ),
      ],
    );
  }

  Widget _buildSummaryCards() {
    final onCount = devices.where((device) => device.isOn).length;
    final offCount = devices.where((device) => device.status == 'OFF').length;
    final alertCount = devices
        .where((device) =>
            device.status == 'ERROR' || device.status == 'DISCONNECTED')
        .length;
    final eventCount = _visibleLogs.fold<int>(
      0,
      (sum, entry) => sum + entry.events.length,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 640;
        final cardWidth = isWide
            ? (constraints.maxWidth - 3 * 12) / 4
            : (constraints.maxWidth - 12) / 2;

        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _SummaryCard(
              width: cardWidth,
              icon: Icons.devices_other_rounded,
              color: Colors.indigo,
              label: 'Total Devices',
              value: '${devices.length}',
            ),
            _SummaryCard(
              width: cardWidth,
              icon: Icons.power_rounded,
              color: Colors.green,
              label: 'Devices ON',
              value: '$onCount',
            ),
            _SummaryCard(
              width: cardWidth,
              icon: Icons.power_off_rounded,
              color: Colors.grey,
              label: 'Devices OFF',
              value: '$offCount',
            ),
            _SummaryCard(
              width: cardWidth,
              icon: Icons.warning_amber_rounded,
              color: Colors.orange,
              label: 'Alerts',
              value: '$alertCount',
            ),
            _SummaryCard(
              width: cardWidth,
              icon: Icons.history_rounded,
              color: Colors.teal,
              label: 'Events',
              value: '$eventCount',
            ),
          ],
        );
      },
    );
  }

  Widget _buildDistributionSection() {
    final typeRows = _barsFromMap(_countByType());
    final statusRows = _barsFromMap(_countByStatus());
    final floorCounts = _countByFloor();

    final floorNames = {
      for (final floor in floors) floor.level: floor.name,
    };
    final allLevels = <int>{...floorCounts.keys, ...floorNames.keys}
        .toList()
      ..sort();

    final floorRows = [
      for (final level in allLevels)
        _StatRow(
          label: floorNames[level] ?? 'Floor $level',
          count: floorCounts[level] ?? 0,
        ),
    ];

    if (floorRows.isEmpty) {
      floorRows.add(const _StatRow(label: 'Ground Floor', count: 0));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Device Distribution',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        _DistributionCard(
          title: 'By Type',
          rows: typeRows,
          maxCount: _maxCount([for (final r in typeRows) r.count]),
        ),
        const SizedBox(height: 12),
        _DistributionCard(
          title: 'By Status',
          rows: statusRows,
          maxCount: _maxCount([for (final r in statusRows) r.count]),
        ),
        const SizedBox(height: 12),
        _DistributionCard(
          title: 'By Floor',
          rows: floorRows,
          maxCount: _maxCount(floorCounts.values),
        ),
      ],
    );
  }

  Widget _buildActivitySection() {
    final visible = _visibleLogs;
    final active = _mostActive();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Activity', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Showing ${visible.length} log ${visible.length == 1 ? 'entry' : 'entries'}',
          style: TextStyle(color: Colors.grey.shade600),
        ),
        const SizedBox(height: 12),
        if (active.isNotEmpty) ...[
          _DistributionCard(
            title: 'Most Active Devices',
            rows: active.entries
                .take(5)
                .map(
                  (e) => _StatRow(
                    label: e.key,
                    count: e.value,
                    color: Colors.teal,
                  ),
                )
                .toList(),
            maxCount: active.values.first,
          ),
          const SizedBox(height: 12),
        ],
        if (visible.isEmpty)
          _buildEmptyActivityCard()
        else
          Card(
            elevation: 1,
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < visible.length && i < 50; i++) ...[
                  if (i > 0) const Divider(height: 1, indent: 72),
                  _ActivityTile(entry: visible[i]),
                ],
                if (visible.length > 50)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'Showing first 50 of ${visible.length} entries',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildEmptyActivityCard() {
    return Card(
      elevation: 1,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(
              Icons.insights_rounded,
              size: 48,
              color: Colors.grey.shade400,
            ),
            const SizedBox(height: 12),
            const Text('No activity recorded for this range.'),
            const SizedBox(height: 4),
            Text(
              'Toggle a device to generate report data. Event history is '
              'persisted server-side by the recordDeviceEvents Cloud Function.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  int _maxCount(Iterable<int> counts) {
    var max = 0;
    for (final count in counts) {
      if (count > max) {
        max = count;
      }
    }
    return max;
  }

  List<_StatRow> _barsFromMap(Map<String, int> counts) {
    const palette = [
      Colors.indigo,
      Colors.green,
      Colors.orange,
      Colors.red,
      Colors.teal,
      Colors.purple,
    ];

    final rows = counts.entries
        .map((e) => _StatRow(label: e.key, count: e.value))
        .toList()
      ..sort((a, b) => b.count.compareTo(a.count));

    for (var i = 0; i < rows.length; i++) {
      rows[i] = _StatRow(
        label: rows[i].label,
        count: rows[i].count,
        color: palette[i % palette.length],
      );
    }

    return rows;
  }
}

class _SummaryCard extends StatelessWidget {
  final double width;
  final IconData icon;
  final Color color;
  final String label;
  final String value;

  const _SummaryCard({
    required this.width,
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Card(
        elevation: 2,
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: color.withValues(alpha: 0.16),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      value,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatRow {
  final String label;
  final int count;
  final Color color;

  const _StatRow({
    required this.label,
    required this.count,
    this.color = Colors.indigo,
  });
}

class _DistributionCard extends StatelessWidget {
  final String title;
  final List<_StatRow> rows;
  final int maxCount;

  const _DistributionCard({
    required this.title,
    required this.rows,
    required this.maxCount,
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
            Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 14),
            if (rows.isEmpty)
              Text(
                'No data yet',
                style: TextStyle(color: Colors.grey.shade600),
              )
            else
              for (final row in rows) ...[
                _StatBarRow(row: row, maxCount: maxCount),
                const SizedBox(height: 10),
              ],
          ],
        ),
      ),
    );
  }
}

class _StatBarRow extends StatelessWidget {
  final _StatRow row;
  final int maxCount;

  const _StatBarRow({required this.row, required this.maxCount});

  @override
  Widget build(BuildContext context) {
    final fraction = maxCount <= 0 ? 0.0 : row.count / maxCount;

    return Row(
      children: [
        SizedBox(
          width: 130,
          child: Text(
            row.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Container(
              height: 18,
              color: Colors.grey.shade200,
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: fraction,
                child: ColoredBox(color: row.color),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 28,
          child: Text(
            '${row.count}',
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}

class _ActivityTile extends StatelessWidget {
  final DeviceLogEntry entry;

  const _ActivityTile({required this.entry});

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final sameDay =
        dt.year == now.year && dt.month == now.month && dt.day == now.day;
    String two(int n) => n.toString().padLeft(2, '0');
    final hhmm = '${two(dt.hour)}:${two(dt.minute)}';

    if (sameDay) {
      return 'Today $hhmm';
    }

    return '${dt.year}-${two(dt.month)}-${two(dt.day)} $hhmm';
  }

  @override
  Widget build(BuildContext context) {
    final lastTo = entry.events.isNotEmpty ? entry.events.last.to : 'OFF';
    final isOn = lastTo == 'ON';
    final color = isOn
        ? Colors.green
        : (lastTo == 'OFF' ? Colors.grey : Colors.orange);

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: color.withValues(alpha: 0.16),
        child: Icon(
          isOn ? Icons.power_rounded : Icons.power_off_rounded,
          color: color,
          size: 20,
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              entry.deviceName,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _formatTime(entry.timestamp),
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ],
      ),
      subtitle: Text(
        entry.events.map((e) => e.description).join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

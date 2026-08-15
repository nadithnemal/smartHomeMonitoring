import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import 'camera_video_screen.dart';
import 'main.dart' show HomeDevice;

/// Lists all cameras (devices of type "Camera") from the Realtime Database.
///
/// Tapping a camera opens [CameraVideoScreen], which plays the shared demo
/// video. The list is live, so cameras added later appear automatically.
class CameraListScreen extends StatefulWidget {
  const CameraListScreen({super.key});

  @override
  State<CameraListScreen> createState() => _CameraListScreenState();
}

class _CameraListScreenState extends State<CameraListScreen> {
  final DatabaseReference devicesRef =
      FirebaseDatabase.instance.ref('devices');

  StreamSubscription<DatabaseEvent>? subscription;
  List<HomeDevice> cameras = [];
  bool isLoading = true;
  String? errorText;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  void _subscribe() {
    subscription = devicesRef.onValue.listen(
      (event) {
        final value = event.snapshot.value;
        final list = <HomeDevice>[];

        if (value is Map) {
          for (final entry in value.entries) {
            if (entry.value is! Map) {
              continue;
            }
            final device = HomeDevice.fromMap(
              entry.key.toString(),
              Map<String, dynamic>.from(entry.value as Map),
            );
            if (device.type == 'Camera') {
              list.add(device);
            }
          }
        }

        list.sort((a, b) => a.name.compareTo(b.name));

        setState(() {
          cameras = list;
          isLoading = false;
          errorText = null;
        });
      },
      onError: (error) {
        setState(() {
          isLoading = false;
          errorText = 'Firebase error: $error';
        });
      },
    );
  }

  @override
  void dispose() {
    subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cameras')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final error = errorText;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            error,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.red.shade700),
          ),
        ),
      );
    }

    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (cameras.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No cameras found. Add a Camera component from the dashboard.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: cameras.length,
      itemBuilder: (context, index) {
        final camera = cameras[index];
        final online = camera.status == 'ON';
        return Card(
          elevation: 2,
          margin: const EdgeInsets.only(bottom: 12),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor:
                  (online ? Colors.green : Colors.grey).withValues(alpha: 0.16),
              child: Icon(
                Icons.videocam,
                color: online ? Colors.green : Colors.grey,
              ),
            ),
            title: Text(camera.name),
            subtitle: Text(camera.room),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  online ? 'Online' : 'Offline',
                  style: TextStyle(
                    color: online ? Colors.green : Colors.grey,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Icon(Icons.chevron_right, color: Colors.grey),
              ],
            ),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => CameraVideoScreen(cameraName: camera.name),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

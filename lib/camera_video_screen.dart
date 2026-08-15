import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Demo video played for every camera. Swapping this URL changes the shared
/// mock feed for all cameras at once.
///
/// Note: the classic BigBuckBunny sample
/// (commondatastorage.googleapis.com/gtv-videos-bucket/...) now returns 403,
/// so a CC0 public sample that supports CORS and range requests is used.
const String demoVideoUrl =
    'https://drive.google.com/uc?export=download&id=1fIG2djXugzE9QTPhSItKPhp4Vb8vKqzX';

/// Plays the shared demo video for a camera.
///
/// The mock feed is intentionally not tied to any per-camera field, so the
/// same clip is shown for every camera - existing or newly added later.
class CameraVideoScreen extends StatefulWidget {
  const CameraVideoScreen({super.key, required this.cameraName});

  final String cameraName;

  @override
  State<CameraVideoScreen> createState() => _CameraVideoScreenState();
}

class _CameraVideoScreenState extends State<CameraVideoScreen> {
  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(demoVideoUrl),
    );

    try {
      await controller.initialize();

      if (!mounted) {
        controller.dispose();
        return;
      }

      setState(() {
        _videoController = controller;
        _chewieController = ChewieController(
          videoPlayerController: controller,
          autoPlay: true,
          looping: true,
        );
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = 'Could not load demo feed:\n$error';
        });
      }
      controller.dispose();
    }
  }

  @override
  void dispose() {
    _chewieController?.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.cameraName),
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              Text(
                error,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade700),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () {
                  setState(() => _error = null);
                  _initPlayer();
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final chewie = _chewieController;
    if (chewie == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Center(
      child: AspectRatio(
        aspectRatio: _videoController!.value.aspectRatio,
        child: Chewie(controller: chewie),
      ),
    );
  }
}

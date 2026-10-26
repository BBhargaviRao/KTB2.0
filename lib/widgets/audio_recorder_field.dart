import 'dart:async';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:just_audio/just_audio.dart';

/// A compact voice-recording control: idle mic button -> recording timer ->
/// inline playback preview with a delete/retake option. Used wherever a
/// child can answer a nudge with a recorded voice note instead of typing.
class AudioRecorderField extends StatefulWidget {
  // Fires whenever the recorded answer changes. Null args means "no
  // recording" (deleted / never started) — the surrounding answer card owns
  // the decision to prefer this over typed text when the answer is saved.
  final void Function(String? localFilePath, int? durationSeconds) onChanged;
  final Color accentColor;

  const AudioRecorderField({
    super.key,
    required this.onChanged,
    this.accentColor = const Color(0xFF7C6FCD),
  });

  @override
  State<AudioRecorderField> createState() => _AudioRecorderFieldState();
}

class _AudioRecorderFieldState extends State<AudioRecorderField> {
  final _recorder = AudioRecorder();
  AudioPlayer? _player;
  Timer? _timer;

  bool _isRecording = false;
  bool _isPlaying = false;
  bool _permissionDenied = false;
  Duration _elapsed = Duration.zero;
  String? _path;
  int? _durationSeconds;

  @override
  void dispose() {
    _timer?.cancel();
    _recorder.dispose();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    final granted = await _recorder.hasPermission();
    if (!granted) {
      if (mounted) setState(() => _permissionDenied = true);
      return;
    }
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/nudge_answer_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
    if (!mounted) return;
    setState(() {
      _isRecording = true;
      _permissionDenied = false;
      _elapsed = Duration.zero;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed += const Duration(seconds: 1));
    });
  }

  Future<void> _stopRecording() async {
    final path = await _recorder.stop();
    _timer?.cancel();
    if (path == null || !mounted) return;
    final dur = _elapsed.inSeconds;
    setState(() {
      _isRecording = false;
      _path = path;
      _durationSeconds = dur;
    });
    widget.onChanged(path, dur);
  }

  Future<void> _togglePreviewPlayback() async {
    if (_path == null) return;
    _player ??= AudioPlayer();
    if (_isPlaying) {
      await _player!.pause();
      if (mounted) setState(() => _isPlaying = false);
      return;
    }
    await _player!.setFilePath(_path!);
    _player!.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed && mounted) {
        setState(() => _isPlaying = false);
      }
    });
    await _player!.play();
    if (mounted) setState(() => _isPlaying = true);
  }

  void _delete() {
    _player?.stop();
    setState(() {
      _path = null;
      _durationSeconds = null;
      _isPlaying = false;
    });
    widget.onChanged(null, null);
  }

  String _fmt(int seconds) {
    final m = seconds ~/ 60, s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Widget _pill({required Color color, required Color border, required Widget child}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: border),
        ),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    if (_isRecording) {
      return _pill(
        color: Colors.red.shade50,
        border: Colors.red.shade200,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Text('Recording  ${_fmt(_elapsed.inSeconds)}',
              style: const TextStyle(
                  fontFamily: 'PlusJakartaSans',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.red)),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: _stopRecording,
            child: Container(
              width: 28,
              height: 28,
              decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
              child: const Icon(Icons.stop_rounded, color: Colors.white, size: 16),
            ),
          ),
        ]),
      );
    }

    if (_path != null) {
      return _pill(
        color: widget.accentColor.withValues(alpha: 0.12),
        border: widget.accentColor.withValues(alpha: 0.4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          GestureDetector(
            onTap: _togglePreviewPlayback,
            child: Icon(
                _isPlaying ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded,
                color: widget.accentColor,
                size: 26),
          ),
          const SizedBox(width: 8),
          Text('Voice answer  ${_fmt(_durationSeconds ?? 0)}',
              style: TextStyle(
                  fontFamily: 'PlusJakartaSans',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: widget.accentColor)),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: _delete,
            child: const Icon(Icons.close_rounded, size: 18, color: Colors.black45),
          ),
        ]),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      GestureDetector(
        onTap: _startRecording,
        child: _pill(
          color: Colors.black.withValues(alpha: 0.06),
          border: Colors.black.withValues(alpha: 0.12),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.mic_rounded, size: 18, color: Colors.black87),
            SizedBox(width: 6),
            Text('Record instead',
                style: TextStyle(
                    fontFamily: 'PlusJakartaSans',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87)),
          ]),
        ),
      ),
      if (_permissionDenied) ...[
        const SizedBox(height: 4),
        const Text('Microphone permission denied — enable it in device settings.',
            style: TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 11, color: Colors.red)),
      ],
    ]);
  }
}

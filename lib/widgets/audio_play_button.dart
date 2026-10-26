import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

/// Compact play/pause control for a recorded nudge answer already uploaded
/// to Firebase Storage — used wherever an answer is shown read-only (the
/// parent's "Child nudges" tab, the child's own answered-nudge history).
class AudioPlayButton extends StatefulWidget {
  final String audioUrl;
  final int? durationSeconds;
  final Color color;

  const AudioPlayButton({
    super.key,
    required this.audioUrl,
    this.durationSeconds,
    this.color = Colors.black87,
  });

  @override
  State<AudioPlayButton> createState() => _AudioPlayButtonState();
}

class _AudioPlayButtonState extends State<AudioPlayButton> {
  AudioPlayer? _player;
  bool _isPlaying = false;
  bool _loading = false;
  bool _loaded = false;

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_isPlaying) {
      await _player?.pause();
      if (mounted) setState(() => _isPlaying = false);
      return;
    }
    setState(() => _loading = true);
    try {
      _player ??= AudioPlayer();
      if (!_loaded) {
        await _player!.setUrl(widget.audioUrl);
        _loaded = true;
        _player!.playerStateStream.listen((s) {
          if (s.processingState == ProcessingState.completed && mounted) {
            setState(() => _isPlaying = false);
          }
        });
      }
      await _player!.play();
      if (mounted) setState(() {
        _isPlaying = true;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _fmt(int seconds) {
    final m = seconds ~/ 60, s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _loading ? null : _toggle,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: widget.color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: widget.color.withValues(alpha: 0.3)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _loading
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: widget.color))
              : Icon(
                  _isPlaying ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded,
                  color: widget.color,
                  size: 22),
          const SizedBox(width: 8),
          Text(
            widget.durationSeconds != null
                ? 'Voice answer  ${_fmt(widget.durationSeconds!)}'
                : 'Voice answer',
            style: TextStyle(
                fontFamily: 'PlusJakartaSans',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: widget.color),
          ),
        ]),
      ),
    );
  }
}

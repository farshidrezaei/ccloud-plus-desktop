import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import '../core/constants/app_colors.dart';
import '../models/media_item.dart';
import '../providers/app_settings_provider.dart';
import '../providers/mini_player_provider.dart';
import '../providers/watch_history_provider.dart';
import '../platform/vlc_launcher.dart';

class VideoPlayerScreen extends StatefulWidget {
  final String videoUrl;
  final String title;
  final String? subtitleUrl;
  final MediaItem? mediaItem;
  final int? startPositionMs;
  final String? episodeTitle;
  final Player? existingPlayer;
  final VideoController? existingVideoController;
  final String? nextEpisodeUrl;
  final String? nextEpisodeTitle;

  const VideoPlayerScreen({
    super.key,
    required this.videoUrl,
    required this.title,
    this.subtitleUrl,
    this.mediaItem,
    this.startPositionMs,
    this.episodeTitle,
    this.existingPlayer,
    this.existingVideoController,
    this.nextEpisodeUrl,
    this.nextEpisodeTitle,
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen>
    with WindowListener {
  late final Player _player;
  late final VideoController _videoController;

  bool _showControls = true;
  Timer? _hideTimer;
  bool _isFullscreen = false;
  double _playbackSpeed = 1.0;
  final FocusNode _focusNode = FocusNode();

  String? _errorMessage;
  bool _isLoading = true;
  StreamSubscription? _errorSub;
  StreamSubscription? _bufferingSub;
  StreamSubscription? _positionSub;
  StreamSubscription? _completedSub;
  Timer? _loadTimeoutTimer;
  Timer? _progressSaveTimer;
  bool _hasSeekedInitial = false;
  bool _isDocking = false;
  bool _isDisposed = false;
  double _subtitleDelaySeconds = 0.0;
  bool _showNextEpisodePrompt = false;
  int _nextEpisodeCountdown = 12;
  Timer? _countdownTimer;
  bool _isAutoNextDismissed = false;

  // Ergonomic UI extensions
  BoxFit _videoFit = BoxFit.contain;
  bool _showRemainingTime = false;
  int _seekRippleDelta = 0;
  Timer? _seekRippleTimer;

  // Sleep Timer & Desktop HUD
  Timer? _sleepTimer;
  int? _sleepTimerRemainingMinutes;
  Timer? _sleepTicker;
  bool _sleepAtEpisodeEnd = false;
  String? _hudToastMessage;
  IconData? _hudToastIcon;
  Timer? _hudToastTimer;

  @override
  void initState() {
    super.initState();
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      try {
        windowManager.addListener(this);
      } catch (_) {}
    }

    if (widget.existingPlayer != null &&
        widget.existingVideoController != null) {
      _player = widget.existingPlayer!;
      _videoController = widget.existingVideoController!;
      _isLoading = false;
    } else {
      // Clean up previous docked mini-player to prevent dual MPV hardware decoding collision
      try {
        final miniPlayer = Provider.of<MiniPlayerProvider>(
          context,
          listen: false,
        );
        if (miniPlayer.isDocked) {
          miniPlayer.close();
        }
      } catch (_) {}

      final settings = Provider.of<AppSettingsProvider>(context, listen: false);
      // High-performance streaming configuration with sane 64MB RAM buffer
      _player = Player(
        configuration: const PlayerConfiguration(
          logLevel: MPVLogLevel.warn,
          bufferSize: 64 * 1024 * 1024,
        ),
      );
      _videoController = VideoController(
        _player,
        configuration: VideoControllerConfiguration(
          hwdec: settings.hwdec,
          enableHardwareAcceleration: settings.enableHardwareAcceleration,
        ),
      );
      _startPlayback();
    }

    _initStreams();
    _startHideTimer();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_isDisposed) {
        _focusNode.requestFocus();
      }
    });
  }

  void _initStreams() {
    _errorSub = _player.stream.error.listen((err) {
      if (mounted && !_isDisposed && err.isNotEmpty) {
        _loadTimeoutTimer?.cancel();
        setState(() {
          _errorMessage =
              'ارتباط با سرور پخش قطع شد. سرورهای محتوای ایرانی در صورت فعال بودن فیلترشکن ارتباط را مسدود می‌کنند. VPN را در حالت Bypass Iran قرار دهید یا ویدیو را در VLC باز کنید.';
          _isLoading = false;
        });
      }
    });

    _bufferingSub = _player.stream.buffering.listen((buffering) {
      if (mounted && !_isDisposed) {
        setState(() {
          if (buffering) {
            _isLoading = true;
            _showControls = true;
          } else if (_player.state.position > Duration.zero) {
            _isLoading = false;
            _startHideTimer();
          }
        });
      }
    });

    _positionSub = _player.stream.position.listen((pos) {
      if (!_hasSeekedInitial &&
          widget.startPositionMs != null &&
          widget.startPositionMs! > 0 &&
          _player.state.duration > Duration.zero) {
        _hasSeekedInitial = true;
        try {
          _player.seek(Duration(milliseconds: widget.startPositionMs!));
        } catch (_) {}
      }
      if (mounted && !_isDisposed && pos > Duration.zero && _isLoading) {
        setState(() {
          _isLoading = false;
          _errorMessage = null;
        });
        _loadTimeoutTimer?.cancel();
        _startHideTimer();
      }

      // Auto-Next Episode Trigger (within last 15 seconds)
      if (widget.nextEpisodeUrl != null &&
          !_isAutoNextDismissed &&
          _player.state.duration > Duration.zero) {
        final remainingSec = (_player.state.duration - pos).inSeconds;
        if (remainingSec <= 15 && remainingSec > 0 && !_showNextEpisodePrompt) {
          _triggerNextEpisodeCountdown(remainingSec);
        }
      }
    });

    _completedSub = _player.stream.completed.listen((completed) {
      if (mounted && !_isDisposed && completed) {
        if (_sleepAtEpisodeEnd) {
          _player.pause();
          setState(() {
            _sleepAtEpisodeEnd = false;
            _showControls = true;
          });
          _showHud('تایمر خواب: پایان قسمت و توقف پخش', Icons.bedtime_rounded);
          return;
        }

        if (widget.nextEpisodeUrl != null && !_isAutoNextDismissed) {
          _playNextEpisode();
        } else {
          setState(() {
            _showControls = true;
          });
        }
      }
    });

    _progressSaveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _saveCurrentWatchProgress();
    });
  }

  void _triggerNextEpisodeCountdown(int initialSeconds) {
    setState(() {
      _showNextEpisodePrompt = true;
      _nextEpisodeCountdown = initialSeconds;
    });

    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _isDisposed) {
        timer.cancel();
        return;
      }
      if (_nextEpisodeCountdown <= 1) {
        timer.cancel();
        _playNextEpisode();
      } else {
        setState(() {
          _nextEpisodeCountdown--;
        });
      }
    });
  }

  void _playNextEpisode() {
    _countdownTimer?.cancel();
    if (widget.nextEpisodeUrl == null) return;

    Navigator.of(context, rootNavigator: true).pushReplacement(
      MaterialPageRoute(
        builder: (_) => VideoPlayerScreen(
          videoUrl: widget.nextEpisodeUrl!,
          title: widget.nextEpisodeTitle ?? widget.title,
          mediaItem: widget.mediaItem,
          episodeTitle: widget.nextEpisodeTitle,
        ),
      ),
    );
  }

  void _cancelAutoNext() {
    _countdownTimer?.cancel();
    setState(() {
      _showNextEpisodePrompt = false;
      _isAutoNextDismissed = true;
    });
  }

  Future<void> _startPlayback() async {
    if (_isDisposed) return;

    final trimmedUrl = widget.videoUrl.trim();
    if (trimmedUrl.isEmpty) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'آدرس ویدیو یافت نشد یا نامعتبر است.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    _loadTimeoutTimer?.cancel();

    // Reset previous stream before attempting new playback
    try {
      await _player.stop();
    } catch (_) {}

    if (_isDisposed) return;

    // Start 15-second watchdog timer BEFORE open() to catch network hangs
    _loadTimeoutTimer = Timer(const Duration(seconds: 15), () async {
      if (mounted &&
          !_isDisposed &&
          _isLoading &&
          _player.state.position == Duration.zero) {
        try {
          await _player.stop();
        } catch (_) {}
        if (mounted && !_isDisposed) {
          setState(() {
            _errorMessage =
                'زمان پاسخگویی سرور پخش به پایان رسید. اگر فیلترشکن شما روشن است، لطفاً آن را روی Bypass Iran قرار دهید یا ویدیو را در VLC پخش کنید.';
            _isLoading = false;
          });
        }
      }
    });

    try {
      final settings = Provider.of<AppSettingsProvider>(context, listen: false);
      final platform = _player.platform as dynamic;
      // High-performance streaming & sane caching options for MPV
      await platform?.setProperty('hwdec', settings.hwdec);
      await platform?.setProperty('network-timeout', '15');
      await platform?.setProperty('tls-verify', 'no');
      await platform?.setProperty('ytdl', 'no');
      await platform?.setProperty('cache', 'yes');
      await platform?.setProperty('cache-secs', '60');
      await platform?.setProperty(
        'demuxer-max-bytes',
        '67108864',
      ); // 64 MiB RAM buffer ahead
      await platform?.setProperty(
        'demuxer-max-back-bytes',
        '20971520',
      ); // 20 MiB RAM buffer behind for instant rewind
      await platform?.setProperty(
        'demuxer-readahead-secs',
        '60',
      ); // 1 min readahead
      await platform?.setProperty('demuxer-lavf-buffersize', '524288');
      await platform?.setProperty('demuxer-hysteresis-secs', '5');
      await platform?.setProperty('force-seekable', 'yes');
      await platform?.setProperty(
        'user-agent',
        'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
      );
    } catch (_) {}

    if (_isDisposed) return;

    try {
      await _player.open(
        Media(
          trimmedUrl,
          httpHeaders: {
            'User-Agent':
                'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
          },
        ),
      );
    } catch (e) {
      if (mounted && !_isDisposed) {
        _loadTimeoutTimer?.cancel();
        try {
          await _player.stop();
        } catch (_) {}
        setState(() {
          _errorMessage = 'عدم امکان پخش استریم: $e';
          _isLoading = false;
        });
      }
      return;
    }

    if (mounted && !_isDisposed) {
      final settings = Provider.of<AppSettingsProvider>(context, listen: false);
      _applySubtitleSettings(settings);
    }
  }

  void _applySubtitleSettings(AppSettingsProvider settings) {
    try {
      _player.setSubtitleTrack(SubtitleTrack.auto());
    } catch (_) {}
  }

  @override
  void onWindowClose() async {
    try {
      await _player.stop();
      await _player.dispose();
    } catch (_) {}
  }

  void _saveCurrentWatchProgress() {
    if (widget.mediaItem == null) return;
    try {
      final posMs = _player.state.position.inMilliseconds;
      final durMs = _player.state.duration.inMilliseconds;
      if (posMs > 3000 && durMs > 0) {
        Provider.of<WatchHistoryProvider>(context, listen: false).saveProgress(
          mediaItem: widget.mediaItem!,
          videoUrl: widget.videoUrl,
          positionMs: posMs,
          durationMs: durMs,
          episodeTitle: widget.episodeTitle,
        );
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _isDisposed = true;
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      try {
        windowManager.removeListener(this);
      } catch (_) {}
    }
    _countdownTimer?.cancel();
    _seekRippleTimer?.cancel();
    _progressSaveTimer?.cancel();
    _sleepTimer?.cancel();
    _sleepTicker?.cancel();
    _hudToastTimer?.cancel();
    _saveCurrentWatchProgress();
    _hideTimer?.cancel();
    _loadTimeoutTimer?.cancel();
    _errorSub?.cancel();
    _bufferingSub?.cancel();
    _positionSub?.cancel();
    _completedSub?.cancel();
    _focusNode.dispose();
    if (!_isDocking) {
      _player
          .stop()
          .then((_) {
            _player.dispose();
          })
          .catchError((_) {
            _player.dispose();
          });
    }
    super.dispose();
  }

  void _exitPlayer() async {
    if (_isFullscreen) {
      try {
        if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
          await windowManager.setFullScreen(false);
        }
      } catch (_) {}
    }
    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
  }

  void _dockToMiniPlayer() async {
    _isDocking = true;
    _saveCurrentWatchProgress();
    if (_isFullscreen) {
      try {
        if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
          await windowManager.setFullScreen(false);
        }
      } catch (_) {}
    }
    if (mounted) {
      try {
        Provider.of<MiniPlayerProvider>(context, listen: false).dock(
          player: _player,
          videoController: _videoController,
          title: widget.title,
          videoUrl: widget.videoUrl,
          mediaItem: widget.mediaItem,
          episodeTitle: widget.episodeTitle,
        );
      } catch (_) {}
      Navigator.of(context, rootNavigator: true).pop();
    }
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted && _player.state.playing && !_isLoading) {
        setState(() {
          _showControls = false;
        });
      }
    });
  }

  void _onUserInteraction() {
    if (!_showControls) {
      setState(() {
        _showControls = true;
      });
    }
    _startHideTimer();
  }

  void _togglePlayPause() {
    if (_isLoading) return;
    _player.playOrPause();
    _onUserInteraction();
  }

  void _seek(int seconds) {
    final current = _player.state.position;
    final target = current + Duration(seconds: seconds);
    _player.seek(target < Duration.zero ? Duration.zero : target);
    _triggerSeekRipple(seconds);
    _onUserInteraction();
  }

  void _triggerSeekRipple(int seconds) {
    setState(() {
      _seekRippleDelta = seconds;
    });
    _seekRippleTimer?.cancel();
    _seekRippleTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) {
        setState(() {
          _seekRippleDelta = 0;
        });
      }
    });
  }

  void _toggleMute() {
    if (_player.state.volume > 0) {
      _player.setVolume(0);
    } else {
      _player.setVolume(100);
    }
    _onUserInteraction();
  }

  void _adjustVolume(double delta) {
    final current = _player.state.volume;
    final next = (current + delta).clamp(0.0, 100.0);
    _player.setVolume(next);
    _onUserInteraction();
  }

  void _toggleFullscreen() async {
    try {
      if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
        final isFull = await windowManager.isFullScreen();
        await windowManager.setFullScreen(!isFull);
        if (mounted && !_isDisposed) {
          setState(() {
            _isFullscreen = !isFull;
          });
        }
      }
    } catch (_) {}
    _onUserInteraction();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final settings = Provider.of<AppSettingsProvider>(context, listen: false);
    final seekStep = settings.seekStepSeconds;

    if (event.logicalKey == LogicalKeyboardKey.space ||
        event.logicalKey == LogicalKeyboardKey.keyK) {
      _togglePlayPause();
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
        event.logicalKey == LogicalKeyboardKey.keyL) {
      _seek(seekStep);
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
        event.logicalKey == LogicalKeyboardKey.keyJ) {
      _seek(-seekStep);
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _adjustVolume(5);
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _adjustVolume(-5);
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.keyM) {
      _toggleMute();
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.keyF) {
      _toggleFullscreen();
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_isFullscreen) {
        _toggleFullscreen();
      } else {
        _exitPlayer();
      }
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.bracketLeft) {
      _stepPlaybackRate(-0.25);
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.bracketRight) {
      _stepPlaybackRate(0.25);
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.keyC) {
      _toggleSubtitleVisibility();
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.keyZ) {
      _adjustSubtitleDelay(-0.5);
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.keyX) {
      _adjustSubtitleDelay(0.5);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _showHud(String message, IconData icon) {
    if (!mounted) return;
    setState(() {
      _hudToastMessage = message;
      _hudToastIcon = icon;
    });
    _hudToastTimer?.cancel();
    _hudToastTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) {
        setState(() {
          _hudToastMessage = null;
          _hudToastIcon = null;
        });
      }
    });
  }

  void _stepPlaybackRate(double delta) {
    const rates = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    int currentIndex = rates.indexWhere(
      (r) => (r - _playbackSpeed).abs() < 0.05,
    );
    if (currentIndex == -1) currentIndex = 2;

    int nextIndex = (currentIndex + (delta > 0 ? 1 : -1)).clamp(
      0,
      rates.length - 1,
    );
    final newRate = rates[nextIndex];
    setState(() => _playbackSpeed = newRate);
    _player.setRate(newRate);
    _showHud('سرعت پخش: ${newRate}x', Icons.speed_rounded);
    _onUserInteraction();
  }

  void _toggleSubtitleVisibility() {
    final currentSub = _player.state.track.subtitle;
    if (currentSub == SubtitleTrack.no()) {
      final available = _player.state.tracks.subtitle
          .where((t) => t != SubtitleTrack.no())
          .toList();
      if (available.isNotEmpty) {
        _player.setSubtitleTrack(available.first);
        _showHud('زیرنویس: فعال', Icons.subtitles_rounded);
      } else {
        _showHud('هیچ زیرنویسی یافت نشد', Icons.subtitles_off_rounded);
      }
    } else {
      _player.setSubtitleTrack(SubtitleTrack.no());
      _showHud('زیرنویس: خاموش', Icons.subtitles_off_rounded);
    }
    _onUserInteraction();
  }

  void _adjustSubtitleDelay(double delta) {
    _subtitleDelaySeconds = double.parse(
      (_subtitleDelaySeconds + delta).toStringAsFixed(1),
    );
    _applySubtitleDelay(_subtitleDelaySeconds);
    _showHud(
      'تأخیر زیرنویس: ${_subtitleDelaySeconds >= 0 ? '+' : ''}${_subtitleDelaySeconds.toStringAsFixed(1)}s',
      Icons.sync_rounded,
    );
    _onUserInteraction();
  }

  void _setSleepTimer(int? minutes, {bool atEpisodeEnd = false}) {
    _sleepTimer?.cancel();
    _sleepTicker?.cancel();
    _sleepTimer = null;
    _sleepTicker = null;

    if (atEpisodeEnd) {
      setState(() {
        _sleepAtEpisodeEnd = true;
        _sleepTimerRemainingMinutes = null;
      });
      _showHud('تایمر خواب: پایان این قسمت', Icons.bedtime_rounded);
      return;
    }

    setState(() {
      _sleepAtEpisodeEnd = false;
      _sleepTimerRemainingMinutes = minutes;
    });

    if (minutes == null || minutes <= 0) {
      _showHud('تایمر خواب غیرفعال شد', Icons.timer_off_rounded);
      return;
    }

    _showHud('تایمر خواب: $minutes دقیقه', Icons.bedtime_rounded);

    _sleepTimer = Timer(Duration(minutes: minutes), () {
      if (mounted && !_isDisposed) {
        _player.pause();
        setState(() {
          _sleepTimerRemainingMinutes = null;
          _showControls = true;
        });
        _showHud('تایمر خواب: پخش متوقف شد', Icons.bedtime_rounded);
      }
    });

    _sleepTicker = Timer.periodic(const Duration(minutes: 1), (timer) {
      if (mounted && !_isDisposed && _sleepTimerRemainingMinutes != null) {
        setState(() {
          if (_sleepTimerRemainingMinutes! > 1) {
            _sleepTimerRemainingMinutes = _sleepTimerRemainingMinutes! - 1;
          } else {
            timer.cancel();
          }
        });
      } else {
        timer.cancel();
      }
    });
  }

  void _showSleepTimerDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141620),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final isTimerActive =
                _sleepTimerRemainingMinutes != null || _sleepAtEpisodeEnd;

            return Directionality(
              textDirection: TextDirection.rtl,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.bedtime_rounded,
                              color: AppColors.brandRed,
                              size: 22,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              'تایمر خواب (Sleep Timer)',
                              style: GoogleFonts.vazirmatn(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.close_rounded,
                            color: Colors.white70,
                          ),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    const Divider(color: Colors.white12, height: 20),
                    Text(
                      'با پایان زمان تعیین‌شده، پخش ویدیو خودکار متوقف می‌شود:',
                      style: GoogleFonts.vazirmatn(
                        color: AppColors.textMuted,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        if (isTimerActive)
                          _buildSleepChip(
                            label: 'غیرفعال کردن تایمر',
                            icon: Icons.timer_off_rounded,
                            isSelected: false,
                            isCancel: true,
                            onTap: () {
                              _setSleepTimer(null);
                              Navigator.pop(ctx);
                            },
                          ),
                        _buildSleepChip(
                          label: '۱۵ دقیقه',
                          isSelected: _sleepTimerRemainingMinutes == 15,
                          onTap: () {
                            _setSleepTimer(15);
                            Navigator.pop(ctx);
                          },
                        ),
                        _buildSleepChip(
                          label: '۳۰ دقیقه',
                          isSelected: _sleepTimerRemainingMinutes == 30,
                          onTap: () {
                            _setSleepTimer(30);
                            Navigator.pop(ctx);
                          },
                        ),
                        _buildSleepChip(
                          label: '۴۵ دقیقه',
                          isSelected: _sleepTimerRemainingMinutes == 45,
                          onTap: () {
                            _setSleepTimer(45);
                            Navigator.pop(ctx);
                          },
                        ),
                        _buildSleepChip(
                          label: '۶۰ دقیقه',
                          isSelected: _sleepTimerRemainingMinutes == 60,
                          onTap: () {
                            _setSleepTimer(60);
                            Navigator.pop(ctx);
                          },
                        ),
                        _buildSleepChip(
                          label: 'اتمام این قسمت',
                          icon: Icons.flag_rounded,
                          isSelected: _sleepAtEpisodeEnd,
                          onTap: () {
                            _setSleepTimer(null, atEpisodeEnd: true);
                            Navigator.pop(ctx);
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSleepChip({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
    IconData? icon,
    bool isCancel = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.brandRed
              : isCancel
              ? Colors.redAccent.withValues(alpha: 0.15)
              : AppColors.surfaceCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? AppColors.brandRed
                : isCancel
                ? Colors.redAccent.withValues(alpha: 0.5)
                : AppColors.glassBorder,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 16,
                color: isSelected
                    ? Colors.white
                    : isCancel
                    ? Colors.redAccent
                    : Colors.white70,
              ),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: GoogleFonts.vazirmatn(
                color: isSelected
                    ? Colors.white
                    : isCancel
                    ? Colors.redAccent
                    : Colors.white,
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  void _cycleAspectRatio() {
    setState(() {
      if (_videoFit == BoxFit.contain) {
        _videoFit = BoxFit.cover;
      } else if (_videoFit == BoxFit.cover) {
        _videoFit = BoxFit.fill;
      } else {
        _videoFit = BoxFit.contain;
      }
    });
    _onUserInteraction();
  }

  String get _aspectRatioLabel {
    switch (_videoFit) {
      case BoxFit.cover:
        return 'بزرگنمایی (Fill)';
      case BoxFit.fill:
        return 'کشش (Stretch)';
      default:
        return 'تطابق اصلی (Fit)';
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<AppSettingsProvider>(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _exitPlayer();
        }
      },
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: MouseRegion(
            onHover: (_) => _onUserInteraction(),
            child: Stack(
              children: [
                // 1. Video rendering surface with dynamic aspect ratio fit
                Center(
                  child: Video(
                    controller: _videoController,
                    fit: _videoFit,
                    controls: NoVideoControls,
                  ),
                ),

                // 2. Gesture Zones (Double Tap Left / Right for ±10s Seek, Tap Center for Play/Pause)
                Positioned.fill(
                  child: Row(
                    children: [
                      // Left 35%: Seek -10s on double click
                      Expanded(
                        flex: 35,
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onTap: _onUserInteraction,
                          onDoubleTap: () => _seek(-settings.seekStepSeconds),
                        ),
                      ),
                      // Center 30%: Toggle Play/Pause
                      Expanded(
                        flex: 30,
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onTap: _togglePlayPause,
                          onDoubleTap: _toggleFullscreen,
                        ),
                      ),
                      // Right 35%: Seek +10s on double click
                      Expanded(
                        flex: 35,
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onTap: _onUserInteraction,
                          onDoubleTap: () => _seek(settings.seekStepSeconds),
                        ),
                      ),
                    ],
                  ),
                ),

                // 3. Ripple Seek Indicator Overlay
                if (_seekRippleDelta != 0)
                  Align(
                    alignment: _seekRippleDelta > 0
                        ? const Alignment(0.65, 0.0)
                        : const Alignment(-0.65, 0.0),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.75),
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(
                          color: AppColors.brandRed.withValues(alpha: 0.6),
                          width: 1.5,
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: AppColors.brandRedGlow,
                            blurRadius: 24,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _seekRippleDelta > 0
                                ? Icons.forward_10_rounded
                                : Icons.replay_10_rounded,
                            color: Colors.white,
                            size: 28,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${_seekRippleDelta.abs()} ثانیه ${_seekRippleDelta > 0 ? '+' : '-'}',
                            style: GoogleFonts.vazirmatn(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                // HUD Message Overlay
                if (_hudToastMessage != null)
                  Align(
                    alignment: const Alignment(0.0, -0.65),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: AppColors.brandRed.withValues(alpha: 0.7),
                          width: 1.2,
                        ),
                        boxShadow: const [
                          BoxShadow(color: Colors.black54, blurRadius: 16),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_hudToastIcon != null) ...[
                            Icon(
                              _hudToastIcon,
                              color: AppColors.brandRed,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                          ],
                          Text(
                            _hudToastMessage!,
                            style: GoogleFonts.vazirmatn(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                // 4. Controls Overlay
                AnimatedOpacity(
                  opacity: _showControls ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 220),
                  child: IgnorePointer(
                    ignoring: !_showControls,
                    child: Directionality(
                      textDirection: TextDirection.ltr,
                      child: Stack(
                        children: [
                          // Top & Bottom gradient shadows
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            height: 120,
                            child: Container(
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Color(0xB8000000),
                                    Colors.transparent,
                                  ],
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            height: 150,
                            child: Container(
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.bottomCenter,
                                  end: Alignment.topCenter,
                                  colors: [
                                    Color(0xD9000000),
                                    Colors.transparent,
                                  ],
                                ),
                              ),
                            ),
                          ),

                          // Top Bar: Back button, Title & Episode badge (RTL)
                          Positioned(
                            top: 24,
                            left: 24,
                            right: 24,
                            child: Directionality(
                              textDirection: TextDirection.rtl,
                              child: Row(
                                children: [
                                  IconButton(
                                    icon: const Icon(
                                      Icons.arrow_forward_rounded,
                                      color: Colors.white,
                                      size: 26,
                                    ),
                                    tooltip: 'بازگشت (Esc)',
                                    onPressed: _exitPlayer,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          widget.title,
                                          style: GoogleFonts.vazirmatn(
                                            color: Colors.white,
                                            fontSize: 18,
                                            fontWeight: FontWeight.bold,
                                            shadows: const [
                                              Shadow(
                                                color: Colors.black,
                                                blurRadius: 8,
                                              ),
                                            ],
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        if (widget.episodeTitle != null) ...[
                                          const SizedBox(height: 2),
                                          Text(
                                            widget.episodeTitle!,
                                            style: GoogleFonts.vazirmatn(
                                              color: Colors.white70,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          // Center Controls (Netflix Cinematic Style)
                          Center(
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                IconButton(
                                  iconSize: 42,
                                  icon: const Icon(
                                    Icons.replay_10_rounded,
                                    color: Colors.white70,
                                  ),
                                  tooltip: '۱۰ ثانیه قبل (J / ←)',
                                  onPressed: () =>
                                      _seek(-settings.seekStepSeconds),
                                ),
                                const SizedBox(width: 32),
                                StreamBuilder<bool>(
                                  stream: _player.stream.playing,
                                  builder: (context, snapshot) {
                                    final isPlaying = snapshot.data ?? false;
                                    return Container(
                                      width: 68,
                                      height: 68,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: AppColors.brandRed.withValues(
                                          alpha: 0.95,
                                        ),
                                        boxShadow: const [
                                          BoxShadow(
                                            color: AppColors.brandRedGlow,
                                            blurRadius: 20,
                                            spreadRadius: 2,
                                          ),
                                        ],
                                      ),
                                      child: _isLoading && _errorMessage == null
                                          ? const Center(
                                              child: SizedBox(
                                                width: 32,
                                                height: 32,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 3,
                                                      color: Colors.white,
                                                    ),
                                              ),
                                            )
                                          : IconButton(
                                              iconSize: 46,
                                              icon: Icon(
                                                isPlaying
                                                    ? Icons.pause_rounded
                                                    : Icons.play_arrow_rounded,
                                                color: Colors.white,
                                              ),
                                              onPressed: _togglePlayPause,
                                            ),
                                    );
                                  },
                                ),
                                const SizedBox(width: 32),
                                IconButton(
                                  iconSize: 42,
                                  icon: const Icon(
                                    Icons.forward_10_rounded,
                                    color: Colors.white70,
                                  ),
                                  tooltip: '۱۰ ثانیه بعد (L / →)',
                                  onPressed: () =>
                                      _seek(settings.seekStepSeconds),
                                ),
                              ],
                            ),
                          ),

                          // Bottom Bar: Precision Scrubber, Time toggle, Volume Slider, Speed Badge
                          Positioned(
                            bottom: 16,
                            left: 24,
                            right: 24,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Precision Scrubbing Slider with Buffered Track
                                StreamBuilder<Duration>(
                                  stream: _player.stream.buffer,
                                  builder: (context, bufSnap) {
                                    final buffer =
                                        bufSnap.data ?? _player.state.buffer;
                                    return StreamBuilder<Duration>(
                                      stream: _player.stream.position,
                                      builder: (context, posSnap) {
                                        final pos =
                                            posSnap.data ?? Duration.zero;
                                        final dur = _player.state.duration;
                                        final maxMs = dur.inMilliseconds
                                            .toDouble();
                                        final curMs = pos.inMilliseconds
                                            .toDouble()
                                            .clamp(
                                              0.0,
                                              maxMs > 0 ? maxMs : 1.0,
                                            );
                                        final bufMs = buffer.inMilliseconds
                                            .toDouble()
                                            .clamp(
                                              0.0,
                                              maxMs > 0 ? maxMs : 1.0,
                                            );

                                        return SliderTheme(
                                          data: SliderTheme.of(context).copyWith(
                                            trackHeight: 4,
                                            thumbShape:
                                                const RoundSliderThumbShape(
                                                  enabledThumbRadius: 6,
                                                ),
                                            overlayShape:
                                                const RoundSliderOverlayShape(
                                                  overlayRadius: 12,
                                                ),
                                            activeTrackColor:
                                                AppColors.brandRed,
                                            secondaryActiveTrackColor: Colors
                                                .white
                                                .withValues(alpha: 0.38),
                                            inactiveTrackColor: Colors.white24,
                                            thumbColor: AppColors.brandRed,
                                          ),
                                          child: Slider(
                                            min: 0.0,
                                            max: maxMs > 0 ? maxMs : 1.0,
                                            value: curMs,
                                            secondaryTrackValue: maxMs > 0
                                                ? bufMs
                                                : null,
                                            onChanged: (val) {
                                              _onUserInteraction();
                                              _player.seek(
                                                Duration(
                                                  milliseconds: val.toInt(),
                                                ),
                                              );
                                            },
                                          ),
                                        );
                                      },
                                    );
                                  },
                                ),

                                // Bottom Details Bar
                                Row(
                                  children: [
                                    // Time Indicator (Clickable to switch between elapsed and remaining)
                                    StreamBuilder<Duration>(
                                      stream: _player.stream.position,
                                      builder: (context, snapshot) {
                                        final pos =
                                            snapshot.data ?? Duration.zero;
                                        final dur = _player.state.duration;
                                        final remaining = dur - pos;
                                        return InkWell(
                                          onTap: () {
                                            setState(() {
                                              _showRemainingTime =
                                                  !_showRemainingTime;
                                            });
                                          },
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 4,
                                              vertical: 2,
                                            ),
                                            child: Text(
                                              _showRemainingTime
                                                  ? '-${_formatDuration(remaining < Duration.zero ? Duration.zero : remaining)} / ${_formatDuration(dur)}'
                                                  : '${_formatDuration(pos)} / ${_formatDuration(dur)}',
                                              style: GoogleFonts.spaceMono(
                                                color: Colors.white,
                                                fontSize: 13,
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                    const SizedBox(width: 8),

                                    // Volume Control
                                    StreamBuilder<double>(
                                      stream: _player.stream.volume,
                                      builder: (context, snapshot) {
                                        final vol = snapshot.data ?? 100.0;
                                        return Row(
                                          children: [
                                            IconButton(
                                              icon: Icon(
                                                vol == 0
                                                    ? Icons.volume_off_rounded
                                                    : vol < 50
                                                    ? Icons.volume_down_rounded
                                                    : Icons.volume_up_rounded,
                                                color: Colors.white,
                                                size: 20,
                                              ),
                                              tooltip: 'بی‌صدا (M)',
                                              onPressed: _toggleMute,
                                            ),
                                            SizedBox(
                                              width: 80,
                                              child: SliderTheme(
                                                data: SliderTheme.of(context)
                                                    .copyWith(
                                                      trackHeight: 3,
                                                      thumbShape:
                                                          const RoundSliderThumbShape(
                                                            enabledThumbRadius:
                                                                5,
                                                          ),
                                                      activeTrackColor:
                                                          Colors.white,
                                                      inactiveTrackColor:
                                                          Colors.white24,
                                                      thumbColor: Colors.white,
                                                    ),
                                                child: Slider(
                                                  min: 0,
                                                  max: 100,
                                                  value: vol,
                                                  onChanged: (v) {
                                                    _onUserInteraction();
                                                    _player.setVolume(v);
                                                  },
                                                ),
                                              ),
                                            ),
                                          ],
                                        );
                                      },
                                    ),

                                    const Spacer(),

                                    // Action Controls Pill (Speed, Aspect ratio, Audio & Subtitles, PiP, VLC, Fullscreen)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(
                                          0xFF13151F,
                                        ).withValues(alpha: 0.8),
                                        borderRadius: BorderRadius.circular(16),
                                        border: Border.all(
                                          color: Colors.white12,
                                          width: 0.8,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          // Playback Speed Button
                                          PopupMenuButton<double>(
                                            initialValue: _playbackSpeed,
                                            tooltip: 'سرعت پخش',
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                    vertical: 4,
                                                  ),
                                              decoration: BoxDecoration(
                                                border: Border.all(
                                                  color: Colors.white30,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                              ),
                                              child: Text(
                                                '${_playbackSpeed}x',
                                                style: GoogleFonts.spaceMono(
                                                  color: Colors.white,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ),
                                            itemBuilder: (context) =>
                                                [
                                                  0.5,
                                                  0.75,
                                                  1.0,
                                                  1.25,
                                                  1.5,
                                                  2.0,
                                                ].map((speed) {
                                                  return PopupMenuItem<double>(
                                                    value: speed,
                                                    child: Text('${speed}x'),
                                                  );
                                                }).toList(),
                                            onSelected: (speed) {
                                              setState(() {
                                                _playbackSpeed = speed;
                                              });
                                              _player.setRate(speed);
                                              _onUserInteraction();
                                            },
                                          ),
                                          const SizedBox(width: 4),

                                          // Aspect Ratio Toggle
                                          IconButton(
                                            icon: const Icon(
                                              Icons.aspect_ratio_rounded,
                                              color: Colors.white,
                                              size: 20,
                                            ),
                                            tooltip:
                                                'نسبت تصویر: $_aspectRatioLabel',
                                            onPressed: _cycleAspectRatio,
                                          ),

                                          // Audio & Subtitles
                                          IconButton(
                                            icon: const Icon(
                                              Icons.subtitles_rounded,
                                              color: Colors.white,
                                              size: 20,
                                            ),
                                            tooltip: 'زیرنویس و صدا',
                                            onPressed:
                                                _showTrackSelectionDialog,
                                          ),

                                          // Sleep Timer
                                          IconButton(
                                            icon: Icon(
                                              _sleepTimerRemainingMinutes !=
                                                          null ||
                                                      _sleepAtEpisodeEnd
                                                  ? Icons.bedtime_rounded
                                                  : Icons.bedtime_outlined,
                                              color:
                                                  _sleepTimerRemainingMinutes !=
                                                          null ||
                                                      _sleepAtEpisodeEnd
                                                  ? AppColors.brandRed
                                                  : Colors.white,
                                              size: 20,
                                            ),
                                            tooltip:
                                                _sleepTimerRemainingMinutes !=
                                                    null
                                                ? 'تایمر خواب: $_sleepTimerRemainingMinutes دقیقه'
                                                : _sleepAtEpisodeEnd
                                                ? 'تایمر خواب: پایان این قسمت'
                                                : 'تایمر خواب (Sleep Timer)',
                                            onPressed: _showSleepTimerDialog,
                                          ),

                                          // PiP
                                          IconButton(
                                            icon: const Icon(
                                              Icons
                                                  .picture_in_picture_alt_rounded,
                                              color: Colors.white,
                                              size: 20,
                                            ),
                                            tooltip: 'تصویر در تصویر (PiP)',
                                            onPressed: _dockToMiniPlayer,
                                          ),

                                          // VLC
                                          IconButton(
                                            icon: const Icon(
                                              Icons.tv_rounded,
                                              color: Colors.white,
                                              size: 20,
                                            ),
                                            tooltip: 'پخش با VLC',
                                            onPressed: () =>
                                                VLCLauncher.launchInVLC(
                                                  widget.videoUrl,
                                                ),
                                          ),

                                          // Fullscreen
                                          IconButton(
                                            icon: Icon(
                                              _isFullscreen
                                                  ? Icons
                                                        .fullscreen_exit_rounded
                                                  : Icons.fullscreen_rounded,
                                              color: Colors.white,
                                              size: 22,
                                            ),
                                            tooltip: 'تمام‌صفحه (F)',
                                            onPressed: _toggleFullscreen,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // Auto-Next Episode Floating Banner
                if (_showNextEpisodePrompt && widget.nextEpisodeUrl != null)
                  Positioned(
                    bottom: 110,
                    left: 32,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF13151F).withValues(alpha: 0.95),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: AppColors.brandRed.withValues(alpha: 0.6),
                          width: 1.2,
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black87,
                            blurRadius: 20,
                            spreadRadius: 4,
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 38,
                            height: 38,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppColors.brandRed,
                            ),
                            child: Center(
                              child: Text(
                                '$_nextEpisodeCountdown',
                                style: GoogleFonts.spaceMono(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'پخش خودکار قسمت بعد...',
                                style: GoogleFonts.vazirmatn(
                                  color: AppColors.textMuted,
                                  fontSize: 11,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                widget.nextEpisodeTitle ?? 'قسمت بعدی',
                                style: GoogleFonts.vazirmatn(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(width: 16),
                          ElevatedButton(
                            onPressed: _playNextEpisode,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.brandRed,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            child: Text(
                              'پخش اکنون',
                              style: GoogleFonts.vazirmatn(
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(
                              Icons.close_rounded,
                              size: 20,
                              color: Colors.white70,
                            ),
                            tooltip: 'لغو پخش خودکار',
                            onPressed: _cancelAutoNext,
                          ),
                        ],
                      ),
                    ),
                  ),

                // Error Overlay
                if (_errorMessage != null)
                  Center(
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 480),
                      margin: const EdgeInsets.symmetric(horizontal: 24),
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: const Color(0xFF161822).withValues(alpha: 0.95),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white12),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black87,
                            blurRadius: 24,
                            spreadRadius: 4,
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.wifi_off_rounded,
                            color: Color(0xFFE11D48),
                            size: 52,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'عدم امکان پخش استریم',
                            style: GoogleFonts.vazirmatn(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            _errorMessage!,
                            textAlign: TextAlign.center,
                            style: GoogleFonts.vazirmatn(
                              color: Colors.white70,
                              fontSize: 13,
                              height: 1.6,
                            ),
                          ),
                          const SizedBox(height: 24),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              ElevatedButton.icon(
                                icon: const Icon(Icons.tv_rounded, size: 20),
                                label: Text(
                                  'پخش در VLC',
                                  style: GoogleFonts.vazirmatn(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFFE11D48),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                    vertical: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                onPressed: () =>
                                    VLCLauncher.launchInVLC(widget.videoUrl),
                              ),
                              const SizedBox(width: 12),
                              OutlinedButton.icon(
                                icon: const Icon(
                                  Icons.refresh_rounded,
                                  size: 20,
                                ),
                                label: Text(
                                  'تلاش دوباره',
                                  style: GoogleFonts.vazirmatn(),
                                ),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white70,
                                  side: const BorderSide(color: Colors.white24),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                onPressed: _startPlayback,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showTrackSelectionDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141620),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final currentTracks = _player.state.tracks;

            return Directionality(
              textDirection: TextDirection.rtl,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'تنظیمات زیرنویس و صدا',
                          style: GoogleFonts.vazirmatn(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.close_rounded,
                            color: Colors.white70,
                          ),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    const Divider(color: Colors.white12, height: 24),

                    // Section 1: Subtitle Delay / Syncer
                    Text(
                      'هماهنگی زمانی زیرنویس (Subtitle Syncer):',
                      style: GoogleFonts.vazirmatn(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'در صورت جلو یا عقب بودن زیرنویس نسبت به صدا، با دکمه‌های زیر آن را هماهنگ کنید',
                      style: GoogleFonts.vazirmatn(
                        color: AppColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceCard,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: AppColors.glassBorder,
                          width: 0.8,
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _buildDelayBtn('-1s', -1.0, setSheetState),
                          const SizedBox(width: 6),
                          _buildDelayBtn('-0.5s', -0.5, setSheetState),
                          const SizedBox(width: 6),
                          _buildDelayBtn('-0.1s', -0.1, setSheetState),
                          const SizedBox(width: 12),

                          // Delay Display Pill
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: _subtitleDelaySeconds != 0.0
                                  ? AppColors.brandRed.withValues(alpha: 0.2)
                                  : Colors.white10,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: _subtitleDelaySeconds != 0.0
                                    ? AppColors.brandRed
                                    : Colors.white24,
                                width: 0.8,
                              ),
                            ),
                            child: Text(
                              '${_subtitleDelaySeconds >= 0 ? '+' : ''}${_subtitleDelaySeconds.toStringAsFixed(1)}s',
                              style: GoogleFonts.spaceMono(
                                color: _subtitleDelaySeconds != 0.0
                                    ? AppColors.brandRed
                                    : Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ),

                          const SizedBox(width: 12),
                          _buildDelayBtn('+0.1s', 0.1, setSheetState),
                          const SizedBox(width: 6),
                          _buildDelayBtn('+0.5s', 0.5, setSheetState),
                          const SizedBox(width: 6),
                          _buildDelayBtn('+1s', 1.0, setSheetState),
                          const SizedBox(width: 10),
                          IconButton(
                            icon: const Icon(
                              Icons.restart_alt_rounded,
                              size: 20,
                            ),
                            color: Colors.white70,
                            tooltip: 'ریست تأخیر (0.0s)',
                            onPressed: () {
                              setSheetState(() => _subtitleDelaySeconds = 0.0);
                              _applySubtitleDelay(0.0);
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Section 2: External Subtitle Picker
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'تراک‌های زیرنویس:',
                          style: GoogleFonts.vazirmatn(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () async {
                            try {
                              final result = await FilePicker.platform
                                  .pickFiles(
                                    type: FileType.custom,
                                    allowedExtensions: [
                                      'srt',
                                      'vtt',
                                      'ass',
                                      'sub',
                                    ],
                                  );
                              if (result != null &&
                                  result.files.single.path != null) {
                                final filePath = result.files.single.path!;
                                await _player.setSubtitleTrack(
                                  SubtitleTrack.uri(filePath),
                                );
                                if (ctx.mounted) Navigator.pop(ctx);
                              }
                            } catch (e) {
                              debugPrint('Error picking subtitle: $e');
                            }
                          },
                          icon: const Icon(Icons.folder_open_rounded, size: 16),
                          label: Text(
                            'بارگذاری فایل زیرنویس (SRT / VTT)',
                            style: GoogleFonts.vazirmatn(fontSize: 12),
                          ),
                          style: TextButton.styleFrom(
                            foregroundColor: AppColors.brandRed,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        // No Subtitle option
                        ChoiceChip(
                          label: Text(
                            'بدون زیرنویس',
                            style: GoogleFonts.vazirmatn(
                              color:
                                  _player.state.track.subtitle ==
                                      SubtitleTrack.no()
                                  ? Colors.white
                                  : Colors.white70,
                            ),
                          ),
                          selected:
                              _player.state.track.subtitle ==
                              SubtitleTrack.no(),
                          selectedColor: AppColors.brandRed,
                          backgroundColor: Colors.white12,
                          onSelected: (selected) {
                            if (selected) {
                              try {
                                _player.setSubtitleTrack(SubtitleTrack.no());
                              } catch (_) {}
                            }
                            Navigator.pop(ctx);
                          },
                        ),
                        ...currentTracks.subtitle.map((sub) {
                          final isSelected =
                              _player.state.track.subtitle.id == sub.id;
                          return ChoiceChip(
                            label: Text(
                              sub.title ?? sub.language ?? 'زیرنویس ${sub.id}',
                              style: GoogleFonts.vazirmatn(
                                color: isSelected
                                    ? Colors.white
                                    : Colors.white70,
                              ),
                            ),
                            selected: isSelected,
                            selectedColor: AppColors.brandRed,
                            backgroundColor: Colors.white12,
                            onSelected: (selected) {
                              if (selected) {
                                try {
                                  _player.setSubtitleTrack(sub);
                                } catch (_) {}
                              }
                              Navigator.pop(ctx);
                            },
                          );
                        }),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // Section 3: Audio Tracks
                    if (currentTracks.audio.isNotEmpty) ...[
                      Text(
                        'تراک‌های صدا (دوبله و زبان اصلی):',
                        style: GoogleFonts.vazirmatn(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: currentTracks.audio.map((aud) {
                          final isSelected =
                              _player.state.track.audio.id == aud.id;
                          return ChoiceChip(
                            label: Text(
                              aud.title ?? aud.language ?? 'صدای ${aud.id}',
                              style: GoogleFonts.vazirmatn(
                                color: isSelected
                                    ? Colors.white
                                    : Colors.white70,
                              ),
                            ),
                            selected: isSelected,
                            selectedColor: AppColors.brandRed,
                            backgroundColor: Colors.white12,
                            onSelected: (selected) {
                              if (selected) {
                                try {
                                  _player.setAudioTrack(aud);
                                } catch (_) {}
                              }
                              Navigator.pop(ctx);
                            },
                          );
                        }).toList(),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildDelayBtn(
    String label,
    double delta,
    void Function(void Function()) setSheetState,
  ) {
    return InkWell(
      onTap: () {
        setSheetState(() {
          _subtitleDelaySeconds = double.parse(
            (_subtitleDelaySeconds + delta).toStringAsFixed(2),
          );
        });
        _applySubtitleDelay(_subtitleDelaySeconds);
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: GoogleFonts.spaceMono(
            color: Colors.white70,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  void _applySubtitleDelay(double delaySeconds) {
    try {
      final platform = _player.platform as dynamic;
      platform?.setProperty('sub-delay', '$delaySeconds');
    } catch (_) {}
  }
}

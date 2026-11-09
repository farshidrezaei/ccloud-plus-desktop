import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/media_item.dart';
import '../models/watch_history_item.dart';

// Wrapper class to add timestamp to MediaItem for favorites
class MediaItemWithTimestamp {
  final MediaItem mediaItem;
  final int timestamp;

  MediaItemWithTimestamp(this.mediaItem, this.timestamp);

  Map<String, dynamic> toJson() {
    final json = mediaItem.toJson();
    json['timestamp'] = timestamp;
    return json;
  }

  static MediaItemWithTimestamp fromJson(Map<String, dynamic> json) {
    final timestamp =
        json['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch;
    // Remove timestamp before creating MediaItem
    final jsonWithoutTimestamp = Map<String, dynamic>.from(json);
    jsonWithoutTimestamp.remove('timestamp');
    final mediaItem = MediaItem.fromJson(jsonWithoutTimestamp);
    return MediaItemWithTimestamp(mediaItem, timestamp);
  }
}

class StorageUtils {
  static Future<String> get _localPath async {
    final directory = await getApplicationDocumentsDirectory();
    return directory.path;
  }

  static Future<File> get _localMoviesFile async {
    final path = await _localPath;
    return File('$path/movies.json');
  }

  static Future<File> get _localSeriesFile async {
    final path = await _localPath;
    return File('$path/series.json');
  }

  static Future<File> get _localFavoritesFile async {
    final path = await _localPath;
    return File('$path/favorites.json');
  }

  static Future<File> get _localWatchHistoryFile async {
    final path = await _localPath;
    return File('$path/watch_history.json');
  }

  // Save a single movie to storage
  static Future<void> saveMovie(MediaItem movie) async {
    try {
      // Clear all existing movie data first
      await clearAllMovies();

      final file = await _localMoviesFile;
      final jsonString = jsonEncode(movie.toJson());
      await file.writeAsString(jsonString);
    } catch (e) {
      // Handle error silently or log it
      print('Error saving movie: $e');
    }
  }

  // Load a movie from storage
  static Future<MediaItem?> loadMovie() async {
    try {
      final file = await _localMoviesFile;
      if (await file.exists()) {
        final jsonString = await file.readAsString();
        final jsonMap = jsonDecode(jsonString) as Map<String, dynamic>;
        return MediaItem.fromJson(jsonMap);
      }
      return null;
    } catch (e) {
      // Handle error silently or log it
      print('Error loading movie: $e');
      return null;
    }
  }

  // Clear all movies from storage
  static Future<void> clearAllMovies() async {
    try {
      final file = await _localMoviesFile;
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      // Handle error silently or log it
      print('Error clearing movies: $e');
    }
  }

  // Save a single series to storage
  static Future<void> saveSeries(MediaItem series) async {
    try {
      // Clear all existing series data first
      await clearAllSeries();

      final file = await _localSeriesFile;
      final jsonString = jsonEncode(series.toJson());
      await file.writeAsString(jsonString);
    } catch (e) {
      // Handle error silently or log it
      print('Error saving series: $e');
    }
  }

  // Load a series from storage
  static Future<MediaItem?> loadSeries() async {
    try {
      final file = await _localSeriesFile;
      if (await file.exists()) {
        final jsonString = await file.readAsString();
        final jsonMap = jsonDecode(jsonString) as Map<String, dynamic>;
        return MediaItem.fromJson(jsonMap);
      }
      return null;
    } catch (e) {
      // Handle error silently or log it
      print('Error loading series: $e');
      return null;
    }
  }

  // Clear all series from storage
  static Future<void> clearAllSeries() async {
    try {
      final file = await _localSeriesFile;
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      // Handle error silently or log it
      print('Error clearing series: $e');
    }
  }

  // Add a media item to favorites with timestamp
  static Future<void> addToFavorites(MediaItem mediaItem) async {
    try {
      final favorites = await loadFavoritesWithTimestamp();
      // Check if item already exists
      final existingIndex = favorites.indexWhere(
        (item) =>
            item.mediaItem.id == mediaItem.id &&
            item.mediaItem.type == mediaItem.type,
      );
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      if (existingIndex != -1) {
        // Update existing item's timestamp
        favorites.removeAt(existingIndex);
        favorites.insert(0, MediaItemWithTimestamp(mediaItem, timestamp));
      } else {
        // Add new item at the beginning (newest first)
        favorites.insert(0, MediaItemWithTimestamp(mediaItem, timestamp));
      }
      await _saveFavoritesWithTimestamp(favorites);
    } catch (e) {
      print('Error adding to favorites: $e');
    }
  }

  // Remove a media item from favorites
  static Future<void> removeFromFavorites(int id, String type) async {
    try {
      final favorites = await loadFavoritesWithTimestamp();
      favorites.removeWhere(
        (item) => item.mediaItem.id == id && item.mediaItem.type == type,
      );
      await _saveFavoritesWithTimestamp(favorites);
    } catch (e) {
      print('Error removing from favorites: $e');
    }
  }

  // Load all favorites with timestamps
  static Future<List<MediaItemWithTimestamp>>
  loadFavoritesWithTimestamp() async {
    try {
      final file = await _localFavoritesFile;
      if (await file.exists()) {
        final jsonString = await file.readAsString();
        final jsonArray = jsonDecode(jsonString) as List<dynamic>;
        final favorites = <MediaItemWithTimestamp>[];

        for (final item in jsonArray) {
          final jsonMap = item as Map<String, dynamic>;
          final favoriteItem = MediaItemWithTimestamp.fromJson(jsonMap);
          favorites.add(favoriteItem);
        }

        // Sort by timestamp descending (newest first)
        favorites.sort((a, b) => b.timestamp.compareTo(a.timestamp));
        return favorites;
      }
      return [];
    } catch (e) {
      print('Error loading favorites: $e');
      return [];
    }
  }

  // Load all favorites (backward compatibility)
  static Future<List<MediaItem>> loadFavorites() async {
    final favoritesWithTimestamp = await loadFavoritesWithTimestamp();
    return favoritesWithTimestamp.map((item) => item.mediaItem).toList();
  }

  // Clear all favorites
  static Future<void> clearAllFavorites() async {
    try {
      final file = await _localFavoritesFile;
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      print('Error clearing favorites: $e');
    }
  }

  // Save favorites to file with timestamps
  static Future<void> _saveFavoritesWithTimestamp(
    List<MediaItemWithTimestamp> favorites,
  ) async {
    try {
      final file = await _localFavoritesFile;
      final jsonArray = favorites.map((item) => item.toJson()).toList();
      final jsonString = jsonEncode(jsonArray);
      await file.writeAsString(jsonString);
    } catch (e) {
      print('Error saving favorites: $e');
    }
  }

  // Check if a media item is in favorites
  static Future<bool> isFavorite(int id, String type) async {
    try {
      final favorites = await loadFavorites();
      return favorites.any((item) => item.id == id && item.type == type);
    } catch (e) {
      print('Error checking favorite status: $e');
      return false;
    }
  }

  // --- Watch History ---

  static Future<List<WatchHistoryItem>> loadWatchHistory() async {
    try {
      final file = await _localWatchHistoryFile;
      if (!await file.exists()) {
        return [];
      }
      final contents = await file.readAsString();
      if (contents.isEmpty) return [];
      final List<dynamic> jsonList = jsonDecode(contents);
      final items = jsonList
          .map((json) {
            try {
              return WatchHistoryItem.fromJson(json as Map<String, dynamic>);
            } catch (_) {
              return null;
            }
          })
          .whereType<WatchHistoryItem>()
          .toList();

      // Sort by last watched date descending
      items.sort((a, b) => b.lastWatchedAt.compareTo(a.lastWatchedAt));
      return items;
    } catch (e) {
      print('Error loading watch history: $e');
      return [];
    }
  }

  static Future<void> saveWatchHistoryItem(WatchHistoryItem item) async {
    try {
      final items = await loadWatchHistory();
      // Remove any previous entry for this item id
      items.removeWhere((i) => i.id == item.id);

      // If user watched more than 95%, remove it from "continue watching"
      if (!item.isCompleted) {
        items.insert(0, item);
      }

      // Limit to 20 items max
      final limited = items.take(20).toList();

      final file = await _localWatchHistoryFile;
      final jsonString = jsonEncode(limited.map((i) => i.toJson()).toList());
      await file.writeAsString(jsonString);
    } catch (e) {
      print('Error saving watch history: $e');
    }
  }

  static Future<void> removeFromWatchHistory(String id) async {
    try {
      final items = await loadWatchHistory();
      items.removeWhere((i) => i.id == id);
      final file = await _localWatchHistoryFile;
      final jsonString = jsonEncode(items.map((i) => i.toJson()).toList());
      await file.writeAsString(jsonString);
    } catch (e) {
      print('Error removing from watch history: $e');
    }
  }

  static Future<void> clearWatchHistory() async {
    try {
      final file = await _localWatchHistoryFile;
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      print('Error clearing watch history: $e');
    }
  }

  static Future<File> get _localWatchedEpisodesFile async {
    final path = await _localPath;
    return File('$path/watched_episodes.json');
  }

  static Future<Set<String>> getWatchedEpisodes(int seriesId) async {
    try {
      final file = await _localWatchedEpisodesFile;
      if (!await file.exists()) return {};
      final content = await file.readAsString();
      final Map<String, dynamic> data = jsonDecode(content);
      final List<dynamic>? list = data[seriesId.toString()];
      return list?.map((e) => e.toString()).toSet() ?? {};
    } catch (_) {
      return {};
    }
  }

  static Future<void> toggleEpisodeWatched(int seriesId, int episodeId) async {
    try {
      final file = await _localWatchedEpisodesFile;
      Map<String, dynamic> data = {};
      if (await file.exists()) {
        final content = await file.readAsString();
        data = jsonDecode(content);
      }
      final key = seriesId.toString();
      final List<String> list =
          (data[key] as List<dynamic>?)?.map((e) => e.toString()).toList() ??
          [];
      final epStr = episodeId.toString();
      if (list.contains(epStr)) {
        list.remove(epStr);
      } else {
        list.add(epStr);
      }
      data[key] = list;
      await file.writeAsString(jsonEncode(data));
    } catch (_) {}
  }

  static Future<String> exportBackup() async {
    final favorites = await loadFavoritesWithTimestamp();
    final watchHistory = await loadWatchHistory();

    Map<String, dynamic> watchedEpisodes = {};
    try {
      final epFile = await _localWatchedEpisodesFile;
      if (await epFile.exists()) {
        watchedEpisodes = jsonDecode(await epFile.readAsString());
      }
    } catch (_) {}

    final backupData = {
      'version': 1,
      'app': 'ccloud_plus',
      'exportedAt': DateTime.now().toIso8601String(),
      'favorites': favorites.map((f) => f.toJson()).toList(),
      'watch_history': watchHistory.map((w) => w.toJson()).toList(),
      'watched_episodes': watchedEpisodes,
    };

    return const JsonEncoder.withIndent('  ').convert(backupData);
  }

  static Future<Map<String, int>> importBackup(String jsonString) async {
    final dynamic decoded = jsonDecode(jsonString);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('ساختار فایل پشتیبان نامعتبر است.');
    }

    int restoredFavorites = 0;
    int restoredHistory = 0;

    // Restore favorites
    if (decoded.containsKey('favorites') && decoded['favorites'] is List) {
      final list = decoded['favorites'] as List;
      final existingFavorites = await loadFavoritesWithTimestamp();
      for (final item in list) {
        try {
          final fav = MediaItemWithTimestamp.fromJson(
            item as Map<String, dynamic>,
          );
          final idx = existingFavorites.indexWhere(
            (e) =>
                e.mediaItem.id == fav.mediaItem.id &&
                e.mediaItem.type == fav.mediaItem.type,
          );
          if (idx != -1) {
            existingFavorites[idx] = fav;
          } else {
            existingFavorites.add(fav);
          }
          restoredFavorites++;
        } catch (_) {}
      }
      existingFavorites.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      await _saveFavoritesWithTimestamp(existingFavorites);
    }

    // Restore watch history
    if (decoded.containsKey('watch_history') &&
        decoded['watch_history'] is List) {
      final list = decoded['watch_history'] as List;
      final existingHistory = await loadWatchHistory();
      for (final item in list) {
        try {
          final hist = WatchHistoryItem.fromJson(item as Map<String, dynamic>);
          existingHistory.removeWhere((e) => e.id == hist.id);
          existingHistory.add(hist);
          restoredHistory++;
        } catch (_) {}
      }
      existingHistory.sort(
        (a, b) => b.lastWatchedAt.compareTo(a.lastWatchedAt),
      );
      final file = await _localWatchHistoryFile;
      await file.writeAsString(
        jsonEncode(existingHistory.take(50).map((e) => e.toJson()).toList()),
      );
    }

    // Restore watched episodes
    if (decoded.containsKey('watched_episodes') &&
        decoded['watched_episodes'] is Map) {
      try {
        final Map<String, dynamic> incoming = decoded['watched_episodes'];
        final epFile = await _localWatchedEpisodesFile;
        Map<String, dynamic> existing = {};
        if (await epFile.exists()) {
          existing = jsonDecode(await epFile.readAsString());
        }
        for (final entry in incoming.entries) {
          final existingList =
              (existing[entry.key] as List<dynamic>?)
                  ?.map((e) => e.toString())
                  .toSet() ??
              {};
          final incomingList =
              (entry.value as List<dynamic>?)
                  ?.map((e) => e.toString())
                  .toSet() ??
              {};
          existing[entry.key] = existingList.union(incomingList).toList();
        }
        await epFile.writeAsString(jsonEncode(existing));
      } catch (_) {}
    }

    return {'favorites': restoredFavorites, 'history': restoredHistory};
  }
}

bool containsFarsiOrArabic(String text) {
  final farsiArabicRegex = RegExp(
    r'[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]',
  );

  return farsiArabicRegex.hasMatch(text);
}

import 'dart:convert';
import 'package:workmanager/workmanager.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

// Background task name
const String fetchLocationTask = "fetchLocationTask";

class BackgroundService {
  static Future<void> initialize() async {
    // Initialize WorkManager once at app startup
    await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);

    // Register a periodic background task every hour
    await Workmanager().registerPeriodicTask(
      "1",
      fetchLocationTask,
      frequency: const Duration(hours: 1),
      existingWorkPolicy: ExistingWorkPolicy.keep, // ✅ Correct enum
      // initialDelay: const Duration(minutes: 5),
    );
  }
}

// Dispatcher for WorkManager background tasks
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task == fetchLocationTask) {
      final token = await FlutterSecureStorage().read(key: 'token');
      if (token == null) {
        print("No token stored, skipping location task");
        return Future.value(false);
      }

      // ✅ Restrict tracking hours (9 AM - 5 PM)
      final now = DateTime.now();
      final hour = now.hour;
      if (hour < 9 || hour > 17) {
        print("Outside tracking interval");
        return Future.value(true); // success, no action
      }

      // ✅ Get current position
      Position? pos;
      try {
        pos = await _determinePosition();
      } catch (e) {
        print("Error getting location: $e");
      }

      if (pos == null) {
        return Future.value(false);
      }

      final lat = pos.latitude;
      final lon = pos.longitude;
      final timestamp = now.toIso8601String();

      // ✅ Retry sending location up to 3 times
      bool sent = false;
      for (int i = 0; i < 3; i++) {
        sent = await _uploadLocation(token, lat, lon, timestamp);
        if (sent) break;
        await Future.delayed(const Duration(seconds: 10));
      }

      // ✅ Save locally if upload failed after retries
      if (!sent) {
        print("📍 Location could not be uploaded after retries.");
      } else {
        print("✅ Location uploaded successfully after retries.");
      }

      return Future.value(true);
    }

    return Future.value(false);
  });
}

// Helper: Upload location to API
Future<bool> _uploadLocation(
  String token,
  double lat,
  double lon,
  String timestamp,
) async {
  try {
    final url = Uri.parse('https://gateway.seher.org.pk/api/save-location');
    final response = await http.post(
      url,
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'latitude': lat,
        'longitude': lon,
        'recorded_at': timestamp,
      }),
    );

    if (response.statusCode == 200) {
      print(
        "✅ Location uploaded (${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)})",
      );
      return true;
    } else {
      print("⚠️ Upload failed: ${response.statusCode}");
      return false;
    }
  } catch (e) {
    print("❌ Upload exception: $e");
    return false;
  }
}

// Helper: Get user position safely
Future<Position> _determinePosition() async {
  bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
  if (!serviceEnabled) {
    throw Exception('Location services are disabled.');
  }

  LocationPermission permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied) {
      throw Exception('Location permissions are denied');
    }
  }

  if (permission == LocationPermission.deniedForever) {
    throw Exception('Location permissions are permanently denied.');
  }

  return await Geolocator.getCurrentPosition(
    desiredAccuracy: LocationAccuracy.high,
  );
}

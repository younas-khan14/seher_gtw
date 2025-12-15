import 'package:flutter/material.dart';
import 'package:workmanager/workmanager.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
// ...existing code...
import 'dart:async';

// This is the background task that will run even when the app is closed
@pragma('vm:entry-point')
void callbackDispatcher() {
  WidgetsFlutterBinding.ensureInitialized();

  Workmanager().executeTask((task, inputData) async {
    try {
      debugPrint('🌍 Background location task started at {DateTime.now()}');

      // First check if location services are enabled
      if (!await Geolocator.isLocationServiceEnabled()) {
        debugPrint('❌ Location services are disabled');
        return false;
      }

      // Check location permission
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        debugPrint('❌ Location permission denied');
        return false;
      }

      // Get current location with timeout and retry
      Position? position;
      int retries = 3;

      while (position == null && retries > 0) {
        try {
          position =
              await Geolocator.getCurrentPosition(
                desiredAccuracy: LocationAccuracy.high,
                forceAndroidLocationManager: true,
              ).timeout(
                const Duration(seconds: 10),
                onTimeout: () {
                  throw TimeoutException('Location request timed out');
                },
              );
        } catch (e) {
          debugPrint('⚠️ Location attempt failed: $e');
          retries--;
          if (retries > 0) {
            await Future.delayed(const Duration(seconds: 2));
          }
        }
      }

      if (position == null) {
        throw Exception('Failed to get location after all retries');
      }

      // Check if it's a mock location
      Position? realPosition;
      if (position.isMocked) {
        debugPrint('📍 Mock location detected in background');
        realPosition = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          forceAndroidLocationManager: true,
        );
      }

      // Try to send to server
      const storage = FlutterSecureStorage();
      final userId = await storage.read(key: 'user_id');
      final token = await storage.read(key: 'token');

      if (userId != null && token != null) {
        try {
          final locationData = {
            'user_id': int.parse(userId),
            'latitude': position.latitude,
            'longitude': position.longitude,
            'recorded_at': DateTime.now().toIso8601String(),
            'is_mocked': position.isMocked,
          };

          if (position.isMocked && realPosition != null) {
            locationData['real_latitude'] = realPosition.latitude;
            locationData['real_longitude'] = realPosition.longitude;
            locationData['location_difference'] = Geolocator.distanceBetween(
              position.latitude,
              position.longitude,
              realPosition.latitude,
              realPosition.longitude,
            );
          }

          final response = await http.post(
            Uri.parse('https://gateway.seher.org.pk/api/save-location'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(locationData),
          );

          debugPrint(
            '📤 Background location sent: ${response.statusCode == 200 ? 'Success' : 'Failed'}',
          );
        } catch (e) {
          debugPrint('❌ Error sending location: $e');
          // No local saving, just log the error
        }
      }

      return true;
    } catch (e) {
      debugPrint('❌ Background task error: $e');
      return false;
    }
  });
}

class BackgroundLocationService {
  static const String _tag = 'BackgroundLocationService';

  static Future<void> initialize() async {
    try {
      debugPrint('$_tag: Initializing background service...');

      // Ensure location services are available
      if (!await Geolocator.isLocationServiceEnabled()) {
        debugPrint('$_tag: Location services are disabled');
        await Geolocator.openLocationSettings();
        return;
      }

      // Check and request permissions if needed
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          debugPrint('$_tag: Location permissions are denied');
          return;
        }
      }

      // Initialize Workmanager with crash protection
      await Workmanager().initialize(
        callbackDispatcher,
        isInDebugMode: false, // Set to false for release build
      );

      // Register periodic task to run every 15 minutes
      await Workmanager().registerPeriodicTask(
        'locationUpdate',
        'updateLocation',
        frequency: const Duration(minutes: 15),
        constraints: Constraints(
          networkType: NetworkType.connected,
          requiresBatteryNotLow: true,
        ),
        existingWorkPolicy: ExistingWorkPolicy.keep,
        // Add these options for better reliability
        backoffPolicy: BackoffPolicy.linear,
        backoffPolicyDelay: const Duration(minutes: 15),
      );

      // Also register a one-off task that runs once on app launch
      await Workmanager().registerOneOffTask(
        'initialLocationUpdate',
        'updateLocation',
        constraints: Constraints(
          networkType: NetworkType.connected,
          requiresBatteryNotLow: true,
        ),
      );

      debugPrint('✅ Background location service initialized');
    } catch (e) {
      debugPrint('❌ Failed to initialize background service: $e');
    }
  }
}

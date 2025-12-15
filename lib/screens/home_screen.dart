import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final storage = const FlutterSecureStorage();
  Position? _currentPosition;
  Position? _realPosition;
  String _status = 'Ready to share location';
  bool _isLocationMocked = false;

  @override
  void initState() {
    super.initState();
    _checkLocationPermission();
  }

  Future<void> _checkLocationPermission() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() => _status = 'Location services are disabled');
      return;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        setState(() => _status = 'Location permissions are denied');
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      setState(() => _status = 'Location permissions are permanently denied');
      return;
    }
  }

  double _calculateDistance(Position pos1, Position pos2) {
    return Geolocator.distanceBetween(
      pos1.latitude,
      pos1.longitude,
      pos2.latitude,
      pos2.longitude,
    );
  }

  Future<Position?> _getRealLocation() async {
    try {
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        forceAndroidLocationManager: true,
      );
    } catch (e) {
      debugPrint('Error getting real location: $e');
      return null;
    }
  }

  Future<void> _getCurrentLocation() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        forceAndroidLocationManager: true,
      );

      if (await _isMockLocation(position)) {
        return;
      }

      setState(() {
        _currentPosition = position;
        _status = 'Location updated successfully';
      });

      await _sendLocation(position);
    } catch (e) {
      setState(() => _status = 'Error getting location: $e');
    }
  }

  Future<bool> _isMockLocation(Position position) async {
    if (position.isMocked) {
      _realPosition = await _getRealLocation();
      setState(() {
        _status = 'Mock location detected';
        _isLocationMocked = true;
      });
      return true;
    }
    _isLocationMocked = false;
    return false;
  }

  Future<void> _sendLocation(Position position) async {
    try {
      final userId = await storage.read(key: 'user_id');
      final token = await storage.read(key: 'token');
      if (userId == null || token == null) {
        setState(() => _status = 'Not authenticated');
        return;
      }

      final uri = Uri.parse('https://gateway.seher.org.pk/api/save-location');
      final now = DateTime.now();

      final locationData = {
        'user_id': int.parse(userId),
        'latitude': position.latitude,
        'longitude': position.longitude,
        'recorded_at': now.toIso8601String(),
        'is_mocked': position.isMocked,
      };

      if (_isLocationMocked && _realPosition != null) {
        locationData['real_latitude'] = _realPosition!.latitude;
        locationData['real_longitude'] = _realPosition!.longitude;
        locationData['location_difference'] = _calculateDistance(
          position,
          _realPosition!,
        );
      }

      final response = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(locationData),
      );

      if (response.statusCode == 200) {
        setState(() => _status = 'Location shared successfully');
      } else {
        setState(() => _status = 'Failed to send location');
      }
    } catch (e) {
      debugPrint('Error sending location: $e');
      setState(() => _status = 'Error: Failed to send location');
    }
  }

  Future<void> _logout() async {
    await storage.delete(key: 'auth_token');
    if (mounted) {
      Navigator.of(context).pushReplacementNamed('/');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Location Sharing'),
        actions: [
          IconButton(icon: const Icon(Icons.logout), onPressed: _logout),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _status,
              style: TextStyle(
                color: _isLocationMocked ? Colors.red : Colors.black,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            if (_currentPosition != null) ...[
              Text('Latitude: ${_currentPosition!.latitude}'),
              Text('Longitude: ${_currentPosition!.longitude}'),
              if (_realPosition != null && _isLocationMocked) ...[
                const SizedBox(height: 20),
                const Text(
                  'Real Location:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Text('Latitude: ${_realPosition!.latitude}'),
                Text('Longitude: ${_realPosition!.longitude}'),
                Text(
                  'Distance Difference: ${_calculateDistance(_currentPosition!, _realPosition!).toStringAsFixed(2)} meters',
                  style: const TextStyle(color: Colors.red),
                ),
              ],
            ],
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _getCurrentLocation,
              child: const Text('Share Location'),
            ),
          ],
        ),
      ),
    );
  }
}

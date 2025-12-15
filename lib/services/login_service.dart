import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

final _secure = FlutterSecureStorage();

// Generate a salt (random string)
String _generateSalt([int length = 16]) {
  final rand = Random.secure();
  final bytes = List<int>.generate(length, (_) => rand.nextInt(256));
  return base64Url.encode(bytes);
}

// Hash the password using salt (simplified PBKDF2)
String _hashPassword(String password, String salt) {
  final key = utf8.encode(password + salt);
  final bytes = sha256.convert(key).bytes;
  return base64Url.encode(bytes);
}

// Store hashed password + salt on successful login
Future<void> storeCredentials(String username, String password) async {
  final salt = _generateSalt();
  final hash = _hashPassword(password, salt);
  await _secure.write(key: 'salt_$username', value: salt);
  await _secure.write(key: 'hash_$username', value: hash);
  await _secure.write(
    key: 'last_login_$username',
    value: DateTime.now().toIso8601String(),
  );
}

// Try login via server
Future<bool> loginOnline(String username, String password) async {
  try {
    final url = Uri.parse('https://gateway.seher.org.pk/api/login');

    final response = await http.post(
      url,
      body: {'email': username, 'password': password},
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);

      if (data['status'] == 1 && data['data'] != null) {
        final userData = data['data'];

        await storeCredentials(username, password);
        await _secure.write(key: 'token', value: userData['token']);
        await _secure.write(key: 'user_id', value: userData['id'].toString());
        await _secure.write(key: 'email', value: userData['email']);
        await _secure.write(key: 'name', value: userData['name']);

        return true;
      } else {
        return false; // Invalid credentials
      }
    } else {
      return false; // Server error
    }
  } catch (e) {
    print('Login error: $e');
    return false; // Network error
  }
}

// Try login offline (only if user has logged in before)
Future<bool> loginOffline(String username, String password) async {
  final salt = await _secure.read(key: 'salt_$username');
  final storedHash = await _secure.read(key: 'hash_$username');
  final lastLoginStr = await _secure.read(key: 'last_login_$username');

  if (salt == null || storedHash == null || lastLoginStr == null) {
    return false; // Never logged in before
  }

  // Check password
  final hash = _hashPassword(password, salt);
  if (hash != storedHash) return false;

  // Optionally: deny login if too many days since last online login
  final lastLogin = DateTime.parse(lastLoginStr);
  if (DateTime.now().difference(lastLogin).inDays > 7) {
    return false; // Offline login expired after 7 days
  }

  return true;
}

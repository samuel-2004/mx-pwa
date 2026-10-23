import 'package:geolocator/geolocator.dart';

import 'geo.dart';

/// The device position could not be read. [message] is safe to show.
class LocationUnavailableException implements Exception {
  const LocationUnavailableException(this.message);

  final String message;
}

/// Checks whether device-level location services are enabled.
///
/// Takes no parameters. Returns whether the platform reports location services
/// as enabled. Throws if the platform cannot provide the service state.
Future<bool> isLocationServiceEnabled() =>
    Geolocator.isLocationServiceEnabled();

/// Reads the current position of the device.
///
/// Asks for permission if needed. Browsers only allow this on HTTPS (or
/// localhost) and after the person agrees to the prompt. Returns the point
/// with its accuracy in metres and origin [GeoOrigin.device].
/// Throws [LocationUnavailableException] if permission is refused, location
/// is switched off or no position arrives within 20 seconds.
Future<GeoPoint> getDeviceLocation() async {
  try {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw const LocationUnavailableException('Location access was refused.');
    }
    final Position position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 20),
      ),
    );
    return GeoPoint(
      lat: position.latitude,
      lng: position.longitude,
      origin: GeoOrigin.device,
      accuracyM: position.accuracy,
      capturedAt: DateTime.now().toUtc(),
    );
  } on LocationUnavailableException {
    rethrow;
  } on Exception {
    throw const LocationUnavailableException('Could not get your location.');
  }
}

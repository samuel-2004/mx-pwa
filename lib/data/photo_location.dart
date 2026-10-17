import 'dart:typed_data';

import 'package:exif/exif.dart'
    show IfdRatios, IfdTag, IfdValues, Ratio, readExifFromBytes;

import 'geo.dart';

/// Reads the GPS position stored in a photo's metadata.
///
/// [bytes] must be the original file: resizing or re-encoding drops the
/// metadata. Returns null when the photo has no usable position, which is
/// common because many browsers and phones strip location when a photo is
/// shared. A position of exactly 0, 0 is treated as missing, since cameras
/// write it when they have no fix. Does not throw.
Future<GeoPoint?> readPhotoLocation(Uint8List bytes) async {
  try {
    final Map<String, IfdTag> tags = await readExifFromBytes(bytes);
    final double? lat = _coordinate(
      tags['GPS GPSLatitude'],
      tags['GPS GPSLatitudeRef'],
    );
    final double? lng = _coordinate(
      tags['GPS GPSLongitude'],
      tags['GPS GPSLongitudeRef'],
    );
    if (lat == null || lng == null) return null;
    if (!isValidLatLng(lat, lng) || (lat == 0 && lng == 0)) return null;
    return GeoPoint(lat: lat, lng: lng, origin: GeoOrigin.photo);
  } catch (_) {
    // Malformed metadata can fail in ways that are not Exceptions.
    return null;
  }
}

/// Converts degrees, minutes and seconds plus a hemisphere letter to signed
/// decimal degrees, or null when either tag is missing or malformed.
double? _coordinate(IfdTag? value, IfdTag? reference) {
  if (value == null || reference == null) return null;
  final IfdValues raw = value.values;
  if (raw is! IfdRatios) return null;
  final List<Ratio> parts = raw.ratios;
  if (parts.length < 3) return null;
  for (final Ratio part in parts) {
    if (part.denominator == 0) return null;
  }
  final double degrees = parts[0].numerator / parts[0].denominator +
      parts[1].numerator / parts[1].denominator / 60 +
      parts[2].numerator / parts[2].denominator / 3600;
  final String hemisphere = reference.printable;
  return hemisphere == 'S' || hemisphere == 'W' ? -degrees : degrees;
}
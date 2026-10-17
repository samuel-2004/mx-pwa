/// Build-time configuration passed with `--dart-define-from-file`.
///
/// Only public values belong here. Anything read here is compiled into the
/// web bundle, so never add the Supabase secret key, database passwords or
/// the PowerSync replication password.
class AppConfig {
  const AppConfig._();

  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const String supabasePublishableKey =
      String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
  static const String powersyncUrl =
      String.fromEnvironment('POWERSYNC_INSTANCE_URL');
  static const String appUrl =
      String.fromEnvironment('APP_URL');

  /// Raster tile URL template for maps. The default is the public
  /// OpenStreetMap server, which is for light use only: set a keyed provider
  /// (MapTiler, Stadia, ...) for a real event.
  static const String mapTileUrl = String.fromEnvironment(
    'MAP_TILE_URL',
    defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  );

  /// Credit shown on the map. It must match the tile provider's terms.
  static const String mapAttribution = String.fromEnvironment(
    'MAP_ATTRIBUTION',
    defaultValue: 'OpenStreetMap contributors',
  );

  /// Checks that every required value was supplied.
  ///
  /// Returns normally when all are present. Throws [StateError] naming the
  /// missing values.
  static void validate() {
    final List<String> missing = <String>[
      if (supabaseUrl.isEmpty) 'SUPABASE_URL',
      if (supabasePublishableKey.isEmpty) 'SUPABASE_PUBLISHABLE_KEY',
      if (powersyncUrl.isEmpty) 'POWERSYNC_INSTANCE_URL',
    ];
    if (missing.isEmpty) return;
    throw StateError(
      'Missing ${missing.join(', ')}. '
      'Run with --dart-define-from-file=client.env.json.',
    );
  }
}
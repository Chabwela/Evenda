/// Build-time configuration, passed with --dart-define (or --dart-define-from-file=env/prod.json).
///
/// Only public values belong here. The Supabase publishable key is designed to
/// ship in clients; it is safe because every table is protected by RLS. Service
/// role keys, FCM service accounts and SMS provider secrets live only in
/// Supabase (Edge Function secrets / Auth settings), never in the app.
abstract final class AppConfig {
  ///
  /// Defaults point at the production project, so a plain `flutter run` works;
  /// --dart-define can still override them (e.g. for a staging project).
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL', defaultValue: 'https://plihgjgaabxwlbugqbni.supabase.co');
  /// Publishable (client) key. SUPABASE_ANON_KEY is accepted for older projects.
  static const supabaseKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY',
      defaultValue: String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: 'sb_publishable_h-G5GdACswONm25AOMO0WA_EedeK-xm'));

  /// Raster tile template for the map. Defaults to the OpenStreetMap
  /// standard tile server, which is for development only (see the OSMF tile
  /// usage policy). Production must use a tile provider such as MapTiler,
  /// Stadia or a self-hosted server.
  static const mapTileUrl = String.fromEnvironment('MAP_TILE_URL', defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png');
  static const mapAttribution = String.fromEnvironment('MAP_ATTRIBUTION', defaultValue: '© OpenStreetMap contributors');

  /// Push notifications. On by default: without google-services.json /
  /// GoogleService-Info.plist Firebase fails to start and push is skipped
  /// quietly (in-app notifications still work). Pass false to force it off.
  static const firebaseEnabled = bool.fromEnvironment('FIREBASE_ENABLED', defaultValue: true);

  static bool get hasBackend => supabaseUrl.isNotEmpty && supabaseKey.isNotEmpty;
  static bool get usingDevTiles => mapTileUrl.contains('tile.openstreetmap.org');

  static const userAgentPackage = 'com.dantechsolutionsgroup.evenda';
}

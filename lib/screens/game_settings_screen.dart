import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:powersync/powersync.dart' show PowerSyncDatabase;
import 'package:qr_flutter/qr_flutter.dart';

import '../auth/validators.dart';
import '../data/game_options.dart';
import '../data/game_settings.dart';
import '../layout/app_scaffold.dart';
import '../layout/format.dart';
import '../orient_ui/button.dart';
import '../orient_ui/copy_button.dart';
import '../orient_ui/empty_state.dart';
import '../orient_ui/info_banner.dart';
import '../orient_ui/picker.dart';
import '../orient_ui/style.dart';
import '../orient_ui/tappable_icon.dart';
import '../orient_ui/tile.dart';
import '../orient_ui/toast.dart';
import '../orient_ui/toggle_tile.dart';
import '../widgets/loading_spinner.dart';
import '../widgets/surface_card.dart';
import '../config/app_config.dart';

class GameSettingsScreen extends StatefulWidget {
  const GameSettingsScreen({required this.db, super.key});

  final PowerSyncDatabase db;

  @override
  State<GameSettingsScreen> createState() => _GameSettingsScreenState();
}

class _GameSettingsScreenState extends State<GameSettingsScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final GameSettingsApi _api = GameSettingsApi();
  final TextEditingController _name = TextEditingController();

  late final Stream<GameSettings?> _settings = watchGameSettings(widget.db);

  final Map<String, dynamic> _options = <String, dynamic>{};

  bool _loaded = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _fill(GameSettings settings) {
    _loaded = true;
    _name.text = settings.name;
    _options
      ..clear()
      ..addAll(settings.options);
    for (final GameOption option in gameOptions) {
      if (option.type == GameOptionType.boolean &&
          !_options.containsKey(option.key)) {
        _options[option.key] = option.defaultValue ?? false;
      }
    }
  }

  Future<DateTime?> _pickDateTime(DateTime? current) async {
    final DateTime now = DateTime.now();
    final DateTime base = current ?? now;

    final DateTime first = DateTime(
      (base.year < now.year ? base.year : now.year) - 1,
    );
    final DateTime last = DateTime(
      (base.year > now.year ? base.year : now.year) + 5,
    );

    final DateTime? date = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: first,
      lastDate: last,
    );

    if (date == null || !mounted) return null;

    final TimeOfDay? time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
    );

    if (time == null) return null;

    return DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
  }

  Future<void> _save() async {
    if (_busy) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    String? error;

    try {
      final Map<String, dynamic> options = <String, dynamic>{
        ..._options,
      };

      for (final GameOption option in gameOptions) {
        if (option.type == GameOptionType.dateTime) {
          final Object? value = options[option.key];
          if (value is DateTime) {
            options[option.key] = value.toUtc().toIso8601String();
          }
        }
      }

      await _api.save(
        name: _name.text.trim(),
        options: options,
      );
    } on GameSettingsException catch (e) {
      error = e.message;
    } on Exception catch (e) {
      if (kDebugMode) debugPrint('Save settings failed: $e');
      error = 'Could not save. Check your connection and try again.';
    }

    if (!mounted) return;

    setState(() {
      _busy = false;
      _error = error;
    });

    if (error == null) {
      Toast.show(context: context, message: 'Settings saved.');
    }
  }

  @override
Widget build(BuildContext context) {
  return StreamBuilder<GameSettings?>(
    stream: _settings,
    builder: (
      BuildContext context,
      AsyncSnapshot<GameSettings?> snap,
    ) {
      if (snap.hasError) {
        debugPrint('Error loading settings: ${snap.error}');
        debugPrint('Stack trace: ${snap.stackTrace}');

        return const AppScaffold(
          title: 'Game settings',
          body: EmptyState(title: 'Could not load the settings.'),
        );
      }

      final GameSettings? settings = snap.data;

      if (settings == null) {
        return const AppScaffold(
          title: 'Game settings',
          body: LoadingSpinner(message: 'Syncing your game...'),
        );
      }

      if (!_loaded) {
        _fill(settings);
      }

      return AppScaffold(
        title: 'Game settings',
        floatingActionButton: FloatingActionButton(
          heroTag: null,
          tooltip: 'Share game QR code',
          onPressed: () => _showGameQrCode(settings.gameCode),
          child: const Icon(Icons.qr_code),
        ),
        body: _form(settings),
      );
    },
  );
}

  Widget _form(GameSettings settings) {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          // Vertical padding only: Tile and ToggleTile bring their own, so the
          // plain fields below get a horizontal inset to line up with them.
          SurfaceCard(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: TextFormField(
                    controller: _name,
                    decoration: const InputDecoration(
                      labelText: 'Game name',
                    ),
                    validator: validateGameName,
                  ),
                ),
                const SizedBox(height: 8),
                // Tile shows plain text, so the code can no longer be selected
                // by hand; the copy button covers that.
                Tile(
                  title: 'Game code',
                  subtitle: settings.gameCode.toUpperCase(),
                  trailing: CopyButton(
                    value: settings.gameCode,
                    onCopied: () => Toast.show(
                      context: context,
                      message: 'Game code copied.',
                    ),
                  ),
                ),
                const Divider(),
                ...gameOptions.map(_buildOption),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: InfoBanner(
                title: _error!,
                variant: InfoBannerVariant.error,
              ),
            ),
          const SizedBox(height: 16),
          Button(label: 'Save settings', loading: _busy, onPressed: _save),
        ],
      ),
    );
  }

  Widget _buildOption(GameOption option) {
    switch (option.type) {
      case GameOptionType.text:
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextFormField(
            initialValue: _options[option.key]?.toString(),
            decoration: InputDecoration(
              labelText: option.name,
              helperText: option.description,
            ),
            onChanged: (String value) {
              _options[option.key] = value;
            },
          ),
        );

      case GameOptionType.number:
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextFormField(
            initialValue: _options[option.key]?.toString(),
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: option.name,
              helperText: option.description,
            ),
            onChanged: (String value) {
              _options[option.key] = num.tryParse(value);
            },
          ),
        );

      case GameOptionType.boolean:
        return ToggleTile(
          title: option.name,
          subtitle: option.description,
          value: (_options[option.key] as bool?) ??
              (option.defaultValue as bool? ?? false),
          onChanged: option.enabled
              ? (bool value) {
                  setState(() {
                    _options[option.key] = value;
                  });
                }
              : null,
        );

      case GameOptionType.dropdown:
        final List<GameOptionChoice> choices =
            option.options ?? <GameOptionChoice>[];
        final Object? current = _options[option.key];
        final GameOptionChoice? selected = choices
            .where((GameOptionChoice choice) => choice.value == current)
            .firstOrNull;

        // Picker has no helper text slot, so the description sits under it.
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Picker<GameOptionChoice>(
                label: option.name,
                value: selected,
                items: choices,
                itemLabel: (GameOptionChoice choice) => choice.label,
                onChanged: (GameOptionChoice choice) {
                  setState(() {
                    _options[option.key] = choice.value;
                  });
                },
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  option.description,
                  style: context.typography.bodySmall.muted(context),
                ),
              ),
            ],
          ),
        );

      case GameOptionType.dateTime:
        final Object? rawValue = _options[option.key];
        final DateTime? value = rawValue is String
            ? DateTime.tryParse(rawValue)?.toLocal()
            : rawValue is DateTime
                ? rawValue
                : null;

        return _TimeTile(
          label: option.name,
          description: option.description,
          value: value,
          onPick: () async {
            final DateTime? picked = await _pickDateTime(value);

            if (picked != null && mounted) {
              setState(() {
                _options[option.key] = picked;
              });
            }
          },
          onClear: () {
            setState(() {
              _options[option.key] = null;
            });
          },
        );
    }
  }
  
  Future<void> _showGameQrCode(String gameCode) async {
    try {
      final uri = Uri.parse(AppConfig.appUrl).replace(
        fragment: Uri(
          path: '/login',
          queryParameters: {'gameCode': gameCode},
        ).toString(),
      );

      if (!mounted) return;

      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Join game'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Wrap QrImageView in a SizedBox to provide explicit constraints
              SizedBox(
                width: 250,
                height: 250,
                child: QrImageView(
                  data: uri.toString(),
                  version: QrVersions.auto,
                ),
              ),
              const SizedBox(height: 16),
              SelectableText(gameCode.toUpperCase()),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('QR code generation failed: $e');
      if (!mounted) return;

      Toast.show(
        context: context,
        message: 'Could not generate QR code.',
      );
    }
  }
}

class _TimeTile extends StatelessWidget {
  const _TimeTile({
    required this.label,
    required this.description,
    required this.value,
    required this.onPick,
    required this.onClear,
  });

  final String label;
  final String description;
  final DateTime? value;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final DateTime? picked = value;
    return Tile(
      title: label,
      subtitle: '$description\n'
          '${picked == null ? 'Not set' : formatLocalDateTime(picked.toUtc())}',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (picked != null)
            TappableIcon(
              icon: const Icon(Icons.clear),
              tooltip: 'Clear',
              onPressed: onClear,
            ),
          const Icon(Icons.edit_calendar_outlined),
        ],
      ),
      onTap: onPick,
    );
  }
}

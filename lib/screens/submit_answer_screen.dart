import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:powersync/powersync.dart' show PowerSyncDatabase;

import '../auth/auth_scope.dart';
import '../data/activity_writes.dart';
import '../data/admin_api.dart';
import '../data/answer_writes.dart';
import '../data/device_location.dart';
import '../data/geo.dart';
import '../data/photo_location.dart';
import '../layout/app_scaffold.dart';
import '../layout/format.dart';
import '../orient_ui/button.dart';
import '../orient_ui/empty_state.dart';
import '../orient_ui/info_banner.dart';
import '../orient_ui/multi_choice_tile.dart';
import '../orient_ui/single_choice_tile.dart';
import '../orient_ui/style.dart';
import '../orient_ui/tile.dart' show TileVariant;
import '../orient_ui/toast.dart';
import '../router/routes.dart';
import '../widgets/geo_answer_field.dart';
import '../widgets/loading_spinner.dart';
import '../widgets/surface_card.dart';
import '../widgets/activity_notes_card.dart';

const int _bytesPerMb = 1024 * 1024;

// Photos read for a location are picked at full size, because resizing drops
// the metadata. They are re-encoded before upload, so the stored file is small.
const int _maxLocatedPhotoBytes = 25 * _bytesPerMb;

/// Answer an activity. Players answer for themselves; with [onBehalf] an
/// admin picks a user and answers for them.
class SubmitAnswerScreen extends StatefulWidget {
  const SubmitAnswerScreen({
    required this.db,
    required this.activityId,
    required this.onBehalf,
    super.key,
  });

  final PowerSyncDatabase db;
  final String activityId;
  final bool onBehalf;

  @override
  State<SubmitAnswerScreen> createState() => _SubmitAnswerScreenState();
}

class _SubmitAnswerScreenState extends State<SubmitAnswerScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _text = TextEditingController();
  late final Future<SubmitActivity?> _activity;
  Future<List<GameUser>>? _users;
  String? _selectedUserId;
  String? _latestFor;
  Future<LatestAnswer?>? _latest;
  Timer? _clock;
  bool _checked = false;
  final Set<String> _selected = <String>{};
  Uint8List? _imageBytes;
  String? _imageMime;
  bool _busy = false;
  String? _error;
  String? _notice;
  GeoPoint? _geo;
  bool _geoFallback = false;
  String? _geoMessage;

  @override
  void initState() {
    super.initState();
    _activity = loadSubmitActivity(widget.db, widget.activityId);
    _clock = Timer.periodic(const Duration(seconds: 30), (Timer _) {
      if (mounted) setState(() {});
    });
    if (widget.onBehalf) _users = AdminApi().listUsers();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.onBehalf) return;
    final String? me = AuthScope.of(context).userId;
    if (me != _latestFor) _loadLatest(me);
  }

  @override
  void dispose() {
    _clock?.cancel();
    _text.dispose();
    super.dispose();
  }

  void _loadLatest(String? userId) {
    _latestFor = userId;
    if (userId == null) {
      _latest = null;
      return;
    }
    _latest = widget.onBehalf
        ? loadLatestRemote(activityId: widget.activityId, userId: userId)
        : loadLatestLocal(
            widget.db,
            activityId: widget.activityId,
            userId: userId,
          );
  }

  void _selectUser(String? userId) {
    setState(() {
      _selectedUserId = userId;
      _notice = null;
      _error = null;
      _loadLatest(userId);
    });
  }

  Future<void> _pick(ImageSource source, {required bool readLocation}) async {
    try {
      final XFile? file = await ImagePicker().pickImage(
        source: source,
        // Resizing re-encodes the photo and drops its location metadata, so a
        // photo that is read for a location is picked as it is.
        maxWidth: readLocation ? null : 1600.0,
        maxHeight: readLocation ? null : 1600.0,
        imageQuality: readLocation ? null : 80,
      );
      if (file == null) return;
      final Uint8List bytes = await file.readAsBytes();
      final String? mime = _mimeOf(file);
      final int limit = readLocation ? _maxLocatedPhotoBytes : maxImageBytes;
      if (mime == null || bytes.length > limit) {
        if (!mounted) return;
        setState(
          () => _error = mime == null
              ? 'Use a JPEG, PNG or WebP photo.'
              : 'That photo is too large (${limit ~/ _bytesPerMb} MB maximum).',
        );
        return;
      }
      final GeoPoint? located =
          readLocation ? await readPhotoLocation(bytes) : null;
      if (!mounted) return;
      setState(() {
        _imageBytes = bytes;
        _imageMime = mime;
        _error = null;
        if (!readLocation) return;
        _geo = located;
        _geoFallback = located == null;
        _geoMessage = located == null
            ? 'No location found in this photo. Pick it on the map instead.'
            : null;
      });
    } on Exception catch (e) {
      if (kDebugMode) debugPrint('Image pick failed: $e');
      if (!mounted) return;
      setState(() => _error = 'Could not open the photo. Try again.');
    }
  }

  // The browser may not report a type, so fall back to the file extension.
  String? _mimeOf(XFile file) {
    final String? reported = file.mimeType;
    if (reported != null && allowedImageTypes.containsKey(reported)) {
      return reported;
    }
    final String name = file.name.toLowerCase();
    if (name.endsWith('.jpg') || name.endsWith('.jpeg')) return 'image/jpeg';
    if (name.endsWith('.png')) return 'image/png';
    if (name.endsWith('.webp')) return 'image/webp';
    return null;
  }

  Future<void> _submit(SubmitActivity activity, String userId) async {
    if (_busy) return;
    final AnswerSchema schema = activity.schema;
    final Uint8List? bytes = _imageBytes;
    final String? mime = _imageMime;

    if (!(_formKey.currentState?.validate() ?? false)) return;
    final String? me = AuthScope.of(context).userId;
    if (me == null) return;

    final GeoMode geoMode = _modeFor(schema);
    String? problem;
    if (schema.has(AnswerType.multipleChoice) && _selected.isEmpty) {
      problem = 'Choose an answer.';
    } else if (schema.has(AnswerType.checkbox) && !_checked) {
      problem = 'Tick the box to submit.';
    } else if (schema.has(AnswerType.image) && (bytes == null || mime == null)) {
      problem = 'Choose a photo first.';
    } else if (schema.asksLocation &&
        geoMode != GeoMode.auto &&
        _geo == null) {
      problem = geoMode == GeoMode.photo
          ? 'Choose a photo with a location, or pick the location on the map.'
          : 'Pick your location on the map.';
    }
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }

    // Automatic mode reads the device only now, so the position is current.
    // It is not kept in state: a retry after a failed upload reads it again.
    GeoPoint? geo = _geo;
    if (schema.asksLocation && geo == null && geoMode == GeoMode.auto) {
      setState(() {
        _busy = true;
        _error = null;
      });
      try {
        geo = await getDeviceLocation();
      } on LocationUnavailableException catch (e) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _geoFallback = true;
          _geoMessage = '${e.message} Pick your location on the map instead.';
        });
        return;
      }
      if (!mounted) return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      final String answerId = await newId(widget.db);
      final Map<AnswerType, Map<String, Object>> parts =
          <AnswerType, Map<String, Object>>{};
      for (final AnswerType type in schema.playerTypes) {
        switch (type) {
          case AnswerType.shortAnswer:
            parts[type] = <String, Object>{'text': _text.text.trim()};
          case AnswerType.multipleChoice:
            // Keep the activity's option order, not the tap order.
            parts[type] = <String, Object>{
              'selected': <String>[
                for (final String o in schema.options)
                  if (_selected.contains(o)) o,
              ],
            };
          case AnswerType.checkbox:
            parts[type] = <String, Object>{'checked': true};
          case AnswerType.image:
            // The photo goes up first so an answer never points at a missing
            // file. Photos need a connection; the other parts do not.
            parts[type] = <String, Object>{
              'path': await uploadSubmissionImage(
                gameId: activity.gameId,
                userId: userId,
                answerId: answerId,
                bytes: bytes!,
                mimeType: mime!,
              ),
            };
          case AnswerType.geo:
            parts[type] = geo!.toAnswerPart();
        }
      }
      await insertAnswer(
        widget.db,
        id: answerId,
        activityId: activity.id,
        userId: userId,
        submittedBy: me,
        answerJson: buildAnswerJson(parts),
      );
    } on Exception catch (e) {
      if (kDebugMode) debugPrint('Submit failed: $e');
      error = 'Could not submit. Check your connection and try again.';
    }
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _busy = false;
        _error = error;
      });
      return;
    }

    _text.clear();
    _selected.clear();
    setState(() {
      _busy = false;
      _checked = false;
      _imageBytes = null;
      _imageMime = null;
      _geo = null;
      _geoFallback = false;
      _geoMessage = null;
    });
    if (!widget.onBehalf) {
      Toast.show(context: context, message: 'Submitted.');
      if (context.canPop()) {
        context.pop();
      } else {
        context.go(Routes.activities);
      }
      return;
    }
    // Other users' answers are not synced here, so the status above will not
    // update until you reopen this page.
    setState(() => _notice = 'Submitted.');
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: widget.onBehalf ? 'Submit for a user' : 'Submit',
      body: FutureBuilder<SubmitActivity?>(
        future: _activity,
        builder: (BuildContext context, AsyncSnapshot<SubmitActivity?> snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const LoadingSpinner();
          }
          if (snap.hasError) {
            return const EmptyState(title: 'Could not load the activity.');
          }
          final SubmitActivity? activity = snap.data;
          if (activity == null) {
            return const EmptyState(title: 'Activity not found.');
          }
          if (!activity.schema.isAnswerable) {
            return EmptyState(
              title: 'Not open yet.',
              description: widget.onBehalf
                  ? 'Set the location solution in the activity editor first.'
                  : null,
            );
          }
          if (!widget.onBehalf &&
              !AuthScope.of(context).isSubsectionAdmin &&
              !activity.gameWindowIsOpenAt(DateTime.now().toUtc())) {
            return const EmptyState(
              title: 'Activities are not available right now.',
            );
          }
          return _content(activity);
        },
      ),
    );
  }

  Widget _content(SubmitActivity activity) {
    final String? userId =
        widget.onBehalf ? _selectedUserId : AuthScope.of(context).userId;
    final int? points = activity.points;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Text(activity.name, style: context.typography.heading),
        if (activity.description.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Text(activity.description),
        ],
        if (points != null) Text('$points points'),
        const SizedBox(height: 16),
        if (widget.onBehalf) _userPicker(),
        if (activity.adminOnlySubmission && !widget.onBehalf)
          const InfoBanner(
            title: 'View only. A game admin must submit an answer.',
          )
        else if (userId != null)
          _submission(activity, userId)
        else if (widget.onBehalf)
          const Text('Choose a user to continue.'),
        if (!widget.onBehalf && userId != null) ...<Widget>[
          const SizedBox(height: 16),
          ActivityNotesCard(
            key: ValueKey<String>('notes-${activity.id}'),
            db: widget.db,
            userId: userId,
            activityId: activity.id,
          ),
        ],
      ],
    );
  }

  // Stays a Material dropdown: Orient UI's Picker menu does not scroll, and a
  // game can have many users.
  Widget _userPicker() {
    return FutureBuilder<List<GameUser>>(
      future: _users,
      builder: (BuildContext context, AsyncSnapshot<List<GameUser>> snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(8),
            child: LoadingSpinner(size: 20),
          );
        }
        if (snap.hasError) return const Text('Could not load users.');
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: DropdownButtonFormField<String>(
            initialValue: _selectedUserId,
            decoration: const InputDecoration(labelText: 'Submit as'),
            items: <DropdownMenuItem<String>>[
              for (final GameUser u in snap.requireData)
                DropdownMenuItem<String>(
                  value: u.id,
                  child: Text(u.isAdmin ? '${u.username} (admin)' : u.username),
                ),
            ],
            onChanged: _selectUser,
          ),
        );
      },
    );
  }

  Widget _submission(SubmitActivity activity, String userId) {
    return FutureBuilder<LatestAnswer?>(
      future: _latest,
      builder: (BuildContext context, AsyncSnapshot<LatestAnswer?> snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const LoadingSpinner();
        }
        // If the lookup failed, carry on: the server enforces the rules.
        final LatestAnswer? latest = snap.data;
        // Admins bypass the release time and the resubmission rule.
        final DateTime? opensAt = widget.onBehalf
            ? null
            : activity.opensAfter(DateTime.now().toUtc());
        final bool blocked =
            !widget.onBehalf && latest != null && !activity.canResubmit;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (latest != null) _LatestCard(latest: latest),
            if (_notice != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: InfoBanner(
                  title: _notice!,
                  variant: InfoBannerVariant.success,
                ),
              ),
            if (opensAt != null)
              InfoBanner(title: 'Opens ${formatLocalDateTime(opensAt)}.')
            else if (blocked)
              const InfoBanner(title: 'You have already submitted this activity.')
            else
              SurfaceCard(
                child: _form(activity, userId, resubmitting: latest != null),
              ),
          ],
        );
      },
    );
  }

  Widget _form(
    SubmitActivity activity,
    String userId, {
    required bool resubmitting,
  }) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final AnswerType type in activity.schema.playerTypes) ...<Widget>[
            _partField(type, activity.schema),
            const SizedBox(height: 16),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: InfoBanner(
                title: _error!,
                variant: InfoBannerVariant.error,
              ),
            ),
          Button(
            label: resubmitting ? 'Resubmit' : 'Submit',
            loading: _busy,
            onPressed: () => _submit(activity, userId),
          ),
        ],
      ),
    );
  }

  Widget _partField(AnswerType type, AnswerSchema schema) {
    return switch (type) {
      AnswerType.shortAnswer => TextFormField(
          controller: _text,
          decoration: const InputDecoration(labelText: 'Your answer'),
          minLines: 3,
          maxLines: 6,
          maxLength: 2000,
        ),
      AnswerType.multipleChoice => _choiceField(schema),
      AnswerType.checkbox => MultiChoiceTile(
          title: 'I completed this',
          value: _checked,
          variant: TileVariant.bordered,
          onChanged: (bool v) => setState(() => _checked = v),
        ),
      AnswerType.image => _imageField(schema),
      AnswerType.geo => _geoField(schema),
    };
  }

  // An admin answering for someone else is not at the player's location, so
  // automatic mode becomes picking the point on the map.
  GeoMode _modeFor(AnswerSchema schema) {
    if (widget.onBehalf && schema.geo.mode == GeoMode.auto) {
      return GeoMode.manual;
    }
    return schema.geo.mode;
  }

  Widget _geoField(AnswerSchema schema) {
    final GeoMode mode = _modeFor(schema);
    // A photo activity without the Image type has no photo to read.
    final bool noPhotoToRead =
        mode == GeoMode.photo && !schema.has(AnswerType.image);
    return GeoAnswerField(
      mode: mode,
      value: _geo,
      pickOnMap: mode == GeoMode.manual || _geoFallback || noPhotoToRead,
      allowDeviceLocation: !widget.onBehalf,
      message: _geoMessage,
      onChanged: (GeoPoint? point) => setState(() {
        _geo = point;
        _geoMessage = null;
      }),
    );
  }

  Widget _choiceField(AnswerSchema schema) {
    final String? picked = _selected.isEmpty ? null : _selected.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: <Widget>[
        Text(
          schema.multiple ? 'Choose all that apply' : 'Choose one',
          style: context.typography.body.w600,
        ),
        for (final String option in schema.options)
          if (schema.multiple)
            MultiChoiceTile(
              title: option,
              value: _selected.contains(option),
              variant: TileVariant.bordered,
              onChanged: (bool on) => setState(() {
                if (on) {
                  _selected.add(option);
                } else {
                  _selected.remove(option);
                }
              }),
            )
          else
            SingleChoiceTile<String?>(
              title: option,
              value: option,
              groupValue: picked,
              variant: TileVariant.bordered,
              onChanged: (String? _) => setState(() {
                _selected
                  ..clear()
                  ..add(option);
              }),
            ),
      ],
    );
  }

  Widget _imageField(AnswerSchema schema) {
    final Uint8List? bytes = _imageBytes;
    final bool readLocation =
        schema.asksLocation && _modeFor(schema) == GeoMode.photo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (bytes != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(bytes, height: 240, fit: BoxFit.cover),
            ),
          ),
        Wrap(
          spacing: 8,
          children: <Widget>[
            Button.small(
              label: 'Take photo',
              icon: const Icon(Icons.photo_camera_outlined),
              variant: ButtonVariant.outline,
              onPressed: _busy
                  ? null
                  : () => _pick(ImageSource.camera, readLocation: readLocation),
            ),
            Button.small(
              label: 'Choose photo',
              icon: const Icon(Icons.photo_library_outlined),
              variant: ButtonVariant.outline,
              onPressed: _busy
                  ? null
                  : () => _pick(ImageSource.gallery, readLocation: readLocation),
            ),
          ],
        ),
      ],
    );
  }
}

class _LatestCard extends StatelessWidget {
  const _LatestCard({required this.latest});

  final LatestAnswer latest;

  @override
  Widget build(BuildContext context) {
    final TypographyTokens typography = context.typography;
    final DateTime? at = latest.createdAt;
    final int? points = latest.points;
    final List<String> parts = <String>[
      if (latest.summary.isNotEmpty) latest.summary,
      if (at != null) formatLocalDateTime(at),
      points == null ? 'Awaiting grading' : '$points points',
    ];
    // A SurfaceCard rather than a TileCard, because Tile cuts its subtitle at two
    // lines and the summary can be longer.
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Latest submission', style: typography.subtitle),
            const SizedBox(height: 4),
            Text(parts.join(' · '), style: typography.body.muted(context)),
          ],
        ),
      ),
    );
  }
}

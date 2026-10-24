import 'dart:typed_data';
import 'dart:async' show Timer;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart' show TextInputFormatter;
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:go_router/go_router.dart';

import '../data/activity_writes.dart' show AnswerType;
import '../data/answer_view.dart';
import '../data/answer_writes.dart' show downloadSubmissionImage;
import '../data/geo.dart';
import '../data/grading_api.dart';
import '../layout/app_scaffold.dart';
import '../layout/format.dart';
import '../orient_ui/button.dart';
import '../orient_ui/empty_state.dart';
import '../orient_ui/info_banner.dart';
import '../orient_ui/picker.dart';
import '../orient_ui/search_field.dart';
import '../orient_ui/style.dart';
import '../orient_ui/tag.dart';
import '../orient_ui/toast.dart';
import '../orient_ui/toggle_tile.dart';
import '../widgets/geo_map.dart';
import '../widgets/loading_spinner.dart';
import '../widgets/signed_integer_input_formatter.dart';
import '../widgets/surface_card.dart';
import '../auth/auth_scope.dart';
import '../router/routes.dart';

// The ceiling when an activity has no points set.
const int _maxPoints = 2147483647;
const String _allSubsections = '';

enum _ActivityTypeFilter {
  all(null, 'All types'),
  shortAnswer(AnswerType.shortAnswer, 'Short answer'),
  multipleChoice(AnswerType.multipleChoice, 'Multiple choice'),
  checkbox(AnswerType.checkbox, 'Checkbox'),
  image(AnswerType.image, 'Image'),
  location(AnswerType.geo, 'Location');

  const _ActivityTypeFilter(this.type, this.label);

  final AnswerType? type;
  final String label;
}

/// Review submitted answers and give them points. Admins see every answer in
/// their game; subsection admins only their own subsections. The server
/// decides what each grader may see and change.
class GradingScreen extends StatefulWidget {
  const GradingScreen({super.key});

  @override
  State<GradingScreen> createState() => _GradingScreenState();
}

class _GradingScreenState extends State<GradingScreen> {
  final GradingApi _api = GradingApi();
  List<GradingItem>? _items;
  Object? _loadError;
  bool _loading = true;
  bool _includeGraded = false;
  bool _showFilters = true;
  String _subsectionFilter = _allSubsections;
  _ActivityTypeFilter _activityTypeFilter = _ActivityTypeFilter.all;
  String _usernameQuery = '';
  String _activityQuery = '';
  final TextEditingController _usernameSearch = TextEditingController();
  final TextEditingController _activitySearch = TextEditingController();

  static const Duration _pollInterval = Duration(seconds: 15);
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    // The queue is computed on the server and is not synced to the device, so
    // new answers only appear by asking again.
    _timer = Timer.periodic(_pollInterval, (Timer _) => _load(silent: true));
  }

  Future<void> _load({bool silent = false}) async {
    final bool includeGraded = _includeGraded;
    try {
      final List<GradingItem> items =
          await _api.loadQueue(includeGraded: includeGraded);
      // Drop a reply for a toggle state that is no longer selected.
      if (!mounted || includeGraded != _includeGraded) return;
      setState(() {
        _items = items;
        _loadError = null;
        _loading = false;
      });
    } on Exception catch (e) {
      if (kDebugMode) debugPrint('Grading load failed: $e');
      // A failed background refresh keeps showing the last good list.
      if (!mounted || (silent && _items != null)) return;
      setState(() {
        _loadError = e;
        _loading = false;
      });
    }
  }

  void _refresh() {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _usernameSearch.dispose();
    _activitySearch.dispose();
    super.dispose();
  }

  List<GradingItem> _filterItems(List<GradingItem> items) {
    return <GradingItem>[
      for (final GradingItem item in items)
        if ((_subsectionFilter == _allSubsections ||
                item.subsectionName == _subsectionFilter) &&
            (_activityTypeFilter.type == null ||
                parseAnswerParts(item.answerJson).any(
                  (AnswerPartView part) =>
                      part.type == _activityTypeFilter.type,
                )) &&
            item.username.toLowerCase().contains(_usernameQuery) &&
            ('${item.activityName} ${item.activityDescription}'
                .toLowerCase()
                .contains(_activityQuery)))
          item,
    ];
  }

  Widget _filters(List<GradingItem> items) {
    final List<String> subsections = <String>{
      for (final GradingItem item in items)
        if (item.subsectionName != null && item.subsectionName!.isNotEmpty)
          item.subsectionName!,
    }.toList()
      ..sort();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: <Widget>[
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double fieldWidth = constraints.maxWidth >= 600
                  ? (constraints.maxWidth - 8) / 2
                  : constraints.maxWidth;
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  SizedBox(
                    width: fieldWidth,
                    child: Picker<String>(
                      label: 'Activity Section',
                      value: _subsectionFilter,
                      items: <String>[_allSubsections, ...subsections],
                      itemLabel: (String value) => value.isEmpty
                          ? 'All subsections'
                          : value,
                      onChanged: (String value) => setState(() {
                        _subsectionFilter = value;
                      }),
                    ),
                  ),
                  SizedBox(
                    width: fieldWidth,
                    child: Picker<_ActivityTypeFilter>(
                      label: 'Activity type',
                      value: _activityTypeFilter,
                      items: _ActivityTypeFilter.values,
                      itemLabel: (_ActivityTypeFilter filter) => filter.label,
                      onChanged: (_ActivityTypeFilter filter) => setState(() {
                        _activityTypeFilter = filter;
                      }),
                    ),
                  ),
                ],
              );
            },
          ),
          SearchField(
            controller: _usernameSearch,
            placeholder: 'Filter by user',
            onChanged: (String value) => setState(() {
              _usernameQuery = value.trim().toLowerCase();
            }),
          ),
          SearchField(
            controller: _activitySearch,
            placeholder: 'Search activities',
            onChanged: (String value) => setState(() {
              _activityQuery = value.trim().toLowerCase();
            }),
          ),
        ],
      ),
    );
  }

  void _clearFilters() {
    _usernameSearch.clear();
    _activitySearch.clear();
    setState(() {
      _subsectionFilter = _allSubsections;
      _activityTypeFilter = _ActivityTypeFilter.all;
      _usernameQuery = '';
      _activityQuery = '';
    });
  }

  bool _onScrollNotification(
    ScrollNotification notification,
    bool isSmallScreen,
  ) {
    if (!isSmallScreen ||
        notification.metrics.axis != Axis.vertical ||
        notification is! UserScrollNotification) {
      return false;
    }

    if (notification.direction == ScrollDirection.reverse && _showFilters) {
      setState(() => _showFilters = false);
    } else if (notification.direction == ScrollDirection.forward &&
        !_showFilters) {
      setState(() => _showFilters = true);
    }
    return false;
  }

  /// Saves a grade. Returns an error message, or null on success.
  Future<String?> _grade(GradingItem item, int points) async {
    try {
      await _api.grade(answerId: item.answerId, points: points);
    } on GradingException catch (e) {
      return e.message;
    } on Exception {
      return 'Could not reach the server. Try again.';
    }
    if (!mounted) return null;
    setState(() {
      final List<GradingItem> items = _items ?? const <GradingItem>[];
      _items = <GradingItem>[
        for (final GradingItem i in items)
          // Graded answers leave the queue unless graded ones are shown.
          if (i.answerId != item.answerId)
            i
          else if (_includeGraded)
            i.withPoints(points),
      ];
    });
    Toast.show(context: context, message: 'Grade saved.');
    return null;
  }

  Widget _body() {
    if (_loading) return const LoadingSpinner();
    if (_loadError != null) {
      final Object error = _loadError!;
      return EmptyState(
        title: 'Could not load answers',
        description: error is GradingException
            ? error.message
            : 'Check your connection.',
        action: Button.small(
          label: 'Retry',
          variant: ButtonVariant.outline,
          onPressed: _refresh,
        ),
      );
    }
    final List<GradingItem> items = _items ?? const <GradingItem>[];
    if (items.isEmpty) {
      return EmptyState(
        title:
            _includeGraded ? 'No answers yet.' : 'Nothing waiting to be graded.',
      );
    }
    final List<GradingItem> filteredItems = _filterItems(items);
    if (filteredItems.isEmpty) {
      return EmptyState(
        title: 'No answers match these filters.',
        action: Button.small(
          label: 'Clear filters',
          variant: ButtonVariant.outline,
          onPressed: _clearFilters,
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: filteredItems.length,
      itemBuilder: (BuildContext context, int index) {
        final GradingItem item = filteredItems[index];
        return PageContent(
          child: _GradeCard(
            key: ValueKey<String>(item.answerId),
            item: item,
            onGrade: (int points) => _grade(item, points),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isSmallScreen =
        MediaQuery.sizeOf(context).width < Style.breakpoints.desktop;
    return AppScaffold(
      title: 'Grading',
      fullWidthBody: true,
      floatingActionButton: AuthScope.of(context).isAdmin
          ? Button.small(
              label: 'Bulk scores',
              icon: const Icon(Icons.grid_on),
              onPressed: () => context.go(Routes.scoreGrid),
            )
          : null,
      body: NotificationListener<ScrollNotification>(
        onNotification: (ScrollNotification notification) =>
            _onScrollNotification(notification, isSmallScreen),
        child: Column(
          children: <Widget>[
            AnimatedSize(
              alignment: Alignment.topCenter,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeInOut,
              child: _showFilters
                  ? Column(
                      children: <Widget>[
                        PageContent(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                            child: ToggleTile(
                              title: 'Show graded',
                              value: _includeGraded,
                              onChanged: (bool on) {
                                _includeGraded = on;
                                _refresh();
                              },
                            ),
                          ),
                        ),
                        if (!_loading &&
                            _loadError == null &&
                            (_items?.isNotEmpty ?? false))
                          PageContent(child: _filters(_items!)),
                      ],
                    )
                  : const SizedBox.shrink(),
            ),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }
}

class _GradeCard extends StatefulWidget {
  const _GradeCard({required this.item, required this.onGrade, super.key});

  final GradingItem item;
  final Future<String?> Function(int points) onGrade;

  @override
  State<_GradeCard> createState() => _GradeCardState();
}

class _GradeCardState extends State<_GradeCard> {
  late final TextEditingController _points =
      TextEditingController(text: widget.item.points?.toString() ?? '');
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _points.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    final int? limit = widget.item.maxPoints;
    final int minimum = limit == null
        ? -_maxPoints
        : (limit < 0 ? limit : 0);
    final int maximum = limit == null
        ? _maxPoints
        : (limit > 0 ? limit : 0);
    final int? value = int.tryParse(_points.text.trim());
    if (value == null || value < minimum || value > maximum) {
      setState(() {
        _error = 'Enter a whole number from $minimum to $maximum.';
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final String? error = await widget.onGrade(value);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final GradingItem item = widget.item;
    final TypographyTokens typography = context.typography;
    final DateTime? at = item.createdAt;
    final int? max = item.maxPoints;
    final int? graded = item.points;
    final List<String> meta = <String>[
      if (item.subsectionName != null) item.subsectionName!,
      'by ${item.username}',
      if (at != null) formatLocalDateTime(at),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: SurfaceCard(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(item.activityName, style: typography.subtitle),
                      Text(meta.join(' · '), style: typography.bodySmall),
                    ],
                  ),
                ),
                if (graded != null)
                  Tag(
                    label: max == null ? '$graded' : '$graded / $max',
                    color: context.style.colors.foreground,
                  ),
              ],
            ),
            if (item.activityDescription.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(item.activityDescription, style: typography.bodySmall),
            ],
            const SizedBox(height: 12),
            for (final AnswerPartView part in parseAnswerParts(item.answerJson))
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _PartView(
                  part: part,
                  solution: item.geoSolution,
                  distanceM: item.distanceM,
                ),
              ),
            const Divider(),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                SizedBox(
                  width: 140,
                  child: TextField(
                    controller: _points,
                    decoration: InputDecoration(
                      labelText: 'Points',
                      suffixText: max == null
                          ? null
                          : (max < 0 ? 'min $max' : '/ $max'),
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      signed: true,
                    ),
                    inputFormatters: const <TextInputFormatter>[
                      SignedIntegerInputFormatter(),
                    ],
                    onSubmitted: (String _) => _save(),
                  ),
                ),
                if (max != null)
                  Button.small(
                    label: max < 0 ? 'Full penalty ($max)' : 'Full marks ($max)',
                    variant: ButtonVariant.outline,
                    onPressed: () => _points.text = '$max',
                  ),
                Button.small(
                  label: '0',
                  variant: ButtonVariant.outline,
                  onPressed: () => _points.text = '0',
                ),
                Button.small(
                  label: graded == null ? 'Save grade' : 'Update grade',
                  loading: _busy,
                  onPressed: _save,
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: InfoBanner(
                  title: _error!,
                  variant: InfoBannerVariant.error,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PartView extends StatelessWidget {
  const _PartView({required this.part, this.solution, this.distanceM});

  final AnswerPartView part;

  /// Where a location answer should be, when the grader may see it.
  final GeoSolution? solution;

  /// How far a location answer is from [solution], in metres.
  final double? distanceM;

  @override
  Widget build(BuildContext context) {
    final TypographyTokens typography = context.typography;
    final Color tagColor = context.style.colors.foreground;
    final String? path = part.imagePath;
    final String? answer = part.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(part.type.label, style: typography.bodySmall.w600),
        const SizedBox(height: 4),
        switch (part.type) {
          AnswerType.shortAnswer => TextFormField(
            initialValue: answer ?? '',
            readOnly: true,
            maxLines: null,
            decoration: const InputDecoration(
              hintText: '(empty)',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          AnswerType.multipleChoice => Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final String option in part.selected)
                  Tag(label: option, color: tagColor),
              ],
            ),
          AnswerType.checkbox => const Row(
              children: <Widget>[
                Icon(Icons.check_box_outlined),
                SizedBox(width: 8),
                Text('Marked as completed'),
              ],
            ),
          AnswerType.image => path == null
              ? const Text('(no photo)')
              : _PhotoPreview(path: path),
          AnswerType.geo => _GeoPartView(
              point: part.geo,
              solution: solution,
              distanceM: distanceM,
            ),
        },
      ],
    );
  }
}

/// A submitted location with its distance from the solution. The map is
/// opened on request, so a long list does not load a map per card.
class _GeoPartView extends StatefulWidget {
  const _GeoPartView({
    required this.point,
    required this.solution,
    required this.distanceM,
  });

  final GeoPoint? point;
  final GeoSolution? solution;
  final double? distanceM;

  @override
  State<_GeoPartView> createState() => _GeoPartViewState();
}

class _GeoPartViewState extends State<_GeoPartView> {
  bool _showMap = false;

  @override
  Widget build(BuildContext context) {
    final GeoPoint? point = widget.point;
    if (point == null) return const Text('(no location)');
    final GeoSolution? solution = widget.solution;
    final double? distance = widget.distanceM;
    final double? limit = solution?.maxDistanceM;
    final ColorTokens colors = context.style.colors;
    final Color answerColor = Theme.of(context).colorScheme.primary;
    final GeoMapCircle? circle = solution != null && limit != null
        ? GeoMapCircle(
            center: LatLng(solution.lat, solution.lng),
            radiusM: limit,
            color: colors.success,
          )
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: <Widget>[
        Text(
          '${point.lat.toStringAsFixed(5)}, ${point.lng.toStringAsFixed(5)}'
          ' (from ${point.origin.label})',
        ),
        if (distance != null)
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Text('Distance from solution: ${formatDistance(distance)}'),
              if (limit != null)
                Tag(
                  label: distance <= limit
                      ? 'Within ${formatDistance(limit)}'
                      : 'Outside ${formatDistance(limit)}',
                  color: distance <= limit ? colors.success : colors.error,
                ),
            ],
          ),
        Button.small(
          label: _showMap ? 'Hide map' : 'Show map',
          variant: ButtonVariant.outline,
          onPressed: () => setState(() => _showMap = !_showMap),
        ),
        if (_showMap)
          GeoMap(
            markers: <GeoMapMarker>[
              GeoMapMarker(
                point: LatLng(point.lat, point.lng),
                color: answerColor,
              ),
              if (solution != null)
                GeoMapMarker(
                  point: LatLng(solution.lat, solution.lng),
                  color: colors.success,
                ),
            ],
            circle: circle,
            height: 240,
          ),
      ],
    );
  }
}

class _PhotoPreview extends StatefulWidget {
  const _PhotoPreview({required this.path});

  final String path;

  @override
  State<_PhotoPreview> createState() => _PhotoPreviewState();
}

class _PhotoPreviewState extends State<_PhotoPreview> {
  // Started once per card, and only when the card is built on screen.
  late final Future<Uint8List> _bytes = _download();

  Future<Uint8List> _download() async {
    try {
      return await downloadSubmissionImage(widget.path);
    } on Exception catch (e) {
      if (kDebugMode) debugPrint('Photo download failed for ${widget.path}: $e');
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (BuildContext context, AsyncSnapshot<Uint8List> snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox(height: 120, child: LoadingSpinner());
        }
        final Uint8List? bytes = snap.data;
        if (snap.hasError || bytes == null) {
          return const Text('Could not load the photo.');
        }
        // Orient UI's Popup is capped at 560 wide with padding, too small
        // for a zoomable photo, so the full-size viewer stays a Dialog.
        return InkWell(
          onTap: () => showDialog<void>(
            context: context,
            builder: (BuildContext context) => Dialog(
              child: InteractiveViewer(child: Image.memory(bytes)),
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(bytes, height: 240, fit: BoxFit.cover),
          ),
        );
      },
    );
  }
}

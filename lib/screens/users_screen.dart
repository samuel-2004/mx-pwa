import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

import '../auth/validators.dart';
import '../data/admin_api.dart';
import '../layout/app_scaffold.dart';
import '../orient_ui/button.dart';
import '../orient_ui/confirmation_popup.dart';
import '../orient_ui/empty_state.dart';
import '../orient_ui/multi_choice_tile.dart';
import '../orient_ui/popover_menu.dart';
import '../orient_ui/picker.dart';
import '../orient_ui/search_field.dart';
import '../orient_ui/style.dart';
import '../orient_ui/tappable_icon.dart';
import '../orient_ui/tile.dart';
import '../orient_ui/toast.dart';
import '../widgets/loading_spinner.dart';
import '../widgets/popups.dart';
import '../widgets/surface_card.dart';

typedef _Credentials = ({String username, String password});

enum _UserAction { resetPassword, subsections, remove }

enum _UserTypeFilter {
  all('All types'),
  admin('Admin'),
  subsectionAdmin('Subsection admin'),
  user('Player');

  const _UserTypeFilter(this.label);

  final String label;
}

String _messageFor(Object error) => error is AdminApiException
    ? error.message
    : 'Could not reach the server. Check your connection.';

/// Admin page to add participants, reset their passwords, choose which
/// subsections they can manage, and remove them.
class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  final AdminApi _api = AdminApi();
  late Future<UserDirectory> _directory;
  _UserTypeFilter _userTypeFilter = _UserTypeFilter.all;
  String _usernameQuery = '';
  final TextEditingController _usernameSearch = TextEditingController();

  @override
  void initState() {
    super.initState();
    _directory = _api.loadDirectory();
  }

  void _reload() => setState(() => _directory = _api.loadDirectory());

  @override
  void dispose() {
    _usernameSearch.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, String success) async {
    try {
      await action();

      final UserDirectory directory = await _api.loadDirectory();

      if (!mounted) return;

      setState(() {
        _directory = Future<UserDirectory>.value(directory);
      });

      Toast.show(context: context, message: success);
    } on Exception catch (e) {
      if (!mounted) return;

      // Server messages can be long, and toasts do not wrap.
      unawaited(
        showMessagePopup(
          context: context,
          title: 'Something went wrong',
          message: _messageFor(e),
        ),
      );
    }
  }

  void _addUser() {
    unawaited(
      showFormPopup(
        context: context,
        title: 'Add user',
        child: _CredentialsForm(
          askUsername: true,
          onSubmit: (_Credentials credentials) => unawaited(
            _run(
              () => _api.createUser(
                username: credentials.username,
                password: credentials.password,
              ),
              'User added.',
            ),
          ),
        ),
      ),
    );
  }

  void _onAction(_UserAction action, GameUser user, UserDirectory directory) {
    switch (action) {
      case _UserAction.resetPassword:
        unawaited(
          showFormPopup(
            context: context,
            title: 'New password for ${user.username}',
            child: _CredentialsForm(
              askUsername: false,
              onSubmit: (_Credentials credentials) => unawaited(
                _run(
                  () => _api.resetPassword(
                    userId: user.id,
                    password: credentials.password,
                  ),
                  'Password updated.',
                ),
              ),
            ),
          ),
        );
      case _UserAction.subsections:
        unawaited(
          showFormPopup(
            context: context,
            title: 'Subsections for ${user.username}',
            child: _SubsectionsForm(
              subsections: directory.subsections,
              selected: user.subsectionIds.toSet(),
              onSave: (Set<String> chosen) => unawaited(
                _run(
                  () => _api.setSubsections(
                    userId: user.id,
                    subsectionIds: chosen.toList(),
                  ),
                  'Subsections updated.',
                ),
              ),
            ),
          ),
        );
      case _UserAction.remove:
        unawaited(
          ConfirmationPopup.show(
            context: context,
            title: 'Remove ${user.username}?',
            description: 'They will no longer be able to sign in.',
            confirmLabel: 'Remove',
            cancelLabel: 'Cancel',
            destructive: true,
            onConfirm: () => unawaited(
              _run(() => _api.removeUser(user.id), '${user.username} removed.'),
            ),
          ),
        );
    }
  }

  String? _subtitle(GameUser user, UserDirectory directory) {
    if (user.isAdmin) return 'Admin';
    final List<String> names = <String>[
      for (final String id in user.subsectionIds)
        if (directory.subsectionName(id) != null) directory.subsectionName(id)!,
    ];
    return names.isEmpty ? 'Player' : 'Manages: ${names.join(', ')}';
  }

  Widget _actionsMenu(GameUser user, UserDirectory directory) {
    // PopoverMenu.show anchors to the context it is given, so the trigger
    // gets its own Builder.
    return Builder(
      builder: (BuildContext triggerContext) => TappableIcon(
        icon: const Icon(Icons.more_vert),
        tooltip: 'Actions',
        onPressed: () => PopoverMenu.show(
          context: triggerContext,
          items: <PopoverMenuItem>[
            PopoverMenuItem(
              label: 'Reset password',
              onTap: () => _onAction(_UserAction.resetPassword, user, directory),
            ),
            PopoverMenuItem(
              label: 'Subsections they manage',
              onTap: () => _onAction(_UserAction.subsections, user, directory),
            ),
            PopoverMenuItem(
              label: 'Remove',
              onTap: () => _onAction(_UserAction.remove, user, directory),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Users',
      fullWidthBody: true,
      floatingActionButton: Button.small(
        label: 'Add user',
        icon: const Icon(Icons.person_add),
        onPressed: _addUser,
      ),
      body: FutureBuilder<UserDirectory>(
        future: _directory,
        builder: (BuildContext context, AsyncSnapshot<UserDirectory> snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const LoadingSpinner();
          }
          if (snap.hasError) {
            debugPrint('[UsersScreen] loadDirectory failed');
            debugPrint('[UsersScreen] error: ${snap.error}');
            debugPrint('[UsersScreen] stack: ${snap.stackTrace}');

            return EmptyState(
              title: _messageFor(snap.error!),
              description: '${snap.error}',
              action: Button.small(
                label: 'Retry',
                variant: ButtonVariant.outline,
                onPressed: _reload,
              ),
            );
          }
          final UserDirectory directory = snap.requireData;
          final List<GameUser> sortedUsers = _sortedUsers(
            directory.users,
            // Your current user's ID here.
            Supabase.instance.client.auth.currentSession?.user.id,
          );
          if (sortedUsers.isEmpty) {
            return const EmptyState(title: 'No users yet.');
          }
          final List<GameUser> users = <GameUser>[
            for (final GameUser user in sortedUsers)
              if ((_userTypeFilter == _UserTypeFilter.all ||
                      (_userTypeFilter == _UserTypeFilter.admin &&
                          user.isAdmin) ||
                      (_userTypeFilter == _UserTypeFilter.subsectionAdmin &&
                          !user.isAdmin && user.subsectionIds.isNotEmpty) ||
                      (_userTypeFilter == _UserTypeFilter.user &&
                          !user.isAdmin && user.subsectionIds.isEmpty)) &&
                  user.username.toLowerCase().contains(_usernameQuery))
                user,
          ];
          return Column(
            children: <Widget>[
              PageContent(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 8,
                    children: <Widget>[
                      Picker<_UserTypeFilter>(
                        label: 'User type',
                        value: _userTypeFilter,
                        items: _UserTypeFilter.values,
                        itemLabel: (_UserTypeFilter filter) => filter.label,
                        onChanged: (_UserTypeFilter filter) => setState(() {
                          _userTypeFilter = filter;
                        }),
                      ),
                      SearchField(
                        controller: _usernameSearch,
                        placeholder: 'Search users',
                        onChanged: (String value) => setState(() {
                          _usernameQuery = value.trim().toLowerCase();
                        }),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: users.isEmpty
                    ? EmptyState(
                        title: 'No users match these filters.',
                        action: Button.small(
                          label: 'Clear filters',
                          variant: ButtonVariant.outline,
                          onPressed: () {
                            _usernameSearch.clear();
                            setState(() {
                              _userTypeFilter = _UserTypeFilter.all;
                              _usernameQuery = '';
                            });
                          },
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 88),
                        itemCount: users.length,
                        itemBuilder: (BuildContext context, int index) {
                          final GameUser user = users[index];
                          return PageContent(
                            child: TileCard(
                              leading: Icon(
                                user.isAdmin
                                    ? Icons.admin_panel_settings
                                    : (user.subsectionIds.isEmpty
                                        ? Icons.person
                                        : Icons.supervisor_account),
                              ),
                              title: user.username,
                              subtitle: _subtitle(user, directory),
                              trailing: user.isAdmin
                                  ? null
                                  : _actionsMenu(user, directory),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Ticks the subsections a participant can grade.
class _SubsectionsForm extends StatefulWidget {
  const _SubsectionsForm({
    required this.subsections,
    required this.selected,
    required this.onSave,
  });

  final List<SubsectionRef> subsections;
  final Set<String> selected;
  final void Function(Set<String> chosen) onSave;

  @override
  State<_SubsectionsForm> createState() => _SubsectionsFormState();
}

class _SubsectionsFormState extends State<_SubsectionsForm> {
  late final Set<String> _selected = Set<String>.of(widget.selected);

  @override
  Widget build(BuildContext context) {
    final bool none = widget.subsections.isEmpty;
    return FormPopupLayout(
      body: none
          ? const Text(
              'There are no subsections yet. Create them on the Activities page.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: <Widget>[
                Text(
                  'They can grade answers in the ticked subsections.',
                  style: context.typography.bodySmall,
                ),
                for (final SubsectionRef s in widget.subsections)
                  MultiChoiceTile(
                    title: s.name,
                    value: _selected.contains(s.id),
                    variant: TileVariant.bordered,
                    onChanged: (bool on) => setState(() {
                      if (on) {
                        _selected.add(s.id);
                      } else {
                        _selected.remove(s.id);
                      }
                    }),
                  ),
              ],
            ),
      actions: <Widget>[
        Button.small(
          label: 'Cancel',
          variant: ButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(),
        ),
        if (!none)
          Button.small(
            label: 'Save',
            onPressed: () {
              Navigator.of(context).pop();
              widget.onSave(_selected);
            },
          ),
      ],
    );
  }
}

class _CredentialsForm extends StatefulWidget {
  const _CredentialsForm({required this.askUsername, required this.onSubmit});

  final bool askUsername;
  final void Function(_Credentials credentials) onSubmit;

  @override
  State<_CredentialsForm> createState() => _CredentialsFormState();
}

class _CredentialsFormState extends State<_CredentialsForm> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();
  bool _hidden = true;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final _Credentials credentials = (
      username: _username.text,
      password: _password.text,
    );
    Navigator.of(context).pop();
    widget.onSubmit(credentials);
  }

  @override
  Widget build(BuildContext context) {
    return FormPopupLayout(
      body: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (widget.askUsername)
              TextFormField(
                controller: _username,
                decoration: const InputDecoration(labelText: 'Username'),
                validator: validateUsername,
                textInputAction: TextInputAction.next,
              ),
            TextFormField(
              controller: _password,
              decoration: InputDecoration(
                labelText: 'Password',
                suffixIcon: TappableIcon(
                  icon: Icon(_hidden ? Icons.visibility : Icons.visibility_off),
                  tooltip: _hidden ? 'Show' : 'Hide',
                  onPressed: () => setState(() => _hidden = !_hidden),
                ),
              ),
              obscureText: _hidden,
              validator: validatePassword,
              onFieldSubmitted: (String _) => _submit(),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        Button.small(
          label: 'Cancel',
          variant: ButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(),
        ),
        Button.small(label: 'Save', onPressed: _submit),
      ],
    );
  }
}

List<GameUser> _sortedUsers(
  List<GameUser> users,
  String? currentUserId,
) {
  final List<GameUser> sorted = List<GameUser>.of(users);

  sorted.sort((GameUser a, GameUser b) {
    int priority(GameUser user) {
      if (user.id == currentUserId) return 0;
      if (user.subsectionIds.isNotEmpty) return 1;
      return 2;
    }

    final int priorityComparison = priority(a).compareTo(priority(b));
    if (priorityComparison != 0) return priorityComparison;

    return a.username.toLowerCase().compareTo(b.username.toLowerCase());
  });

  return sorted;
}

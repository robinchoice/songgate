import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/brand.dart';
import '../../core/locale.dart';
import '../converter/conversion.dart';
import '../friends/social.dart';
import 'account.dart';
import 'sync.dart';

/// The own identity for invites: the account's profile when logged in, else
/// what was entered on this phone.
Friend? ownIdentity(Social social, Profile? profile) =>
    profile?.asFriend ?? social.me;

class _Page extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Page({required this.title, required this.children});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: contentMaxWidth),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: children,
          ),
        ),
      ),
    ),
  );
}

class _ErrorText extends StatelessWidget {
  final String? error;
  const _ErrorText(this.error);

  @override
  Widget build(BuildContext context) => error == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(error!, style: const TextStyle(color: errorGlow)),
        );
}

/// Email, then the code from the mail.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  var _codeSent = false;
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendCode() => _run(() async {
    await ref.read(accountProvider.notifier).requestCode(_email.text.trim());
    if (mounted) setState(() => _codeSent = true);
  });

  Future<void> _logIn() => _run(() async {
    final profile = await ref
        .read(accountProvider.notifier)
        .verifyCode(_email.text.trim(), _code.text.trim());
    if (!mounted) return;
    if (profile.complete) {
      await ref.read(syncProvider).merge();
      if (mounted) Navigator.of(context).pop();
    } else {
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => const ProfileScreen(setup: true),
        ),
      );
    }
  });

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(messagesProvider);
    final theme = Theme.of(context);
    return _Page(
      title: t.logInWithMail,
      children: [
        TextField(
          controller: _email,
          enabled: !_codeSent,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          decoration: InputDecoration(labelText: t.loginEmailLabel),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        Text(t.accountPrivacyNote, style: theme.textTheme.bodySmall),
        const SizedBox(height: 16),
        if (!_codeSent)
          FilledButton(
            onPressed: _busy || !_email.text.contains('@') ? null : _sendCode,
            child: Text(t.sendCode),
          )
        else ...[
          Text(t.codeSentTo(_email.text.trim())),
          const SizedBox(height: 8),
          TextField(
            controller: _code,
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            autofillHints: const [AutofillHints.oneTimeCode],
            decoration: InputDecoration(labelText: t.codeLabel),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busy || _code.text.trim().length != 6 ? null : _logIn,
            child: Text(t.logIn),
          ),
          TextButton(
            onPressed: _busy ? null : _sendCode,
            child: Text(t.newCode),
          ),
        ],
        _ErrorText(_error),
      ],
    );
  }
}

class _ProfileFields extends ConsumerWidget {
  final TextEditingController name;
  final String platform;
  final ValueChanged<String> onPlatform;
  final VoidCallback onChanged;
  const _ProfileFields({
    required this.name,
    required this.platform,
    required this.onPlatform,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(messagesProvider);
    return Column(
      children: [
        TextField(
          controller: name,
          maxLength: 40,
          decoration: InputDecoration(labelText: t.name),
          onChanged: (_) => onChanged(),
        ),
        DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: platform,
          decoration: InputDecoration(labelText: t.listensOn),
          items: [
            for (final entry in platforms.entries)
              DropdownMenuItem(value: entry.key, child: Text(entry.value)),
          ],
          onChanged: (value) => onPlatform(value!),
        ),
      ],
    );
  }
}

/// Name and service others see. After the first login ([setup]) it also
/// brings this phone's contacts into the account.
class ProfileScreen extends ConsumerStatefulWidget {
  final bool setup;
  const ProfileScreen({super.key, this.setup = false});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  late final TextEditingController _name;
  late String _platform;
  var _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final profile = ref.read(accountProvider).value;
    final me = ref.read(socialProvider).me;
    _name = TextEditingController(text: profile?.name ?? me?.name ?? '');
    _platform = profile?.platform ?? me?.platform ?? 'spotify';
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(accountProvider.notifier)
          .updateProfile(_name.text.trim(), _platform);
      if (widget.setup) await ref.read(syncProvider).merge();
      if (mounted && widget.setup) Navigator.of(context).pop();
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(messagesProvider);
    final theme = Theme.of(context);
    final social = ref.watch(socialProvider);
    return _Page(
      title: t.profileTitle,
      children: [
        _ProfileFields(
          name: _name,
          platform: _platform,
          onPlatform: (value) => setState(() => _platform = value),
          onChanged: () => setState(() {}),
        ),
        const SizedBox(height: 8),
        Text(t.profileHint, style: theme.textTheme.bodySmall),
        if (widget.setup &&
            (social.friends.isNotEmpty || social.groups.isNotEmpty)) ...[
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                t.localCopied(social.friends.length, social.groups.length),
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy || _name.text.trim().isEmpty ? null : _save,
          child: Text(widget.setup ? t.done : t.save),
        ),
        _ErrorText(_error),
      ],
    );
  }
}

/// Edit the profile, log out or delete the account.
class AccountScreen extends ConsumerStatefulWidget {
  const AccountScreen({super.key});

  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen> {
  late final TextEditingController _name;
  late String _platform;
  var _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final profile = ref.read(accountProvider).value;
    _name = TextEditingController(text: profile?.name ?? '');
    _platform = profile?.platform ?? 'spotify';
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool leave = false,
  }) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (leave && mounted) Navigator.of(context).pop();
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final t = ref.read(messagesProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.deleteAccount),
        content: Text(t.deleteAccountConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: errorDeep),
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.deleteAccount),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(ref.read(accountProvider.notifier).delete, leave: true);
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(messagesProvider);
    final theme = Theme.of(context);
    final profile = ref.watch(accountProvider).value;
    final changed =
        profile != null &&
        (_name.text.trim() != profile.name || _platform != profile.platform);
    return _Page(
      title: t.accountTitle,
      children: [
        if (profile != null) Text(profile.email),
        const SizedBox(height: 8),
        _ProfileFields(
          name: _name,
          platform: _platform,
          onPlatform: (value) => setState(() => _platform = value),
          onChanged: () => setState(() {}),
        ),
        const SizedBox(height: 8),
        Text(t.accountServiceHint, style: theme.textTheme.bodySmall),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy || !changed || _name.text.trim().isEmpty
              ? null
              : () => _run(
                  () => ref
                      .read(accountProvider.notifier)
                      .updateProfile(_name.text.trim(), _platform),
                ),
          child: Text(t.save),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _busy
              ? null
              : () => _run(
                  ref.read(accountProvider.notifier).logout,
                  leave: true,
                ),
          child: Text(t.logOut),
        ),
        const SizedBox(height: 32),
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: errorGlow,
            side: const BorderSide(color: errorDeep),
          ),
          onPressed: _busy ? null : _delete,
          child: Text(t.deleteAccount),
        ),
        const SizedBox(height: 8),
        Text(t.deleteAccountHint, style: theme.textTheme.bodySmall),
        _ErrorText(_error),
      ],
    );
  }
}

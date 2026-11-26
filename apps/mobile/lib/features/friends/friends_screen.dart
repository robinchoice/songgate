import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/brand.dart';
import '../../core/locale.dart';
import '../account/account.dart';
import '../account/account_screens.dart';
import '../account/sync.dart';
import '../converter/conversion.dart';
import 'friends_bar.dart';
import 'social.dart';

Future<String?> askText(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
}) async {
  final controller = TextEditingController(text: initial);
  final t = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(messagesProvider);
  final route = DialogRoute<String>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 40,
        decoration: InputDecoration(labelText: label),
        onSubmitted: (value) =>
            Navigator.pop(context, value.trim().isEmpty ? null : value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            controller.text.trim().isEmpty ? null : controller.text.trim(),
          ),
          child: Text(t.save),
        ),
      ],
    ),
  );
  final result = await Navigator.of(context).push(route);
  await route.completed;
  controller.dispose();
  return result;
}

/// Name plus service. Saves it as a friend unless [save] is false.
Future<Friend?> showAddFriendDialog(
  BuildContext context,
  WidgetRef ref, {
  String? title,
  Friend? initial,
  bool save = true,
}) async {
  final t = ref.read(messagesProvider);
  final controller = TextEditingController(text: initial?.name ?? '');
  var platform = initial?.platform ?? 'spotify';
  final route = DialogRoute<Friend>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        scrollable: true,
        title: Text(title ?? t.addFriend),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              autofocus: initial == null,
              maxLength: 40,
              decoration: InputDecoration(labelText: t.name),
            ),
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: platform,
              decoration: InputDecoration(labelText: t.listensOn),
              items: [
                for (final entry in platforms.entries)
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
              ],
              onChanged: (value) => setState(() => platform = value!),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t.cancel),
          ),
          FilledButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                Navigator.pop(
                  context,
                  Friend(
                    name,
                    platform,
                    id: name == initial?.name ? initial?.id : null,
                  ),
                );
              }
            },
            child: Text(t.save),
          ),
        ],
      ),
    ),
  );
  final friend = await Navigator.of(context).push(route);
  await route.completed;
  controller.dispose();
  if (friend != null && save) {
    await ref.read(socialProvider.notifier).addFriend(friend);
  }
  return friend;
}

Future<void> shareInvite(BuildContext context, WidgetRef ref) async {
  final t = ref.read(messagesProvider);
  final profile = ref.read(accountProvider).value?.asFriend;
  final current = ref.read(socialProvider).me;
  // With an account, name and service come from the profile
  final me =
      profile ??
      await showAddFriendDialog(
        context,
        ref,
        title: t.myInvite,
        initial: current ?? const Friend('', 'spotify'),
        save: false,
      );
  if (me == null) return;
  if (profile == null) await ref.read(socialProvider.notifier).setMe(me);
  if (!context.mounted) return;
  final box = context.findRenderObject()! as RenderBox;
  final origin = box.localToGlobal(Offset.zero) & box.size;
  try {
    await SharePlus.instance.share(
      ShareParams(text: inviteText(me, t), sharePositionOrigin: origin),
    );
  } on PlatformException {
    await Clipboard.setData(ClipboardData(text: inviteText(me, t)));
  }
}

/// Face to face the invite is scanned instead of sent.
Future<void> showInviteQr(BuildContext context, WidgetRef ref) async {
  final t = ref.read(messagesProvider);
  final profile = ref.read(accountProvider).value?.asFriend;
  final current = ref.read(socialProvider).me;
  final me =
      profile ??
      current ??
      await showAddFriendDialog(
        context,
        ref,
        title: t.myInvite,
        initial: const Friend('', 'spotify'),
        save: false,
      );
  if (me == null || !context.mounted) return;
  if (profile == null && current == null) {
    await ref.read(socialProvider.notifier).setMe(me);
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      title: Text('${me.name} · ${platforms[me.platform]}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 240,
            height: 240,
            child: QrImageView(
              data: inviteUrl(me),
              backgroundColor: Colors.white,
              semanticsLabel: t.inviteQrLabel,
            ),
          ),
          const SizedBox(height: 12),
          Text(t.scanHint, textAlign: TextAlign.center),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.done),
        ),
      ],
    ),
  );
}

/// The card that offers the account, shown while logged out.
class _AccountCard extends ConsumerWidget {
  const _AccountCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(messagesProvider);
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.accountCardTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Text(t.accountCardText),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
              ),
              child: Text(t.logInWithMail),
            ),
          ],
        ),
      ),
    );
  }
}

/// Your own line while logged in, it opens the account.
class _AccountTile extends ConsumerWidget {
  final Profile profile;
  const _AccountTile(this.profile);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(messagesProvider);
    final me = profile.asFriend;
    return ListTile(
      key: const ValueKey('account-tile'),
      contentPadding: EdgeInsets.zero,
      leading: me == null
          ? const CircleAvatar(child: Icon(Icons.person_outline))
          : FriendAvatar(Friend(me.name, me.platform), size: 40),
      title: Text(me?.name ?? profile.email),
      subtitle: Text(
        me == null
            ? t.profileSetUp
            : t.accountSubtitle(platforms[me.platform]!, profile.email),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => me == null
              ? const ProfileScreen(setup: true)
              : const AccountScreen(),
        ),
      ),
    );
  }
}

class FriendsScreen extends ConsumerStatefulWidget {
  const FriendsScreen({super.key});

  @override
  ConsumerState<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends ConsumerState<FriendsScreen> {
  @override
  void initState() {
    super.initState();
    unawaited(ref.read(syncProvider).refreshProfiles());
  }

  @override
  Widget build(BuildContext context) {
    final social = ref.watch(socialProvider);
    final profile = ref.watch(accountProvider).value;
    final notifier = ref.read(socialProvider.notifier);
    final t = ref.watch(messagesProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.friends)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: contentMaxWidth),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (profile == null)
                  const _AccountCard()
                else
                  _AccountTile(profile),
                Text(profile == null ? t.friendsIntro : t.accountIntro),
                const SizedBox(height: 16),
                Builder(
                  builder: (context) => FilledButton.icon(
                    onPressed: () => shareInvite(context, ref),
                    icon: const Icon(Icons.ios_share),
                    label: Text(
                      ownIdentity(social, profile) == null
                          ? t.shareMyInvite
                          : t.shareInviteAs(
                              ownIdentity(social, profile)!.name,
                              platforms[ownIdentity(
                                social,
                                profile,
                              )!.platform]!,
                            ),
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => showInviteQr(context, ref),
                  icon: const Icon(Icons.qr_code_2),
                  label: Text(t.showInviteQr),
                ),
                TextButton.icon(
                  onPressed: () => showAddFriendDialog(context, ref),
                  icon: const Icon(Icons.person_add_alt),
                  label: Text(t.addFriendManually),
                ),
                const SizedBox(height: 8),
                if (social.friends.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(t.noFriends, style: theme.textTheme.bodySmall),
                  ),
                for (final friend in social.friends)
                  ListTile(
                    key: ValueKey('manage-${friend.name}'),
                    contentPadding: EdgeInsets.zero,
                    leading: FriendAvatar(friend, size: 40),
                    title: Text(friend.name),
                    subtitle: Text(platforms[friend.platform]!),
                    onTap: () => showAddFriendDialog(
                      context,
                      ref,
                      title: t.editFriend,
                      initial: friend,
                    ),
                    trailing: IconButton(
                      tooltip: t.remove(friend.name),
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => notifier.removeFriend(friend.name),
                    ),
                  ),
                if (social.groups.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(t.groups, style: theme.textTheme.titleSmall),
                  for (final group in social.groups)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const CircleAvatar(
                        child: Icon(Icons.group_outlined),
                      ),
                      title: Text(group.name),
                      subtitle: Text(group.members.join(', ')),
                      trailing: IconButton(
                        tooltip: t.remove(group.name),
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => notifier.removeGroup(group.name),
                      ),
                    ),
                ],
                const SizedBox(height: 16),
                Text(t.groupsHint, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Opened by musiclink://app/friend?name=…&service=…&u=… from an invite page.
/// A valid `u` links the contact to the sender's account.
class AddFriendScreen extends ConsumerWidget {
  final String? name;
  final String? service;
  final String? userId;
  const AddFriendScreen({super.key, this.name, this.service, this.userId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final platform = platformForSlug(service);
    final name = this.name?.trim() ?? '';
    final valid = platform != null && name.isNotEmpty && name.length <= 40;
    final t = ref.watch(messagesProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.invite)),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: contentMaxWidth),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: !valid
                  ? Text(t.inviteIncomplete)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: FriendAvatar(
                            Friend(name, platform, id: profileId(userId)),
                            size: 76,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          t.friendListensOn(name, platforms[platform]!),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          t.saveFriendHint(name, platforms[platform]!),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        FilledButton(
                          onPressed: () async {
                            await ref
                                .read(socialProvider.notifier)
                                .addFriend(
                                  Friend(name, platform, id: profileId(userId)),
                                );
                            if (context.mounted) context.go('/');
                          },
                          child: Text(t.saveName(name)),
                        ),
                        TextButton(
                          onPressed: () => context.go('/'),
                          child: Text(t.notNow),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

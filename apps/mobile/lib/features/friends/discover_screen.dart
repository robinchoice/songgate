import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/brand.dart';
import '../../core/locale.dart';
import '../account/account.dart';
import '../account/account_screens.dart';
import '../account/discover.dart';
import '../converter/conversion.dart';
import 'friends_bar.dart';
import 'friends_screen.dart';
import 'social.dart';

/// The card on the contacts screen that starts the search, or asks for the
/// own number first.
class DiscoverCard extends ConsumerWidget {
  final Profile profile;
  const DiscoverCard(this.profile, {super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(messagesProvider);
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.discoverCardTitle, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(
              profile.discoverable ? t.discoverCardText : t.discoverNeedsNumber,
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => profile.discoverable
                  ? Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const DiscoverScreen(),
                      ),
                    )
                  : openPhoneScreen(context),
              child: Text(profile.discoverable ? t.findContacts : t.addNumber),
            ),
          ],
        ),
      ),
    );
  }
}

/// Searches when it opens, the contacts permission is asked only here.
class DiscoverScreen extends ConsumerStatefulWidget {
  const DiscoverScreen({super.key});

  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen> {
  DiscoverResult? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search();
  }

  Future<void> _search() async {
    try {
      final result = await ref.read(discoveryProvider).run();
      if (mounted) setState(() => _result = result);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(messagesProvider);
    final theme = Theme.of(context);
    final social = ref.watch(socialProvider);
    final result = _result;
    return Scaffold(
      appBar: AppBar(title: Text(t.foundTitle)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: contentMaxWidth),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_error != null)
                  Text(_error!, style: const TextStyle(color: errorGlow))
                else if (result == null)
                  Row(
                    children: [
                      const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(t.checkingContacts)),
                    ],
                  )
                else if (result.denied)
                  Text(t.contactsDenied)
                else ...[
                  if (result.limited) ...[
                    Text(t.checkedPartly(result.checked, result.total)),
                    const SizedBox(height: 16),
                  ],
                  if (result.matches.isEmpty && !result.limited) ...[
                    Text(t.noMatches),
                    const SizedBox(height: 16),
                    Builder(
                      builder: (context) => FilledButton.icon(
                        onPressed: () => shareInvite(context, ref),
                        icon: const Icon(Icons.ios_share),
                        label: Text(t.shareMyInvite),
                      ),
                    ),
                  ] else if (result.matches.isNotEmpty) ...[
                    Text(t.foundCount(result.matches.length)),
                    const SizedBox(height: 8),
                    for (final match in result.matches)
                      _MatchTile(
                        match,
                        saved: social.friends.any(
                          (friend) => friend.id == match.id,
                        ),
                      ),
                    const SizedBox(height: 8),
                    Text(t.foundNote, style: theme.textTheme.bodySmall),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MatchTile extends ConsumerWidget {
  final Match match;
  final bool saved;
  const _MatchTile(this.match, {required this.saved});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(messagesProvider);
    final friend = Friend(match.name, match.platform, id: match.id);
    return ListTile(
      key: ValueKey('match-${match.name}'),
      contentPadding: EdgeInsets.zero,
      leading: FriendAvatar(friend, size: 40),
      title: Text(match.name),
      subtitle: Text(
        saved
            ? '${platforms[match.platform]} · ${t.alreadySaved}'
            : platforms[match.platform]!,
      ),
      trailing: saved
          ? null
          : TextButton(
              onPressed: () => ref
                  .read(socialProvider.notifier)
                  .addFriend(
                    Friend(
                      freeName(
                        match.name,
                        match.id,
                        ref.read(socialProvider).friends,
                      ),
                      match.platform,
                      id: match.id,
                    ),
                  ),
              child: Text(t.save),
            ),
    );
  }
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

import '../../calls/call_controller.dart';
import '../../calls/push_to_talk.dart';
import 'call_stage.dart';
import 'call_volume.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../theme/hanashi_theme.dart';
import '../widgets/avatar.dart';
import '../widgets/emoji_text.dart';

/// Whether this device can call in [summary]: the server carries calls, and
/// everyone in the chat is of this server (calls across servers come later).
bool canCall(WidgetRef ref, ConversationSummary summary) {
  if (ref.watch(callsAvailableProvider).value != true) return false;
  final me = ref.watch(chatRepositoryProvider).me;
  final host = UserId.tryParse(me)?.host;
  return summary.conversation.members.every((m) => UserId.tryParse(m)?.host == host);
}

/// Whether the voice goes out by push to talk on this device: set so, and
/// it has the voice gate that does it.
bool pushToTalkOn(WidgetRef ref) =>
    ref.watch(voiceGateSettingsProvider).value?.pushToTalk == true &&
    ref.watch(voiceGateAvailableProvider).value == true;

/// Push to talk on screen: the voice goes out while this is held down
/// (phones above all, where there is no key). [builder] draws it, held or
/// not; muted, it holds nothing.
class HoldToTalk extends ConsumerStatefulWidget {
  const HoldToTalk({super.key, required this.muted, required this.builder});

  final bool muted;
  final Widget Function(BuildContext context, bool held) builder;

  @override
  ConsumerState<HoldToTalk> createState() => _HoldToTalkState();
}

class _HoldToTalkState extends ConsumerState<HoldToTalk> {
  late final PushToTalkController _push = ref.read(pushToTalkProvider.notifier);

  @override
  void dispose() {
    // Gone while held (the controls hid, the call ended): let go.
    _push.hold(this, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final held = ref.watch(pushToTalkProvider) && !widget.muted;
    if (widget.muted) return widget.builder(context, false);
    return Listener(
      onPointerDown: (_) => _push.hold(this, true),
      onPointerUp: (_) => _push.hold(this, false),
      onPointerCancel: (_) => _push.hold(this, false),
      child: widget.builder(context, held),
    );
  }
}

/// The call going on in a conversation, if any.
Call? activeCallIn(WidgetRef ref, String conversationId) =>
    ref.watch(callsProvider).value?.values.where((c) => c.conv == conversationId && c.active).firstOrNull;

/// Calls a chat, or joins its call: in its title bar. With [video], a video
/// call: only in chats of two, where the server has video, and not while a
/// call goes on there (that one is joined with the other button).
class CallButton extends ConsumerWidget {
  const CallButton({super.key, required this.summary, required this.foreground, this.video = false});

  final ConversationSummary summary;
  final Color foreground;
  final bool video;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!canCall(ref, summary)) return const SizedBox.shrink();
    final view = ref.watch(callControllerProvider);
    final going = activeCallIn(ref, summary.id);
    final inIt = view.phase != CallPhase.idle && view.conv == summary.id;
    if (video && (!summary.conversation.isDirect || going != null || ref.watch(videoAvailableProvider).value != true)) {
      return const SizedBox.shrink();
    }
    return IconButton(
      key: Key(video ? 'video-call-button' : 'call-button'),
      tooltip: video ? 'Video call' : (inIt ? 'In the call' : (going != null ? 'Join the call' : 'Voice call')),
      icon: Icon(
        video ? Icons.videocam_outlined : (going != null ? Icons.phone_in_talk_outlined : Icons.phone_outlined),
        color: foreground,
      ),
      onPressed: inIt || view.phase != CallPhase.idle
          ? null
          : () async {
              final controller = ref.read(callControllerProvider.notifier);
              if (await confirmCall(context, summary, video: video, joining: going != null)) {
                unawaited(controller.start(summary.id, video: video));
              }
            },
    );
  }
}

/// Asks before a call goes out, or in, from a chat's title bar, where a
/// click can miss: true to go on. Esc or a click outside is no.
Future<bool> confirmCall(
  BuildContext context,
  ConversationSummary summary, {
  required bool video,
  required bool joining,
}) async {
  final group = summary.conversation.isGroup;
  final (question, go) = joining
      ? ('Join the call in ${summary.title}?', 'Join')
      : video
      ? ('Video call ${summary.title}?', 'Video call')
      : group
      ? ('Start a call in ${summary.title}?', 'Start the call')
      : ('Call ${summary.title}?', 'Call');
  final answer = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('call-confirm-dialog'),
      title: EmojiText(question),
      content: group && !joining ? const Text('Everyone in the group can join it.') : null,
      actions: [
        TextButton(
          key: const Key('call-confirm-cancel'),
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          key: const Key('call-confirm'),
          onPressed: () => Navigator.pop(context, true),
          icon: Icon(video ? Icons.videocam : Icons.phone, size: 18),
          label: Text(go),
        ),
      ],
    ),
  );
  return answer ?? false;
}

/// A group's call going on that this device is not in: under the chat's
/// title, with a way in.
class CallStrip extends ConsumerWidget {
  const CallStrip({super.key, required this.conversationId});

  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = activeCallIn(ref, conversationId);
    final view = ref.watch(callControllerProvider);
    if (call == null || call.direct || (view.phase != CallPhase.idle && view.call?.id == call.id)) {
      return const SizedBox.shrink();
    }
    final count = call.users.length;
    return Material(
      key: const Key('call-strip'),
      color: context.palette.online.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            Icon(Icons.graphic_eq, size: 20, color: context.palette.online),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                count == 0 ? 'A call is starting' : 'Call in progress · ${count == 1 ? '1 person' : '$count people'}',
                style: TextStyle(fontSize: 14, color: context.palette.textPrimary),
              ),
            ),
            FilledButton(
              key: const Key('call-join'),
              style: FilledButton.styleFrom(
                backgroundColor: context.palette.online,
                visualDensity: VisualDensity.compact,
              ),
              onPressed: view.phase == CallPhase.idle
                  ? () => unawaited(ref.read(callControllerProvider.notifier).start(conversationId))
                  : null,
              child: const Text('Join'),
            ),
          ],
        ),
      ),
    );
  }
}

/// How long ago [since] was, as a call's running time: 0:42, 12:05, 1:02:05.
String callTime(Duration elapsed) {
  final s = elapsed.inSeconds;
  String two(int n) => n.toString().padLeft(2, '0');
  return s >= 3600 ? '${s ~/ 3600}:${two(s % 3600 ~/ 60)}:${two(s % 60)}' : '${s ~/ 60}:${two(s % 60)}';
}

/// How long a call that ended lasted, in words: "45 s", "12 min", "1 h 5 min".
String callLength(Duration length) {
  final minutes = (length.inSeconds / 60).round();
  if (length.inSeconds < 60) return '${length.inSeconds} s';
  if (minutes < 60) return '$minutes min';
  return '${minutes ~/ 60} h${minutes % 60 == 0 ? '' : ' ${minutes % 60} min'}';
}

/// A call's place in a chat (a `call` message): what became of it, and a
/// way in while it goes on.
class CallRecord extends ConsumerWidget {
  const CallRecord({super.key, required this.callId, required this.conversationId, required this.mine});

  final String callId;
  final String conversationId;

  /// The user started it.
  final bool mine;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(callsProvider.select((calls) => calls.value?[callId]));
    final view = ref.watch(callControllerProvider);
    // Another chat's call is not this one's to join.
    final ours = call != null && call.conv == conversationId;
    final missed = ours && !call.active && !mine && (call.reason == CallEnd.missed || call.reason == CallEnd.cancelled);
    final (icon, color) = missed
        ? (Icons.phone_missed_outlined, context.palette.failed)
        : (mine ? Icons.call_made : Icons.call_received, context.palette.online);
    final status = switch (call) {
      _ when !ours => null,
      Call(active: true) => 'Going on',
      Call(reason: CallEnd.ended) => callLength(call.endedAt!.difference(call.answeredAt ?? call.startedAt)),
      Call(reason: CallEnd.missed) when mine => 'No answer',
      Call(reason: CallEnd.cancelled) when mine => 'Cancelled',
      Call(reason: CallEnd.declined) when mine => 'Declined',
      Call(reason: CallEnd.declined) => 'You declined',
      Call(reason: CallEnd.failed) => 'Could not start',
      _ => null,
    };
    final joinable = ours && call.active && !(view.phase != CallPhase.idle && view.call?.id == call.id);
    return Container(
      key: ValueKey('call-record-$callId'),
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 280),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: context.palette.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.palette.mediaCardBorder, width: 1.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: color.withValues(alpha: 0.14),
            child: Icon(icon, size: 20, color: color),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(switch ((missed, call?.video ?? false)) {
                  (true, true) => 'Missed video call',
                  (true, false) => 'Missed voice call',
                  (false, true) => 'Video call',
                  (false, false) => 'Voice call',
                }, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: context.palette.textPrimary)),
                if (status != null && !missed)
                  Text(status, style: TextStyle(fontSize: 13, color: context.palette.textSecondary)),
              ],
            ),
          ),
          if (joinable) ...[
            const SizedBox(width: 10),
            FilledButton(
              key: ValueKey('call-record-join-$callId'),
              style: FilledButton.styleFrom(
                backgroundColor: context.palette.online,
                visualDensity: VisualDensity.compact,
              ),
              onPressed: view.phase == CallPhase.idle
                  ? () => unawaited(ref.read(callControllerProvider.notifier).start(conversationId))
                  : null,
              child: const Text('Join'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Above every screen: the call that rings, the call this device is in, and
/// why the last one ended. Outside the router's navigator, so no tooltips.
class CallOverlay extends ConsumerWidget {
  const CallOverlay({
    super.key,
    required this.child,
    required this.onOpenChat,
    this.openChat,
    this.navigatorContext,
    this.backButtonDispatcher,
  });

  final Widget child;
  final void Function(String conversationId) onOpenChat;

  /// The chat on screen, if any: its call's video shows in it, without the
  /// call bar (see [CallStage]).
  final ValueListenable<String?>? openChat;

  /// Where dialogs go (the screen picker), as this is outside the router's
  /// navigator.
  final BuildContext? Function()? navigatorContext;

  /// The app's: the system's back puts the phone's call view away first.
  final BackButtonDispatcher? backButtonDispatcher;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(callControllerProvider);
    final full = ref.watch(callStageFullProvider);
    final narrow = narrowCallLayout(context, ref);
    final shown = view.phase.inCall && callShown(view, ref);
    // Phones: a call with video (or opened) has a view of its own, until put
    // away.
    final phoneView = shown && narrow && !full && !ref.watch(callViewMinimizedProvider);
    final top = MediaQuery.paddingOf(context).top + 60;
    return Stack(
      children: [
        child,
        if (view.phase == CallPhase.incoming && view.call != null)
          Positioned(
            top: top,
            left: 12,
            right: 12,
            child: Center(child: _IncomingCall(call: view.call!)),
          ),
        if (view.phase.inCall && !full && !phoneView)
          Positioned(
            key: const ValueKey('call-pill-place'),
            top: top,
            left: 12,
            right: 12,
            child: ValueListenableBuilder(
              valueListenable: openChat ?? ValueNotifier(null),
              // Not over the chat that shows the call's video.
              builder: (context, open, _) => shown && !narrow && open == view.conv
                  ? const SizedBox.shrink()
                  : Center(
                      child: _CallPill(view: view, onOpenChat: onOpenChat, navigatorContext: navigatorContext),
                    ),
            ),
          ),
        if (phoneView)
          Positioned.fill(
            key: const ValueKey('phone-call-place'),
            child: PhoneCallView(backButtonDispatcher: backButtonDispatcher),
          ),
        if (full)
          Positioned.fill(
            key: const ValueKey('full-call-place'),
            child: FullCallStage(backButtonDispatcher: backButtonDispatcher),
          ),
        if (view.phase == CallPhase.idle && view.problem != null)
          Positioned(
            top: top,
            left: 12,
            right: 12,
            child: Center(child: _Notice(text: view.problem!)),
          ),
        if (view.phase.inCall && view.notice != null)
          Positioned(
            bottom: MediaQuery.paddingOf(context).bottom + 96,
            left: 12,
            right: 12,
            child: Center(
              child: _Notice(key: ValueKey(view.noticeCount), text: view.notice!),
            ),
          ),
      ],
    );
  }
}

String _nameOf(WidgetRef ref, String user) {
  final me = ref.watch(chatRepositoryProvider).me;
  return ref.watch(profilesProvider).value?[user]?.displayName ?? UserId.fallbackName(user, me: me);
}

class _IncomingCall extends ConsumerWidget {
  const _IncomingCall({required this.call});

  final Call call;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = _nameOf(ref, call.startedBy);
    final controller = ref.read(callControllerProvider.notifier);
    return Material(
      key: const Key('incoming-call'),
      elevation: 8,
      color: context.palette.surface,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 360),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(
          children: [
            Avatar(id: call.startedBy, label: name, size: 48),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: context.palette.textPrimary),
                  ),
                  Text(
                    call.video ? 'Video call' : 'Voice call',
                    style: TextStyle(fontSize: 13, color: context.palette.textSecondary),
                  ),
                ],
              ),
            ),
            _RoundButton(
              key: const Key('call-decline'),
              label: 'Decline',
              icon: Icons.call_end,
              color: context.palette.failed,
              onPressed: () => unawaited(controller.decline()),
            ),
            const SizedBox(width: 12),
            _RoundButton(
              key: const Key('call-accept'),
              label: 'Accept',
              icon: Icons.call,
              color: context.palette.online,
              onPressed: () => unawaited(controller.accept()),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
    this.onPressed,
    this.size = 22,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onPressed;

  /// The icon's; the button is about twice as wide.
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: Material(
      color: color,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: Padding(
          padding: EdgeInsets.all(size / 2.2),
          child: Icon(icon, color: Colors.white, size: size),
        ),
      ),
    ),
  );
}

/// Someone in a call: each person once, however many devices they are in it
/// with; speaking if any of them is, muted or deafened if all of them are.
typedef _Person = ({String user, bool speaking, bool muted, bool deafened});

List<_Person> _peopleIn(CallView view) {
  final people = <String, _Person>{};
  for (final peer in view.room.peers) {
    final was = people[peer.user];
    people[peer.user] = (
      user: peer.user,
      speaking: (was?.speaking ?? false) || peer.speaking,
      muted: (was?.muted ?? true) && peer.muted,
      deafened: (was?.deafened ?? true) && peer.deafened,
    );
  }
  return [...people.values];
}

/// A person's microphone off and headset off, as a red badge: round with one,
/// longer with both; nothing with neither.
class _StateBadge extends StatelessWidget {
  const _StateBadge({required this.person, this.size = 10});

  final _Person person;

  /// Its icons' size.
  final double size;

  @override
  Widget build(BuildContext context) {
    if (!person.muted && !person.deafened) return const SizedBox.shrink();
    return Container(
      height: size + 6,
      padding: EdgeInsets.symmetric(horizontal: size * 0.3),
      decoration: BoxDecoration(color: context.palette.failed, borderRadius: BorderRadius.circular(size)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: size * 0.1,
        children: [
          if (person.deafened)
            Icon(
              Icons.headset_off,
              key: ValueKey('call-peer-deafened-${person.user}'),
              size: size,
              color: Colors.white,
              semanticLabel: 'Deafened',
            ),
          if (person.muted)
            Icon(
              Icons.mic_off,
              key: ValueKey('call-peer-muted-${person.user}'),
              size: size,
              color: Colors.white,
              semanticLabel: 'Muted',
            ),
        ],
      ),
    );
  }
}

/// A person's picture, ringed while they speak, with their [_StateBadge].
/// Not [named] (over the lock screen, without previews): a picture of
/// nobody in particular.
class _PersonAvatar extends ConsumerWidget {
  const _PersonAvatar({required this.person, required this.size, this.named = true});

  final _Person person;
  final double size;
  final bool named;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Stack(
    clipBehavior: Clip.none,
    children: [
      Container(
        key: ValueKey('call-peer-${person.user}'),
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: person.speaking ? context.palette.online : Colors.transparent, width: 2),
        ),
        child: Avatar(id: named ? person.user : '', label: named ? _nameOf(ref, person.user) : '', size: size),
      ),
      Positioned(
        right: -2,
        bottom: -2,
        child: _StateBadge(person: person, size: size * 0.38),
      ),
    ],
  );
}

/// The call this device is in: where, for how long, who speaks, and mute,
/// deafen and hang up.
class _CallPill extends ConsumerWidget {
  const _CallPill({required this.view, required this.onOpenChat, this.navigatorContext});

  /// Narrower than this (phones), it takes two rows.
  static const wideFrom = 520.0;

  final CallView view;
  final void Function(String conversationId) onOpenChat;
  final BuildContext? Function()? navigatorContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = view.call;
    final conv = view.conv;
    final summary = conv == null ? null : ref.watch(conversationProvider(conv));
    final controller = ref.read(callControllerProvider.notifier);
    final me = ref.watch(chatRepositoryProvider).me;
    final video = ref.watch(videoAvailableProvider).value ?? false;
    // Phones: the call's view, put away, comes back from here.
    final narrow = narrowCallLayout(context, ref);
    final expands = narrow && callShown(view, ref);
    final unheard = view.room.peers.any((p) => !p.encrypted || !p.decrypting);
    final status = switch (view.phase) {
      CallPhase.connecting => 'Connecting...',
      _ when call != null && call.unanswered && call.startedBy == me => 'Calling...',
      _ when call != null => null,
      _ => '',
    };
    final where = InkWell(
      key: const Key('call-pill-where'),
      onTap: expands
          ? () => ref.read(callViewMinimizedProvider.notifier).set(false)
          : conv == null
          ? null
          : () => onOpenChat(conv),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  summary?.title ?? 'Call',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: context.palette.onRail, fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ),
              if (expands) ...[
                const SizedBox(width: 6),
                Icon(Icons.open_in_full, size: 14, color: context.palette.railIcon, semanticLabel: 'Show the video'),
              ],
            ],
          ),
          if (status != null)
            Text(status, style: TextStyle(color: context.palette.railIcon, fontSize: 12))
          else
            CallClock(since: call!.answeredAt ?? call.startedAt),
          if (unheard)
            Text("Someone's audio can't be heard", style: TextStyle(color: context.palette.warning, fontSize: 12)),
        ],
      ),
    );
    // One avatar a person, however many devices they are in it with; a tap
    // sets how loud each one plays here, all of them.
    final everyone = _peopleIn(view);
    final people = Builder(
      builder: (context) => Semantics(
        button: true,
        label: 'Volume',
        child: InkWell(
          key: const Key('call-pill-people'),
          borderRadius: BorderRadius.circular(16),
          onTap: everyone.isEmpty
              ? null
              : () {
                  final menus = navigatorContext?.call();
                  if (menus == null) return;
                  unawaited(showVolumes(menus, at: below(context), users: [for (final p in everyone) p.user]));
                },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final person in everyone.take(4))
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: _PersonAvatar(person: person, size: 26),
                ),
            ],
          ),
        ),
      ),
    );
    final lock = Icon(
      view.room.encrypted ? Icons.lock : Icons.lock_open,
      size: 16,
      color: view.room.encrypted ? context.palette.online : context.palette.railIcon,
      semanticLabel: view.room.encrypted ? 'Encrypted' : 'Not encrypted yet',
    );
    final controls = [
      if (pushToTalkOn(ref))
        HoldToTalk(
          muted: view.muted,
          builder: (context, held) => _PillButton(
            key: const Key('call-talk'),
            label: 'Hold to talk',
            icon: Icons.record_voice_over,
            active: false,
            color: held ? context.palette.online : null,
            // Held, not tapped: the pointer does it.
            onPressed: view.muted ? null : () {},
          ),
        ),
      _PillButton(
        key: const Key('call-mute'),
        label: view.muted ? 'Unmute' : 'Mute',
        icon: view.muted ? Icons.mic_off : Icons.mic,
        active: view.muted,
        onPressed: () => unawaited(controller.toggleMute()),
      ),
      _PillButton(
        key: const Key('call-deafen'),
        label: view.deafened ? 'Undeafen' : 'Deafen',
        icon: view.deafened ? Icons.headset_off : Icons.headset,
        active: view.deafened,
        onPressed: () => unawaited(controller.toggleDeafen()),
      ),
      // Everyone in the call, as a grid: in its chat, or (phones) a view of
      // its own; with nothing to see too.
      _PillButton(
        key: const Key('call-show'),
        label: 'Show the call',
        icon: Icons.grid_view,
        active: false,
        onPressed: () {
          ref.read(callViewOpenProvider.notifier).set(true);
          ref.read(callViewMinimizedProvider.notifier).set(false);
          if (!narrow && conv != null) onOpenChat(conv);
        },
      ),
      // Phones: the earpiece, or the speaker.
      if (ref.watch(callOnPhoneProvider))
        _PillButton(
          key: const Key('call-speaker'),
          label: view.speaker ? 'Earpiece' : 'Speaker',
          icon: view.speaker ? Icons.volume_up : Icons.phone_in_talk,
          active: false,
          onPressed: () => unawaited(controller.toggleSpeaker()),
        ),
      if (video)
        _PillButton(
          key: const Key('call-camera'),
          label: view.camera ? 'Turn camera off' : 'Turn camera on',
          icon: view.camera ? Icons.videocam : Icons.videocam_off,
          active: !view.camera,
          onPressed: () => unawaited(controller.toggleCamera()),
        ),
      // Not iPhones yet (a broadcast extension of their own).
      if (video && !Platform.isIOS)
        _PillButton(
          key: const Key('call-share'),
          label: view.sharing ? 'Stop sharing' : 'Share your screen',
          icon: view.sharing ? Icons.stop_screen_share : Icons.screen_share,
          active: false,
          onPressed: () {
            final context = navigatorContext?.call();
            if (view.sharing) {
              unawaited(controller.stopSharing());
            } else if (context != null) {
              unawaited(pickAndShareScreen(context, ref));
            }
          },
        ),
    ];
    final hangUp = _RoundButton(
      key: const Key('call-hang-up'),
      label: 'Hang up',
      icon: Icons.call_end,
      color: context.palette.failed,
      onPressed: () => unawaited(controller.hangUp()),
    );
    return Material(
      key: const Key('call-pill'),
      elevation: 6,
      color: context.palette.rail,
      borderRadius: BorderRadius.circular(24),
      child: LayoutBuilder(
        builder: (context, constraints) => constraints.maxWidth >= wideFrom
            ? Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    lock,
                    const SizedBox(width: 8),
                    Flexible(child: where),
                    const SizedBox(width: 8),
                    people,
                    const SizedBox(width: 4),
                    ...controls,
                    const SizedBox(width: 4),
                    hangUp,
                  ],
                ),
              )
            // Narrow (phones): who and where above, what to do below.
            : Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        lock,
                        const SizedBox(width: 8),
                        Expanded(child: where),
                        people,
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Row(mainAxisSize: MainAxisSize.min, children: controls),
                          ),
                        ),
                        hangUp,
                      ],
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    super.key,
    required this.label,
    required this.icon,
    required this.active,
    this.color,
    this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool active;

  /// Its own colour, if any (talking).
  final Color? color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    toggled: active,
    label: label,
    child: IconButton(
      onPressed: onPressed,
      icon: Icon(icon, color: color ?? (active ? context.palette.failed : Colors.white), size: 20),
    ),
  );
}

/// A call's running time, ticking.
class CallClock extends ConsumerStatefulWidget {
  const CallClock({super.key, required this.since, this.fontSize = 12});

  final DateTime since;
  final double fontSize;

  @override
  ConsumerState<CallClock> createState() => _CallClockState();
}

class _CallClockState extends ConsumerState<CallClock> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = ref.read(clockProvider)().difference(widget.since);
    return Text(
      callTime(elapsed.isNegative ? Duration.zero : elapsed),
      style: TextStyle(
        color: context.palette.railIcon,
        fontSize: widget.fontSize,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// Why a call ended, for a few seconds.
class _Notice extends StatefulWidget {
  const _Notice({super.key, required this.text});

  final String text;

  @override
  State<_Notice> createState() => _NoticeState();
}

class _NoticeState extends State<_Notice> {
  var _shown = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 4), () => setState(() => _shown = false));
  }

  @override
  void didUpdateWidget(_Notice old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) {
      _timer?.cancel();
      _shown = true;
      _timer = Timer(const Duration(seconds: 4), () => setState(() => _shown = false));
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => !_shown
      ? const SizedBox.shrink()
      : Material(
          key: const Key('call-notice'),
          color: context.palette.rail,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(widget.text, style: TextStyle(color: context.palette.onRail, fontSize: 14)),
          ),
        );
}

/// The app over the lock screen (Android), opened by a call's notification:
/// that call and nothing else. Back behind the lock once the call is over
/// (see [CallController]). Outside the router's navigator, so no tooltips.
class LockedCallScreen extends ConsumerWidget {
  const LockedCallScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(callControllerProvider);
    if (view.phase.inCall && view.call != null && callHasVideo(view)) return const PhoneCallView(locked: true);
    final controller = ref.read(callControllerProvider.notifier);
    final call = view.call;
    final me = ref.watch(chatRepositoryProvider).me;
    // Names show where notifications show them.
    final named = call != null && (ref.watch(notificationPreferencesProvider).value?.preview ?? true);
    final summary = call == null ? null : ref.watch(conversationProvider(call.conv));
    final name = named ? summary?.title ?? _nameOf(ref, call.startedBy) : context.appName;
    final status = switch (view.phase) {
      CallPhase.incoming => call?.video ?? false ? 'Incoming video call' : 'Incoming voice call',
      CallPhase.connecting => 'Connecting...',
      CallPhase.connected when call != null && call.unanswered => 'Calling...',
      CallPhase.connected when call != null => null,
      _ => view.problem ?? 'Connecting...',
    };
    final white = TextStyle(color: context.palette.onRail);
    // Who else is in it, and whether they are muted or deafened: on the
    // picture, with words, for one other person; for more, their pictures.
    final people = view.phase.inCall ? _peopleIn(view) : const <_Person>[];
    final one = people.length == 1 ? people.single : null;
    return Material(
      key: const Key('locked-call'),
      color: context.palette.rail,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 56, 24, 24),
          child: Column(
            children: [
              if (named)
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Avatar(id: call.startedBy == me ? call.conv : call.startedBy, label: name, size: 112),
                    if (one != null) Positioned(right: 0, bottom: 4, child: _StateBadge(person: one, size: 22)),
                  ],
                )
              else
                Icon(Icons.call, size: 72, color: context.palette.onRail),
              const SizedBox(height: 20),
              Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: white.copyWith(fontSize: 26, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              if (status != null)
                Text(status, style: TextStyle(color: context.palette.railIcon, fontSize: 16))
              else
                CallClock(since: call!.answeredAt ?? call.startedAt, fontSize: 16),
              if (one != null && (one.muted || one.deafened))
                Padding(
                  key: const Key('locked-peer-state'),
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 6,
                    children: [
                      if (one.muted) ...[
                        Icon(Icons.mic_off, size: 18, color: context.palette.failed),
                        Text('Muted', style: TextStyle(color: context.palette.failed, fontSize: 15)),
                      ],
                      if (one.muted && one.deafened) const SizedBox(width: 8),
                      if (one.deafened) ...[
                        Icon(Icons.headset_off, size: 18, color: context.palette.failed),
                        Text('Deafened', style: TextStyle(color: context.palette.failed, fontSize: 15)),
                      ],
                    ],
                  ),
                ),
              if (people.length > 1)
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 10,
                    runSpacing: 10,
                    children: [for (final person in people) _PersonAvatar(person: person, size: 40, named: named)],
                  ),
                ),
              const Spacer(),
              if (view.phase == CallPhase.incoming)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _Labelled(
                      label: 'Decline',
                      child: _RoundButton(
                        key: const Key('locked-decline'),
                        label: 'Decline',
                        icon: Icons.call_end,
                        color: context.palette.failed,
                        size: 34,
                        onPressed: () => unawaited(controller.decline()),
                      ),
                    ),
                    _Labelled(
                      label: 'Accept',
                      child: _RoundButton(
                        key: const Key('locked-accept'),
                        label: 'Accept',
                        icon: Icons.call,
                        color: context.palette.online,
                        size: 34,
                        onPressed: () => unawaited(controller.accept()),
                      ),
                    ),
                  ],
                )
              else if (view.phase.inCall)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    if (pushToTalkOn(ref))
                      _Labelled(
                        label: 'Hold to talk',
                        child: HoldToTalk(
                          muted: view.muted,
                          builder: (context, held) => _RoundButton(
                            key: const Key('locked-talk'),
                            label: 'Hold to talk',
                            icon: Icons.record_voice_over,
                            color: held ? context.palette.online : context.palette.onRail.withAlpha(0x3D),
                            size: 30,
                            onPressed: view.muted ? null : () {},
                          ),
                        ),
                      ),
                    _Labelled(
                      label: view.muted ? 'Unmute' : 'Mute',
                      child: _RoundButton(
                        key: const Key('locked-mute'),
                        label: view.muted ? 'Unmute' : 'Mute',
                        icon: view.muted ? Icons.mic_off : Icons.mic,
                        color: view.muted ? context.palette.failed : context.palette.onRail.withAlpha(0x3D),
                        size: 30,
                        onPressed: () => unawaited(controller.toggleMute()),
                      ),
                    ),
                    _Labelled(
                      label: view.speaker ? 'Earpiece' : 'Speaker',
                      child: _RoundButton(
                        key: const Key('locked-speaker'),
                        label: view.speaker ? 'Earpiece' : 'Speaker',
                        icon: view.speaker ? Icons.volume_up : Icons.phone_in_talk,
                        color: context.palette.onRail.withAlpha(0x3D),
                        size: 30,
                        onPressed: () => unawaited(controller.toggleSpeaker()),
                      ),
                    ),
                    _Labelled(
                      label: 'Hang up',
                      child: _RoundButton(
                        key: const Key('locked-hang-up'),
                        label: 'Hang up',
                        icon: Icons.call_end,
                        color: context.palette.failed,
                        size: 30,
                        onPressed: () => unawaited(controller.hangUp()),
                      ),
                    ),
                  ],
                )
              else
                SizedBox(
                  height: 88,
                  child: Center(child: CircularProgressIndicator(color: context.palette.onRail)),
                ),
              const SizedBox(height: 24),
              TextButton(
                key: const Key('locked-unlock'),
                onPressed: () => unawaited(ref.read(callWindowProvider).unlock()),
                child: Text(
                  'Unlock to open ${context.appName}',
                  style: TextStyle(color: context.palette.railIcon, fontSize: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A button with its name under it.
class _Labelled extends StatelessWidget {
  const _Labelled({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      child,
      const SizedBox(height: 8),
      ExcludeSemantics(
        child: Text(label, style: TextStyle(color: context.palette.onRail, fontSize: 13)),
      ),
    ],
  );
}

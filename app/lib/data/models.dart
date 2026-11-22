import 'dart:typed_data';

import 'package:hanashi_protocol/hanashi_protocol.dart';

/// Public profile of a user, as shown in lists and message headers.
class UserProfile {
  const UserProfile({required this.id, required this.displayName, this.avatar, this.card = ProfileCard.empty});

  /// `name@host`.
  final String id;
  final String displayName;

  /// Their profile picture (an encrypted blob), once they told us.
  final MediaRef? avatar;

  /// What else they tell about themself (status message, birthday), once
  /// this device has fetched it.
  final ProfileCard card;
}

class Conversation {
  const Conversation({required this.id, required this.members, required this.isDirect, this.title});

  final String id;

  /// Member user IDs, including the current user.
  final List<String> members;

  /// The chat of two contacts, rather than a group (which can have two people).
  final bool isDirect;

  /// A group's title, once its state reached this device; direct chats are
  /// titled after the other member.
  final String? title;

  bool get isGroup => !isDirect;
}

/// A conversation as shown in the chat list.
class ConversationSummary {
  const ConversationSummary({
    required this.conversation,
    required this.title,
    required this.avatarId,
    this.picture,
    this.description,
    this.lastMessage,
    this.unreadCount = 0,
    this.securityIssue,
  });

  final Conversation conversation;
  final String title;

  /// User ID (or conversation ID for groups) used to derive the avatar.
  final String avatarId;

  /// A group's picture (a direct chat shows the other person's).
  final MediaRef? picture;

  /// What a group is about, as its members said.
  final String? description;
  final ChatMessage? lastMessage;
  final int unreadCount;

  /// Why sending is paused (e.g. an unverified device in the group), if it is.
  final String? securityIssue;

  String get id => conversation.id;
}

enum DeliveryState {
  /// Stored in the local outbox, not yet acknowledged by the server.
  pending,

  /// Acknowledged by the server and assigned a sequence number.
  sent,

  /// Rejected by the server; can be retried or discarded.
  failed,
}

class ChatMessage {
  const ChatMessage({
    required this.envelope,
    this.seq,
    this.state = DeliveryState.sent,
    this.edited = false,
    this.reactions = const {},
    this.replyTo,
  });

  /// The message as it reads now: with the latest edit's text, or of type
  /// [Envelope.deletedType] once deleted.
  final Envelope envelope;

  /// Server sequence number; null while the message is pending.
  final int? seq;
  final DeliveryState state;

  /// The sender changed the text after sending.
  final bool edited;

  /// Emoji -> who reacted with it, in the order the reactions came.
  final Map<String, List<String>> reactions;

  /// The message this one replies to, with its current text (or the quote
  /// the sender included, where the original is not available).
  final ReplyRef? replyTo;

  String get id => envelope.id;
  String get senderId => envelope.from;
  DateTime get sentAt => envelope.sentAt;
  bool get isDeleted => envelope.type == Envelope.deletedType;

  ChatMessage copyWith({int? seq, DeliveryState? state, Map<String, List<String>>? reactions}) => ChatMessage(
    envelope: envelope,
    seq: seq ?? this.seq,
    state: state ?? this.state,
    edited: edited,
    reactions: reactions ?? this.reactions,
    replyTo: replyTo,
  );
}

enum ConnectionStatus { connecting, online, offline, updateRequired }

/// The key of a call's audio in one epoch of its conversation's group.
typedef CallKey = ({int epoch, Uint8List key});

import 'dart:typed_data';

import 'package:hanashi_protocol/hanashi_protocol.dart';

import 'models.dart';
import 'packs/sticker_pack.dart';
import 'remote/link_previews.dart';

/// Boundary between the UI and wherever chats come from (mock data now, the
/// server-backed local cache later). All streams emit their current value on
/// listen and again whenever it changes.
abstract interface class ChatRepository {
  /// The signed-in user's ID (`name@host`).
  String get me;

  Stream<List<ConversationSummary>> watchConversations();

  /// Messages of one conversation, oldest first.
  Stream<List<ChatMessage>> watchMessages(String conversationId);

  /// Everyone the user knows about, including the user themself.
  Stream<List<UserProfile>> watchProfiles();

  /// How the user stands with others; those with nothing between them are
  /// left out. Only [ContactState.accepted] ones are their contacts.
  Stream<Map<String, ContactState>> watchContacts();

  /// Asks [userId] to become a contact, which says nothing but who asks, and
  /// returns how the two stand now; if they had asked too, that makes them
  /// contacts. Throws an `ApiException`.
  Future<ContactState> requestContact(String userId);

  /// Says yes to [userId]'s request. Their direct chat starts right after, on
  /// its own (see [openDirectConversation]). Throws an `ApiException`.
  Future<void> acceptContact(String userId);

  /// Says no to [userId]'s request; they are not told.
  Future<void> declineContact(String userId);

  /// Takes the user's request to [userId] back.
  Future<void> cancelContactRequest(String userId);

  /// Stops being contacts, on both sides. Their chat stays, but nothing more
  /// can be sent in it.
  Future<void> removeContact(String userId);

  /// Stops being contacts and keeps [userId] from asking. They see at most the
  /// contact end.
  Future<void> blockContact(String userId);

  Future<void> unblockContact(String userId);

  /// [replyTo] is the ID of the message this one answers; [link] the
  /// preview of a link in [text], made by this device.
  Future<void> sendText(String conversationId, String text, {String? replyTo, LinkPreviewDraft? link});

  /// The largest file the server accepts; null until it is known.
  int? get maxUploadBytes;

  /// Prepares a local file (hash, thumbnail, size) and queues it for sending.
  /// Throws an `AttachmentException` with a user-facing message on failure.
  Future<void> sendAttachment(String conversationId, {required String path, required String name, String? replyTo});

  /// Sends a GIF: a saved one or one from GIF search. Nothing is uploaded:
  /// a saved file is on the server already.
  Future<void> sendGif(String conversationId, GifRef gif, {String? replyTo});

  /// Sends a sticker: the user's own (on the server already), or one of a
  /// pack they keep, named (as the picker gives it) or kept. A pack's goes
  /// as its picture, with the pack beside it for whoever gets it to add
  /// (see [StickerSource]); this device uploads the picture the first time
  /// it sends it. Throws `StickerPackMissing` for one of a pack the user
  /// does not have.
  Future<void> sendSticker(String conversationId, StickerRef sticker, {String? replyTo});

  /// The GIFs the user saved, most recent first; the same on all of their
  /// devices.
  Stream<List<GifRef>> watchSavedGifs();

  /// Saves [gif] (first in the list), or with [saved] false forgets it.
  /// Throws an `ApiException` when offline.
  Future<void> setGifSaved(GifRef gif, bool saved);

  /// The user's stickers, most recent first: ones they made, and any they
  /// kept from chats or the packs; the same on all of their devices.
  Stream<List<StickerRef>> watchSavedStickers();

  /// Keeps [sticker] (first in the list), or with [saved] false lets it go.
  /// One of a pack is kept as its picture, uploaded first if need be, so it
  /// stays when the pack goes. Throws an `ApiException` when offline.
  Future<void> setStickerSaved(StickerRef sticker, bool saved);

  /// The sticker packs the user keeps, in the order the picker shows them;
  /// the same on all of their devices, each [StickerPack.state] as far as it
  /// is on this one.
  Stream<List<StickerPack>> watchStickerPacks();

  /// Adds the pack a sticker someone sent comes from ([source]): fetched,
  /// checked, and kept on the user's own server. A pack of its ID the user
  /// has stays as it is. Throws a `PackageException` for a file that is not
  /// that pack, and an `ApiException` when offline.
  Future<StickerPack> addStickerPack(StickerSource source);

  /// Adds the sticker pack file at [path] (one its maker made, say), kept on
  /// the user's own server. Throws [StickerPackInstalled] when the user has
  /// a pack of its ID, unless [replace]; a `PackageException` for a file
  /// that is not a sticker pack; an `ApiException` when offline.
  Future<StickerPack> importStickerPack(String path, {bool replace = false});

  /// Lets the pack [id] go, on all of the user's devices. Stickers they kept
  /// of it stay. Throws an `ApiException` when offline.
  Future<void> removeStickerPack(String id);

  /// Makes the image at [path] a sticker of the user's own (see
  /// `prepareSticker`): encrypted, uploaded once, and kept first among their
  /// stickers. Throws an `AttachmentException` for an image that cannot be
  /// one, and an `ApiException` when offline.
  Future<StickerRef> makeSticker(String path);

  /// The user's own custom emojis, by name, the same on all of their
  /// devices; with [conversationId], that group's instead.
  Stream<Map<String, MediaRef>> watchEmojis({String? conversationId});

  /// Makes the image at [path] a custom emoji's picture (see `prepareEmoji`),
  /// encrypted and uploaded, for [changeEmojis]. Throws an
  /// `AttachmentException` for an image that cannot be one, and an
  /// `ApiException` when offline.
  Future<MediaRef> uploadEmoji(String path);

  /// Changes the user's own custom emojis or, with [conversationId], that
  /// group's (by a commit, as its name is changed): [change] gets them as
  /// they are and returns them as they are to be. Should another device or
  /// member change them first, it runs again on what that made of them.
  /// Throws `TooManyEmojis` past [CustomEmoji.maxPerSet], and an
  /// `ApiException` when offline.
  Future<void> changeEmojis(
    Map<String, MediaRef> Function(Map<String, MediaRef> current) change, {
    String? conversationId,
  });

  /// The server's KLIPY API key for GIF search; null without one.
  Future<String?> klipyApiKey();

  // Calls (see docs/calls.md)

  /// Whether the server carries voice calls.
  Future<bool> callsAvailable();

  /// Whether calls may carry cameras and shared screens, and chats of two
  /// have video calls.
  Future<bool> videoAvailable();

  /// The calls of the user's conversations, by ID, as the server last said:
  /// going on, or ended lately. One that is missing is unknown, not ended.
  Stream<Map<String, Call>> watchCalls();

  /// Joins a conversation's call, or starts one; the chat then gets its
  /// record (a `call` message). Throws an `ApiException` when offline, or
  /// when the server refuses (no calls, `calls_unavailable` with people of
  /// other servers, `not_a_contact`).
  ///
  /// With [video], one it starts is a video call.
  Future<CallJoin> joinCall(String conversationId, {bool video = false});

  /// What a push told of a call: taken like the server's other word of it,
  /// unless that was newer.
  void noteCall(Call call);

  /// Says no to a call of two that rings the user.
  Future<void> declineCall(String callId);

  /// Hangs this device up.
  Future<void> leaveCall(String callId);

  /// The key of a call's audio at each epoch of its conversation's group,
  /// as it moves on: the current one first. Null while there is none (the
  /// group is not here, or this device's own change of it is not settled);
  /// for good once the group is gone.
  Stream<CallKey?> watchCallKeys(String conversationId, String callId);

  /// Adds [emoji] to the user's reactions to a message (there can be
  /// several), or with [remove] takes it back.
  Future<void> react(String messageId, String emoji, {bool remove = false});

  /// Changes the text of one of the user's own messages, for everyone.
  Future<void> editMessage(String messageId, String text);

  /// Deletes one of the user's own messages, for everyone.
  Future<void> deleteMessage(String messageId);

  /// Changes the user's display name. Throws an `ApiException` when offline.
  Future<void> setDisplayName(String name);

  /// Sets the user's profile picture from an image file, or removes it with
  /// null. The picture is encrypted: only the people the user chats with can
  /// read it. Throws an `AttachmentException` or `ApiException`.
  Future<void> setAvatar(String? path);

  /// Sets what the user tells about themself besides name and picture (see
  /// [ProfileCard]): end-to-end encrypted like the picture. Throws an
  /// `ApiException` when offline.
  Future<void> setProfileCard(ProfileCard card);

  /// The user's settings for each chat (see [ChatSettings]), the same on all
  /// of their devices; chats without any are left out.
  Stream<Map<String, ChatSettings>> watchChatSettings();

  /// Changes the user's settings for one chat, end-to-end encrypted for
  /// their own devices. Throws an `ApiException` when offline.
  Future<void> setChatSettings(String conversationId, ChatSettings settings);

  /// The status of everyone the user shares a chat with, the user included,
  /// as last heard; anyone missing is offline.
  Stream<Map<String, Presence>> watchPresence();

  /// How the user chose to appear.
  Stream<PresenceMode> watchPresenceMode();

  /// Throws an `ApiException` when offline.
  Future<void> setPresenceMode(PresenceMode mode);

  /// Whether the user is using this device: others see them idle once none
  /// of their devices is in use.
  void setActive(bool active);

  /// Sets a group's picture from an image file, or removes it with null. It
  /// is end-to-end encrypted like the user's own: only the members get its
  /// key. Throws an `AttachmentException` or `ApiException`.
  Future<void> setGroupPicture(String conversationId, String? path);

  /// [media] decrypted into memory, downloaded first if need be; null when
  /// media is unavailable (demo data). For pictures and other small files:
  /// the cache keeps media encrypted, and nothing decrypted is written.
  Future<Uint8List?> mediaBytes(MediaRef media, {void Function(double progress)? onProgress});

  /// [media] decrypted, if this device has it; never downloads.
  Future<Uint8List?> localMediaBytes(MediaRef media);

  /// [media] for a player, decrypted as it plays (see `EncryptedMediaStream`),
  /// downloaded first if need be; null when media is unavailable.
  Future<PlayableMedia?> playableMedia(MediaRef media, {void Function(double progress)? onProgress});

  /// Saves [media] decrypted as [path], downloading it first if need be;
  /// false when media is unavailable.
  Future<bool> saveMedia(MediaRef media, String path, {void Function(double progress)? onProgress});

  /// Users whose security key changed and who the user has not reviewed yet.
  Stream<Set<String>> watchIdentityChanges();

  /// Contacts the user verified by comparing emoji (and whose key has not
  /// changed since).
  Stream<Set<String>> watchVerifiedUsers();

  /// Trusts [userId]'s new security key.
  Future<void> acceptIdentityChange(String userId);

  /// Marks everything currently in the conversation as read.
  Future<void> markRead(String conversationId);

  /// Returns the direct conversation with [userId], a contact, starting it if
  /// there is none: being contacts and having a chat are not the same. Throws
  /// a [StateError] with a user-facing message if they are not a contact, or
  /// cannot be added to a chat, or an `ApiException`.
  Future<String> openDirectConversation(String userId);

  /// Creates a group with [members] (besides the user); returns its ID.
  /// Throws a [StateError] with a user-facing message if a member has not
  /// set up encryption yet.
  Future<String> createGroup(String title, List<String> members);

  /// Adds [userId] to a group; throws like [createGroup]. With
  /// [shareHistory], they get the keys to the messages from before.
  Future<void> addMember(String conversationId, String userId, {bool shareHistory = true});

  Future<void> renameGroup(String conversationId, String title);

  /// Sets what a group is about, or removes it with null. End-to-end
  /// encrypted like its name.
  Future<void> setGroupDescription(String conversationId, String? description);

  /// Leaves a group; it disappears from all of the user's devices.
  Future<void> leaveGroup(String conversationId);

  /// Tells the others that the user is typing (sent at most every few seconds).
  void sendTyping(String conversationId);

  /// Who else is typing in the conversation right now.
  Stream<Set<String>> watchTyping(String conversationId);

  /// Fetches older messages of a conversation, if the server has any that
  /// are not stored locally yet.
  Future<void> loadOlderMessages(String conversationId);

  /// Puts a failed message back into the outbox.
  Future<void> retry(String messageId);

  /// Removes a message that was never delivered.
  Future<void> discard(String messageId);

  Stream<ConnectionStatus> watchConnection();

  /// Why the app is not online, if it knows (the server cannot be reached,
  /// or syncing after connecting failed); null otherwise.
  Stream<String?> watchConnectionProblem();

  /// The devices the user is signed in on.
  Future<List<DeviceInfo>> devices();

  /// Signs another device out.
  Future<void> revokeDevice(String deviceId);
}

/// Where a player finds media ([uri]: a file, or a stream on this device),
/// and what to call once it is done with it.
typedef PlayableMedia = ({String uri, Future<void> Function()? close});

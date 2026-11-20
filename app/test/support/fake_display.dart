import 'package:hanashi/notifications/notification_center.dart';

/// Records what would be shown.
class FakeDisplay implements NotificationDisplay {
  final shown = <ChatNotification>[];
  final active = <String, ChatNotification>{};
  final contacts = <ContactNotification>[];
  final activeContacts = <String, ContactNotification>{};

  @override
  Future<void> show(ChatNotification notification) async {
    shown.add(notification);
    active[notification.conversationId] = notification;
  }

  @override
  Future<void> cancel(String conversationId) async => active.remove(conversationId);

  @override
  Future<void> showContact(ContactNotification notification) async {
    contacts.add(notification);
    activeContacts[notification.userId] = notification;
  }

  @override
  Future<void> cancelContact(String userId) async => activeContacts.remove(userId);

  @override
  Future<void> cancelAll() async {
    active.clear();
    activeContacts.clear();
  }

  @override
  Future<bool> requestPermission() async => true;
}

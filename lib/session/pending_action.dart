import '../protocol/ids.dart';

enum PendingActionStatus { queued, sent, acknowledged, rejected, unknown }

final class PendingAction {
  PendingAction({
    required this.messageId,
    required this.actionId,
    required this.strokeId,
    required this.actionKind,
    required this.chunkIndex,
    required this.sentAt,
  });

  final MessageId messageId;
  final ActionId actionId;
  final StrokeId strokeId;
  final String actionKind;
  final int? chunkIndex;
  final DateTime sentAt;

  PendingActionStatus status = PendingActionStatus.queued;
  List<EventId> generatedEventIds = const <EventId>[];
  String? failureMessage;

  void markSent() {
    if (status == PendingActionStatus.queued) {
      status = PendingActionStatus.sent;
    }
  }

  void acknowledge(List<EventId> eventIds) {
    status = PendingActionStatus.acknowledged;
    generatedEventIds = List<EventId>.unmodifiable(eventIds);
    failureMessage = null;
  }

  void reject(String message) {
    status = PendingActionStatus.rejected;
    failureMessage = message;
  }

  void markUnknown() {
    if (status == PendingActionStatus.queued ||
        status == PendingActionStatus.sent) {
      status = PendingActionStatus.unknown;
    }
  }
}

final class ActionFailure {
  const ActionFailure({required this.action, required this.safeMessage});

  final PendingAction action;
  final String safeMessage;
}

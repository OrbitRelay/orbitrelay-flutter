enum OrbitRelayConnectionState {
  disconnected,
  connecting,
  negotiating,
  authenticating,
  subscribing,
  ready,
  closing,
  failed,
}

extension OrbitRelayConnectionStateLabel on OrbitRelayConnectionState {
  String get label => switch (this) {
    OrbitRelayConnectionState.disconnected => 'Disconnected',
    OrbitRelayConnectionState.connecting => 'Connecting',
    OrbitRelayConnectionState.negotiating => 'Negotiating protocol',
    OrbitRelayConnectionState.authenticating => 'Authenticating',
    OrbitRelayConnectionState.subscribing => 'Subscribing',
    OrbitRelayConnectionState.ready => 'Realtime',
    OrbitRelayConnectionState.closing => 'Closing',
    OrbitRelayConnectionState.failed => 'Connection failed',
  };
}

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../events.dart';
import '../exceptions.dart';
import '../extensions.dart';
import '../internal/events.dart';
import '../logger.dart';
import '../managers/event.dart';
import '../options.dart';
import '../proto/livekit_models.pb.dart' as lk_models;
import '../proto/livekit_rtc.pb.dart' as lk_rtc;
import '../support/disposable.dart';
import '../support/websocket.dart';
import '../types.dart';
import '../utils.dart';

class SignalClient extends Disposable with EventsEmittable<SignalEvent> {
  // Connection state of the socket conection.
  ConnectionState _connectionState = ConnectionState.disconnected;

  final WebSocketConnector _wsConnector;
  LiveKitWebSocket? _ws;

  @internal
  SignalClient(WebSocketConnector wsConnector) : _wsConnector = wsConnector {
    events.listen((event) {
      logger.fine('[SignalEvent] $event');
    });

    onDispose(() async {
      await events.dispose();
      await _cleanUp();
    });
  }

  @internal
  Future<void> connect(
    String uriString,
    String token, {
    ConnectOptions? connectOptions,
    bool reconnect = false,
  }) async {
    final rtcUri = await Utils.buildUri(
      uriString,
      token: token,
      connectOptions: connectOptions,
      reconnect: reconnect,
    );

    logger.fine('SignalClient connecting with url: $rtcUri');

    try {
      _updateConnectionState(reconnect
          ? ConnectionState.reconnecting
          : ConnectionState.connecting);
      // Clean up existing socket
      await _cleanUp();
      // Attempt to connect
      _ws = await _wsConnector(
        rtcUri,
        WebSocketEventHandlers(
          onData: _onSocketData,
          onDispose: _onSocketDispose,
          onError: _handleError,
        ),
      );
      // Successful connection
      _updateConnectionState(ConnectionState.connected);
    } catch (socketError) {
      // Attempt Validation
      try {
        // Skip validation if reconnect mode
        if (reconnect) rethrow;

        // Re-build same uri for validate mode
        final validateUri = await Utils.buildUri(
          uriString,
          token: token,
          connectOptions: connectOptions,
          validate: true,
          forceSecure: rtcUri.isSecureScheme,
        );

        final validateResponse = await http.get(validateUri);
        if (validateResponse.statusCode != 200) {
          throw ConnectException(validateResponse.body);
        }
        throw ConnectException();
      } catch (error) {
        // Pass it up if it's already a `ConnectError`
        if (error is ConnectException) rethrow;
        // HTTP doesn't work either
        throw ConnectException();
      } finally {
        _updateConnectionState(ConnectionState.disconnected);
        rethrow;
      }
    }
  }

  Future<void> _cleanUp() async {
    await _ws?.dispose();
    _ws = null;
  }

  @internal
  Future<void> disconnect() async {
    logger.fine('SignalClient disconnect');
    await _cleanUp();
  }

  void _sendRequest(lk_rtc.SignalRequest req) {
    if (_ws == null || isDisposed) {
      logger.warning(
          '[$objectId] Could not send message, not connected or already disposed');
      return;
    }

    final buf = req.writeToBuffer();
    _ws?.send(buf);
  }

  void _updateConnectionState(ConnectionState newValue) {
    if (_connectionState == newValue) return;

    logger.fine('SignalClient ConnectionState '
        '${_connectionState.name} -> ${newValue.name}');

    bool didReconnect = _connectionState == ConnectionState.reconnecting &&
        newValue == ConnectionState.connected;

    _connectionState = newValue;

    events.emit(SignalConnectionStateUpdatedEvent(
      connectionState: _connectionState,
      didReconnect: didReconnect,
    ));
  }

  Future<void> _onSocketData(dynamic message) async {
    if (message is! List<int>) return;
    final msg = lk_rtc.SignalResponse.fromBuffer(message);

    switch (msg.whichMessage()) {
      case lk_rtc.SignalResponse_Message.join:
        events.emit(SignalJoinResponseEvent(response: msg.join));
        break;
      case lk_rtc.SignalResponse_Message.answer:
        events.emit(SignalAnswerEvent(sd: msg.answer.toSDKType()));
        break;
      case lk_rtc.SignalResponse_Message.offer:
        events.emit(SignalOfferEvent(sd: msg.offer.toSDKType()));
        break;
      case lk_rtc.SignalResponse_Message.trickle:
        events.emit(SignalTrickleEvent(
          candidate: RTCIceCandidateExt.fromJson(msg.trickle.candidateInit),
          target: msg.trickle.target,
        ));
        break;
      case lk_rtc.SignalResponse_Message.update:
        events.emit(SignalParticipantUpdateEvent(
            participants: msg.update.participants));
        break;
      case lk_rtc.SignalResponse_Message.trackPublished:
        events.emit(SignalLocalTrackPublishedEvent(
          cid: msg.trackPublished.cid,
          track: msg.trackPublished.track,
        ));
        break;
      case lk_rtc.SignalResponse_Message.speakersChanged:
        events.emit(
            SignalSpeakersChangedEvent(speakers: msg.speakersChanged.speakers));
        break;
      case lk_rtc.SignalResponse_Message.roomUpdate:
        events.emit(SignalRoomUpdateEvent(room: msg.roomUpdate.room));
        break;
      case lk_rtc.SignalResponse_Message.connectionQuality:
        events.emit(SignalConnectionQualityUpdateEvent(
          updates: msg.connectionQuality.updates,
        ));
        break;
      case lk_rtc.SignalResponse_Message.leave:
        events.emit(SignalLeaveEvent(canReconnect: msg.leave.canReconnect));
        break;
      case lk_rtc.SignalResponse_Message.mute:
        events.emit(SignalMuteTrackEvent(
          sid: msg.mute.sid,
          muted: msg.mute.muted,
        ));
        break;
      case lk_rtc.SignalResponse_Message.streamStateUpdate:
        events.emit(SignalStreamStateUpdatedEvent(
          updates: msg.streamStateUpdate.streamStates,
        ));
        break;
      case lk_rtc.SignalResponse_Message.subscribedQualityUpdate:
        events.emit(SignalSubscribedQualityUpdatedEvent(
          trackSid: msg.subscribedQualityUpdate.trackSid,
          updates: msg.subscribedQualityUpdate.subscribedQualities,
        ));
        break;
      case lk_rtc.SignalResponse_Message.subscriptionPermissionUpdate:
        events.emit(SignalSubscriptionPermissionUpdateEvent(
          participantSid: msg.subscriptionPermissionUpdate.participantSid,
          trackSid: msg.subscriptionPermissionUpdate.trackSid,
          allowed: msg.subscriptionPermissionUpdate.allowed,
        ));
        break;
      case lk_rtc.SignalResponse_Message.refreshToken:
        events.emit(SignalTokenUpdatedEvent(token: msg.refreshToken));
        break;
      case lk_rtc.SignalResponse_Message.notSet:
        logger.info('signal message not set');
        break;
    }
  }

  void _handleError(dynamic error) {
    logger.warning('received websocket error $error');
  }

  void _onSocketDispose() {
    logger.fine('SignalClient onSocketDispose $_connectionState');
    // don't emit event's when reconnecting state
    if (_connectionState != ConnectionState.reconnecting) {
      logger.fine('SignalClient did disconnect ${_connectionState}');
      _updateConnectionState(ConnectionState.disconnected);
    }
  }
}

extension SignalClientRequests on SignalClient {
  @internal
  void sendOffer(rtc.RTCSessionDescription offer) =>
      _sendRequest(lk_rtc.SignalRequest(
        offer: offer.toPBType(),
      ));

  @internal
  void sendAnswer(rtc.RTCSessionDescription answer) =>
      _sendRequest(lk_rtc.SignalRequest(
        answer: answer.toPBType(),
      ));

  @internal
  void sendIceCandidate(
          rtc.RTCIceCandidate candidate, lk_rtc.SignalTarget target) =>
      _sendRequest(
        lk_rtc.SignalRequest(
          trickle: lk_rtc.TrickleRequest(
            candidateInit: candidate.toJson(),
            target: target,
          ),
        ),
      );

  @internal
  void sendMuteTrack(String trackSid, bool muted) =>
      _sendRequest(lk_rtc.SignalRequest(
        mute: lk_rtc.MuteTrackRequest(
          sid: trackSid,
          muted: muted,
        ),
      ));

  @internal
  void sendAddTrack({
    required String cid,
    required String name,
    required lk_models.TrackType type,
    required lk_models.TrackSource source,
    VideoDimensions? dimensions,
    bool? dtx,
    Iterable<lk_models.VideoLayer>? videoLayers,
  }) {
    final req = lk_rtc.AddTrackRequest(
      cid: cid,
      name: name,
      type: type,
      source: source,
    );

    if (type == lk_models.TrackType.VIDEO) {
      // video specific
      if (dimensions != null) {
        req.width = dimensions.width;
        req.height = dimensions.height;
      }
      if (videoLayers != null && videoLayers.isNotEmpty) {
        req.layers
          ..clear()
          ..addAll(videoLayers);
      }
    }

    if (type == lk_models.TrackType.AUDIO && dtx != null) {
      // audio specific
      req.disableDtx = !dtx;
    }

    _sendRequest(lk_rtc.SignalRequest(
      addTrack: req,
    ));
  }

  @internal
  void sendUpdateTrackSettings(lk_rtc.UpdateTrackSettings settings) =>
      _sendRequest(lk_rtc.SignalRequest(
        trackSetting: settings,
      ));

  @internal
  void sendUpdateSubscription(lk_rtc.UpdateSubscription subscription) =>
      _sendRequest(lk_rtc.SignalRequest(
        subscription: subscription,
      ));

  @internal
  void sendUpdateVideoLayers(
    String trackSid,
    Iterable<lk_models.VideoLayer> layers,
  ) =>
      _sendRequest(lk_rtc.SignalRequest(
        updateLayers: lk_rtc.UpdateVideoLayers(
          trackSid: trackSid,
          layers: layers,
        ),
      ));

  @internal
  void sendUpdateSubscriptionPermissions({
    required bool allParticipants,
    required Iterable<lk_rtc.TrackPermission> trackPermissions,
  }) =>
      _sendRequest(lk_rtc.SignalRequest(
        subscriptionPermission: lk_rtc.SubscriptionPermission(
          allParticipants: allParticipants,
          trackPermissions: trackPermissions,
        ),
      ));

  @internal
  void sendLeave() => _sendRequest(lk_rtc.SignalRequest(
        leave: lk_rtc.LeaveRequest(),
      ));

  @internal
  void sendSyncState({
    required lk_rtc.SessionDescription? answer,
    required lk_rtc.UpdateSubscription subscription,
    required Iterable<lk_rtc.TrackPublishedResponse>? publishTracks,
  }) =>
      _sendRequest(lk_rtc.SignalRequest(
        syncState: lk_rtc.SyncState(
          answer: answer,
          subscription: subscription,
          publishTracks: publishTracks,
        ),
      ));

  @internal
  void sendSimulateScenario({
    int? speakerUpdate,
    bool? nodeFailure,
    bool? migration,
    bool? serverLeave,
  }) =>
      _sendRequest(lk_rtc.SignalRequest(
        simulate: lk_rtc.SimulateScenario(
          speakerUpdate: speakerUpdate,
          nodeFailure: nodeFailure,
          migration: migration,
          serverLeave: serverLeave,
        ),
      ));
}

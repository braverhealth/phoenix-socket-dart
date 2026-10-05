//
//  Generated code. Do not modify.
//  source: exchange.proto
//
// @dart = 2.12

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_final_fields
// ignore_for_file: unnecessary_import, unnecessary_this, unused_import

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

class EchoRequest extends $pb.GeneratedMessage {
  factory EchoRequest({
    $core.String? text,
  }) {
    final $result = create();
    if (text != null) {
      $result.text = text;
    }
    return $result;
  }
  EchoRequest._() : super();
  factory EchoRequest.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory EchoRequest.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'EchoRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'phoenix_example'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'text')
    ..hasRequiredFields = false;

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  EchoRequest clone() => EchoRequest()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  EchoRequest copyWith(void Function(EchoRequest) updates) =>
      super.copyWith((message) => updates(message as EchoRequest))
          as EchoRequest;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static EchoRequest create() => EchoRequest._();
  EchoRequest createEmptyInstance() => create();
  static $pb.PbList<EchoRequest> createRepeated() => $pb.PbList<EchoRequest>();
  @$core.pragma('dart2js:noInline')
  static EchoRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<EchoRequest>(create);
  static EchoRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get text => $_getSZ(0);
  @$pb.TagNumber(1)
  set text($core.String v) {
    $_setString(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasText() => $_has(0);
  @$pb.TagNumber(1)
  void clearText() => clearField(1);
}

class EchoReply extends $pb.GeneratedMessage {
  factory EchoReply({
    $core.String? text,
  }) {
    final $result = create();
    if (text != null) {
      $result.text = text;
    }
    return $result;
  }
  EchoReply._() : super();
  factory EchoReply.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory EchoReply.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'EchoReply',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'phoenix_example'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'text')
    ..hasRequiredFields = false;

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  EchoReply clone() => EchoReply()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  EchoReply copyWith(void Function(EchoReply) updates) =>
      super.copyWith((message) => updates(message as EchoReply)) as EchoReply;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static EchoReply create() => EchoReply._();
  EchoReply createEmptyInstance() => create();
  static $pb.PbList<EchoReply> createRepeated() => $pb.PbList<EchoReply>();
  @$core.pragma('dart2js:noInline')
  static EchoReply getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<EchoReply>(create);
  static EchoReply? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get text => $_getSZ(0);
  @$pb.TagNumber(1)
  set text($core.String v) {
    $_setString(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasText() => $_has(0);
  @$pb.TagNumber(1)
  void clearText() => clearField(1);
}

enum Envelope_Payload { jsonPayload, binaryPayload, binaryResponse, notSet }

/// An application-defined envelope, not Phoenix's standard binary framing.
class Envelope extends $pb.GeneratedMessage {
  factory Envelope({
    $core.String? joinRef,
    $core.String? ref,
    $core.String? topic,
    $core.String? event,
    $core.String? jsonPayload,
    $core.List<$core.int>? binaryPayload,
    $core.List<$core.int>? binaryResponse,
    $core.String? replyStatus,
  }) {
    final $result = create();
    if (joinRef != null) {
      $result.joinRef = joinRef;
    }
    if (ref != null) {
      $result.ref = ref;
    }
    if (topic != null) {
      $result.topic = topic;
    }
    if (event != null) {
      $result.event = event;
    }
    if (jsonPayload != null) {
      $result.jsonPayload = jsonPayload;
    }
    if (binaryPayload != null) {
      $result.binaryPayload = binaryPayload;
    }
    if (binaryResponse != null) {
      $result.binaryResponse = binaryResponse;
    }
    if (replyStatus != null) {
      $result.replyStatus = replyStatus;
    }
    return $result;
  }
  Envelope._() : super();
  factory Envelope.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory Envelope.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static const $core.Map<$core.int, Envelope_Payload> _Envelope_PayloadByTag = {
    5: Envelope_Payload.jsonPayload,
    6: Envelope_Payload.binaryPayload,
    7: Envelope_Payload.binaryResponse,
    0: Envelope_Payload.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Envelope',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'phoenix_example'),
      createEmptyInstance: create)
    ..oo(0, [5, 6, 7])
    ..aOS(1, _omitFieldNames ? '' : 'joinRef')
    ..aOS(2, _omitFieldNames ? '' : 'ref')
    ..aOS(3, _omitFieldNames ? '' : 'topic')
    ..aOS(4, _omitFieldNames ? '' : 'event')
    ..aOS(5, _omitFieldNames ? '' : 'jsonPayload')
    ..a<$core.List<$core.int>>(
        6, _omitFieldNames ? '' : 'binaryPayload', $pb.PbFieldType.OY)
    ..a<$core.List<$core.int>>(
        7, _omitFieldNames ? '' : 'binaryResponse', $pb.PbFieldType.OY)
    ..aOS(8, _omitFieldNames ? '' : 'replyStatus')
    ..hasRequiredFields = false;

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  Envelope clone() => Envelope()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  Envelope copyWith(void Function(Envelope) updates) =>
      super.copyWith((message) => updates(message as Envelope)) as Envelope;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static Envelope create() => Envelope._();
  Envelope createEmptyInstance() => create();
  static $pb.PbList<Envelope> createRepeated() => $pb.PbList<Envelope>();
  @$core.pragma('dart2js:noInline')
  static Envelope getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Envelope>(create);
  static Envelope? _defaultInstance;

  Envelope_Payload whichPayload() => _Envelope_PayloadByTag[$_whichOneof(0)]!;
  void clearPayload() => clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  $core.String get joinRef => $_getSZ(0);
  @$pb.TagNumber(1)
  set joinRef($core.String v) {
    $_setString(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasJoinRef() => $_has(0);
  @$pb.TagNumber(1)
  void clearJoinRef() => clearField(1);

  @$pb.TagNumber(2)
  $core.String get ref => $_getSZ(1);
  @$pb.TagNumber(2)
  set ref($core.String v) {
    $_setString(1, v);
  }

  @$pb.TagNumber(2)
  $core.bool hasRef() => $_has(1);
  @$pb.TagNumber(2)
  void clearRef() => clearField(2);

  @$pb.TagNumber(3)
  $core.String get topic => $_getSZ(2);
  @$pb.TagNumber(3)
  set topic($core.String v) {
    $_setString(2, v);
  }

  @$pb.TagNumber(3)
  $core.bool hasTopic() => $_has(2);
  @$pb.TagNumber(3)
  void clearTopic() => clearField(3);

  @$pb.TagNumber(4)
  $core.String get event => $_getSZ(3);
  @$pb.TagNumber(4)
  set event($core.String v) {
    $_setString(3, v);
  }

  @$pb.TagNumber(4)
  $core.bool hasEvent() => $_has(3);
  @$pb.TagNumber(4)
  void clearEvent() => clearField(4);

  @$pb.TagNumber(5)
  $core.String get jsonPayload => $_getSZ(4);
  @$pb.TagNumber(5)
  set jsonPayload($core.String v) {
    $_setString(4, v);
  }

  @$pb.TagNumber(5)
  $core.bool hasJsonPayload() => $_has(4);
  @$pb.TagNumber(5)
  void clearJsonPayload() => clearField(5);

  @$pb.TagNumber(6)
  $core.List<$core.int> get binaryPayload => $_getN(5);
  @$pb.TagNumber(6)
  set binaryPayload($core.List<$core.int> v) {
    $_setBytes(5, v);
  }

  @$pb.TagNumber(6)
  $core.bool hasBinaryPayload() => $_has(5);
  @$pb.TagNumber(6)
  void clearBinaryPayload() => clearField(6);

  @$pb.TagNumber(7)
  $core.List<$core.int> get binaryResponse => $_getN(6);
  @$pb.TagNumber(7)
  set binaryResponse($core.List<$core.int> v) {
    $_setBytes(6, v);
  }

  @$pb.TagNumber(7)
  $core.bool hasBinaryResponse() => $_has(6);
  @$pb.TagNumber(7)
  void clearBinaryResponse() => clearField(7);

  @$pb.TagNumber(8)
  $core.String get replyStatus => $_getSZ(7);
  @$pb.TagNumber(8)
  set replyStatus($core.String v) {
    $_setString(7, v);
  }

  @$pb.TagNumber(8)
  $core.bool hasReplyStatus() => $_has(7);
  @$pb.TagNumber(8)
  void clearReplyStatus() => clearField(8);
}

const _omitFieldNames = $core.bool.fromEnvironment('protobuf.omit_field_names');
const _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');

//
//  Generated code. Do not modify.
//  source: exchange.proto
//
// @dart = 2.12

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_final_fields
// ignore_for_file: unnecessary_import, unnecessary_this, unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use echoRequestDescriptor instead')
const EchoRequest$json = {
  '1': 'EchoRequest',
  '2': [
    {'1': 'text', '3': 1, '4': 1, '5': 9, '10': 'text'},
  ],
};

/// Descriptor for `EchoRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List echoRequestDescriptor =
    $convert.base64Decode('CgtFY2hvUmVxdWVzdBISCgR0ZXh0GAEgASgJUgR0ZXh0');

@$core.Deprecated('Use echoReplyDescriptor instead')
const EchoReply$json = {
  '1': 'EchoReply',
  '2': [
    {'1': 'text', '3': 1, '4': 1, '5': 9, '10': 'text'},
  ],
};

/// Descriptor for `EchoReply`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List echoReplyDescriptor =
    $convert.base64Decode('CglFY2hvUmVwbHkSEgoEdGV4dBgBIAEoCVIEdGV4dA==');

@$core.Deprecated('Use envelopeDescriptor instead')
const Envelope$json = {
  '1': 'Envelope',
  '2': [
    {
      '1': 'join_ref',
      '3': 1,
      '4': 1,
      '5': 9,
      '9': 1,
      '10': 'joinRef',
      '17': true
    },
    {'1': 'ref', '3': 2, '4': 1, '5': 9, '9': 2, '10': 'ref', '17': true},
    {'1': 'topic', '3': 3, '4': 1, '5': 9, '9': 3, '10': 'topic', '17': true},
    {'1': 'event', '3': 4, '4': 1, '5': 9, '10': 'event'},
    {'1': 'json_payload', '3': 5, '4': 1, '5': 9, '9': 0, '10': 'jsonPayload'},
    {
      '1': 'binary_payload',
      '3': 6,
      '4': 1,
      '5': 12,
      '9': 0,
      '10': 'binaryPayload'
    },
    {
      '1': 'binary_response',
      '3': 7,
      '4': 1,
      '5': 12,
      '9': 0,
      '10': 'binaryResponse'
    },
    {
      '1': 'reply_status',
      '3': 8,
      '4': 1,
      '5': 9,
      '9': 4,
      '10': 'replyStatus',
      '17': true
    },
  ],
  '8': [
    {'1': 'payload'},
    {'1': '_join_ref'},
    {'1': '_ref'},
    {'1': '_topic'},
    {'1': '_reply_status'},
  ],
};

/// Descriptor for `Envelope`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List envelopeDescriptor = $convert.base64Decode(
    'CghFbnZlbG9wZRIeCghqb2luX3JlZhgBIAEoCUgBUgdqb2luUmVmiAEBEhUKA3JlZhgCIAEoCU'
    'gCUgNyZWaIAQESGQoFdG9waWMYAyABKAlIA1IFdG9waWOIAQESFAoFZXZlbnQYBCABKAlSBWV2'
    'ZW50EiMKDGpzb25fcGF5bG9hZBgFIAEoCUgAUgtqc29uUGF5bG9hZBInCg5iaW5hcnlfcGF5bG'
    '9hZBgGIAEoDEgAUg1iaW5hcnlQYXlsb2FkEikKD2JpbmFyeV9yZXNwb25zZRgHIAEoDEgAUg5i'
    'aW5hcnlSZXNwb25zZRImCgxyZXBseV9zdGF0dXMYCCABKAlIBFILcmVwbHlTdGF0dXOIAQFCCQ'
    'oHcGF5bG9hZEILCglfam9pbl9yZWZCBgoEX3JlZkIICgZfdG9waWNCDwoNX3JlcGx5X3N0YXR1'
    'cw==');

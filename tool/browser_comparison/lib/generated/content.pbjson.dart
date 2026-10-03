//
//  Generated code. Do not modify.
//  source: content.proto
//
// @dart = 2.12

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_final_fields
// ignore_for_file: unnecessary_import, unnecessary_this, unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use contentDescriptor instead')
const Content$json = {
  '1': 'Content',
  '2': [
    {'1': 'text', '3': 1, '4': 1, '5': 9, '10': 'text'},
    {
      '1': 'records',
      '3': 2,
      '4': 3,
      '5': 11,
      '6': '.benchmark.Record',
      '10': 'records'
    },
    {'1': 'numbers', '3': 3, '4': 3, '5': 17, '10': 'numbers'},
    {'1': 'bytes', '3': 4, '4': 1, '5': 12, '10': 'bytes'},
  ],
};

/// Descriptor for `Content`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List contentDescriptor = $convert.base64Decode(
    'CgdDb250ZW50EhIKBHRleHQYASABKAlSBHRleHQSKwoHcmVjb3JkcxgCIAMoCzIRLmJlbmNobW'
    'Fyay5SZWNvcmRSB3JlY29yZHMSGAoHbnVtYmVycxgDIAMoEVIHbnVtYmVycxIUCgVieXRlcxgE'
    'IAEoDFIFYnl0ZXM=');

@$core.Deprecated('Use recordDescriptor instead')
const Record$json = {
  '1': 'Record',
  '2': [
    {'1': 'id', '3': 1, '4': 1, '5': 13, '10': 'id'},
    {'1': 'name', '3': 2, '4': 1, '5': 9, '10': 'name'},
    {'1': 'active', '3': 3, '4': 1, '5': 8, '10': 'active'},
    {'1': 'score', '3': 4, '4': 1, '5': 1, '10': 'score'},
    {'1': 'tags', '3': 5, '4': 3, '5': 9, '10': 'tags'},
    {
      '1': 'detail',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.benchmark.Detail',
      '10': 'detail'
    },
  ],
};

/// Descriptor for `Record`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List recordDescriptor = $convert.base64Decode(
    'CgZSZWNvcmQSDgoCaWQYASABKA1SAmlkEhIKBG5hbWUYAiABKAlSBG5hbWUSFgoGYWN0aXZlGA'
    'MgASgIUgZhY3RpdmUSFAoFc2NvcmUYBCABKAFSBXNjb3JlEhIKBHRhZ3MYBSADKAlSBHRhZ3MS'
    'KQoGZGV0YWlsGAYgASgLMhEuYmVuY2htYXJrLkRldGFpbFIGZGV0YWls');

@$core.Deprecated('Use detailDescriptor instead')
const Detail$json = {
  '1': 'Detail',
  '2': [
    {'1': 'note', '3': 1, '4': 1, '5': 9, '10': 'note'},
    {'1': 'values', '3': 2, '4': 3, '5': 17, '10': 'values'},
    {
      '1': 'attributes',
      '3': 3,
      '4': 3,
      '5': 11,
      '6': '.benchmark.Attribute',
      '10': 'attributes'
    },
  ],
};

/// Descriptor for `Detail`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List detailDescriptor = $convert.base64Decode(
    'CgZEZXRhaWwSEgoEbm90ZRgBIAEoCVIEbm90ZRIWCgZ2YWx1ZXMYAiADKBFSBnZhbHVlcxI0Cg'
    'phdHRyaWJ1dGVzGAMgAygLMhQuYmVuY2htYXJrLkF0dHJpYnV0ZVIKYXR0cmlidXRlcw==');

@$core.Deprecated('Use attributeDescriptor instead')
const Attribute$json = {
  '1': 'Attribute',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 9, '10': 'value'},
  ],
};

/// Descriptor for `Attribute`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List attributeDescriptor = $convert.base64Decode(
    'CglBdHRyaWJ1dGUSEAoDa2V5GAEgASgJUgNrZXkSFAoFdmFsdWUYAiABKAlSBXZhbHVl');

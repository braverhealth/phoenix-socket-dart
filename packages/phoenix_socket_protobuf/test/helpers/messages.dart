import 'package:protobuf/protobuf.dart';

// Minimal wire schemas exercise the runtime across protobuf versions without
// depending on version-specific generated helpers. The repository's protobuf
// example additionally tests the adapter with real generated application types.
abstract class _WireFixture extends GeneratedMessage {
  @override
  GeneratedMessage clone() => createEmptyInstance()..mergeFromMessage(this);
}

class Request extends _WireFixture {
  Request({String? text}) {
    if (text != null) this.text = text;
  }

  Request.fromBuffer(List<int> bytes) {
    mergeFromBuffer(bytes);
  }

  static final _info = BuilderInfo('Request', createEmptyInstance: Request.new)
    ..aOS(1, 'text')
    ..hasRequiredFields = false;

  @override
  BuilderInfo get info_ => _info;

  @override
  Request createEmptyInstance() => Request();

  String get text => $_getSZ(0);
  set text(String value) => $_setString(0, value);
}

class Reply extends _WireFixture {
  Reply({String? text}) {
    if (text != null) this.text = text;
  }

  Reply.fromBuffer(List<int> bytes) {
    mergeFromBuffer(bytes);
  }

  static final _info = BuilderInfo('Reply', createEmptyInstance: Reply.new)
    ..aOS(1, 'text')
    ..hasRequiredFields = false;

  @override
  BuilderInfo get info_ => _info;

  @override
  Reply createEmptyInstance() => Reply();

  String get text => $_getSZ(0);
  set text(String value) => $_setString(0, value);
}

class Update extends _WireFixture {
  Update({String? id}) {
    if (id != null) this.id = id;
  }

  Update.fromBuffer(List<int> bytes) {
    mergeFromBuffer(bytes);
  }

  static final _info = BuilderInfo('Update', createEmptyInstance: Update.new)
    ..aOS(2, 'id')
    ..hasRequiredFields = false;

  @override
  BuilderInfo get info_ => _info;

  @override
  Update createEmptyInstance() => Update();

  String get id => $_getSZ(0);
  set id(String value) => $_setString(0, value);
}

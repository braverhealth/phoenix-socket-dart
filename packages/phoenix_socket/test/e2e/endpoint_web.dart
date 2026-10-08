String? get e2eEndpoint {
  const value = String.fromEnvironment('PHOENIX_E2E_URL');
  return value.isEmpty ? null : value;
}

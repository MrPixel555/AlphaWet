class AwXrayBuildResult {
  const AwXrayBuildResult({
    required this.config,
    required this.prettyJson,
    required this.primaryOutboundTag,
  });

  final Map<String, dynamic> config;
  final String prettyJson;
  final String primaryOutboundTag;
}

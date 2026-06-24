Map<String, String> parseHeaderBlock(String raw) {
  final headers = <String, String>{};
  if (raw.isEmpty) return headers;
  for (final line in raw.split(RegExp(r'\r\n|\n'))) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final separator = trimmed.indexOf(':');
    if (separator <= 0) continue;
    final name = trimmed.substring(0, separator).trim();
    final value = trimmed.substring(separator + 1).trim();
    if (name.isEmpty) continue;
    headers[name] = value;
  }
  return headers;
}

String formatHeaderBlock(Map<String, String> headers) {
  final buffer = StringBuffer();
  headers.forEach((name, value) {
    buffer.write(name);
    buffer.write(': ');
    buffer.write(value);
    buffer.write('\r\n');
  });
  return buffer.toString();
}

Iterable<List<T>> chunkBytes<T>(List<T> data, int chunkSize) sync* {
  if (chunkSize <= 0) {
    yield data;
    return;
  }
  for (var offset = 0; offset < data.length; offset += chunkSize) {
    final remaining = data.length - offset;
    final end = offset + (remaining < chunkSize ? remaining : chunkSize);
    yield data.sublist(offset, end);
  }
}

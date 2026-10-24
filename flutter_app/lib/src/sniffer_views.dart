/// Assemble overlapping multiword views from the recovered raw address map.
/// Missing words stay unavailable instead of silently decoding padded zeroes.
List<Map<String, dynamic>> snifferViews(Map<String, Map<String, dynamic>> map) {
  final rows = map.values.toList()
    ..sort((a, b) {
      final byAddress = (a['address'] as int).compareTo(b['address'] as int);
      return byAddress != 0
          ? byAddress
          : '${a['kind']}'.compareTo('${b['kind']}');
    });
  return rows.map((row) {
    final values = <Object>[];
    for (var n = 0; n < (row['count'] as int? ?? 1); n++) {
      final word =
          map['${row['kind']}/${(row['address'] as int) + n}']?['value'];
      if (word == null) break;
      values.add(word as Object);
    }
    return <String, dynamic>{
      ...row,
      'values': values.length == (row['count'] ?? 1) ? values : null,
    };
  }).toList();
}

List<Map<String, dynamic>> visibleSnifferViews(
  Map<String, Map<String, dynamic>> map, {
  String area = 'all',
  String query = '',
  bool descending = false,
}) {
  final search = query.trim().toLowerCase();
  final rows = snifferViews(map)
      .where(
        (r) =>
            r['hidden'] != true &&
            (area == 'all' || r['kind'] == area) &&
            (search.isEmpty ||
                '${r['name']} ${r['address']}'.toLowerCase().contains(search)),
      )
      .toList();
  return descending ? rows.reversed.toList() : rows;
}

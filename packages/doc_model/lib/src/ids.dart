import 'dart:math';

final _random = Random();
var _counter = 0;

/// Neue, stabile Element- oder Seiten-ID. Kurz, gut lesbar und praktisch kollisionsfrei.
String newId([String prefix = 'e']) {
  _counter = (_counter + 1) & 0xFFFF;
  final t = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final r = _random.nextInt(0x7FFFFFFF).toRadixString(36);
  return '$prefix$t${_counter.toRadixString(36)}$r';
}

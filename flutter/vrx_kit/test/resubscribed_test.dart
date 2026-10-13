import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

void main() {
  test('a more call is made again when its connection ends or fails', () async {
    var opened = 0;
    Stream<int> open() async* {
      opened++;
      if (opened == 2) throw StateError('vrxhost is restarting');
      yield opened;
    }

    final got = await resubscribed(open, retry: Duration.zero).take(2).toList();
    expect(got, [1, 3], reason: 'the first ends, the second fails, the third answers');
  });
}

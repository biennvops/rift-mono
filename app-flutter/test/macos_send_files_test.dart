import 'package:rift/src/platform/macos_send_files.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parseCallbackArguments filters invalid native picker items', () {
    final items = MacOSSendFiles.parseCallbackArguments([
      {
        'localPath': '/tmp/alpha.txt',
        'fileName': 'alpha.txt',
      },
      {
        'localPath': '/tmp/missing-name.txt',
      },
      'not-a-map',
      {
        'localPath': '',
        'fileName': 'empty.txt',
      },
    ]);

    expect(
      items,
      [
        {
          'localPath': '/tmp/alpha.txt',
          'fileName': 'alpha.txt',
        },
      ],
    );
  });
}

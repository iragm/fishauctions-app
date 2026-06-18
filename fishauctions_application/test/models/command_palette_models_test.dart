import 'package:fishauctions_application/models/command_palette_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PaletteItem.fromJson', () {
    test('reads all fields', () {
      final item = PaletteItem.fromJson({
        'type': 'lot',
        'title': 'Guppy',
        'subtitle': 'Auction A',
        'url': '/lots/1/',
        'icon': 'bi-tag',
        'id': 42,
      });
      expect(item.type, 'lot');
      expect(item.title, 'Guppy');
      expect(item.url, '/lots/1/');
      expect(item.id, 42);
    });

    test('falls back to empty strings and null id when fields are missing', () {
      final item = PaletteItem.fromJson(const {});
      expect(item.type, '');
      expect(item.title, '');
      expect(item.subtitle, '');
      expect(item.url, '');
      expect(item.icon, '');
      expect(item.id, isNull);
    });
  });

  group('PaletteGroup.fromJson', () {
    test('parses nested items', () {
      final group = PaletteGroup.fromJson({
        'label': 'Lots',
        'items': [
          {'type': 'lot', 'title': 'A', 'url': '/a/'},
          {'type': 'lot', 'title': 'B', 'url': '/b/'},
        ],
      });
      expect(group.label, 'Lots');
      expect(group.items, hasLength(2));
      expect(group.items.first.title, 'A');
    });

    test('defaults to an empty item list when items are absent', () {
      final group = PaletteGroup.fromJson({'label': 'Empty'});
      expect(group.items, isEmpty);
    });
  });
}

class PaletteItem {
  const PaletteItem({
    required this.type,
    required this.title,
    required this.subtitle,
    required this.url,
    required this.icon,
    this.id,
  });

  factory PaletteItem.fromJson(Map<String, dynamic> json) => PaletteItem(
    type: json['type'] as String? ?? '',
    title: json['title'] as String? ?? '',
    subtitle: json['subtitle'] as String? ?? '',
    url: json['url'] as String? ?? '',
    icon: json['icon'] as String? ?? '',
    id: json['id'] as int?,
  );

  final String type;
  final String title;
  final String subtitle;
  final String url;
  final String icon;
  final int? id;
}

class PaletteGroup {
  const PaletteGroup({required this.label, required this.items});

  factory PaletteGroup.fromJson(Map<String, dynamic> json) => PaletteGroup(
    label: json['label'] as String? ?? '',
    items: (json['items'] as List<dynamic>? ?? [])
        .map((e) => PaletteItem.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  final String label;
  final List<PaletteItem> items;
}

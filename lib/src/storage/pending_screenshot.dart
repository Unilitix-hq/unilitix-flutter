import 'dart:typed_data';

/// A screenshot pending upload.
class PendingScreenshot {
  final int? id;
  final String sessionId;
  final int ordinal;
  final String screenName;
  final int viewportWidth;
  final int viewportHeight;
  final int capturedAt;
  final Uint8List imageBytes;
  final int createdAt;

  PendingScreenshot({
    this.id,
    required this.sessionId,
    required this.ordinal,
    required this.screenName,
    required this.viewportWidth,
    required this.viewportHeight,
    required this.capturedAt,
    required this.imageBytes,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'session_id': sessionId,
        'ordinal': ordinal,
        'screen_name': screenName,
        'viewport_width': viewportWidth,
        'viewport_height': viewportHeight,
        'captured_at': capturedAt,
        'image_bytes': imageBytes,
        'created_at': createdAt,
      };

  factory PendingScreenshot.fromMap(Map<String, dynamic> map) =>
      PendingScreenshot(
        id: map['id'] as int?,
        sessionId: map['session_id'] as String,
        ordinal: map['ordinal'] as int,
        screenName: map['screen_name'] as String,
        viewportWidth: map['viewport_width'] as int,
        viewportHeight: map['viewport_height'] as int,
        capturedAt: map['captured_at'] as int,
        imageBytes: map['image_bytes'] as Uint8List,
        createdAt: map['created_at'] as int,
      );
}

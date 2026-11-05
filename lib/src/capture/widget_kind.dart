import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../privacy/privacy_mask.dart';

/// The wireframe type name of a widget, decided with `is` checks.
///
/// `runtimeType.toString()` returns mangled names in a build made with
/// `--obfuscate`, which made every wireframe empty and `maskImages` a no-op
/// there. Type tests survive obfuscation. Subclasses come before the class
/// they extend (Center before Align, Expanded before Flexible, Row and Column
/// before Flex, InkWell before InkResponse).
///
/// Widgets that match none of these fall back to their runtime type name,
/// which is right for unobfuscated builds and harmless (not renderable) for
/// obfuscated ones.
String widgetKind(Widget w) {
  for (final k in _kinds) {
    if (k.test(w)) return k.name;
  }
  return w.runtimeType.toString();
}

class _Kind {
  final String name;
  final bool Function(Widget) test;
  const _Kind(this.name, this.test);
}

final List<_Kind> _kinds = [
  _Kind('UnilitixPrivate', (w) => w is UnilitixPrivate),
  // Platform views: WebViews, maps, video. Their pixels are not Flutter's.
  const _Kind(kPlatformViewKind, PrivacyRegistry.isPlatformViewWidget),
  // Text
  _Kind('Text', (w) => w is Text),
  _Kind('RichText', (w) => w is RichText),
  _Kind('SelectableText', (w) => w is SelectableText),
  // Inputs
  _Kind('TextFormField', (w) => w is TextFormField),
  _Kind('TextField', (w) => w is TextField),
  _Kind('CupertinoTextField', (w) => w is CupertinoTextField),
  _Kind('EditableText', (w) => w is EditableText),
  // Images
  _Kind('Image', (w) => w is Image),
  _Kind('CircleAvatar', (w) => w is CircleAvatar),
  _Kind('Icon', (w) => w is Icon),
  // Layout
  _Kind('Container', (w) => w is Container),
  _Kind('SizedBox', (w) => w is SizedBox),
  _Kind('Padding', (w) => w is Padding),
  _Kind('Center', (w) => w is Center),
  _Kind('Align', (w) => w is Align),
  _Kind('ConstrainedBox', (w) => w is ConstrainedBox),
  _Kind('FractionallySizedBox', (w) => w is FractionallySizedBox),
  _Kind('AspectRatio', (w) => w is AspectRatio),
  _Kind('Expanded', (w) => w is Expanded),
  _Kind('Flexible', (w) => w is Flexible),
  _Kind('Spacer', (w) => w is Spacer),
  // Structure
  _Kind('Column', (w) => w is Column),
  _Kind('Row', (w) => w is Row),
  _Kind('Flex', (w) => w is Flex),
  _Kind('Stack', (w) => w is Stack),
  _Kind('Wrap', (w) => w is Wrap),
  _Kind('ListView', (w) => w is ListView),
  _Kind('GridView', (w) => w is GridView),
  _Kind('CustomScrollView', (w) => w is CustomScrollView),
  _Kind('SingleChildScrollView', (w) => w is SingleChildScrollView),
  _Kind('Scaffold', (w) => w is Scaffold),
  _Kind('AppBar', (w) => w is AppBar),
  _Kind('BottomNavigationBar', (w) => w is BottomNavigationBar),
  _Kind('NavigationDrawer', (w) => w is NavigationDrawer),
  _Kind('Drawer', (w) => w is Drawer),
  _Kind('TabBarView', (w) => w is TabBarView),
  _Kind('TabBar', (w) => w is TabBar),
  _Kind('BottomAppBar', (w) => w is BottomAppBar),
  _Kind('NavigationBar', (w) => w is NavigationBar),
  _Kind('NavigationRail', (w) => w is NavigationRail),
  // Visual
  _Kind('DecoratedBox', (w) => w is DecoratedBox),
  _Kind('Card', (w) => w is Card),
  _Kind('VerticalDivider', (w) => w is VerticalDivider),
  _Kind('Divider', (w) => w is Divider),
  _Kind('ClipRRect', (w) => w is ClipRRect),
  _Kind('ClipOval', (w) => w is ClipOval),
  _Kind('ClipRect', (w) => w is ClipRect),
  // Interactive
  _Kind('GestureDetector', (w) => w is GestureDetector),
  _Kind('InkWell', (w) => w is InkWell),
  _Kind('InkResponse', (w) => w is InkResponse),
  _Kind('ElevatedButton', (w) => w is ElevatedButton),
  _Kind('TextButton', (w) => w is TextButton),
  _Kind('OutlinedButton', (w) => w is OutlinedButton),
  _Kind('IconButton', (w) => w is IconButton),
  _Kind('FloatingActionButton', (w) => w is FloatingActionButton),
  _Kind('CupertinoButton', (w) => w is CupertinoButton),
  _Kind('SwitchListTile', (w) => w is SwitchListTile),
  _Kind('CheckboxListTile', (w) => w is CheckboxListTile),
  _Kind('RadioListTile', (w) => w is RadioListTile),
  _Kind('ListTile', (w) => w is ListTile),
  _Kind('Switch', (w) => w is Switch),
  _Kind('Checkbox', (w) => w is Checkbox),
  _Kind('Radio', (w) => w is Radio),
  _Kind('Slider', (w) => w is Slider),
  _Kind('DropdownButton', (w) => w is DropdownButton),
  _Kind('PopupMenuButton', (w) => w is PopupMenuButton),
  // Feedback
  _Kind('CircularProgressIndicator', (w) => w is CircularProgressIndicator),
  _Kind('LinearProgressIndicator', (w) => w is LinearProgressIndicator),
  _Kind('RefreshIndicator', (w) => w is RefreshIndicator),
  _Kind('SnackBar', (w) => w is SnackBar),
  // Overlays
  _Kind('AlertDialog', (w) => w is AlertDialog),
  _Kind('SimpleDialog', (w) => w is SimpleDialog),
  _Kind('Dialog', (w) => w is Dialog),
  _Kind('BottomSheet', (w) => w is BottomSheet),
  _Kind('Tooltip', (w) => w is Tooltip),
];

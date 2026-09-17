import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'finders.dart';
import 'screen.dart' show isOnstage, visitOnstageChildren;

class TreeDump {
  TreeDump(this.text, this.count, this.truncated);

  final String text;
  final int count;
  final bool truncated;
}

/// Produces a compact, indented text dump of the element tree.
///
/// In summary mode only "interesting" nodes are kept: anything with a
/// ValueKey, visible text, a label, an interactive widget, or a structural
/// container (Scaffold, AppBar, dialogs, scrollables). Depth is the count of
/// kept ancestors, so the output stays readable for a model.
class TreeDumper {
  TreeDumper({required this.summary, required this.maxNodes});

  final bool summary;
  final int maxNodes;

  final StringBuffer _buf = StringBuffer();
  int _count = 0;
  bool _truncated = false;

  TreeDump dump(Element root) {
    _visit(root, 0);
    if (_truncated) {
      // The walk stops mid-tree, and overlay entries come last, so a route
      // pushed on top is exactly what gets dropped. Say so in the dump itself:
      // the text is the part a model reads.
      _buf.writeln('… truncated at $maxNodes nodes; raise maxNodes or pass a finder to dump one subtree');
    }
    return TreeDump(_buf.toString(), _count, _truncated);
  }

  void _visit(Element element, int depth) {
    if (_truncated) {
      return;
    }
    // Routes under an opaque one and off-screen PageView pages sit in the
    // tree with stale rects; a summary dump of them is pure noise and was
    // what pushed the visible route past maxNodes.
    if (summary && !isOnstage(element.widget)) {
      return;
    }
    final String? line = describeElement(element, summary: summary);
    int childDepth = depth;
    if (line != null) {
      if (_count >= maxNodes) {
        _truncated = true;
        return;
      }
      _count++;
      _buf.writeln('${'  ' * depth}$line');
      childDepth = depth + 1;
    }
    if (summary) {
      visitOnstageChildren(element, (Element child) => _visit(child, childDepth));
    } else {
      element.visitChildren((Element child) => _visit(child, childDepth));
    }
  }
}

/// One-line description of an element, or null if it is filtered out.
String? describeElement(Element e, {required bool summary}) {
  final Widget w = e.widget;
  final String? key = keyString(w.key);
  final String? text = textOf(w);
  final String? label = labelOf(w);
  final bool interactive = isInteractive(w);
  final bool structural = isStructural(w);
  if (summary && key == null && text == null && label == null && !interactive && !structural) {
    return null;
  }
  final StringBuffer sb = StringBuffer(w.runtimeType.toString());
  if (key != null) {
    sb.write(' key=$key');
  }
  if (text != null) {
    sb.write(' "${_trunc(text, 60)}"');
  }
  if (label != null && label != text) {
    sb.write(' label="${_trunc(label, 40)}"');
  }
  if (w is EditableText && w.obscureText) {
    sb.write(' obscured');
  }
  final Rect? r = rectOf(e);
  if (r != null) {
    sb.write(' [${r.left.round()},${r.top.round()} ${r.width.round()}x${r.height.round()}]');
  } else {
    sb.write(' [not laid out]');
  }
  return sb.toString();
}

/// Global (logical px) rect of the element's render box, if laid out.
Rect? rectOf(Element e) {
  final RenderObject? ro = e.renderObject;
  if (ro is RenderBox && ro.attached && ro.hasSize) {
    try {
      final Offset o = ro.localToGlobal(Offset.zero);
      return o & ro.size;
    } catch (_) {
      return null;
    }
  }
  return null;
}

bool isInteractive(Widget w) {
  return w is ButtonStyleButton ||
      w is IconButton ||
      w is FloatingActionButton ||
      w is InkWell ||
      w is InkResponse ||
      w is GestureDetector ||
      w is ListTile ||
      w is Checkbox ||
      w is Switch ||
      w is Radio ||
      w is Slider ||
      w is TextField ||
      w is TextFormField ||
      w is EditableText ||
      w is DropdownButton ||
      w is PopupMenuButton ||
      w is Tab ||
      w is Chip ||
      w is ActionChip ||
      w is ChoiceChip ||
      w is FilterChip ||
      w is Dismissible ||
      w is CupertinoButton ||
      w is CupertinoTextField ||
      w is CupertinoSwitch ||
      w is BackButton ||
      w is CloseButton;
}

bool isStructural(Widget w) {
  return w is Image ||
      w is Icon ||
      w is CircularProgressIndicator ||
      w is CupertinoActivityIndicator ||
      w is Scaffold ||
      w is AppBar ||
      w is Dialog ||
      w is AlertDialog ||
      w is SimpleDialog ||
      w is BottomSheet ||
      w is Drawer ||
      w is TabBar ||
      w is BottomNavigationBar ||
      w is NavigationBar ||
      w is NavigationRail ||
      w is ListView ||
      w is GridView ||
      w is CustomScrollView ||
      w is SingleChildScrollView ||
      w is PageView ||
      w is TabBarView ||
      w is Card ||
      w is SnackBar ||
      w is Form ||
      w is CupertinoPageScaffold ||
      w is CupertinoNavigationBar ||
      w is CupertinoTabBar ||
      w is CupertinoAlertDialog;
}

String _trunc(String s, int max) {
  final String one = s.replaceAll('\n', '⏎');
  return one.length <= max ? one : '${one.substring(0, max)}…';
}

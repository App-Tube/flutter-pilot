import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'finders.dart';
import 'tree.dart';

/// One visible thing on screen: a label, a text, or a text field.
class ScreenItem {
  ScreenItem({
    required this.kind,
    required this.text,
    required this.rect,
    this.tappable = false,
    this.key,
    this.obscured = false,
  });

  /// `label` (Semantics), `text`, or `field`.
  final String kind;
  final String text;
  final Rect rect;
  bool tappable;
  final String? key;
  final bool obscured;

  /// `tap "Get started" @20,780 387x44`, `field(obscured) "" key=pin @...`
  String get line {
    final StringBuffer sb = StringBuffer();
    if (kind == 'field') {
      sb.write(obscured ? 'field(obscured)' : 'field');
    } else {
      sb.write(tappable ? 'tap' : kind);
    }
    sb.write(' "${_trunc(text, 60)}"');
    if (key != null) {
      sb.write(' key=${_trunc(key!, 48)}');
    }
    sb.write(' @${rect.left.round()},${rect.top.round()} ${rect.width.round()}x${rect.height.round()}');
    return sb.toString();
  }
}

/// A flat, deduplicated list of what a user can see and tap right now.
///
/// Cheaper for a model to read than a tree dump: no structure, no
/// Text/RichText duplication, no off-stage routes, no stale off-screen rects,
/// and a `tap` marker on anything under an interactive widget. Meant to be
/// what an action returns when it fails, and what a model asks for before
/// deciding the next step.
class ScreenSummary {
  ScreenSummary({this.maxItems = 80});

  final int maxItems;

  final List<ScreenItem> _items = <ScreenItem>[];
  int _total = 0;

  /// Rects of interactive ancestors of the element being visited, innermost
  /// last. A whole-screen GestureDetector (dismiss-keyboard-on-tap) would
  /// otherwise make everything tappable, so only ancestors smaller than
  /// [maxTappableFraction] of the view count.
  final List<Rect> _interactive = <Rect>[];
  static const double maxTappableFraction = 0.6;

  Map<String, Object?> summarize(Element root, Size viewSize) {
    final Rect view = Offset.zero & viewSize;
    _visit(root, view);
    final List<ScreenItem> kept = _dedupe(_items);
    kept.sort((ScreenItem a, ScreenItem b) {
      final int dy = (a.rect.top / 8).round().compareTo((b.rect.top / 8).round());
      return dy != 0 ? dy : a.rect.left.compareTo(b.rect.left);
    });
    final List<ScreenItem> shown = kept.take(maxItems).toList();
    return <String, Object?>{
      'items': shown.map((ScreenItem i) => i.line).toList(),
      'count': kept.length,
      if (kept.length > shown.length) 'truncated': kept.length - shown.length,
      'fields': shown.where((ScreenItem i) => i.kind == 'field').length,
      'tappable': shown.where((ScreenItem i) => i.tappable).length,
      'visitedElements': _total,
    };
  }

  void _visit(Element e, Rect view) {
    _total++;
    final Widget w = e.widget;
    if (!isOnstage(w) || w is Icon) {
      return;
    }
    // Text always wraps a RichText carrying the same string: describe the
    // Text and stop, so the pair becomes one item.
    if (w is Text) {
      _add('text', w.data ?? w.textSpan?.toPlainText() ?? '', e, view);
      return;
    }
    if (w is RichText) {
      _add('text', w.text.toPlainText(), e, view);
      return;
    }
    if (w is EditableText) {
      _add('field', w.obscureText ? '' : w.controller.text, e, view, obscured: w.obscureText);
      return;
    }
    if (w is Semantics) {
      final String? label = w.properties.label ?? w.properties.identifier;
      if (label != null && label.isNotEmpty) {
        final bool button = w.properties.button == true || w.properties.onTap != null;
        _add('label', label, e, view, tappable: button);
      }
    } else if (w is Tooltip && w.message != null) {
      _add('label', w.message!, e, view);
    } else if (w is IconButton && w.tooltip != null) {
      _add('label', w.tooltip!, e, view);
    } else if (w is TextField && (w.decoration?.labelText ?? w.decoration?.hintText) != null) {
      // The EditableText below carries the value; this carries the prompt.
      _add('label', (w.decoration!.labelText ?? w.decoration!.hintText)!, e, view);
    }
    final Rect? r = isInteractive(w) ? rectOf(e) : null;
    final bool pushed = r != null && r.width * r.height < view.width * view.height * maxTappableFraction;
    if (pushed) {
      _interactive.add(r);
    }
    visitOnstageChildren(e, (Element child) => _visit(child, view));
    if (pushed) {
      _interactive.removeLast();
    }
  }

  void _add(String kind, String text, Element e, Rect view, {bool obscured = false, bool tappable = false}) {
    final Rect? r = rectOf(e);
    if (r == null || (r.isEmpty && kind != 'field')) {
      return;
    }
    if (!r.overlaps(view)) {
      return;
    }
    if (kind != 'field' && isGlyphOnly(text)) {
      return;
    }
    _items.add(
      ScreenItem(
        kind: kind,
        text: text,
        rect: r,
        tappable: tappable || _interactive.isNotEmpty,
        key: kind == 'field' ? _fieldKey(e) : _shortKey(e),
        obscured: obscured,
      ),
    );
  }

  /// A key on the item itself or on its nearest ancestors: `Semantics` and
  /// `Text` rarely carry the key, the widget two levels up usually does.
  String? _shortKey(Element e) {
    String? k = keyString(e.widget.key);
    if (k != null) {
      return k;
    }
    int hops = 0;
    e.visitAncestorElements((Element a) {
      k = keyString(a.widget.key);
      return k == null && ++hops < 3;
    });
    return k;
  }

  /// The key a test author put on the field is on the TextField (or
  /// TextFormField), a dozen elements above the EditableText that carries the
  /// value. Walk up to it, taking the first ValueKey on the way.
  String? _fieldKey(Element e) {
    String? k = keyString(e.widget.key);
    if (k != null) {
      return k;
    }
    int hops = 0;
    e.visitAncestorElements((Element a) {
      final Widget w = a.widget;
      k = keyString(w.key);
      final bool isField = w is TextField || w is TextFormField || w is CupertinoTextField;
      return k == null && !isField && ++hops < 40;
    });
    return k;
  }

  /// A `Semantics(label: "X")` wrapping a `Text("X")` reads as one thing.
  /// Drop the text when a label with the same string contains its rect.
  static List<ScreenItem> _dedupe(List<ScreenItem> items) {
    // Nested Semantics (a wrapper and the button inside it) repeat the same
    // label at the same rect: keep the first, fold tappability into it.
    final Map<String, ScreenItem> seen = <String, ScreenItem>{};
    final List<ScreenItem> unique = <ScreenItem>[];
    for (final ScreenItem i in items) {
      final String id =
          '${i.kind}|${i.text}|${i.rect.left.round()},${i.rect.top.round()},${i.rect.width.round()}x${i.rect.height.round()}';
      final ScreenItem? prev = seen[id];
      if (prev != null) {
        prev.tappable = prev.tappable || i.tappable;
        continue;
      }
      seen[id] = i;
      unique.add(i);
    }
    items = unique;
    final List<ScreenItem> labels = items.where((ScreenItem i) => i.kind == 'label').toList();
    return items.where((ScreenItem i) {
      if (i.kind != 'text') {
        return true;
      }
      for (final ScreenItem l in labels) {
        if (l.text == i.text && l.rect.inflate(1).contains(i.rect.center)) {
          l.tappable = l.tappable || i.tappable;
          return false;
        }
      }
      return true;
    }).toList();
  }
}

/// Whether anything under this widget can be seen or tapped.
///
/// Overlay marks the routes under an opaque one, and PageView/TabBarView
/// their off-screen pages, with `TickerMode(enabled: false)`; those subtrees
/// keep stale rects from their last layout. `Offstage`, an invisible
/// `Visibility` and a fully transparent `Opacity` hide their child outright.
bool isOnstage(Widget w) {
  if (w is TickerMode) {
    return w.enabled;
  }
  if (w is Offstage) {
    return !w.offstage;
  }
  if (w is Visibility) {
    return w.visible;
  }
  if (w is Opacity) {
    return w.opacity > 0;
  }
  return true;
}

/// Visits the children that are actually on screen. Kept as the single
/// place to extend when a container hides children without a widget
/// [isOnstage] recognises. `IndexedStack` needs nothing: since Flutter 3.13
/// it wraps the non-selected tabs in `Visibility.maintain(visible: false)`.
void visitOnstageChildren(Element e, void Function(Element child) visitor) {
  e.visitChildren((Element child) {
    if (isOnstage(child.widget)) {
      visitor(child);
    }
  });
}

/// Icon fonts render their glyphs as RichText in the Unicode private use
/// area: unreadable as text, and every icon would otherwise be an item.
bool isGlyphOnly(String text) {
  final String t = text.trim();
  if (t.isEmpty) {
    return true;
  }
  for (final int c in t.runes) {
    final bool pua = (c >= 0xE000 && c <= 0xF8FF) || (c >= 0xF0000 && c <= 0x10FFFD);
    if (!pua && c != 0xFFFD && c != 0x200B && c != 0xFEFF) {
      return false;
    }
  }
  return true;
}

String _trunc(String s, int max) {
  final String one = s.replaceAll('\n', '⏎');
  return one.length <= max ? one : '${one.substring(0, max)}…';
}

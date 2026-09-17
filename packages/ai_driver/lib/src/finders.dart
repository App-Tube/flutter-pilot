import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' show Finder, find;

import 'errors.dart';

/// A parsed finder plus a human-readable description.
class FinderSpec {
  FinderSpec(this.finder, this.description);

  final Finder finder;
  final String description;
}

/// Parses a finder from the shorthand grammar or a JSON map.
///
/// Shorthand (preferred, cheap for models):
///   `key:<value>`        widget whose ValueKey's value.toString() == value
///   `text:<exact>`       Text/RichText/EditableText with exactly this text
///                        (obscured fields are never matched)
///   `contains:<sub>`     text containing the substring
///   `type:<WidgetType>`  runtimeType name (generics may be omitted)
///   `label:<value>`      Semantics label or identifier, Tooltip message,
///                        IconButton/FAB tooltip
///   `tooltip:<msg>`      Tooltip message
///   `<a> > <b>`          b that is a descendant of a
/// A bare string without a recognised prefix is treated as `text:`.
FinderSpec parseFinder(Object? raw) {
  if (raw == null) {
    throw const AiDriverException('BAD_ARGS', 'finder is required');
  }
  if (raw is Map) {
    return _parseMap(raw.cast<String, Object?>());
  }
  if (raw is String) {
    return _parseShorthand(raw.trim());
  }
  throw AiDriverException('BAD_ARGS', 'finder must be a string or object, got ${raw.runtimeType}');
}

FinderSpec _parseShorthand(String s) {
  final int arrow = s.indexOf(' > ');
  if (arrow > 0) {
    final FinderSpec of = _parseShorthand(s.substring(0, arrow).trim());
    final FinderSpec matching = _parseShorthand(s.substring(arrow + 3).trim());
    return FinderSpec(
      find.descendant(of: of.finder, matching: matching.finder),
      '${matching.description} inside ${of.description}',
    );
  }
  final int colon = s.indexOf(':');
  if (colon <= 0) {
    return FinderSpec(byVisibleText(s), 'text="$s"');
  }
  final String prefix = s.substring(0, colon).toLowerCase();
  final String value = s.substring(colon + 1);
  switch (prefix) {
    case 'key':
      return FinderSpec(byKeyValue(value), 'key=$value');
    case 'text':
      return FinderSpec(byVisibleText(value), 'text="$value"');
    case 'contains':
      return FinderSpec(byVisibleTextContaining(value), 'text~"$value"');
    case 'type':
      return FinderSpec(byTypeName(value), 'type=$value');
    case 'label':
      return FinderSpec(byLabel(value), 'label="$value"');
    case 'tooltip':
      return FinderSpec(find.byTooltip(value), 'tooltip="$value"');
    default:
      // Unknown prefix: the whole thing is probably literal text (e.g. "Total: 5").
      return FinderSpec(byVisibleText(s), 'text="$s"');
  }
}

FinderSpec _parseMap(Map<String, Object?> m) {
  if (m['descendantOf'] != null || m['matching'] != null) {
    final FinderSpec of = parseFinder(m['descendantOf']);
    final FinderSpec matching = parseFinder(m['matching']);
    return FinderSpec(
      find.descendant(of: of.finder, matching: matching.finder),
      '${matching.description} inside ${of.description}',
    );
  }
  for (final String k in const <String>['key', 'text', 'contains', 'type', 'label', 'tooltip']) {
    final Object? v = m[k];
    if (v != null) {
      return _parseShorthand('$k:$v');
    }
  }
  throw AiDriverException('BAD_ARGS', 'finder object needs one of key/text/contains/type/label/tooltip, got ${m.keys}');
}

/// Like `find.text(..., findRichText: true)`, minus obscured [EditableText]s.
///
/// `find.text` matches an [EditableText] on its controller's value, which for
/// an obscured field is the secret itself. On a passcode keypad that makes
/// every digit key ambiguous with the field as soon as that digit is typed —
/// and the text is not on screen anyway, only bullets are.
Finder byVisibleText(String value) =>
    find.byWidgetPredicate((Widget w) => _visibleText(w) == value, description: 'text="$value"');

/// Substring variant of [byVisibleText].
Finder byVisibleTextContaining(String value) =>
    find.byWidgetPredicate((Widget w) => _visibleText(w)?.contains(value) ?? false, description: 'text~"$value"');

/// The text a user can actually read off this widget.
///
/// [Text] is deliberately not matched: it always inserts a [RichText] child
/// carrying the same string, and matching both would make every text finder
/// ambiguous. This mirrors `find.text(findRichText: true)`.
String? _visibleText(Widget w) {
  if (w is RichText) {
    return w.text.toPlainText();
  }
  if (w is EditableText) {
    return w.obscureText ? null : w.controller.text;
  }
  return null;
}

/// Matches widgets whose key is a [ValueKey] with `value.toString() == value`.
/// Covers `Key('x')`, `ValueKey('x')`, `ValueKey(3)`.
Finder byKeyValue(String value) {
  return find.byWidgetPredicate((Widget w) {
    final Key? k = w.key;
    return k is ValueKey<Object?> && k.value.toString() == value;
  }, description: 'key=$value');
}

/// Matches by runtimeType name; `Radio` matches `Radio<int>`.
Finder byTypeName(String name) {
  return find.byWidgetPredicate((Widget w) {
    final String t = w.runtimeType.toString();
    if (t == name) {
      return true;
    }
    final int lt = t.indexOf('<');
    return lt > 0 && t.substring(0, lt) == name;
  }, description: 'type=$name');
}

/// Matches by semantics label/identifier, tooltip, or button tooltip.
Finder byLabel(String value) {
  return find.byWidgetPredicate((Widget w) {
    if (w is Semantics) {
      return w.properties.label == value || w.properties.identifier == value;
    }
    if (w is Tooltip) {
      return w.message == value;
    }
    if (w is IconButton) {
      return w.tooltip == value;
    }
    if (w is FloatingActionButton) {
      return w.tooltip == value;
    }
    if (w is Icon) {
      return w.semanticLabel == value;
    }
    return false;
  }, description: 'label="$value"');
}

/// Returns the [ValueKey] value as a string, or null for other key kinds.
String? keyString(Key? key) {
  if (key is ValueKey<Object?>) {
    return key.value.toString();
  }
  return null;
}

/// Human-visible text carried directly by a widget, if any.
String? textOf(Widget w) {
  if (w is Text) {
    return w.data ?? w.textSpan?.toPlainText();
  }
  if (w is RichText) {
    return w.text.toPlainText();
  }
  if (w is EditableText) {
    return w.controller.text;
  }
  return null;
}

/// Accessibility-ish label carried by a widget, if any.
String? labelOf(Widget w) {
  if (w is Semantics) {
    return w.properties.label ?? w.properties.identifier;
  }
  if (w is Tooltip) {
    return w.message ?? w.richMessage?.toPlainText();
  }
  if (w is IconButton) {
    return w.tooltip;
  }
  if (w is FloatingActionButton) {
    return w.tooltip;
  }
  if (w is Icon) {
    return w.semanticLabel;
  }
  if (w is TextField) {
    return w.decoration?.labelText ?? w.decoration?.hintText;
  }
  return null;
}

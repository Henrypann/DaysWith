import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Shortest-column masonry, as in TimelineView.swift's MomentWaterfallLayout.
/// Each card is measured at its column width, then placed in the current shortest lane.
class Waterfall extends MultiChildRenderObjectWidget {
  final int columns;
  final double columnSpacing;
  final double rowSpacing;

  const Waterfall({
    super.key,
    required this.columns,
    this.columnSpacing = 8,
    this.rowSpacing = 8,
    required super.children,
  });

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderWaterfall(columns: columns, columnSpacing: columnSpacing, rowSpacing: rowSpacing);

  @override
  void updateRenderObject(BuildContext context, _RenderWaterfall renderObject) {
    renderObject
      ..columns = columns
      ..columnSpacing = columnSpacing
      ..rowSpacing = rowSpacing;
  }
}

class _WaterfallParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderWaterfall extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _WaterfallParentData>, RenderBoxContainerDefaultsMixin<RenderBox, _WaterfallParentData> {
  _RenderWaterfall({required int columns, required double columnSpacing, required double rowSpacing})
      : _columns = columns,
        _columnSpacing = columnSpacing,
        _rowSpacing = rowSpacing;

  int _columns;
  set columns(int value) {
    if (value == _columns) return;
    _columns = value;
    markNeedsLayout();
  }

  double _columnSpacing;
  set columnSpacing(double value) {
    if (value == _columnSpacing) return;
    _columnSpacing = value;
    markNeedsLayout();
  }

  double _rowSpacing;
  set rowSpacing(double value) {
    if (value == _rowSpacing) return;
    _rowSpacing = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _WaterfallParentData) child.parentData = _WaterfallParentData();
  }

  @override
  void performLayout() {
    final count = math.max(1, _columns);
    final width = constraints.maxWidth;
    final columnWidth = math.max(0.0, (width - (count - 1) * _columnSpacing) / count);
    final heights = List<double>.filled(count, 0);
    var child = firstChild;
    var any = false;
    while (child != null) {
      any = true;
      var lane = 0;
      for (var i = 1; i < count; i++) {
        if (heights[i] < heights[lane]) lane = i;
      }
      child.layout(BoxConstraints.tightFor(width: columnWidth), parentUsesSize: true);
      final data = child.parentData! as _WaterfallParentData;
      data.offset = Offset(lane * (columnWidth + _columnSpacing), heights[lane]);
      heights[lane] += child.size.height + _rowSpacing;
      child = data.nextSibling;
    }
    final tallest = heights.reduce(math.max);
    size = constraints.constrain(Size(width, any ? math.max(0, tallest - _rowSpacing) : 0));
  }

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

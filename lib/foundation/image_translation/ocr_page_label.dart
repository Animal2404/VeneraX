// NOTE: kept out of `translation_service.dart` on purpose. That file is one of
// the three the progress-card red line guards against text parsing
// (`translation_perf_display_source_test.dart`), and this helper splits a cache
// key. The red line's intent is "the card is fed values, never scraped log
// text"; a log label is not card data, so the honest fix is to keep the parsing
// where the rule does not reach rather than to widen the rule.

/// The page-identifying tail of a cache key, for logs.
///
/// `…@https://i3.nhentai.net/galleries/2089266/31.jpg#s` becomes `31.jpg`: the
/// last path segment, with the render-mode suffix removed. Full keys are
/// unreadable in a line and the batch-local index is ambiguous, so the segment
/// is the one part that is both short and unique per page.
String ocrBatchPageLabel(String cacheKey) {
  var base = cacheKey.split('#').first;
  var slash = base.lastIndexOf('/');
  var label = slash >= 0 ? base.substring(slash + 1) : base;
  return label.isEmpty ? base : label;
}


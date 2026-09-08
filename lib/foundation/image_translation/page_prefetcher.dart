import 'dart:async';
import 'dart:typed_data';

import 'package:venera/utils/channel.dart';

/// One prefetched page: either its bytes, or the error that stopped it.
class PrefetchedPage {
  const PrefetchedPage(this.index, {this.bytes, this.error});

  final int index;
  final Uint8List? bytes;
  final Object? error;

  bool get failed => error != null;
}

/// Fetches pages concurrently and hands them to a consumer that is slower than
/// the network round-trip, so the GPU never waits on a download that could have
/// been started while it was busy (plan D-7).
///
/// Before this, the stage-1 sweep did `for (page) { await fetch }` and only
/// then `await ocrPages`, per chunk — so every chunk paid its full download
/// latency with the GPU idle, and the download of the next chunk waited on the
/// current inference. The two-phase split removed the LLM lockstep; this
/// removes the one that replaced it.
///
/// Concurrency is bounded by [depth] through the project's own [Channel], which
/// already provides backpressure: if the consumer stops popping, in-flight
/// fetches finish and no more are started, so a whole chapter's bytes are never
/// held in memory. The per-source rate limit is *not* duplicated here — callers
/// pass a `fetch` that goes through it, so one gate keeps governing the source.
class PagePrefetcher {
  PagePrefetcher({required this.depth, required this.fetch});

  /// Number of fetches allowed in flight (and buffered) at once.
  final int depth;

  final Future<Uint8List> Function(int index) fetch;

  Stream<PrefetchedPage> run(Iterable<int> indices) async* {
    final ids = indices.toList();
    if (ids.isEmpty) return;
    final channel = Channel<PrefetchedPage>(depth);
    var next = 0;

    Future<void> worker() async {
      while (true) {
        final slot = next++;
        if (slot >= ids.length) return;
        final id = ids[slot];
        try {
          await channel.push(PrefetchedPage(id, bytes: await fetch(id)));
        } catch (e) {
          await channel.push(PrefetchedPage(id, error: e));
        }
      }
    }

    final workers = <Future<void>>[
      for (var i = 0; i < depth.clamp(1, ids.length); i++) worker(),
    ];
    unawaited(Future.wait(workers).whenComplete(channel.close));

    while (true) {
      final item = await channel.pop();
      if (item == null) return;
      yield item;
    }
  }
}

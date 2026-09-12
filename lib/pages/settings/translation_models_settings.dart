// ===========================================================================
// OWNERSHIP — see the matching notice at the top of
// `lib/foundation/image_translation/translation_models.dart`.
//
// This page and that file are owned EXCLUSIVELY by the local-model validation
// task, and they are one change, not two: the list filter that keeps
// unpublished assets out of the rows, the detection pass that runs as soon as
// the page opens, and the one-click "check every component" notice all read
// `TranslationModels.listedComponents` / `runDetectionPass` /
// `isUnpublishedAsset`. Restoring either file from git deletes half of a fixed
// defect — which already happened once.
// ===========================================================================

part of 'settings_page.dart';

/// Management page for offline translation model files: download (with
/// progress and mirror fallback), delete, and choice of download endpoint.
class TranslationModelsPage extends StatefulWidget {
  const TranslationModelsPage({super.key, this.sourceLang});

  /// Source language whose OCR models are marked "required", or null to use the
  /// global setting. Passed by the reader's per-comic settings so the page marks
  /// the models that comic actually needs, not the ones the global default does.
  final String? sourceLang;

  @override
  State<TranslationModelsPage> createState() => _TranslationModelsPageState();
}

class _TranslationModelsPageState extends State<TranslationModelsPage> {
  /// Ids of components whose "Validate files" run is still in flight.
  final _validating = <String>{};

  /// Per-component outcome of the last detection pass that ran here (the one
  /// on open, the "check every component" button, or a row's own validate).
  /// Rows render from it: "每个组件行内显示结果" is only meaningful once the
  /// page knows which rows it has actually looked at.
  final _detected = <String, ModelState>{};

  /// The detection pass found a component whose files are present but wrong,
  /// so the single button that re-checks *everything* goes on top of the list.
  bool _showCheckAll = false;

  /// A whole-list check is running.
  bool _checkingAll = false;

  @override
  void initState() {
    TranslationModelStore.instance.addListener(_update);
    super.initState();
    // Detection when the page opens, not when the user asks for it: "are my
    // model files usable?" is the whole reason this page exists, and having
    // to click seven rows to find out was the reported defect. It runs after
    // the first frame on purpose — the pass is cheap (it answers from the
    // size@mtime ledger, see [TranslationModels.runDetectionPass]), but the
    // very first one does read each model header, and blocking the first
    // frame with that would make the page look frozen.
    WidgetsBinding.instance.addPostFrameCallback((_) => _detectOnOpen());
  }

  /// Every component this page lists: the three sections as the registry
  /// partitions them, minus the rows with nothing behind them (gate G5).
  List<ModelComponent> _listedComponents() => [
    for (final section in ModelSection.values)
      ...TranslationModels.listedComponents(section),
  ];

  /// The pass that runs as soon as the page opens.
  void _detectOnOpen() {
    if (!mounted) return;
    final result = TranslationModels.runDetectionPass(_listedComponents());
    setState(() {
      _detected.addAll(result.states);
      _showCheckAll = result.hasFailures;
    });
  }

  @override
  void dispose() {
    TranslationModelStore.instance.removeListener(_update);
    super.dispose();
  }

  void _update() {
    if (mounted) setState(() {});
  }

  static String _componentName(ModelComponent component) {
    if (component.displayNameKey != null) {
      return component.displayNameKey!.tl;
    }
    return component.id;
  }

  static String _formatSize(int bytes) {
    if (bytes >= 1 << 30) {
      return "${(bytes / (1 << 30)).toStringAsFixed(2)} GB";
    }
    if (bytes >= 1 << 20) {
      return "${(bytes / (1 << 20)).toStringAsFixed(1)} MB";
    }
    return "${(bytes / (1 << 10)).toStringAsFixed(0)} KB";
  }

  /// One click, every component: a full [validateComponent] pass over
  /// everything the page lists that actually has files on disk.
  ///
  /// Rows whose files are missing are skipped: "not installed" is not a
  /// defect, and turning them red would bury the rows that do have a problem.
  ///
  /// `checkHashes` stays off deliberately. The button re-runs every structural
  /// and dictionary rule — which is what "把全部组件都检测一遍" asks for — while
  /// the SHA-256 comparison would hash ~700 MB of models **on the UI isolate**
  /// and freeze the page for seconds. Anyone who wants that answer has it per
  /// row (the 校验已放入的文件 button), where the cost is an explicit click on
  /// one component.
  Future<void> _checkAllComponents() async {
    if (_checkingAll) return;
    final targets = _listedComponents()
        .where(
          (c) =>
              c.enabled && TranslationModels.stateOf(c) != ModelState.absent,
        )
        .toList();
    if (targets.isEmpty) {
      setState(() => _showCheckAll = false);
      return;
    }
    setState(() {
      _checkingAll = true;
      _validating.addAll(targets.map((c) => c.id));
    });
    var failed = 0;
    for (final component in targets) {
      final verdict = await validateComponent(component);
      if (!mounted) return;
      if (!verdict.ok) failed++;
      setState(() {
        _detected[component.id] = verdict.state;
        _validating.remove(component.id);
      });
    }
    setState(() {
      _checkingAll = false;
      // All green now: the notice goes away with the reason that raised it.
      _showCheckAll = failed > 0;
    });
    context.showMessage(
      message: failed == 0
          ? "All model files passed the check".tl
          : "@n of @m model components failed the full check".tlParams({
              'n': failed,
              'm': targets.length,
            }),
    );
  }

  /// The notice above the sections — shown only while a detection pass found
  /// something actually wrong with a file that is there.
  Widget _buildCheckAllNotice(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          color: context.colorScheme.errorContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: context.colorScheme.error,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                "Model files need attention".tl,
                style: TextStyle(color: context.colorScheme.onErrorContainer),
              ),
            ),
            if (_checkingAll)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: context.colorScheme.primary,
                  ),
                ),
              )
            else
              Button.filled(
                onPressed: _checkAllComponents,
                child: Text("Check all model files".tl),
              ).fixHeight(32),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    var requiredIds = TranslationModels.requiredFor(
      widget.sourceLang ?? TranslationConfig.global.sourceLang,
    ).map((c) => c.id).toSet();

    final hasGpuBackend = (TranslationWorker.instance.lastReport?.active != null &&
            TranslationWorker.instance.lastReport?.active != OrtEpKind.cpu) ||
        (TranslationWorker.instance.lastReport == null &&
            App.isDesktop &&
            () {
              try {
                final probe = probeOrtRuntime();
                return probe.hasDmlSymbol || probe.hasCudaSymbol;
              } catch (_) {
                return false;
              }
            }());

    // Unpublished assets are filtered out by the registry (gate G5), so the
    // three dead "未发布 · 暂不可用" rows are not part of the list at all — the
    // row, not the wording, was the defect. See
    // [TranslationModels.isUnpublishedAsset] for what un-hides them.
    final detComponents = TranslationModels.listedComponents(
      ModelSection.detection,
    );
    final recComponents = TranslationModels.listedComponents(
      ModelSection.recognition,
    );
    final highAndGpuComponents = TranslationModels.listedComponents(
      ModelSection.highAndGpu,
    );

    return Scaffold(
      body: SmoothCustomScrollView(
        scrollbarTopPadding: context.padding.top + 56,
        slivers: [
          SliverAppbar(title: Text("Translation models".tl)),
          if (_showCheckAll) _buildCheckAllNotice(context).toSliver(),
          SelectSetting(
            title: "Model quality".tl,
            settingKey: "imageTranslationModelQuality",
            optionTranslation: {
              'fast': "Fast".tl,
              'high': "High accuracy".tl,
            },
            onChanged: () {
              TranslationModels.invalidateReadyCache();
              TranslationWorker.instance.release();
              _update();
            },
          ).toSliver(),
          SelectSetting(
            title: "Model download source".tl,
            settingKey: "imageTranslationHfEndpoint",
            optionTranslation: const {
              'https://huggingface.co': "HuggingFace",
              'https://hf-mirror.com': "hf-mirror.com",
            },
          ).toSliver(),
          // Plan §7.2.3 (3) / R-3: `{release}` is this fork's own `models`
          // Release, which only exists once publish.py actually ran. Default
          // off (the key's default is registered in appdata.dart; this page
          // only reads/writes it) — with it off, {release} URLs are dropped
          // from the chain instead of burning a 404 in front of every
          // working mirror.
          _SwitchSetting(
            title: "Self-hosted model source".tl,
            settingKey: "imageTranslationSelfHostedSource",
            subtitle:
                "Only enable this after the repository has actually published a 'models' release containing the model files.".tl,
          ).toSliver(),
          ListTile(
            title: Text("Storage used by models".tl),
            subtitle: Text(
              _formatSize(TranslationModelStore.instance.installedSizeBytes),
            ),
          ).toSliver(),
          _buildSectionHeader(context, "Text detection".tl).toSliver(),
          for (var component in detComponents)
            _buildComponent(context, component, requiredIds, hasGpuBackend)
                .toSliver(),
          _buildSectionHeader(context, "Text recognition".tl).toSliver(),
          for (var component in recComponents)
            _buildComponent(context, component, requiredIds, hasGpuBackend)
                .toSliver(),
          _buildSectionHeader(context, "High-accuracy & GPU variants".tl)
              .toSliver(),
          for (var component in highAndGpuComponents)
            _buildComponent(context, component, requiredIds, hasGpuBackend)
                .toSliver(),
          const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: context.colorScheme.primary,
        ),
      ),
    );
  }

  Widget _buildComponent(
    BuildContext context,
    ModelComponent component,
    Set<String> requiredIds,
    bool hasGpuBackend,
  ) {
    var store = TranslationModelStore.instance;
    var state = store.stateOf(component);
    var installed = component.isInstalled;
    final isGpuBlocked = component.requiresGpuEp && !hasGpuBackend;
    // stateOf runs the FFI-free structure gate on first sight, so a broken
    // drop-in is flagged here without any inference having touched it.
    final modelState = component.enabled
        ? TranslationModels.stateOf(component)
        : ModelState.absent;

    // §7.2.3: the two local-import actions live on every *enabled* row,
    // installed or not — the typical flow is "open folder, drop files,
    // validate" precisely while the component is still missing.
    // Android has no filesystem semantics for these paths: no folder button.
    final actions = <Widget>[
      if (component.enabled && !App.isAndroid)
        IconButton(
          icon: const Icon(Icons.folder_open),
          tooltip: "Open model folder".tl,
          onPressed: () => _openModelFolder(component),
        ),
      if (component.enabled)
        IconButton(
          icon: _validating.contains(component.id)
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: context.colorScheme.primary,
                  ),
                )
              : Icon(
                  switch (modelState) {
                    ModelState.verified => Icons.fact_check_outlined,
                    ModelState.invalid => Icons.error_outline,
                    _ => Icons.rule_folder_outlined,
                  },
                  color: switch (modelState) {
                    ModelState.invalid => context.colorScheme.error,
                    ModelState.verified => context.colorScheme.primary,
                    _ => context.colorScheme.outline,
                  },
                ),
          tooltip: "Validate files".tl,
          onPressed: _validating.contains(component.id)
              ? null
              : () => _validateComponentFiles(component),
        ),
    ];

    Widget trailing;
    if (!component.enabled) {
      // R-3 / §7.2.1: reserved placeholders (no files) keep "Coming soon".
      // The "Unpublished · not available" arm below is now a fallback that the
      // list never reaches: unpublished assets are filtered out before rows
      // are built (gate G5, [TranslationModels.isUnpublishedAsset]), which is
      // what defect 2 asked for — no dead row, not a nicer label on it. It
      // stays so that anything rendering this builder from a list that skipped
      // the filter still tells the truth.
      trailing = Text(
        component.files.isEmpty
            ? "Coming soon".tl
            : "Unpublished · not available".tl,
        style: TextStyle(color: context.colorScheme.outline),
      );
    } else if (state.downloading) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              value: state.progress <= 0 ? null : state.progress,
            ),
          ),
          const SizedBox(width: 8),
          Text("${(state.progress * 100).toStringAsFixed(0)}%"),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => store.cancelDownload(component),
          ),
        ],
      );
    } else if (installed) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ...actions,
          Icon(Icons.check_circle, color: context.colorScheme.primary),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
              showConfirmDialog(
                context: App.rootContext,
                title: "Delete".tl,
                content: "Delete the downloaded model files?".tl,
                btnColor: context.colorScheme.error,
                onConfirm: () {
                  store.delete(component);
                },
              );
            },
          ),
        ],
      );
    } else if (isGpuBlocked) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ...actions,
          Button.outlined(
            color: context.colorScheme.outline.withValues(alpha: 0.4),
            onPressed: () {},
            child: Text(
              "Download".tl,
              style: TextStyle(color: context.colorScheme.outline),
            ),
          ).fixHeight(32),
        ],
      );
    } else {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ...actions,
          Button.filled(
            onPressed: () => store.download(component),
            child: Text("Download".tl),
          ).fixHeight(32),
        ],
      );
    }

    // What this model is *for*, in one line, above the size and the verdict.
    // A `.tl` that finds no translation returns its key, and printing an
    // English key into a Chinese row would be worse than printing nothing.
    final blurb = component.blurbKey?.tl;
    final hasBlurb = blurb != null && blurb != component.blurbKey;
    String subtitle = hasBlurb
        ? [blurb, _formatSize(component.approxSizeBytes)].join('\n')
        : _formatSize(component.approxSizeBytes);
    if (component.requiresGpuEp) {
      if (isGpuBlocked) {
        subtitle += " · ${"Unavailable: no GPU backend detected".tl}";
      } else {
        subtitle += " · ${"Requires GPU backend".tl}";
      }
    }
    if (requiredIds.contains(component.id) && !installed && component.enabled) {
      subtitle += " · ${"Required by current settings".tl}";
    }
    if (component.enabled) {
      // §7.2.3 "行内状态": the validation verdict, in words. Once a detection
      // pass has covered this row, "present" reports what it now means — the
      // structure gate ran over these exact bytes and passed — instead of the
      // untouched "nothing has looked at this yet" wording.
      switch (modelState) {
        case ModelState.invalid:
          subtitle += '\n${"Invalid".tl}: ${TranslationModels.validationDetail(component) ?? ""}';
        case ModelState.verified:
          subtitle += ' · ${"Validated".tl}';
        case ModelState.present:
          subtitle += _detected.containsKey(component.id)
              ? ' · ${"Structure checks passed".tl}'
              : ' · ${"Files present, not validated yet".tl}';
        case ModelState.absent:
          break;
      }
    }
    if (state.error != null) {
      subtitle += "\n${"Download failed".tl}: ${state.error}";
    }

    return ListTile(
      title: Text(
        _componentName(component),
        style: component.enabled
            ? null
            : TextStyle(color: context.colorScheme.outline),
      ),
      subtitle: Text(
        subtitle,
        style: component.enabled
            ? null
            : TextStyle(color: context.colorScheme.outline),
      ),
      isThreeLine:
          state.error != null ||
          (component.enabled && modelState == ModelState.invalid) ||
          (hasBlurb && component.enabled),
      trailing: trailing,
    );
  }

  /// §7.2.3 ladder for "Open model folder".
  ///
  /// ① `lib/utils/io.dart` carries no open-folder helper at all ([自验],
  ///   checked at the time of writing: only `DirectoryPicker`, `Share` and
  ///   path/file utilities) — nothing to reuse, so the ladder starts at ②.
  /// ② url_launcher (`Uri.directory(path)` as a file: URL; the dependency
  ///   was already in pubspec.yaml, no new dependency added).
  /// ③ `Process.run`: `explorer` / `open` / `xdg-open` (+ common Linux
  ///   file managers), mirroring what `openComicFolder` does on this repo.
  /// ④ total failure: copy the full path to the clipboard and show it.
  Future<void> _openModelFolder(ModelComponent component) async {
    final dir = Directory(component.directory);
    try {
      // The directory is what the user is supposed to drop files into;
      // creating it on first use beats opening a path that does not exist.
      dir.createSync(recursive: true);
    } catch (_) {}
    final path = dir.path;
    try {
      if (await launchUrlString(Uri.directory(path).toString())) return;
    } catch (_) {}
    if (await _openFolderProcess(path)) return;
    try {
      await Clipboard.setData(ClipboardData(text: path));
    } catch (_) {}
    if (mounted) {
      context.showMessage(
        message:
            '${"Could not open the folder; the path has been copied to the clipboard".tl}\n$path',
      );
    }
  }

  /// ③ of [_openModelFolder]: per-platform spawn. `Process.run` only throws
  /// when the binary cannot start; a non-zero exit from explorer/open is
  /// still "the folder was shown", so it is not treated as failure.
  Future<bool> _openFolderProcess(String path) async {
    try {
      if (App.isWindows) {
        await Process.run('explorer', [path]);
        return true;
      }
      if (App.isMacOS) {
        await Process.run('open', [path]);
        return true;
      }
      if (App.isLinux) {
        for (var opener in const ['xdg-open', 'nautilus', 'dolphin', 'thunar']) {
          try {
            await Process.run(opener, [path]);
            return true;
          } catch (_) {
            // that opener is not installed; try the next candidate
          }
        }
      }
    } catch (_) {}
    return false;
  }

  /// §7.2.2: explicit "校验已放入的文件" action — full validateComponent pass
  /// (checksums included: this is a deliberate user click, the hashing cost
  /// is expected), result as Toast + the inline row state.
  Future<void> _validateComponentFiles(ModelComponent component) async {
    setState(() => _validating.add(component.id));
    final verdict = await validateComponent(component, checkHashes: true);
    if (!mounted) return;
    setState(() {
      _validating.remove(component.id);
      _detected[component.id] = verdict.state;
      // A row the user just repaired takes the notice with it; one that still
      // fails keeps it, because the button is how they re-check all of them at
      // once instead of hunting row by row.
      if (verdict.ok) {
        _showCheckAll = TranslationModels.runDetectionPass(
          _listedComponents(),
        ).hasFailures;
      }
    });
    final name = _componentName(component);
    if (verdict.ok) {
      final extra = verdict.warnings.isEmpty ? '' : '\n${verdict.warnings.first}';
      context.showMessage(message: '${"Validation passed".tl}: $name$extra');
    } else {
      context.showMessage(
        message: '${"Validation failed".tl}: $name\n${verdict.reason}',
      );
    }
  }
}

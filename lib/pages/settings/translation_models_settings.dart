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

  @override
  void initState() {
    TranslationModelStore.instance.addListener(_update);
    super.initState();
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

    final detComponents = TranslationModels.all
        .where((c) => c.kind == ModelKind.detector)
        .toList();
    final recComponents = TranslationModels.all
        .where((c) =>
            c.kind != ModelKind.detector &&
            !c.requiresGpuEp &&
            c.tier != ModelTier.high)
        .toList();
    final highAndGpuComponents = TranslationModels.all
        .where((c) =>
            c.kind != ModelKind.detector &&
            (c.requiresGpuEp || c.tier == ModelTier.high))
        .toList();

    return Scaffold(
      body: SmoothCustomScrollView(
        scrollbarTopPadding: context.padding.top + 56,
        slivers: [
          SliverAppbar(title: Text("Translation models".tl)),
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
      // R-3 / §7.2.1: assets that are registered but never published say so
      // and offer nothing to click; reserved placeholders keep "Coming soon".
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

    String subtitle = _formatSize(component.approxSizeBytes);
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
      // §7.2.3 "行内状态": the validation verdict, in words.
      switch (modelState) {
        case ModelState.invalid:
          subtitle += '\n${"Invalid".tl}: ${TranslationModels.validationDetail(component) ?? ""}';
        case ModelState.verified:
          subtitle += ' · ${"Validated".tl}';
        case ModelState.present:
          subtitle += ' · ${"Files present, not validated yet".tl}';
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
          (component.enabled && modelState == ModelState.invalid),
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
    setState(() => _validating.remove(component.id));
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

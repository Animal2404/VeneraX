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

    Widget trailing;
    if (!component.enabled) {
      trailing = Text(
        "Coming soon".tl,
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
      trailing = Button.outlined(
        color: context.colorScheme.outline.withValues(alpha: 0.4),
        onPressed: () {},
        child: Text(
          "Download".tl,
          style: TextStyle(color: context.colorScheme.outline),
        ),
      ).fixHeight(32);
    } else {
      trailing = Button.filled(
        onPressed: () => store.download(component),
        child: Text("Download".tl),
      ).fixHeight(32);
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
      isThreeLine: state.error != null,
      trailing: trailing,
    );
  }
}

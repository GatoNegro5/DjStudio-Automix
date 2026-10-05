import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../fiestadj/fiesta_loop_synth.dart';
import '../../providers/automix_provider.dart' show wasapiRecordProvider;
import '../../providers/fiestadj_provider.dart';
import '../../providers/theme_provider.dart';
import 'automix_workspace.dart' show LibraryTreePanel;

const Color _kFiesta = Color(0xFFFF4081);

String _name(String? path) =>
    path == null ? '—' : path.replaceAll('\\', '/').split('/').last;

String _clock(Duration d) {
  final s = d.inSeconds;
  return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}

/// FiestaDj: mezcla automática con pista base. Módulo independiente.
class FiestaDjWorkspace extends ConsumerWidget {
  const FiestaDjWorkspace({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool mobileOS = Platform.isAndroid || Platform.isIOS;
    return Scaffold(
      backgroundColor: DjStudioTheme.bgDark,
      body: LayoutBuilder(
        builder: (context, box) {
          final bool wide = !mobileOS && box.maxWidth >= 900;
          if (!wide) return const _FiestaPanel(showFolderButton: true);
          return Row(
            children: [
              Expanded(
                flex: 5,
                child: Material(
                  color: DjStudioTheme.bgPanel,
                  child: LibraryTreePanel(provider: fiestaDjDirectoryProvider),
                ),
              ),
              const VerticalDivider(width: 1, color: Colors.white10),
              const Expanded(flex: 14, child: _FiestaPanel(showFolderButton: false)),
            ],
          );
        },
      ),
    );
  }
}

class _FiestaPanel extends ConsumerWidget {
  const _FiestaPanel({required this.showFolderButton});
  final bool showFolderButton;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(fiestaDjProvider);
    final dir = ref.watch(fiestaDjDirectoryProvider);
    final notifier = ref.read(fiestaDjProvider.notifier);
    final bool recording = ref.watch(wasapiRecordProvider);
    final bool desktop = Platform.isWindows || Platform.isMacOS;
    final bool compact = Platform.isAndroid || Platform.isIOS;

    // Al terminar la fiesta se cierra la grabación automática.
    ref.listen<FiestaPhase>(fiestaDjProvider.select((x) => x.phase), (prev, next) {
      if (next == FiestaPhase.idle &&
          (prev == FiestaPhase.playing || prev == FiestaPhase.paused) &&
          ref.read(wasapiRecordProvider) &&
          ref.read(fiestaDjProvider).autoRecord) {
        ref.read(wasapiRecordProvider.notifier).toggleRecording(
          context,
          filePrefix: 'FiestaMix',
        );
      }
    });

    final files = dir.files.whereType<File>().toList();
    final double progress = s.duration.inMilliseconds > 0
        ? (s.position.inMilliseconds / s.duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    Widget label(String t) => Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Text(
        t,
        style: const TextStyle(
          color: DjStudioTheme.textHidden,
          fontSize: 10,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.1,
        ),
      ),
    );

    Widget chip(String text, bool selected, VoidCallback onTap) => ChoiceChip(
      label: Text(text, style: TextStyle(fontSize: compact ? 10 : 11)),
      selected: selected,
      selectedColor: _kFiesta.withValues(alpha: 0.35),
      backgroundColor: Colors.white10,
      labelStyle: TextStyle(color: selected ? Colors.white : Colors.white70),
      visualDensity: VisualDensity.compact,
      onSelected: (_) => onTap(),
    );

    Widget btn(String text, IconData icon, VoidCallback? onTap, {Color? color}) =>
        ElevatedButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 16),
          label: Text(text, style: const TextStyle(fontSize: 11)),
          style: ElevatedButton.styleFrom(
            backgroundColor: color ?? Colors.white10,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
        );

    return SingleChildScrollView(
      padding: EdgeInsets.all(compact ? 10 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.celebration, color: _kFiesta),
              const SizedBox(width: 8),
              const Text(
                'FIESTA DJ',
                style: TextStyle(
                  color: _kFiesta,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  s.status,
                  style: TextStyle(
                    color: s.mixing ? DjStudioTheme.syncActive : Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (showFolderButton) ...[
            label('CARPETA'),
            Row(
              children: [
                Expanded(
                  child: Text(
                    dir.currentPath.isEmpty
                        ? 'Selecciona una carpeta…'
                        : '${_name(dir.currentPath)}  ·  ${files.length} canciones',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                btn(
                  'Elegir',
                  Icons.folder_open,
                  dir.isProcessing
                      ? null
                      : () => ref.read(fiestaDjDirectoryProvider.notifier).loadDirectory(),
                ),
              ],
            ),
          ] else ...[
            label('CARPETA'),
            Text(
              dir.currentPath.isEmpty
                  ? 'Elige una carpeta en el explorador de la izquierda.'
                  : '${_name(dir.currentPath)}  ·  ${files.length} canciones',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
          label('SONANDO'),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: DjStudioTheme.bgPanel,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: s.mixing ? _kFiesta : Colors.white10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _name(s.currentPath),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 12,
                  children: [
                    Text(
                      s.currentBpm > 0 ? '${s.currentBpm.toStringAsFixed(1)} BPM' : 'BPM ?',
                      style: const TextStyle(color: DjStudioTheme.cyanAccent, fontSize: 12),
                    ),
                    Text(
                      'MAESTRO ${s.masterBpm > 0 ? s.masterBpm.toStringAsFixed(1) : '—'}',
                      style: const TextStyle(color: _kFiesta, fontSize: 12),
                    ),
                    Text(
                      s.currentOnGrid ? 'RITMO ALINEADO' : 'SIN REJILLA (cruce suave)',
                      style: TextStyle(
                        color: s.currentOnGrid ? DjStudioTheme.syncActive : Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: progress,
                  minHeight: 4,
                  color: _kFiesta,
                  backgroundColor: Colors.white10,
                ),
                const SizedBox(height: 4),
                Text(
                  '${_clock(s.position)} / ${_clock(s.duration)}',
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
                const Divider(color: Colors.white10, height: 18),
                Text(
                  'SIGUE: ${_name(s.nextPath)}'
                  '${s.nextBpm > 0 ? '  ·  ${s.nextBpm.toStringAsFixed(1)} BPM' : ''}',
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!s.isActive)
                btn(
                  s.phase == FiestaPhase.preparing ? 'PREPARANDO…' : 'INICIAR FIESTA',
                  Icons.play_arrow,
                  (files.length < 2 || s.phase == FiestaPhase.preparing)
                      ? null
                      : () async {
                          await notifier.startParty(files);
                          if (!context.mounted) return;
                          if (desktop &&
                              ref.read(fiestaDjProvider).isPlaying &&
                              ref.read(fiestaDjProvider).autoRecord &&
                              !ref.read(wasapiRecordProvider)) {
                            await ref
                                .read(wasapiRecordProvider.notifier)
                                .toggleRecording(context, filePrefix: 'FiestaMix');
                          }
                        },
                  color: _kFiesta,
                )
              else ...[
                btn(
                  s.isPlaying ? 'PAUSA' : 'SEGUIR',
                  s.isPlaying ? Icons.pause : Icons.play_arrow,
                  notifier.togglePause,
                  color: _kFiesta,
                ),
                btn('SIGUIENTE', Icons.skip_next, s.isPlaying ? notifier.skipNext : null),
                btn('OTRA', Icons.shuffle, notifier.reroll),
                btn(
                  'DETENER',
                  Icons.stop,
                  notifier.stopParty,
                  color: DjStudioTheme.alertCritical,
                ),
              ],
            ],
          ),
          label('ESTILO DE LA PISTA BASE'),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final st in FiestaStyle.values)
                chip(
                  st == FiestaStyle.auto && s.styleChoice == FiestaStyle.auto && s.isActive
                      ? 'AUTO · ${s.style.label}'
                      : st.label,
                  s.styleChoice == st,
                  () => notifier.setStyle(st),
                ),
            ],
          ),
          label('CUÁNDO SUENA LA BASE'),
          Wrap(
            spacing: 6,
            children: [
              chip('SOLO EN CRUCES', s.baseMode == FiestaBaseMode.transitions,
                  () => notifier.setBaseMode(FiestaBaseMode.transitions)),
              chip('SIEMPRE', s.baseMode == FiestaBaseMode.always,
                  () => notifier.setBaseMode(FiestaBaseMode.always)),
              chip('APAGADA', s.baseMode == FiestaBaseMode.off,
                  () => notifier.setBaseMode(FiestaBaseMode.off)),
            ],
          ),
          label('VOLUMEN DE LA BASE  ${(s.baseVolume * 100).round()}%'),
          Slider(
            value: s.baseVolume,
            onChanged: notifier.setBaseVolume,
            activeColor: _kFiesta,
          ),
          label('AJUSTE DE SINCRONÍA  ${s.latencyMs} ms'),
          Slider(
            value: s.latencyMs.toDouble(),
            min: -200,
            max: 300,
            divisions: 100,
            onChanged: (v) => notifier.setLatency(v.round()),
            activeColor: DjStudioTheme.cyanAccent,
          ),
          const Text(
            'Si al entrar la canción nueva el bombo "arrastra", mueve este ajuste.',
            style: TextStyle(color: Colors.white38, fontSize: 10),
          ),
          label('GRABAR LA MEZCLA'),
          if (desktop)
            Row(
              children: [
                Switch(
                  value: s.autoRecord,
                  onChanged: notifier.setAutoRecord,
                  activeThumbColor: _kFiesta,
                ),
                const Expanded(
                  child: Text(
                    'Grabar automáticamente al iniciar la fiesta',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
                btn(
                  recording ? 'DETENER REC' : 'REC',
                  recording ? Icons.stop_circle : Icons.fiber_manual_record,
                  () => ref
                      .read(wasapiRecordProvider.notifier)
                      .toggleRecording(context, filePrefix: 'FiestaMix'),
                  color: recording ? DjStudioTheme.alertCritical : Colors.white10,
                ),
              ],
            )
          else
            const Text(
              'La grabación de la mezcla solo está disponible en Windows y macOS: '
              'Android y iPhone no permiten capturar la salida de audio.',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

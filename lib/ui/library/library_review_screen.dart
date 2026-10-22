import 'package:flutter/material.dart';

import '../../providers/theme_provider.dart';
import '../../services/library/library_models.dart';

/// Revisión única: carpetas descubiertas, con conteo, para aceptar o quitar.
class LibraryReviewScreen extends StatefulWidget {
  final List<DiscoveredFolder> folders;

  const LibraryReviewScreen({super.key, required this.folders});

  @override
  State<LibraryReviewScreen> createState() => _LibraryReviewScreenState();
}

class _LibraryReviewScreenState extends State<LibraryReviewScreen> {
  late final Set<String> _checked = <String>{
    for (final DiscoveredFolder folder in widget.folders) folder.path,
  };

  @override
  Widget build(BuildContext context) {
    final bool wide = MediaQuery.sizeOf(context).width >= 800;
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: GatoMixTheme.bgDark,
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: EdgeInsets.fromLTRB(16, wide ? 16 : 10, 16, 10),
                decoration: const BoxDecoration(
                  color: GatoMixTheme.bgPanel,
                  border: Border(bottom: BorderSide(color: Color(0xFF2A2E37))),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'BIBLIOTECA',
                      style: TextStyle(
                        color: GatoMixTheme.deckA,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Carpetas encontradas',
                      style: TextStyle(
                        color: GatoMixTheme.textMain,
                        fontSize: wide ? 18 : 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Marca las que entran. No se vuelve a preguntar.',
                      style: TextStyle(
                        color: GatoMixTheme.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(child: _list(wide)),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  height: 40,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: GatoMixTheme.bgPanel,
                      foregroundColor: GatoMixTheme.syncActive,
                      side: const BorderSide(color: GatoMixTheme.syncActive),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    onPressed: () => Navigator.of(context).pop(_checked),
                    child: const Text(
                      'LISTO',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _list(bool wide) {
    if (widget.folders.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No se encontraron carpetas con audio.',
            textAlign: TextAlign.center,
            style: TextStyle(color: GatoMixTheme.textMuted, fontSize: 13),
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: widget.folders.length,
      itemBuilder: (BuildContext context, int index) {
        final DiscoveredFolder folder = widget.folders[index];
        final bool on = _checked.contains(folder.path);
        final int count = folder.trackCount;
        final String tracks = count == 1 ? '1 pista' : '$count pistas';
        return CheckboxListTile(
          dense: true,
          visualDensity: const VisualDensity(vertical: -2),
          value: on,
          activeColor: GatoMixTheme.syncActive,
          checkColor: GatoMixTheme.bgDark,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(
            folder.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: GatoMixTheme.textMain,
              fontSize: wide ? 14 : 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            tracks,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: GatoMixTheme.textMuted, fontSize: 11),
          ),
          onChanged: (bool? value) {
            setState(() {
              if (value == true) {
                _checked.add(folder.path);
              } else {
                _checked.remove(folder.path);
              }
            });
          },
        );
      },
    );
  }
}

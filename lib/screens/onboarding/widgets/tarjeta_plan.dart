import 'package:flutter/material.dart';

/// Tarjeta para la selección de planes en el onboarding.
class TarjetaPlan extends StatelessWidget {
  final String id;
  final String titulo;
  final String precio;
  final String subtitulo;
  final List<String>? beneficios;
  final bool bloqueado;
  final bool seleccionado;
  final VoidCallback? onTap;

  const TarjetaPlan({
    super.key,
    required this.id,
    required this.titulo,
    required this.precio,
    required this.subtitulo,
    this.beneficios,
    this.bloqueado = false,
    required this.seleccionado,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: bloqueado ? null : onTap,
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: seleccionado
              ? Colors.white
              : const Color(0x1EFFFFFF), // 12% opacidad
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: seleccionado
                ? Colors.white
                : const Color(0x40FFFFFF), // 25% opacidad
            width: 2,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Text(
                      titulo,
                      style: TextStyle(
                        color: seleccionado
                            ? const Color(0xFF111111)
                            : Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    if (bloqueado) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: const BoxDecoration(
                          color: Color(0x3DFFFFFF),
                          borderRadius: BorderRadius.all(Radius.circular(8)),
                        ),
                        child: const Text(
                          'PRÓXIMAMENTE',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 8,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                Text(
                  precio,
                  style: TextStyle(
                    color: seleccionado
                        ? const Color(0xFF111111)
                        : Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 22,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              subtitulo,
              style: TextStyle(
                color: seleccionado ? Colors.grey[700] : Colors.white70,
                fontSize: 13,
              ),
            ),
            if (beneficios != null && seleccionado) ...[
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: beneficios!.map((b) {
                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE3F2FD),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.check,
                          size: 12,
                          color: Color(0xFF2E86C1),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          b,
                          style: const TextStyle(
                            color: Color(0xFF2E86C1),
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

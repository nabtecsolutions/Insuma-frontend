import 'package:flutter/material.dart';

/// Secciones del configurador del equipo de cocina en el onboarding.
class SeccionEquipo extends StatelessWidget {
  final String titulo;
  final String descripcion;
  final List<Map<String, dynamic>> usuarios;
  final VoidCallback alAgregar;
  final Function(Map<String, dynamic>) alEliminar;

  const SeccionEquipo({
    super.key,
    required this.titulo,
    required this.descripcion,
    required this.usuarios,
    required this.alAgregar,
    required this.alEliminar,
  });

  @override
  Widget build(BuildContext context) {
    final esAdmin = titulo.contains('Administradores');
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: esAdmin
            ? const Color(0xD9000000)
            : const Color(0xEBFFFFFF), // negro 85% o blanco 92%
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    titulo,
                    style: TextStyle(
                      color: esAdmin ? Colors.white : Colors.black,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  Text(
                    descripcion,
                    style: TextStyle(
                      color: esAdmin ? Colors.white60 : Colors.black54,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
              TextButton(
                onPressed: alAgregar,
                style: TextButton.styleFrom(
                  backgroundColor: esAdmin ? Colors.white10 : Colors.black12,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  '+ Agregar',
                  style: TextStyle(
                    color: esAdmin ? Colors.white : Colors.black,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (usuarios.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                border: Border.all(
                  color: esAdmin ? Colors.white24 : Colors.grey[300]!,
                  style: BorderStyle.solid,
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Center(
                child: Text(
                  'Sin usuarios agregados.',
                  style: TextStyle(
                    color: esAdmin ? Colors.white38 : Colors.black38,
                    fontSize: 12,
                  ),
                ),
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: usuarios.map((u) {
                return Chip(
                  backgroundColor: esAdmin
                      ? Colors.grey[900]
                      : Colors.grey[200],
                  side: BorderSide.none,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        esAdmin ? Icons.lock : Icons.person,
                        size: 14,
                        color: esAdmin ? Colors.white70 : Colors.black54,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        u['nombre'] as String,
                        style: TextStyle(
                          color: esAdmin ? Colors.white : Colors.black,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  deleteIcon: Icon(
                    Icons.close,
                    size: 14,
                    color: esAdmin ? Colors.white60 : Colors.black54,
                  ),
                  onDeleted: () => alEliminar(u),
                );
              }).toList(),
            ),
        ],
      ),
    );
  }
}

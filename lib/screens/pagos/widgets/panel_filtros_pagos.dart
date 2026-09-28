import 'package:flutter/material.dart';

import '../../../constants/categorias.dart';
import '../../../database/database.dart';
import '../../../theme/insuma_colors.dart';
import '../../../utils/filtros_pagos.dart';

/// El desplegable de filtros de la pantalla de Pagos (#237), montado como
/// `endDrawer` (el precedente es el menú lateral del dashboard — no hay otro
/// endDrawer en la app).
///
/// NO filtra ni cuenta nada (mismo contrato que `BarraFiltrosPedidos`): emite
/// [CriteriosFiltroPagos] por [alCambiar] y muestra los contadores que la
/// pantalla ya calculó. Es `Stateful` únicamente porque es dueño del
/// `TextEditingController` del buscador: "Limpiar" tiene que vaciar también el
/// TEXTO VISIBLE, no solo el criterio (#170).
class PanelFiltrosPagos extends StatefulWidget {
  const PanelFiltrosPagos({
    super.key,
    required this.criterios,
    required this.proveedores,
    required this.cantidadProveedores,
    required this.cantidadRecepciones,
    required this.alCambiar,
  });

  final CriteriosFiltroPagos criterios;

  /// Los proveedores ACTIVOS del negocio (para la multi-selección).
  final List<Proveedore> proveedores;

  /// Resultados ya filtrados, calculados por la pantalla en el mismo build.
  final int cantidadProveedores;
  final int cantidadRecepciones;

  final ValueChanged<CriteriosFiltroPagos> alCambiar;

  @override
  State<PanelFiltrosPagos> createState() => _PanelFiltrosPagosState();
}

class _PanelFiltrosPagosState extends State<PanelFiltrosPagos> {
  late final TextEditingController _textoCtrl;

  @override
  void initState() {
    super.initState();
    // Sembrado UNA vez acá y no en build: el drawer se re-renderiza con cada
    // notifyListeners del controlador (recepciones que llegan por sync), y
    // reescribir el texto en build haría saltar el cursor mientras se tipea.
    _textoCtrl = TextEditingController(text: widget.criterios.texto);
  }

  @override
  void dispose() {
    _textoCtrl.dispose();
    super.dispose();
  }

  void _emitir(CriteriosFiltroPagos c) => widget.alCambiar(c);

  void _limpiar() {
    _textoCtrl.clear();
    _emitir(CriteriosFiltroPagos.vacio);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.criterios;
    // Valor SANEADO contra las opciones vigentes (lección #170): una categoría
    // que ya no exista en el catálogo tiraría el assert del dropdown, que en
    // el Chrome del PO es una pantalla roja.
    final categorias = CategoriasApp.categoriasProveedor;
    final categoriaVigente =
        (c.categoria != null && categorias.contains(c.categoria))
        ? c.categoria
        : null;

    return Drawer(
      backgroundColor: Colors.white,
      child: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Filtros',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.black87,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Cerrar filtros',
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _textoCtrl,
                    style: const TextStyle(fontSize: 13, color: Colors.black87),
                    decoration: InputDecoration(
                      hintText: 'Buscar por nombre o CUIT…',
                      prefixIcon: const Icon(Icons.search, size: 18),
                      isDense: true,
                      suffixIcon: c.texto.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Borrar búsqueda',
                              icon: const Icon(Icons.clear, size: 16),
                              onPressed: () {
                                _textoCtrl.clear();
                                _emitir(c.copyWith(texto: ''));
                              },
                            ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onChanged: (v) => _emitir(c.copyWith(texto: v)),
                  ),
                  const SizedBox(height: 16),
                  _rotulo('Categoría'),
                  // DropdownButton y JAMÁS DropdownButtonFormField: el assert
                  // de valor-fuera-de-opciones de ese widget es la pantalla
                  // roja de #170.
                  DropdownButton<String>(
                    isExpanded: true,
                    value: categoriaVigente ?? 'Todos',
                    style: const TextStyle(fontSize: 13, color: Colors.black87),
                    items: [
                      for (final cat in categorias)
                        DropdownMenuItem(value: cat, child: Text(cat)),
                    ],
                    onChanged: (v) => _emitir(
                      c.copyWith(
                        categoria: (v == null || v == 'Todos') ? null : v,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _rotulo('Ordenar por deuda'),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    children: [
                      _chipOrden('Mayor deuda primero', true),
                      _chipOrden('Menor deuda primero', false),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _rotulo('Proveedores'),
                  if (widget.proveedores.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'No hay proveedores cargados.',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    )
                  else
                    ...widget.proveedores.map(
                      (p) => CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(
                          p.nombre,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Colors.black87,
                          ),
                        ),
                        value: c.proveedorIds.contains(p.id),
                        onChanged: (marcado) {
                          final ids = {...c.proveedorIds};
                          if (marcado == true) {
                            ids.add(p.id);
                          } else {
                            ids.remove(p.id);
                          }
                          _emitir(c.copyWith(proveedorIds: ids));
                        },
                      ),
                    ),
                ],
              ),
            ),
            // Pie fijo: el resultado y la salida. Queda fuera del ListView para
            // que se vea aunque la lista de proveedores sea larga.
            Container(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: InsumaColors.cardBorderLight),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${widget.cantidadProveedores} proveedor(es) · '
                      '${widget.cantidadRecepciones} recepción(es)',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                  ),
                  TextButton(
                    onPressed: c.hayAlguno ? _limpiar : null,
                    child: const Text('Limpiar'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rotulo(String t) => Text(
    t,
    style: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.bold,
      color: Colors.grey[600],
      letterSpacing: 0.5,
    ),
  );

  /// Tri-estado con dos chips: tocar el elegido lo des-elige (vuelve al orden
  /// natural), como el toggle de orden de `BarraFiltrosPedidos`.
  Widget _chipOrden(String etiqueta, bool valor) {
    final c = widget.criterios;
    final elegido = c.deudaMayorPrimero == valor;
    return ChoiceChip(
      label: Text(etiqueta, style: const TextStyle(fontSize: 12)),
      selected: elegido,
      selectedColor: InsumaColors.primaryBlue.withValues(alpha: 0.15),
      onSelected: (_) =>
          _emitir(c.copyWith(deudaMayorPrimero: elegido ? null : valor)),
    );
  }
}

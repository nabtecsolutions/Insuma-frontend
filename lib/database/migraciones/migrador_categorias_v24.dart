import 'package:drift/drift.dart';

import '../../utils/id_determinista.dart';
import '../database.dart';

/// Paso v23 -> v24 (#262, Fase 3): backfill del rediseno insumos-por-categoria.
///
/// Vive aparte de `BaseDatosApp` por responsabilidad unica y para poder testearlo
/// solo, con una base en memoria. Espeja el molde de [MigradorInsumosV14] pero
/// resuelve un problema DISTINTO, y por eso NO encola nada (ver mas abajo).
///
/// Que hace:
///  1. Siembra el catalogo `categorias` con una fila por cada nombre distinto que
///     hoy vive como texto libre en `insumos.categoria` y en el rubro
///     `proveedores.categoria` (vocabulario UNIFICADO, decision del PO), mas una
///     "Sin categoria" por negocio.
///  2. Reapunta `insumos.categoria_id` a la categoria que le corresponde (o a
///     "Sin categoria" si el texto venia vacio).
///  3. Siembra `proveedor_categorias` (que categorias suministra cada proveedor)
///     desde DOS ejes: el rubro propio del proveedor y los vinculos vivos
///     `insumo_proveedores` (el insumo aporta su categoria).
///
/// Por que NO encola (a diferencia de [MigradorInsumosV14]):
///  - V14 encolaba porque la fila puente NO existia en ninguna parte: si el
///    cliente no la subia, el vinculo se perdia para siempre.
///  - Aca no se pierde nada. El insumo pendiente (creado offline) YA lleva su
///    `categoria` (texto) en el payload congelado; el servidor recibe todo lo
///    necesario para derivar `categoria_id` por su cuenta (backfill SQL espejo).
///    Es una brecha de reconciliacion, no perdida de dato: se cierra con un
///    segundo pase (la proxima edicion del insumo ya viaja con `categoria_id`,
///    porque el mapeador lo incluye desde la Fase 2) y, mientras tanto, en
///    lectura un insumo con `categoria_id` nulo se resuelve a "Sin categoria".
///  Todo entra como `sincronizado`: cliente y servidor convergen SOLOS gracias a
///  los ids deterministas (ver [IdDeterminista]).
///
/// Por que NO se toca `version`: el backfill no es una edicion del usuario.
/// Bumpearla dispararia conflictos falsos contra ediciones locales en vuelo
/// (mismo criterio que el PASO 1 de HU-138).
class MigradorCategoriasV24 {
  const MigradorCategoriasV24._();

  /// Nombre de display de la categoria paraguas para insumos sin categoria.
  static const String displaySinCategoria = 'Sin categoría';

  /// Clave normalizada de "Sin categoria" (ya en la forma que produce [_clave]).
  /// Es un literal a proposito: cliente y servidor derivan el MISMO id solo si
  /// estos bytes coinciden byte a byte con lo que emite el SQL. Un test lo fija.
  static const String claveSinCategoria = 'sin categoría';

  /// Backfill completo. IDEMPOTENTE: todos los ids son deterministas y las
  /// escrituras usan `insertOnConflictUpdate`, asi que correrlo dos veces -o que
  /// ademas lo corra el servidor- converge a las mismas filas.
  static Future<void> backfill(BaseDatosApp db) async {
    // Guarda de esquema parcial: los tests de migracion v15-v19 arman un esquema
    // minimo SIN estas tablas y llegan igual a este step. Sin `insumos` o
    // `proveedores` no hay nada que migrar; se sale sin tocar nada.
    if (!await _existeTabla(db, 'insumos')) return;
    if (!await _existeTabla(db, 'proveedores')) return;
    final hayVinculos = await _existeTabla(db, 'insumo_proveedores');

    final ahora = DateTime.now();

    // -- 1. Sembrar el catalogo de categorias --------------------------------
    // Fuentes unificadas: el texto libre del insumo y el rubro del proveedor.
    final fuentes = await db
        .customSelect(
          "SELECT negocio_id AS negocio_id, categoria AS nombre, id AS src_id "
          "FROM insumos WHERE categoria IS NOT NULL AND trim(categoria) <> '' "
          "UNION ALL "
          "SELECT negocio_id, categoria, id "
          "FROM proveedores WHERE categoria IS NOT NULL AND trim(categoria) <> ''",
        )
        .get();

    // Agrupa por (negocio, clave). El display GANADOR es el nombre del registro
    // fuente de MENOR id: es el unico campo garantizado byte-identico entre
    // cliente y servidor (mismo criterio de "superviviente" que HU-138 PASO 2),
    // asi que los dos lados eligen el MISMO display sin coordinarse.
    final grupos = <String, _GrupoCategoria>{};
    for (final f in fuentes) {
      final negocioId = f.read<String>('negocio_id');
      final crudo = f.read<String>('nombre');
      final srcId = f.read<String>('src_id');
      final clave = _clave(crudo);
      if (clave.isEmpty) continue; // por si el texto era solo invisibles
      final k = '$negocioId $clave';
      final actual = grupos[k];
      if (actual == null || srcId.compareTo(actual.srcIdGanador) < 0) {
        grupos[k] = _GrupoCategoria(
          negocioId: negocioId,
          clave: clave,
          display: _display(crudo),
          srcIdGanador: srcId,
        );
      }
    }

    // "Sin categoria" por cada negocio que tenga insumos o proveedores.
    final negocios = <String>{
      ...await _negociosDe(db, 'insumos'),
      ...await _negociosDe(db, 'proveedores'),
    };

    await db.batch((b) {
      for (final g in grupos.values) {
        b.insert(
          db.categorias,
          _companionCategoria(g.negocioId, g.clave, g.display, ahora),
          onConflict: DoUpdate(
            (_) => _companionCategoria(g.negocioId, g.clave, g.display, ahora),
          ),
        );
      }
      for (final negocioId in negocios) {
        b.insert(
          db.categorias,
          _companionCategoria(
            negocioId,
            claveSinCategoria,
            displaySinCategoria,
            ahora,
          ),
          onConflict: DoUpdate(
            (_) => _companionCategoria(
              negocioId,
              claveSinCategoria,
              displaySinCategoria,
              ahora,
            ),
          ),
        );
      }
    });

    // -- 2. Reapuntar insumos.categoria_id -----------------------------------
    // Un insumo sin texto de categoria cae en "Sin categoria" de su negocio.
    // Se escribe SOLO la columna `categoria_id`: no se toca `version`,
    // `estado_sync` ni `updated_at` (el backfill no es una edicion del usuario).
    final insumos = await db
        .customSelect(
          'SELECT id AS id, negocio_id AS negocio_id, categoria AS categoria '
          'FROM insumos',
        )
        .get();
    await db.batch((b) {
      for (final i in insumos) {
        final negocioId = i.read<String>('negocio_id');
        final texto = i.read<String?>('categoria');
        final clave = (texto == null || _clave(texto).isEmpty)
            ? claveSinCategoria
            : _clave(texto);
        final categoriaId = IdDeterminista.categoria(negocioId, clave);
        b.update(
          db.insumos,
          InsumosCompanion(categoriaId: Value(categoriaId)),
          where: (t) => t.id.equals(i.read<String>('id')),
        );
      }
    });

    // -- 3. Sembrar proveedor_categorias -------------------------------------
    // Eje A: el rubro propio del proveedor. Eje B: los vinculos vivos
    // insumo<->proveedor (el insumo aporta la categoria que ya le pusimos
    // arriba). Se deduplica por (proveedor, categoria) -- el id determinista del
    // par lo garantiza aunque los dos ejes propongan el mismo vinculo.
    final vinculos = <String, _Vinculo>{};

    final proveedores = await db
        .customSelect(
          'SELECT id AS id, negocio_id AS negocio_id, categoria AS categoria '
          "FROM proveedores WHERE categoria IS NOT NULL AND trim(categoria) <> ''",
        )
        .get();
    for (final p in proveedores) {
      final proveedorId = p.read<String>('id');
      final negocioId = p.read<String>('negocio_id');
      final clave = _clave(p.read<String>('categoria'));
      if (clave.isEmpty) continue;
      final categoriaId = IdDeterminista.categoria(negocioId, clave);
      _agregarVinculo(vinculos, negocioId, proveedorId, categoriaId);
    }

    if (hayVinculos) {
      // `insumos.categoria_id` ya quedo seteado en el paso 2, asi que se lee
      // directo de ahi (incluye "Sin categoria" para insumos sin texto).
      final links = await db
          .customSelect(
            'SELECT ip.proveedor_id AS proveedor_id, i.negocio_id AS negocio_id, '
            'i.categoria_id AS categoria_id '
            'FROM insumo_proveedores ip '
            'JOIN insumos i ON i.id = ip.insumo_id '
            'WHERE ip.activo = 1 AND i.categoria_id IS NOT NULL',
          )
          .get();
      for (final l in links) {
        _agregarVinculo(
          vinculos,
          l.read<String>('negocio_id'),
          l.read<String>('proveedor_id'),
          l.read<String>('categoria_id'),
        );
      }
    }

    await db.batch((b) {
      for (final v in vinculos.values) {
        b.insert(
          db.proveedorCategorias,
          _companionVinculo(v, ahora),
          onConflict: DoUpdate((_) => _companionVinculo(v, ahora)),
        );
      }
    });
  }

  /// Agrega (o pisa, es idempotente) un vinculo proveedor<->categoria al mapa,
  /// con clave = id determinista del par para deduplicar entre ejes.
  static void _agregarVinculo(
    Map<String, _Vinculo> destino,
    String negocioId,
    String proveedorId,
    String categoriaId,
  ) {
    final id = IdDeterminista.parProveedorCategoria(proveedorId, categoriaId);
    destino[id] = _Vinculo(
      id: id,
      negocioId: negocioId,
      proveedorId: proveedorId,
      categoriaId: categoriaId,
    );
  }

  static CategoriasCompanion _companionCategoria(
    String negocioId,
    String clave,
    String display,
    DateTime ahora,
  ) => CategoriasCompanion.insert(
    id: IdDeterminista.categoria(negocioId, clave),
    negocioId: negocioId,
    nombre: display,
    activo: const Value(true),
    fechaCreacion: Value(ahora),
    fechaActualizacion: Value(ahora),
    estadoSync: const Value('sincronizado'),
  );

  static ProveedorCategoriasCompanion _companionVinculo(
    _Vinculo v,
    DateTime ahora,
  ) => ProveedorCategoriasCompanion.insert(
    id: v.id,
    negocioId: v.negocioId,
    proveedorId: v.proveedorId,
    categoriaId: v.categoriaId,
    activo: const Value(true),
    fechaCreacion: Value(ahora),
    fechaActualizacion: Value(ahora),
    estadoSync: const Value('sincronizado'),
  );

  /// Forma de DISPLAY del nombre: colapsa espacios (incluidos los invisibles
  /// NBSP/espacio fino/BOM) y recorta bordes, PRESERVANDO mayusculas y acentos.
  ///
  /// Equivalente EXACTO en Postgres (HU-138, sin `lower`):
  ///   btrim(regexp_replace(translate(nombre, U&'\00A0\202F\FEFF','   '), '\s+',' ','g'))
  static String _display(String s) {
    // translate(...): los tres invisibles del SQL, a espacio normal.
    final traducido = s
        .replaceAll(' ', ' ') // NBSP
        .replaceAll(' ', ' ') // NARROW NO-BREAK SPACE
        .replaceAll('﻿', ' '); // ZERO WIDTH NO-BREAK SPACE / BOM
    // Colapsa SOLO whitespace ASCII, igual que el \s de Postgres (no el \s
    // Unicode de Dart, que ademas comeria U+2003 y divergiria del SQL).
    final colapsado = traducido.replaceAll(RegExp(r'[ \t\n\r\f\x0B]+'), ' ');
    // btrim con default recorta SOLO espacios; tras el colapso los bordes son
    // como mucho un espacio simple.
    return colapsado.replaceAll(RegExp(r'^ +| +$'), '');
  }

  /// Clave de UNICIDAD/derivacion del id: el display en minusculas.
  ///
  /// Equivalente EXACTO en Postgres: `lower(<display>)`. `toLowerCase()` de Dart
  /// y `lower()` de Postgres coinciden sobre el vocabulario real de la app
  /// (ASCII + acentos y n del espanol); si algun dia entra un alfabeto exotico,
  /// revisar esta equivalencia antes de confiar en la convergencia dual.
  static String _clave(String s) => _display(s).toLowerCase();

  static Future<bool> _existeTabla(BaseDatosApp db, String nombre) async =>
      (await db
              .customSelect(
                "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1",
                variables: [Variable<String>(nombre)],
              )
              .get())
          .isNotEmpty;

  static Future<Set<String>> _negociosDe(BaseDatosApp db, String tabla) async {
    final filas = await db
        .customSelect('SELECT DISTINCT negocio_id AS negocio_id FROM $tabla')
        .get();
    return filas.map((f) => f.read<String>('negocio_id')).toSet();
  }
}

/// Grupo (negocio, clave) durante la siembra del catalogo.
class _GrupoCategoria {
  final String negocioId;
  final String clave;
  final String display;
  final String srcIdGanador;
  const _GrupoCategoria({
    required this.negocioId,
    required this.clave,
    required this.display,
    required this.srcIdGanador,
  });
}

/// Vinculo proveedor<->categoria deduplicado durante la siembra de la puente.
class _Vinculo {
  final String id;
  final String negocioId;
  final String proveedorId;
  final String categoriaId;
  const _Vinculo({
    required this.id,
    required this.negocioId,
    required this.proveedorId,
    required this.categoriaId,
  });
}
